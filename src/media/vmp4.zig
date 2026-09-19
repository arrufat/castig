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
//!      buffer, the source file (video, via positional read), or an in-RAM AAC
//!      buffer (audio). Nothing hits disk.
//!
//! Correctness gate (verify-and-degrade): video is copied, so each sample's
//! output bytes must equal `pkt.size` bytes we can reproduce later. For
//! ISO-BMFF sources `pkt.pos` is a reliable file offset; for other containers
//! (Matroska lacing / compression) we verify `pread == pkt.data`. On any
//! violation `build` returns null and the caller falls back to a stream.

const std = @import("std");
const Io = std.Io;
const av = @import("av");
const extra = @import("../av_extra.zig");
const pipeline = @import("pipeline.zig");

const io_buffer_len = 64 * 1024;
const aac_bitrate = 192_000;
const prefix_cap: u64 = 1 << 20; // safety bound on the captured head

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
    /// True until after the first sample; captures everything into `prefix`.
    capture_all: bool = true,
    /// End of the head (= first sample's output offset), set after the 1st frame.
    container_end: u64 = 0,
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
        } else if (c.capture_all) {
            try writeInto(c.gpa, &c.prefix, off, bytes);
        } else if (off < c.container_end) {
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

pub const VMp4 = struct {
    gpa: std.mem.Allocator,
    io: Io,
    source: Io.File,
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
        vm.source.close(vm.io);
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
                const take = @min(@min(want, e.len - delta), vm.mdat_end - o);
                if (e.is_audio) {
                    @memcpy(dest[done..][0..@intCast(take)], vm.aac[@intCast(e.src + delta)..][0..@intCast(take)]);
                } else {
                    const got = try vm.source.readPositionalAll(vm.io, dest[done..][0..@intCast(take)], e.src + delta);
                    if (got < @as(usize, @intCast(take))) return error.ShortRead;
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

    // A separate handle for positional reads (verification and serving).
    var source = try Io.Dir.cwd().openFile(io, path, .{});
    errdefer source.close(io);

    // --- audio decoder + AAC encoder (stereo), mirroring pipeline.Session ----
    const dec_codec = try av.Codec.find_decoder(in_audio.codecpar.codec_id);
    const dec = try av.Codec.Context.alloc(dec_codec);
    defer dec.free();
    try dec.parameters_to_context(in_audio.codecpar);
    try dec.open(dec_codec, null);

    const enc_codec = try av.Codec.find_encoder_by_name("aac");
    const enc = try av.Codec.Context.alloc(enc_codec);
    defer enc.free();
    enc.sample_rate = dec.sample_rate;
    extra.av_channel_layout_default(&enc.ch_layout, 2);
    enc.sample_fmt = .FLTP;
    enc.bit_rate = aac_bitrate;
    enc.time_base = .{ .num = 1, .den = dec.sample_rate };
    enc.flags |= extra.CODEC_FLAG_GLOBAL_HEADER;
    try enc.open(enc_codec, null);
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

    var collector: AudioCollector = .{ .gpa = gpa, .aac = &aac_buf, .samples = &aac_samples };
    var ctx: pipeline.AudioCtx = .{
        .gpa = gpa,
        .dec = dec,
        .enc = enc,
        .swr = try av.swr.Context.alloc_set_opts(&enc.ch_layout, enc.sample_fmt, enc.sample_rate, &dec.ch_layout, dec.sample_fmt, dec.sample_rate, 0, null),
        .fifo = extra.av_audio_fifo_alloc(enc.sample_fmt, enc.ch_layout.nb_channels, 1) orelse return error.OutOfMemory,
        .oc = oc,
        .out_index = out_audio_index,
        .enc_frame = try av.Frame.alloc(),
        .out_packet = try av.Packet.alloc(),
        .next_pts = 0,
        .pts_set = false,
        .in_time_base = in_audio.time_base,
        .sink = null,
        .collect = AudioCollector.cb,
        .collect_ctx = &collector,
    };
    try ctx.swr.init();
    defer ctx.swr.free();
    defer extra.av_audio_fifo_free(ctx.fifo);
    defer ctx.enc_frame.free();
    defer ctx.out_packet.free();

    const pkt = try av.Packet.alloc();
    defer pkt.free();
    const dec_frame = try av.Frame.alloc();
    defer dec_frame.free();

    var verify_buf: std.ArrayList(u8) = .empty;
    defer verify_buf.deinit(gpa);
    var max_size: u32 = 0;

    while (true) {
        ic.read_frame(pkt) catch |err| switch (err) {
            error.EndOfFile => break,
            else => return err,
        };
        defer pkt.unref();
        if (pkt.stream_index == @as(c_int, @intCast(video_index))) {
            if (pkt.pos < 0 or pkt.size <= 0) {
                if (debug) std.debug.print("vmp4: video packet has no byte position; falling back\n", .{});
                return null;
            }
            const size: u32 = @intCast(pkt.size);
            if (!is_bmff) {
                try verify_buf.resize(gpa, size);
                const got = source.readPositionalAll(io, verify_buf.items, @intCast(pkt.pos)) catch 0;
                if (got < size or !std.mem.eql(u8, verify_buf.items, pkt.data[0..size])) {
                    if (debug) std.debug.print("vmp4: video bytes not reproducible from file position ({s}); falling back\n", .{fmt_name});
                    return null;
                }
            }
            if (size > max_size) max_size = size;
            try video.append(gpa, .{
                .pts = pkt.pts,
                .dts = if (pkt.dts == av.NOPTS_VALUE) pkt.pts else pkt.dts,
                .duration = pkt.duration,
                .size = size,
                .pos = pkt.pos,
                .key = (pkt.flags & 1) != 0,
            });
        } else if (pkt.stream_index == @as(c_int, @intCast(audio_index))) {
            try dec.send_packet(pkt);
            try pipeline.drainDecoder(&ctx, dec_frame);
        }
    }
    try dec.send_packet(null);
    try pipeline.drainDecoder(&ctx, dec_frame);
    try pipeline.encodeFifo(&ctx, true);
    try pipeline.encodeFrame(&ctx, null);

    for (aac_samples.items) |a| {
        if (a.size > max_size) max_size = a.size;
    }
    if (video.items.len == 0 or aac_samples.items.len == 0) {
        if (debug) std.debug.print("vmp4: empty video or audio; falling back\n", .{});
        return null;
    }

    // --- phase B: measurement mux, merging by DTS ----------------------------
    const zero = try gpa.alloc(u8, max_size);
    defer gpa.free(zero);
    @memset(zero, 0);

    var map: std.ArrayList(MapEntry) = .empty;
    errdefer map.deinit(gpa);
    try map.ensureTotalCapacity(gpa, video.items.len + aac_samples.items.len);

    try extra.writeHeader(oc, null);

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
            src = @intCast(s.pos);
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
        try extra.writeFrameDirect(oc, fp);
        extra.avio_flush(oc.pb.?);
        if (cap.failed) return error.WriteFailed;

        const out_start = cap.pos - @as(u64, @intCast(fp.size));
        if (first) {
            cap.container_end = out_start;
            cap.prefix.items.len = @intCast(out_start); // drop captured sample bytes
            cap.capture_all = false;
            first = false;
        }
        map.appendAssumeCapacity(.{ .out_start = out_start, .len = @intCast(fp.size), .is_audio = is_audio, .src = src });
    }

    cap.mdat_end = cap.pos; // moov starts here
    try extra.writeTrailer(oc);
    if (cap.failed) return error.WriteFailed;

    // --- own the captured buffers ------------------------------------------
    const vm = try gpa.create(VMp4);
    vm.* = .{
        .gpa = gpa,
        .io = io,
        .source = source,
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
