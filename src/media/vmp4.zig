//! On-the-fly seekable MP4 with no temp file.
//!
//! A single MP4 seeks by byte offset, so the receiver needs the `moov` index up
//! front and the server must answer any byte range. We build that virtually:
//!
//!   1. Measurement pass: drive the real `mp4` muxer (moov-at-end, no faststart,
//!      video copied verbatim, audio re-encoded to AAC) over a custom SEEKABLE
//!      AVIO that discards the bulk `mdat` payload but captures the small head
//!      (ftyp + mdat box header) and the `moov`, and records a map of
//!      output-offset -> source for every sample. `av_write_frame` (not
//!      interleaved) writes each packet's bytes in order, so `avio_tell`
//!      before and after bounds them.
//!   2. Serving: a byte range is answered from the head buffer, the `moov`
//!      buffer, the video (see below), or an in-RAM AAC buffer (audio). Nothing
//!      hits disk.
//!
//! Video is copied, so each sample's output bytes must be reproducible at serve
//! time. ISO-BMFF sources read the sample straight from the file by byte offset
//! (`pkt.pos`). Other containers (Matroska, where `pkt.pos` points at the block,
//! not the frame) re-demux the source and locate the sample by PTS. If neither
//! works (no video, `pkt.pos < 0` in BMFF), `build` fails with an
//! `UnsuitableError` and the caller falls back to a stream.

const std = @import("std");
const Io = std.Io;
const av = @import("av");
const extra = @import("../av_extra.zig");
const pipeline = @import("pipeline.zig");

const VideoSample = struct { pts: i64, dts: i64, duration: i64, size: u32, pos: i64, key: bool };
const AacSample = struct { pts: i64, dts: i64, duration: i64, buf_off: usize, size: u32 };

/// One contiguous run of output bytes and where to read them from.
const MapEntry = struct {
    out_start: u64,
    len: u32,
    src: union(enum) {
        /// Offset into the AAC buffer.
        audio: usize,
        /// Video in `pread` mode: source file byte offset.
        file_pos: u64,
        /// Video in `redemux` mode: the sample's PTS.
        pts: i64,
    },
};

/// The seekable AVIO backing: keeps only the head and moov, discards payload.
const Capture = struct {
    gpa: std.mem.Allocator,
    prefix: std.ArrayList(u8) = .empty,
    moov: std.ArrayList(u8) = .empty,
    pos: u64 = 0,
    size: u64 = 0,
    /// End of the head (= first sample's output offset). Starts at max so every
    /// write before the first sample is captured into `prefix`; set to the real
    /// value after the first frame, after which payload is discarded.
    container_end: u64 = std.math.maxInt(u64),
    /// Where the moov begins, set at trailer time; max until then.
    mdat_end: u64 = std.math.maxInt(u64),
    failed: bool = false,

    const Avio = extra.WriteAvio(Capture, onWrite);

    fn writeInto(gpa: std.mem.Allocator, list: *std.ArrayList(u8), at: u64, bytes: []const u8) !void {
        if (at + bytes.len > list.items.len) {
            try list.resize(gpa, @intCast(at + bytes.len));
        }
        @memcpy(list.items[@intCast(at)..][0..bytes.len], bytes);
    }

    fn onWrite(c: *Capture, bytes: []const u8) !void {
        const off = c.pos;
        if (off >= c.mdat_end) {
            // Positional, not append: the muxer seeks back to patch the moov's
            // own size after writing its contents.
            try writeInto(c.gpa, &c.moov, off - c.mdat_end, bytes);
        } else if (off < c.container_end) {
            // Head bytes (ftyp + mdat header); anything past the first sample's
            // start is bulk payload.
            const take = @min(@as(u64, bytes.len), c.container_end - off);
            try writeInto(c.gpa, &c.prefix, off, bytes[0..@intCast(take)]);
        } // else: bulk payload, discarded
        c.pos = off + bytes.len;
        if (c.pos > c.size) c.size = c.pos;
    }

    fn seekCb(userdata: ?*anyopaque, offset: i64, whence: av.SEEK) callconv(.c) i64 {
        const c: *Capture = @ptrCast(@alignCast(userdata.?));
        if (whence.SIZE) return @intCast(c.size);
        switch (whence.mode) {
            .SET => c.pos = @intCast(offset),
            .CUR => c.pos = @intCast(@as(i64, @intCast(c.pos)) + offset),
            .END => c.pos = @intCast(@as(i64, @intCast(c.size)) + offset),
        }
        return @intCast(c.pos);
    }
};

const AudioCollector = struct {
    gpa: std.mem.Allocator,
    aac: *std.ArrayList(u8),
    samples: *std.ArrayList(AacSample),
    max_size: u32 = 0,

    fn cb(ctx: *anyopaque, pkt: *av.Packet) anyerror!void {
        const self: *AudioCollector = @ptrCast(@alignCast(ctx));
        const size: u32 = @intCast(pkt.size);
        self.max_size = @max(self.max_size, size);
        const off = self.aac.items.len;
        try self.aac.appendSlice(self.gpa, pkt.data[0..size]);
        try self.samples.append(self.gpa, .{
            .pts = pkt.pts,
            .dts = if (pkt.dts == av.NOPTS_VALUE) pkt.pts else pkt.dts,
            .duration = pkt.duration,
            .buf_off = off,
            .size = size,
        });
    }
};

/// Serve-time video demuxer for `redemux` mode. Holds one sample at a time and
/// locates the requested one by PTS (unique per frame, unlike DTS which may be
/// unset for the leading B-frames). A forward read is one packet; a jump seeks.
/// Serialized by a mutex since the HTTP server may open parallel connections.
const VideoReader = struct {
    gpa: std.mem.Allocator,
    io: Io,
    ic: *av.FormatContext,
    stream_index: c_int,
    pkt: *av.Packet,
    have: bool = false,
    cur_pts: i64 = 0,
    mutex: std.Io.Mutex = .init,

    /// Takes over `ic` (already read through by the build pass) and rewinds it.
    fn adopt(gpa: std.mem.Allocator, io: Io, ic: *av.FormatContext, stream_index: usize) !*VideoReader {
        const self = try gpa.create(VideoReader);
        errdefer gpa.destroy(self);
        const pkt = try av.Packet.alloc();
        errdefer pkt.free();
        extra.discardOthers(ic, &.{stream_index});
        try ic.seek_frame(@intCast(stream_index), 0, extra.AVSEEK_FLAG_BACKWARD);
        self.* = .{ .gpa = gpa, .io = io, .ic = ic, .stream_index = @intCast(stream_index), .pkt = pkt };
        return self;
    }

    fn deinit(self: *VideoReader) void {
        self.pkt.free();
        self.ic.close_input();
        self.gpa.destroy(self);
    }

    /// Copies `dest.len` bytes at `off` within the video sample whose PTS is
    /// `pts` (its size must be `expect_size`) into `dest`.
    fn read(self: *VideoReader, pts: i64, expect_size: u32, off: usize, dest: []u8) !void {
        try self.mutex.lock(self.io);
        defer self.mutex.unlock(self.io);
        try self.locate(pts);
        if (@as(u32, @intCast(self.pkt.size)) != expect_size) return error.SampleSizeChanged;
        @memcpy(dest, self.pkt.data[off..][0..dest.len]);
    }

    fn locate(self: *VideoReader, pts: i64) !void {
        if (self.have and self.cur_pts == pts) return; // same sample, another slice
        try self.advance(); // sequential fast path: the next packet is usually it
        if (self.cur_pts == pts) return;
        // A jump: seek to the keyframe at/before this PTS and scan forward.
        try self.ic.seek_frame(self.stream_index, pts, extra.AVSEEK_FLAG_BACKWARD);
        self.have = false;
        var guard: usize = 0;
        while (true) : (guard += 1) {
            if (guard > 1_000_000) return error.SampleNotFound;
            try self.advance();
            if (self.cur_pts == pts) return;
        }
    }

    fn advance(self: *VideoReader) !void {
        while (true) {
            self.pkt.unref();
            self.ic.read_frame(self.pkt) catch |err| switch (err) {
                error.EndOfFile => return error.SampleNotFound,
                else => return err,
            };
            if (self.pkt.stream_index != self.stream_index) continue;
            self.cur_pts = if (self.pkt.pts == av.NOPTS_VALUE) self.pkt.dts else self.pkt.pts;
            self.have = true;
            return;
        }
    }
};

/// How video sample bytes are fetched at serve time.
const VideoSource = union(enum) {
    /// ISO-BMFF: read the sample straight from the source file by byte offset.
    pread: Io.File,
    /// Other containers (Matroska): the file offset is unreliable, so re-demux
    /// the source to the sample (matched by PTS) and copy its data.
    redemux: *VideoReader,
};

pub const VMp4 = struct {
    gpa: std.mem.Allocator,
    io: Io,
    video: VideoSource,
    prefix: []u8,
    moov: []u8,
    aac: []u8,
    map: []MapEntry,
    container_end: u64,
    mdat_end: u64,
    total: u64,

    pub fn deinit(vm: *VMp4) void {
        switch (vm.video) {
            .pread => |f| f.close(vm.io),
            .redemux => |r| r.deinit(),
        }
        vm.gpa.free(vm.prefix);
        vm.gpa.free(vm.moov);
        vm.gpa.free(vm.aac);
        vm.gpa.free(vm.map);
        vm.gpa.destroy(vm);
    }

    /// The map is contiguous over [container_end, mdat_end); find the run holding `o`.
    fn findEntry(vm: *const VMp4, o: u64) ?*const MapEntry {
        const Cmp = struct {
            fn order(offset: u64, e: MapEntry) std.math.Order {
                if (offset < e.out_start) return .lt;
                if (offset >= e.out_start + e.len) return .gt;
                return .eq;
            }
        };
        const i = std.sort.binarySearch(MapEntry, vm.map, o, Cmp.order) orelse return null;
        return &vm.map[i];
    }

    /// Fills `dest` with the virtual file's bytes starting at `offset`.
    pub fn readInto(vm: *VMp4, offset: u64, dest: []u8) !void {
        var done: usize = 0;
        while (done < dest.len) {
            const o = offset + done;
            if (o >= vm.total) return error.OutOfRange;
            const want: u64 = dest.len - done;
            if (o < vm.container_end) {
                const take = @min(want, vm.container_end - o);
                @memcpy(dest[done..][0..@intCast(take)], vm.prefix[@intCast(o)..][0..@intCast(take)]);
                done += @intCast(take);
            } else if (o < vm.mdat_end) {
                const e = vm.findEntry(o) orelse return error.MapGap;
                const delta = o - e.out_start;
                const take = @min(want, e.len - delta);
                const slice = dest[done..][0..@intCast(take)];
                switch (e.src) {
                    .audio => |buf_off| @memcpy(slice, vm.aac[buf_off + @as(usize, @intCast(delta)) ..][0..slice.len]),
                    .file_pos => |pos| {
                        const got = try vm.video.pread.readPositionalAll(vm.io, slice, pos + delta);
                        if (got < slice.len) return error.ShortRead;
                    },
                    .pts => |pts| try vm.video.redemux.read(pts, e.len, @intCast(delta), slice),
                }
                done += @intCast(take);
            } else {
                const take = @min(want, vm.total - o);
                @memcpy(dest[done..][0..@intCast(take)], vm.moov[@intCast(o - vm.mdat_end)..][0..@intCast(take)]);
                done += @intCast(take);
            }
        }
    }
};

/// Fills any NOPTS video DTS in place so the muxer gets monotonic timestamps:
/// the leading unset ones extrapolate backward from the first real DTS.
/// libavformat's own filler is deprecated, so this stays hand-rolled.
fn fillVideoDts(samples: []VideoSample) void {
    const j = for (samples, 0..) |v, i| {
        if (v.dts != av.NOPTS_VALUE) break i;
    } else {
        // No DTS anywhere: use PTS.
        for (samples) |*v| v.dts = v.pts;
        return;
    };
    const step: i64 = if (j + 1 < samples.len and samples[j + 1].dts != av.NOPTS_VALUE)
        samples[j + 1].dts - samples[j].dts
    else if (samples[j].duration > 0) samples[j].duration else 1;
    var i = j;
    while (i > 0) : (i -= 1) samples[i - 1].dts = samples[i].dts - step;
    var k = j + 1;
    while (k < samples.len) : (k += 1) {
        if (samples[k].dts == av.NOPTS_VALUE) {
            const st = if (samples[k].duration > 0) samples[k].duration else step;
            samples[k].dts = samples[k - 1].dts + st;
        }
    }
}

/// Why a source cannot be served as a virtual MP4; the caller falls back to a
/// stream on any of these.
pub const UnsuitableError = error{
    NoVideoStream,
    NoAudioStream,
    /// A video packet has no size or, for ISO-BMFF, no file offset.
    VideoNotAddressable,
    /// The muxer wrote more than one sample's bytes for a packet, so output
    /// offsets could not be attributed.
    MuxerInterleaved,
};

/// Builds the virtual MP4 for `path`. An `UnsuitableError` means the source
/// cannot be served this way (no video, unreliable byte positions, ...).
pub fn build(gpa: std.mem.Allocator, io: Io, path: []const u8) !*VMp4 {
    const ic = try extra.openInput(gpa, path);
    var ic_adopted = false; // by the VideoReader, which then owns it
    defer if (!ic_adopted) ic.close_input();

    const video_index: usize = if (ic.find_best_stream(.VIDEO, -1, -1)) |v| @intCast(v[0]) else |_| return error.NoVideoStream;
    const audio_index: usize = if (ic.find_best_stream(.AUDIO, -1, -1)) |a| @intCast(a[0]) else |_| return error.NoAudioStream;
    extra.discardOthers(ic, &.{ video_index, audio_index });
    const in_video = ic.streams[video_index];
    const in_audio = ic.streams[audio_index];
    const in_vtb = in_video.time_base;

    // ISO-BMFF video reads straight from the file by byte offset; other
    // containers (Matroska) re-demux at serve time, since pkt.pos is unreliable.
    const is_bmff = extra.matchName("mov", ic.iformat.name);

    const at = try pipeline.openStereoAac(in_audio.codecpar);
    defer at.dec.free();
    defer at.enc.free();
    const dec = at.dec;
    const enc = at.enc;
    const enc_tb = enc.time_base;

    // --- output muxer over the capturing seekable AVIO -----------------------
    var cap: Capture = .{ .gpa = gpa };
    defer cap.prefix.deinit(gpa);
    defer cap.moov.deinit(gpa);

    const oc = try extra.allocOutputContext("mp4");
    defer av.avformat_free_context(oc);
    const out_video_index = (try extra.addCopiedStream(oc, in_video.codecpar, in_vtb)).index;
    const out_audio_index = (try extra.addEncodedStream(oc, enc)).index;

    const avio = try Capture.Avio.alloc(&cap, Capture.seekCb);
    defer av.IOContext.free(avio);
    oc.pb = avio;

    // --- phase A: collect video metadata + encoded audio ---------------------
    var video: std.ArrayList(VideoSample) = .empty;
    defer video.deinit(gpa);
    var aac_samples: std.ArrayList(AacSample) = .empty;
    defer aac_samples.deinit(gpa);
    var aac_buf: std.ArrayList(u8) = .empty;
    errdefer aac_buf.deinit(gpa);

    // Size the AAC buffers from the duration so they rarely regrow.
    const duration = extra.durationSeconds(ic);
    if (duration) |dur_s| if (dur_s > 0) {
        const frame_size: f64 = if (enc.frame_size > 0) @floatFromInt(enc.frame_size) else 1024;
        aac_buf.ensureTotalCapacity(gpa, @intFromFloat(dur_s * @as(f64, @floatFromInt(enc.bit_rate)) / 8.0)) catch {};
        aac_samples.ensureTotalCapacity(gpa, @intFromFloat(dur_s * @as(f64, @floatFromInt(enc.sample_rate)) / frame_size)) catch {};
    };

    var collector: AudioCollector = .{ .gpa = gpa, .aac = &aac_buf, .samples = &aac_samples };
    var ctx = try pipeline.AudioCtx.init(dec, enc, in_audio.time_base, 0, AudioCollector.cb, &collector);
    defer ctx.deinit();

    const pkt = try av.Packet.alloc();
    defer pkt.free();

    var max_size: u32 = 0;

    const root = std.Progress.start(io, .{});
    defer root.end();
    const node = root.start("preparing seekable mp4 (seconds)", if (duration) |d| @intFromFloat(d) else 0);
    defer node.end();

    while (true) {
        ic.read_frame(pkt) catch |err| switch (err) {
            error.EndOfFile => break,
            else => return err,
        };
        defer pkt.unref();
        const is_video = pkt.stream_index == @as(c_int, @intCast(video_index));
        if (pkt.pts != av.NOPTS_VALUE) {
            const secs = extra.av_rescale_q(pkt.pts, if (is_video) in_vtb else in_audio.time_base, extra.seconds);
            if (secs > 0) node.setCompletedItems(@intCast(secs));
        }
        if (is_video) {
            // pread mode needs a real file offset; redemux serves by PTS.
            if (pkt.size <= 0 or (is_bmff and pkt.pos < 0)) return error.VideoNotAddressable;
            const size: u32 = @intCast(pkt.size);
            max_size = @max(max_size, size);
            try video.append(gpa, .{
                .pts = pkt.pts,
                .dts = pkt.dts, // may be NOPTS for leading B-frames; filled below
                .duration = pkt.duration,
                .size = size,
                .pos = pkt.pos,
                .key = (pkt.flags & extra.AV_PKT_FLAG_KEY) != 0,
            });
        } else {
            try ctx.feed(pkt);
        }
    }
    try ctx.finish();
    max_size = @max(max_size, collector.max_size);
    if (video.items.len == 0) return error.NoVideoStream;
    if (aac_samples.items.len == 0) return error.NoAudioStream;

    fillVideoDts(video.items);

    // --- phase B: measurement mux, merging by DTS ----------------------------
    const zero = try gpa.alloc(u8, max_size);
    defer gpa.free(zero);
    @memset(zero, 0);

    var map: std.ArrayList(MapEntry) = .empty;
    errdefer map.deinit(gpa);
    try map.ensureTotalCapacity(gpa, video.items.len + aac_samples.items.len);

    // The mp4 muxer turns negative leading B-frame DTS into an edit list itself.
    oc.avoid_negative_ts = extra.AVFMT_AVOID_NEG_TS_DISABLED;
    try extra.writeHeader(oc, null);
    // The mov muxer may pick new track timescales in write_header, so packets
    // are rescaled to what it chose.
    const vtb_out = oc.streams[@intCast(out_video_index)].time_base;
    const atb_out = oc.streams[@intCast(out_audio_index)].time_base;

    const fp = try av.Packet.alloc();
    defer fp.free();
    var vi: usize = 0;
    var ai: usize = 0;
    while (vi < video.items.len or ai < aac_samples.items.len) {
        const use_video = vi < video.items.len and
            (ai >= aac_samples.items.len or
                extra.av_compare_ts(video.items[vi].dts, in_vtb, aac_samples.items[ai].dts, enc_tb) <= 0);
        fp.data = zero.ptr;
        var entry: MapEntry = undefined;
        if (use_video) {
            const s = video.items[vi];
            vi += 1;
            fp.stream_index = out_video_index;
            fp.pts = s.pts;
            fp.dts = s.dts;
            fp.duration = s.duration;
            fp.flags = if (s.key) extra.AV_PKT_FLAG_KEY else 0;
            fp.size = @intCast(s.size);
            extra.av_packet_rescale_ts(fp, in_vtb, vtb_out);
            entry.src = if (is_bmff) .{ .file_pos = @intCast(s.pos) } else .{ .pts = s.pts };
        } else {
            const s = aac_samples.items[ai];
            ai += 1;
            fp.stream_index = out_audio_index;
            fp.pts = s.pts;
            fp.dts = s.dts;
            fp.duration = s.duration;
            fp.flags = extra.AV_PKT_FLAG_KEY;
            fp.size = @intCast(s.size);
            extra.av_packet_rescale_ts(fp, enc_tb, atb_out);
            entry.src = .{ .audio = s.buf_off };
        }
        const before = extra.avioTell(avio);
        try extra.writeFrameDirect(oc, fp);
        if (cap.failed) return error.WriteFailed;
        const after = extra.avioTell(avio);
        entry.len = @intCast(fp.size);
        entry.out_start = after - entry.len;
        if (map.items.len == 0) {
            // The head ends where the first sample starts; the first write also
            // carries the mdat box header. A first sample larger than the AVIO
            // buffer has already flushed part of itself into the prefix.
            cap.container_end = entry.out_start;
            cap.prefix.items.len = @min(cap.prefix.items.len, @as(usize, @intCast(entry.out_start)));
        } else if (after - before != entry.len) {
            // Later writes must be exactly one sample, or the offsets are wrong.
            return error.MuxerInterleaved;
        }
        map.appendAssumeCapacity(entry);
    }

    cap.mdat_end = extra.avioTell(avio); // moov starts here
    try extra.writeTrailer(oc);
    if (cap.failed) return error.WriteFailed;

    // --- the video source used at serve time --------------------------------
    const source: VideoSource = if (is_bmff)
        .{ .pread = try Io.Dir.cwd().openFile(io, path, .{}) }
    else
        .{ .redemux = try VideoReader.adopt(gpa, io, ic, video_index) };
    ic_adopted = source == .redemux;
    errdefer switch (source) {
        .pread => |f| f.close(io),
        .redemux => |r| r.deinit(),
    };

    // --- own the captured buffers ------------------------------------------
    const vm = try gpa.create(VMp4);
    errdefer gpa.destroy(vm);
    vm.* = .{
        .gpa = gpa,
        .io = io,
        .video = source,
        .prefix = try cap.prefix.toOwnedSlice(gpa),
        .moov = try cap.moov.toOwnedSlice(gpa),
        .aac = try aac_buf.toOwnedSlice(gpa),
        .map = try map.toOwnedSlice(gpa),
        .container_end = cap.container_end,
        .mdat_end = cap.mdat_end,
        .total = cap.size,
    };
    return vm;
}

test {
    std.testing.refAllDecls(@This());
}
