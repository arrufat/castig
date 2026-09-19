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
//!      interleaved) plus `avio_flush` bound each packet's bytes so they are
//!      attributable.
//!   2. Serving: a byte range is answered from the head buffer, the `moov`
//!      buffer, the video (see below), or an in-RAM AAC buffer (audio). Nothing
//!      hits disk.
//!
//! Video is copied, so each sample's output bytes must be reproducible at serve
//! time. ISO-BMFF sources read the sample straight from the file by byte offset
//! (`pkt.pos`). Other containers (Matroska, where `pkt.pos` points at the block,
//! not the frame) re-demux the source and locate the sample by PTS. If neither
//! works (no video, `pkt.pos < 0` in BMFF), `build` returns null and the caller
//! falls back to a stream.

const std = @import("std");
const Io = std.Io;
const av = @import("av");
const extra = @import("../av_extra.zig");
const pipeline = @import("pipeline.zig");

const io_buffer_len = 64 * 1024;

const VideoSample = struct { pts: i64, dts: i64, duration: i64, size: u32, pos: i64, key: bool };
const AacSample = struct { pts: i64, dts: i64, duration: i64, buf_off: usize, size: u32 };

/// One contiguous run of output bytes and where to read them from.
const MapEntry = struct {
    out_start: u64,
    len: u32,
    is_audio: bool,
    /// Video: source file byte offset. Audio: offset into the AAC buffer.
    src: u64,
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
            // Head bytes (ftyp + mdat header, then the whole first sample until
            // container_end is known); the sample tail is truncated in phase B.
            const take = @min(@as(u64, bytes.len), c.container_end - off);
            try writeInto(c.gpa, &c.prefix, off, bytes[0..@intCast(take)]);
        } // else: bulk payload, discarded
        c.pos = off + bytes.len;
        if (c.pos > c.size) c.size = c.pos;
    }
};

fn writeCb(userdata: ?*anyopaque, buf: [*:0]u8, size: c_int) callconv(.c) c_int {
    const c: *Capture = @ptrCast(@alignCast(userdata.?));
    const n: usize = @intCast(size);
    const bytes: [*]const u8 = @ptrCast(buf);
    c.onWrite(bytes[0..n]) catch {
        c.failed = true;
        return -1;
    };
    return size;
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

const AudioCollector = struct {
    gpa: std.mem.Allocator,
    aac: *std.ArrayList(u8),
    samples: *std.ArrayList(AacSample),

    fn cb(ctx: *anyopaque, pkt: *av.Packet) anyerror!void {
        const self: *AudioCollector = @ptrCast(@alignCast(ctx));
        const size: u32 = @intCast(pkt.size);
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

/// How video sample bytes are fetched at serve time.
const VideoSrc = enum {
    /// ISO-BMFF: read the sample straight from the source file by byte offset.
    pread,
    /// Other containers (Matroska): the file offset is unreliable, so re-demux
    /// the source to the sample (matched by decode timestamp) and copy its data.
    redemux,
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

    fn open(gpa: std.mem.Allocator, io: Io, path_z: [*:0]const u8, stream_index: usize) !*VideoReader {
        const self = try gpa.create(VideoReader);
        errdefer gpa.destroy(self);
        const ic = try av.FormatContext.open_input(path_z, null, null, null);
        errdefer ic.close_input();
        try ic.find_stream_info(null);
        const pkt = try av.Packet.alloc();
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
        try self.ic.seek_frame(self.stream_index, pts, 1); // AVSEEK_FLAG_BACKWARD
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

pub const VMp4 = struct {
    gpa: std.mem.Allocator,
    io: Io,
    video_src: VideoSrc,
    /// `pread` mode: the source file, read positionally for video.
    source: ?Io.File,
    /// `redemux` mode: re-demuxes the source for video sample bytes.
    vreader: ?*VideoReader,
    prefix: []u8,
    moov: []u8,
    aac: []u8,
    map: []MapEntry,
    container_end: u64,
    mdat_end: u64,
    total: u64,

    pub fn totalSize(vm: *const VMp4) u64 {
        return vm.total;
    }

    pub fn deinit(vm: *VMp4) void {
        if (vm.source) |s| s.close(vm.io);
        if (vm.vreader) |r| r.deinit();
        vm.gpa.free(vm.prefix);
        vm.gpa.free(vm.moov);
        vm.gpa.free(vm.aac);
        vm.gpa.free(vm.map);
        vm.gpa.destroy(vm);
    }

    /// The map is contiguous over [container_end, mdat_end); find the run holding `o`.
    fn findEntry(vm: *const VMp4, o: u64) ?*const MapEntry {
        var lo: usize = 0;
        var hi: usize = vm.map.len;
        while (lo < hi) {
            const mid = lo + (hi - lo) / 2;
            const e = &vm.map[mid];
            if (o < e.out_start) {
                hi = mid;
            } else if (o >= e.out_start + e.len) {
                lo = mid + 1;
            } else return e;
        }
        return null;
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
                // Samples fill [container_end, mdat_end) contiguously, so the
                // entry ends at or before mdat_end; no extra clamp needed.
                const take = @min(want, e.len - delta);
                const slice = dest[done..][0..@intCast(take)];
                if (e.is_audio) {
                    @memcpy(slice, vm.aac[@intCast(e.src + delta)..][0..@intCast(take)]);
                } else switch (vm.video_src) {
                    .pread => {
                        const got = try vm.source.?.readPositionalAll(vm.io, slice, e.src + delta);
                        if (got < slice.len) return error.ShortRead;
                    },
                    .redemux => try vm.vreader.?.read(@bitCast(e.src), e.len, @intCast(delta), slice),
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
/// extrapolate the leading unset ones backward from the first real DTS.
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

/// Builds the virtual MP4 for `path`, or returns null if the source is
/// unsuitable (video needs transcode, no video, unreliable byte positions) and
/// the caller should fall back to a stream. `debug` logs the reason.
pub fn build(gpa: std.mem.Allocator, io: Io, path: []const u8, debug: bool) !?*VMp4 {
    const path_z = try gpa.dupeSentinel(u8, path, 0);
    defer gpa.free(path_z);

    av.LOG.set_level(.ERROR);
    const ic = try av.FormatContext.open_input(path_z, null, null, null);
    defer ic.close_input();
    try ic.find_stream_info(null);

    const video_index: usize = if (ic.find_best_stream(.VIDEO, -1, -1)) |v| @intCast(v[0]) else |_| {
        if (debug) std.debug.print("vmp4: no video stream; falling back\n", .{});
        return null;
    };
    const audio_index: usize = if (ic.find_best_stream(.AUDIO, -1, -1)) |a| @intCast(a[0]) else |_| {
        if (debug) std.debug.print("vmp4: no audio stream; falling back\n", .{});
        return null;
    };
    const in_video = ic.streams[video_index];
    const in_audio = ic.streams[audio_index];
    const in_vtb = in_video.time_base;

    const fmt_name = std.mem.span(ic.iformat.name);
    const is_bmff = std.mem.indexOf(u8, fmt_name, "mp4") != null or
        std.mem.indexOf(u8, fmt_name, "mov") != null or
        std.mem.indexOf(u8, fmt_name, "m4a") != null;
    // ISO-BMFF video reads straight from the file by byte offset; other
    // containers (Matroska) re-demux at serve time, since pkt.pos is unreliable.
    const video_src: VideoSrc = if (is_bmff) .pread else .redemux;

    // Audio decoder + stereo AAC encoder (shared with pipeline.Session).
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

    const out_video = try extra.newStream(oc);
    try extra.copyParameters(out_video.codecpar, in_video.codecpar);
    out_video.codecpar.codec_tag = 0;
    out_video.time_base = in_vtb;
    const out_video_index = out_video.index;

    const out_audio = try extra.newStream(oc);
    try extra.parametersFromContext(out_audio.codecpar, enc);
    out_audio.time_base = enc_tb;
    const out_audio_index = out_audio.index;

    const io_buffer = try av.malloc(io_buffer_len);
    const avio = try av.IOContext.alloc(io_buffer, .writable, &cap, null, writeCb, seekCb);
    defer av.IOContext.free(avio);
    oc.pb = avio;

    // --- phase A: collect video metadata + encoded audio ---------------------
    var video: std.ArrayList(VideoSample) = .empty;
    defer video.deinit(gpa);
    var aac_samples: std.ArrayList(AacSample) = .empty;
    defer aac_samples.deinit(gpa);
    var aac_buf: std.ArrayList(u8) = .empty;
    errdefer aac_buf.deinit(gpa);

    // Preallocate the AAC buffers from the duration to avoid repeated regrowth
    // (best effort; the loops still append safely if the estimate is off).
    if (ic.duration != av.NOPTS_VALUE and ic.duration > 0) {
        const dur_s = @as(f64, @floatFromInt(ic.duration)) / 1_000_000.0;
        const frame_size: f64 = if (enc.frame_size > 0) @floatFromInt(enc.frame_size) else 1024;
        aac_buf.ensureTotalCapacity(gpa, @intFromFloat(dur_s * @as(f64, @floatFromInt(enc.bit_rate)) / 8.0)) catch {};
        aac_samples.ensureTotalCapacity(gpa, @intFromFloat(dur_s * @as(f64, @floatFromInt(enc.sample_rate)) / frame_size)) catch {};
    }

    var collector: AudioCollector = .{ .gpa = gpa, .aac = &aac_buf, .samples = &aac_samples };
    var ctx = try pipeline.AudioCtx.init(dec, enc, in_audio.time_base, 0, AudioCollector.cb, &collector);
    defer ctx.deinit();

    const pkt = try av.Packet.alloc();
    defer pkt.free();

    var max_size: u32 = 0;

    while (true) {
        ic.read_frame(pkt) catch |err| switch (err) {
            error.EndOfFile => break,
            else => return err,
        };
        defer pkt.unref();
        if (pkt.stream_index == @as(c_int, @intCast(video_index))) {
            // pread mode needs a real file offset; redemux serves by DTS.
            if (pkt.size <= 0 or (video_src == .pread and pkt.pos < 0)) {
                if (debug) std.debug.print("vmp4: video packet not addressable; falling back\n", .{});
                return null;
            }
            const size: u32 = @intCast(pkt.size);
            if (size > max_size) max_size = size;
            try video.append(gpa, .{
                .pts = pkt.pts,
                .dts = pkt.dts, // may be NOPTS for leading B-frames; filled below
                .duration = pkt.duration,
                .size = size,
                .pos = pkt.pos,
                .key = (pkt.flags & 1) != 0,
            });
        } else if (pkt.stream_index == @as(c_int, @intCast(audio_index))) {
            try ctx.feed(pkt);
        }
    }
    try ctx.finish();

    for (aac_samples.items) |a| {
        if (a.size > max_size) max_size = a.size;
    }
    if (video.items.len == 0 or aac_samples.items.len == 0) {
        if (debug) std.debug.print("vmp4: empty video or audio; falling back\n", .{});
        return null;
    }

    // Fill missing (NOPTS) video DTS so the muxer gets monotonic timestamps.
    // A B-frame stream leaves the leading packets' DTS unset; the correct values
    // extrapolate backward from the first real DTS by the frame step.
    fillVideoDts(video.items);

    // --- phase B: measurement mux, merging by DTS ----------------------------
    const zero = try gpa.alloc(u8, max_size);
    defer gpa.free(zero);
    @memset(zero, 0);

    var map: std.ArrayList(MapEntry) = .empty;
    errdefer map.deinit(gpa);
    try map.ensureTotalCapacity(gpa, video.items.len + aac_samples.items.len);

    // Shift so the smallest DTS is non-negative (B-frame video starts negative);
    // both streams shift together, keeping A/V sync and a valid MP4 timeline.
    oc.avoid_negative_ts = 1; // AVFMT_AVOID_NEG_TS_MAKE_NON_NEGATIVE
    try extra.writeHeader(oc, null);
    // The mov muxer may change the track timescales in write_header, so read
    // them back and rescale each packet from its source time base; otherwise the
    // video plays at the wrong speed (timestamps interpreted in the new scale).
    const vtb_out = oc.streams[@intCast(out_video_index)].time_base;
    const atb_out = oc.streams[@intCast(out_audio_index)].time_base;

    const fp = try av.Packet.alloc();
    defer fp.free();
    var vi: usize = 0;
    var ai: usize = 0;
    var first = true;
    while (vi < video.items.len or ai < aac_samples.items.len) {
        const use_video = blk: {
            if (vi >= video.items.len) break :blk false;
            if (ai >= aac_samples.items.len) break :blk true;
            const vsec = @as(f64, @floatFromInt(video.items[vi].dts)) * in_vtb.q2d();
            const asec = @as(f64, @floatFromInt(aac_samples.items[ai].dts)) * enc_tb.q2d();
            break :blk vsec <= asec;
        };
        fp.data = zero.ptr;
        var is_audio: bool = undefined;
        var src: u64 = undefined;
        if (use_video) {
            const s = video.items[vi];
            vi += 1;
            fp.stream_index = out_video_index;
            fp.pts = s.pts;
            fp.dts = s.dts;
            fp.duration = s.duration;
            fp.flags = if (s.key) 1 else 0;
            fp.size = @intCast(s.size);
            is_audio = false;
            // pread mode locates the sample by file offset; redemux by its PTS.
            src = if (video_src == .pread) @as(u64, @intCast(s.pos)) else @bitCast(s.pts);
        } else {
            const s = aac_samples.items[ai];
            ai += 1;
            fp.stream_index = out_audio_index;
            fp.pts = s.pts;
            fp.dts = s.dts;
            fp.duration = s.duration;
            fp.flags = 1;
            fp.size = @intCast(s.size);
            is_audio = true;
            src = s.buf_off;
        }
        // Rescale from the source time base to the muxer's chosen output scale.
        if (is_audio) extra.av_packet_rescale_ts(fp, enc_tb, atb_out) else extra.av_packet_rescale_ts(fp, in_vtb, vtb_out);
        const before = cap.pos;
        try extra.writeFrameDirect(oc, fp);
        extra.avio_flush(oc.pb.?);
        if (cap.failed) return error.WriteFailed;

        const out_start = cap.pos - @as(u64, @intCast(fp.size));
        if (first) {
            // The head ends where the first sample begins; drop the sample
            // bytes captured before container_end was known, then stop
            // capturing bulk payload. (The first write also carries the mdat
            // box header, so it writes more than fp.size.)
            cap.container_end = out_start;
            cap.prefix.items.len = @intCast(out_start);
            first = false;
        } else if (cap.pos - before != @as(u64, @intCast(fp.size))) {
            // Every later frame must write exactly its sample bytes; otherwise
            // the muxer interleaved something and out_start would be wrong.
            if (debug) std.debug.print("vmp4: muxer wrote unexpected bytes for a sample; falling back\n", .{});
            return null;
        }
        map.appendAssumeCapacity(.{ .out_start = out_start, .len = @intCast(fp.size), .is_audio = is_audio, .src = src });
    }

    cap.mdat_end = cap.pos; // moov starts here
    try extra.writeTrailer(oc);
    if (cap.failed) return error.WriteFailed;

    // --- the video source used at serve time --------------------------------
    const source: ?Io.File = if (video_src == .pread) try Io.Dir.cwd().openFile(io, path, .{}) else null;
    errdefer if (source) |s| s.close(io);
    const vreader: ?*VideoReader = if (video_src == .redemux) try VideoReader.open(gpa, io, path_z, video_index) else null;
    errdefer if (vreader) |r| r.deinit();

    // --- own the captured buffers ------------------------------------------
    const vm = try gpa.create(VMp4);
    vm.* = .{
        .gpa = gpa,
        .io = io,
        .video_src = video_src,
        .source = source,
        .vreader = vreader,
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
