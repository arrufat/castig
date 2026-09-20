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

/// Stores the encoded AAC packets, ticking the progress bar once per source
/// second.
const AudioCollector = struct {
    gpa: std.mem.Allocator,
    aac: *std.ArrayList(u8),
    samples: *std.ArrayList(AacSample),
    node: std.Progress.Node,
    time_base: av.Rational,
    done_s: i64 = -1,

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
        const sec = extra.av_rescale_q(pkt.pts, self.time_base, extra.seconds);
        if (sec > self.done_s) {
            self.done_s = sec;
            self.node.completeOne();
        }
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

// --- chunked audio encode ---------------------------------------------------
//
// The native AAC encoder is single-threaded and dominates the build (~80 s for
// a 100 min movie), so the audio is encoded as independent chunks on all
// cores and concatenated. Each chunk starts its own encoder, so its output
// must be trimmed to look like a slice of one continuous encode:
//
//   - every chunk decodes from the top of the file and counts samples, exactly
//     like the single pass does. Decoding is a few percent of the encode, and
//     it sidesteps seeking: source timestamps may have holes (a first sample
//     with a long duration, say) that a seek would honour and a count would
//     not, and the chunks must agree on where every sample lies;
//   - the frame grid is `first_pts + n * frame_size`; chunk boundaries and the
//     pre-roll lie on it, so the chunks' packets interleave exactly;
//   - a chunk discards its share up to ~1 s before its first kept frame, then
//     encodes that second as pre-roll so the encoder's psychoacoustic and
//     rate-control state has settled before the first kept packet;
//   - it keeps feeding ~1 s past its last kept frame, because the encoder
//     decides frame n's window shape from frame n+1 and a flush would repeat
//     the previous one;
//   - only packets with pts in [lo, hi) are kept (`AudioCtx.emit_lo/hi`).
//     Chunk 0 keeps the priming packet at first_pts - frame_size (the mp4
//     muxer turns it into the edit list); any other chunk's priming packet
//     would play as audio, so it is dropped.
//
// Quantisation differs slightly for a few frames after a seam (the rate
// control state), which is inaudible; window decisions match, so the MDCT
// overlap-add across the seam is valid.

/// Env override for the audio chunk count (`CASTIG_AUDIO_JOBS`); null means
/// one per core.
pub var audio_jobs: ?usize = null;

/// Chunks shorter than this are not worth a seam and another demuxer.
const min_chunk_s: f64 = 30;

/// One slice of the audio: packets with pts in [lo, hi), counted in samples
/// from the first decoded one. The first slice starts open (it keeps the
/// priming packet), the last ends open.
const Chunk = struct { lo: i64, hi: i64 };

fn audioJobs(duration_s: ?f64) usize {
    const dur = duration_s orelse return 1;
    const by_length: usize = @intFromFloat(@max(1.0, dur / min_chunk_s));
    const want = audio_jobs orelse (std.Thread.getCpuCount() catch 1);
    return @max(1, @min(want, by_length));
}

/// Splits the audio into `jobs` slices of whole frames.
fn planChunks(gpa: std.mem.Allocator, sample_rate: c_int, frame_size: c_int, duration_s: f64, jobs: usize) ![]Chunk {
    const fs: i64 = frame_size;
    const total_frames: i64 = @intFromFloat(@ceil(duration_s * @as(f64, @floatFromInt(sample_rate)) / @as(f64, @floatFromInt(fs))));
    const n: i64 = @min(@as(i64, @intCast(jobs)), @max(total_frames, 1));
    const chunks = try gpa.alloc(Chunk, @intCast(n));
    for (chunks, 0..) |*c, i| {
        const k: i64 = @intCast(i);
        c.* = .{
            .lo = if (k == 0) std.math.minInt(i64) else fs * @divTrunc(k * total_frames, n),
            .hi = if (k == n - 1) std.math.maxInt(i64) else fs * @divTrunc((k + 1) * total_frames, n),
        };
    }
    return chunks;
}

/// What one chunk's worker produced. Errors land here since group tasks
/// cannot return them.
const ChunkResult = struct {
    aac: std.ArrayList(u8) = .empty,
    samples: std.ArrayList(AacSample) = .empty,
    err: ?anyerror = null,

    fn deinit(r: *ChunkResult, gpa: std.mem.Allocator) void {
        r.aac.deinit(gpa);
        r.samples.deinit(gpa);
    }
};

/// Encodes one chunk on its own demuxer, decoder and encoder.
fn encodeChunk(gpa: std.mem.Allocator, path: []const u8, chunk: Chunk, node: std.Progress.Node, result: *ChunkResult) void {
    encodeChunkInner(gpa, path, chunk, node, result) catch |err| {
        result.err = err;
    };
}

fn encodeChunkInner(gpa: std.mem.Allocator, path: []const u8, chunk: Chunk, node: std.Progress.Node, result: *ChunkResult) !void {
    const in = try pipeline.Input.open(gpa, path);
    defer in.deinit();
    extra.discardOthers(in.ic, &.{in.audio_index});
    const in_tb = in.ic.streams[in.audio_index].time_base;
    const enc = try pipeline.openStereoAacEncoder(in.dec);
    defer enc.free();

    var collector: AudioCollector = .{ .gpa = gpa, .aac = &result.aac, .samples = &result.samples, .node = node, .time_base = enc.time_base };
    var ctx = try pipeline.AudioCtx.init(in.dec, enc, in_tb, 0, AudioCollector.cb, &collector);
    defer ctx.deinit();
    // ~1 s of whole frames on each side of the slice (see above); the open
    // ends saturate.
    const roll: i64 = @divFloor(enc.sample_rate + enc.frame_size - 1, enc.frame_size) * enc.frame_size;
    ctx.skip_samples = @max(0, chunk.lo -| roll);
    ctx.emit_lo = chunk.lo;
    ctx.emit_hi = chunk.hi;
    const stop = chunk.hi +| roll;

    const pkt = try av.Packet.alloc();
    defer pkt.free();
    while (ctx.consumed() < stop) {
        in.ic.read_frame(pkt) catch |err| switch (err) {
            error.EndOfFile => break,
            else => return err,
        };
        defer pkt.unref();
        if (pkt.stream_index != @as(c_int, @intCast(in.audio_index))) continue;
        try ctx.feed(pkt);
    }
    try ctx.finish();
}

/// Joins the chunks' AAC in order into `aac`/`samples` (empty on entry),
/// taking the buffers over, and returns the largest packet. Every seam must
/// continue the frame grid exactly. Audio that ends before the plan leaves
/// trailing chunks empty; an empty chunk before a non-empty one is a
/// mismatch too.
fn mergeChunks(gpa: std.mem.Allocator, results: []ChunkResult, frame_size: c_int, aac: *std.ArrayList(u8), samples: *std.ArrayList(AacSample)) !u32 {
    var ended = false;
    for (results) |*r| {
        defer {
            r.deinit(gpa);
            r.* = .{};
        }
        if (r.samples.items.len == 0) {
            ended = true;
            continue;
        }
        if (ended) return error.SeamMismatch;
        if (samples.items.len == 0) {
            std.mem.swap(std.ArrayList(u8), aac, &r.aac);
            std.mem.swap(std.ArrayList(AacSample), samples, &r.samples);
            continue;
        }
        const last = samples.items[samples.items.len - 1];
        if (last.pts + frame_size != r.samples.items[0].pts) return error.SeamMismatch;
        const base = aac.items.len;
        try aac.appendSlice(gpa, r.aac.items);
        try samples.ensureUnusedCapacity(gpa, r.samples.items.len);
        for (r.samples.items) |sample| {
            var moved = sample;
            moved.buf_off += base;
            samples.appendAssumeCapacity(moved);
        }
    }
    var max_size: u32 = 0;
    for (samples.items) |sample| max_size = @max(max_size, sample.size);
    return max_size;
}

/// Phase A's pass over the video stream: per-sample metadata only, the bytes
/// are located again at serve time. Runs alongside the audio chunks.
const VideoSweep = struct {
    ic: *av.FormatContext,
    video_index: usize,
    is_bmff: bool,
    gpa: std.mem.Allocator,
    video: *std.ArrayList(VideoSample),
    err: ?anyerror = null,

    fn run(s: *VideoSweep) void {
        s.sweep() catch |err| {
            s.err = err;
        };
    }

    fn sweep(s: *VideoSweep) !void {
        extra.discardOthers(s.ic, &.{s.video_index});
        const pkt = try av.Packet.alloc();
        defer pkt.free();
        while (true) {
            s.ic.read_frame(pkt) catch |err| switch (err) {
                error.EndOfFile => break,
                else => return err,
            };
            defer pkt.unref();
            if (pkt.stream_index != @as(c_int, @intCast(s.video_index))) continue;
            // pread mode needs a real file offset; redemux serves by PTS.
            if (pkt.size <= 0 or (s.is_bmff and pkt.pos < 0)) return error.VideoNotAddressable;
            try s.video.append(s.gpa, .{
                .pts = pkt.pts,
                .dts = pkt.dts, // may be NOPTS for leading B-frames; filled later
                .duration = pkt.duration,
                .size = @intCast(pkt.size),
                .pos = pkt.pos,
                .key = (pkt.flags & extra.AV_PKT_FLAG_KEY) != 0,
            });
        }
    }
};

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
    /// The audio chunks' packets did not line up (should not happen).
    SeamMismatch,
};

/// Builds the virtual MP4 for `path`. An `UnsuitableError` means the source
/// cannot be served this way (no video, unreliable byte positions, ...).
/// The audio is encoded on `audio_jobs` cores at once.
pub fn build(gpa: std.mem.Allocator, io: Io, path: []const u8, ic: *av.FormatContext) !*VMp4 {
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

    const dec = try pipeline.openDecoder(in_audio.codecpar);
    defer dec.free();
    const enc = try pipeline.openStereoAacEncoder(dec);
    defer enc.free();
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

    // --- phase A: video metadata sweep + chunked audio encode, in parallel ---
    var video: std.ArrayList(VideoSample) = .empty;
    defer video.deinit(gpa);
    video.ensureTotalCapacity(gpa, @intCast(@max(extra.avformat_index_get_entries_count(in_video), 0))) catch {};
    var aac_samples: std.ArrayList(AacSample) = .empty;
    defer aac_samples.deinit(gpa);
    var aac_buf: std.ArrayList(u8) = .empty;
    errdefer aac_buf.deinit(gpa);

    const duration = extra.durationSeconds(ic);
    // The audio may end before the container does; plan on its own length.
    const audio_s: ?f64 = if (in_audio.duration != av.NOPTS_VALUE) extra.toSeconds(in_audio.duration, in_audio.time_base) else duration;

    const root = std.Progress.start(io, .{});
    defer root.end();
    const node = root.start("preparing seekable mp4 (seconds)", if (duration) |d| @intFromFloat(d) else 0);
    defer node.end();

    const chunks = try planChunks(gpa, enc.sample_rate, enc.frame_size, audio_s orelse 0, audioJobs(audio_s));
    defer gpa.free(chunks);
    const results = try gpa.alloc(ChunkResult, chunks.len);
    defer gpa.free(results);
    @memset(results, .{});
    defer for (results) |*r| r.deinit(gpa);

    // Each chunk opens its own demuxer; `ic` does the video. `Group.async`
    // runs a task inline when no thread is free, so this needs no minimum
    // pool size to be correct.
    var sweep: VideoSweep = .{ .ic = ic, .video_index = video_index, .is_bmff = is_bmff, .gpa = gpa, .video = &video };
    var group: Io.Group = .init;
    defer group.cancel(io);
    for (chunks, results) |c, *r| group.async(io, encodeChunk, .{ gpa, path, c, node, r });
    group.async(io, VideoSweep.run, .{&sweep});
    try group.await(io);
    if (sweep.err) |err| return err;
    for (results) |r| if (r.err) |err| return err;

    var max_size = try mergeChunks(gpa, results, enc.frame_size, &aac_buf, &aac_samples);
    for (video.items) |v| max_size = @max(max_size, v.size);
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

test "planChunks tiles the audio on the frame grid" {
    const gpa = std.testing.allocator;
    const fs: c_int = 1024;
    const chunks = try planChunks(gpa, 48000, fs, 600, 4);
    defer gpa.free(chunks);
    try std.testing.expectEqual(4, chunks.len);
    try std.testing.expectEqual(std.math.minInt(i64), chunks[0].lo);
    try std.testing.expectEqual(std.math.maxInt(i64), chunks[3].hi);
    for (chunks[1..], 0..) |c, k| {
        try std.testing.expectEqual(chunks[k].hi, c.lo);
        try std.testing.expectEqual(0, @mod(c.lo, fs));
        // Equal shares, to the frame.
        try std.testing.expectEqual(150 * 48000 / fs * fs, c.lo - @max(chunks[k].lo, 0));
    }
}

test "planChunks with one job is the plain pass" {
    const gpa = std.testing.allocator;
    const chunks = try planChunks(gpa, 44100, 1024, 0, 1);
    defer gpa.free(chunks);
    try std.testing.expectEqualSlices(Chunk, &.{.{ .lo = std.math.minInt(i64), .hi = std.math.maxInt(i64) }}, chunks);
}

test "planChunks never makes empty chunks" {
    const gpa = std.testing.allocator;
    // 0.05 s is three frames at 48 kHz; more jobs than frames collapse.
    const chunks = try planChunks(gpa, 48000, 1024, 0.05, 64);
    defer gpa.free(chunks);
    try std.testing.expectEqual(3, chunks.len);
    for (chunks[1..], 0..) |c, k| try std.testing.expect(c.lo > chunks[k].lo);
}

fn testChunk(gpa: std.mem.Allocator, bytes: []const u8, first_pts: i64) !ChunkResult {
    var r: ChunkResult = .{};
    errdefer r.deinit(gpa);
    try r.aac.appendSlice(gpa, bytes);
    for (bytes, 0..) |_, i| {
        try r.samples.append(gpa, .{ .pts = first_pts + 1024 * @as(i64, @intCast(i)), .dts = 0, .duration = 1024, .buf_off = i, .size = 1 });
    }
    return r;
}

test "mergeChunks rebases offsets across a clean seam and drops a trailing empty chunk" {
    const gpa = std.testing.allocator;
    var results = [_]ChunkResult{ try testChunk(gpa, "abc", -1024), try testChunk(gpa, "de", 2048), .{} };
    defer for (&results) |*r| r.deinit(gpa);
    var aac: std.ArrayList(u8) = .empty;
    defer aac.deinit(gpa);
    var samples: std.ArrayList(AacSample) = .empty;
    defer samples.deinit(gpa);

    try std.testing.expectEqual(1, try mergeChunks(gpa, &results, 1024, &aac, &samples));
    try std.testing.expectEqualStrings("abcde", aac.items);
    try std.testing.expectEqual(5, samples.items.len);
    try std.testing.expectEqual(3, samples.items[3].buf_off);
    try std.testing.expectEqual(2048, samples.items[3].pts);
}

test "mergeChunks refuses a gap or a hole" {
    const gpa = std.testing.allocator;
    var aac: std.ArrayList(u8) = .empty;
    defer aac.deinit(gpa);
    var samples: std.ArrayList(AacSample) = .empty;
    defer samples.deinit(gpa);

    var gap = [_]ChunkResult{ try testChunk(gpa, "abc", 0), try testChunk(gpa, "de", 4096) };
    defer for (&gap) |*r| r.deinit(gpa);
    try std.testing.expectError(error.SeamMismatch, mergeChunks(gpa, &gap, 1024, &aac, &samples));

    aac.clearRetainingCapacity();
    samples.clearRetainingCapacity();
    var hole = [_]ChunkResult{ try testChunk(gpa, "a", 0), .{}, try testChunk(gpa, "b", 1024) };
    defer for (&hole) |*r| r.deinit(gpa);
    try std.testing.expectError(error.SeamMismatch, mergeChunks(gpa, &hole, 1024, &aac, &samples));
}
