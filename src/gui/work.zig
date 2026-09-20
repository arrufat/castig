//! Library calls off the UI thread.
//!
//! Every castig operation blocks, so the frame loop hands one to
//! `Io.concurrent`, which unlike `Io.async` never runs the work inline. The
//! task wakes the loop through the backend when it has an answer.

const std = @import("std");
const Io = std.Io;
const dvui = @import("dvui");
const castig = @import("castig");

const Channel = castig.channel.Channel;

/// One call in flight, returning an error union. Its result comes from
/// `arena` and stays valid until the task is started again.
pub fn Task(comptime Result: type) type {
    return struct {
        arena: std.heap.ArenaAllocator,
        future: ?Io.Future(Result) = null,
        /// `await` blocks, so the loop waits for this before calling it.
        arrived: std.atomic.Value(bool) = .init(false),

        const Self = @This();

        pub fn init(gpa: std.mem.Allocator) Self {
            return .{ .arena = .init(gpa) };
        }

        pub fn deinit(self: *Self, io: Io) void {
            if (self.future) |*f| _ = f.cancel(io) catch {};
            self.arena.deinit();
        }

        /// Cancels a call still running and hands back what it returned, so
        /// a result that owns something can be closed.
        pub fn cancel(self: *Self, io: Io) ?Result {
            if (self.future) |*f| {
                defer self.future = null;
                return f.cancel(io);
            }
            return null;
        }

        pub fn busy(self: *const Self) bool {
            return self.future != null;
        }

        /// The allocator the call must take its result from.
        pub fn allocator(self: *Self) std.mem.Allocator {
            return self.arena.allocator();
        }

        /// `args` must outlive the call, which runs on another thread, and
        /// must not point into `arena`, which starting resets.
        pub fn start(
            self: *Self,
            io: Io,
            win: *dvui.Window,
            comptime func: anytype,
            args: std.meta.ArgsTuple(@TypeOf(func)),
        ) Io.ConcurrentError!void {
            std.debug.assert(self.future == null);
            const Args = @TypeOf(args);
            const wrapped = struct {
                fn call(task: *Self, window: *dvui.Window, inner: Args) Result {
                    defer {
                        task.arrived.store(true, .release);
                        dvui.refresh(window, @src(), null);
                    }
                    return @call(.auto, func, inner);
                }
            }.call;
            _ = self.arena.reset(.retain_capacity);
            self.arrived.store(false, .monotonic);
            self.future = try io.concurrent(wrapped, .{ self, win, args });
        }

        /// What the call returned, once; null while it is still running.
        pub fn collect(self: *Self, io: Io) ?Result {
            if (self.future == null or !self.arrived.load(.acquire)) return null;
            defer self.future = null;
            return self.future.?.await(io);
        }
    };
}

/// A cast in flight. The session thread leaves here what the receiver last
/// said, and the frame loop reads it under the mutex.
pub const Cast = struct {
    arena: std.heap.ArenaAllocator,
    future: ?Io.Future(void) = null,
    arrived: std.atomic.Value(bool) = .init(false),
    /// The window the session thread wakes on every receiver message.
    win: *dvui.Window = undefined,
    mutex: Io.Mutex = .init,
    state: State = .{},
    progress: Progress = .{},

    pub const Phase = enum { idle, preparing, playing, over, failed };

    pub const State = struct {
        phase: Phase = .idle,
        player: Channel.PlayerState = .UNKNOWN,
        position: f64 = 0,
        duration: ?f64 = null,
        rate: f64 = 1,
        /// One line for the window: what is served, a fallback, the end.
        note_buf: [192]u8 = @splat(0),
        note_len: usize = 0,

        pub fn note(s: *const State) []const u8 {
            return s.note_buf[0..s.note_len];
        }
    };

    /// Where the library reports a long preparation. `step` comes from
    /// several encoder tasks at once, so the counters are atomic.
    pub const Progress = struct {
        /// The library's labels are string literals, so the slice is enough.
        label: []const u8 = "",
        total: std.atomic.Value(u64) = .init(0),
        done: std.atomic.Value(u64) = .init(0),
        running: std.atomic.Value(bool) = .init(false),

        pub fn reporter(p: *Progress) castig.Reporter {
            return .{ .context = p, .vtable = &vtable };
        }

        const vtable: castig.Reporter.VTable = .{ .begin = begin, .step = step, .end = end };

        fn begin(context: *anyopaque, label: []const u8, total: u64) void {
            const p: *Progress = @ptrCast(@alignCast(context));
            p.label = label;
            p.total.store(total, .monotonic);
            p.done.store(0, .monotonic);
            p.running.store(true, .release);
        }

        fn step(context: *anyopaque) void {
            const p: *Progress = @ptrCast(@alignCast(context));
            _ = p.done.fetchAdd(1, .monotonic);
        }

        fn end(context: *anyopaque) void {
            const p: *Progress = @ptrCast(@alignCast(context));
            p.running.store(false, .release);
        }

        /// How far along, or null when nothing is being prepared.
        pub fn fraction(p: *const Progress) ?f32 {
            if (!p.running.load(.acquire)) return null;
            const total = p.total.load(.monotonic);
            if (total == 0) return 0;
            const done: f32 = @floatFromInt(p.done.load(.monotonic));
            return std.math.clamp(done / @as(f32, @floatFromInt(total)), 0, 1);
        }
    };

    pub fn init(gpa: std.mem.Allocator) Cast {
        return .{ .arena = .init(gpa) };
    }

    pub fn deinit(c: *Cast, io: Io) void {
        if (c.future) |*f| f.cancel(io);
        c.arena.deinit();
    }

    pub fn busy(c: *const Cast) bool {
        return c.future != null;
    }

    pub fn snapshot(c: *Cast) State {
        Io.Threaded.mutexLock(&c.mutex);
        defer Io.Threaded.mutexUnlock(&c.mutex);
        return c.state;
    }

    /// Starts the session on its own thread. `device` and the paths in
    /// `opts` are copied, so the caller may reuse its buffers.
    pub fn start(
        c: *Cast,
        io: Io,
        win: *dvui.Window,
        gpa: std.mem.Allocator,
        environ: *const std.process.Environ.Map,
        device: []const u8,
        opts: castig.session.Options,
    ) !void {
        std.debug.assert(c.future == null);
        _ = c.arena.reset(.retain_capacity);
        const arena = c.arena.allocator();

        var copy = opts;
        copy.source = try arena.dupe(u8, opts.source);
        if (opts.title) |t| copy.title = try arena.dupe(u8, t);
        if (opts.subtitles == .source) copy.subtitles = .{ .source = try arena.dupe(u8, opts.subtitles.source) };

        c.win = win;
        {
            Io.Threaded.mutexLock(&c.mutex);
            defer Io.Threaded.mutexUnlock(&c.mutex);
            c.state = .{ .phase = .preparing };
            c.say("connecting to {s}", .{device});
        }
        c.arrived.store(false, .monotonic);
        c.future = try io.concurrent(run, .{ c, castig.Env{
            .io = io,
            .arena = arena,
            .gpa = gpa,
            .environ = environ,
            .progress = c.progress.reporter(),
        }, try arena.dupe(u8, device), copy });
    }

    /// Reaps the session thread once it has left, so a new cast can start.
    pub fn poll(c: *Cast, io: Io) void {
        if (c.future == null or !c.arrived.load(.acquire)) return;
        c.future.?.await(io);
        c.future = null;
    }

    fn run(c: *Cast, env: castig.Env, device: []const u8, opts: castig.session.Options) void {
        defer {
            c.arrived.store(true, .release);
            dvui.refresh(c.win, @src(), null);
        }
        c.pump(env, device, opts) catch |err| {
            Io.Threaded.mutexLock(&c.mutex);
            defer Io.Threaded.mutexUnlock(&c.mutex);
            c.state.phase = .failed;
            c.say("{s}", .{@errorName(err)});
        };
    }

    fn pump(c: *Cast, env: castig.Env, device: []const u8, opts: castig.session.Options) !void {
        const s = try castig.session.Session.start(env, device, opts);
        defer s.deinit();
        while (try s.next()) |e| c.record(e);
    }

    fn record(c: *Cast, e: castig.session.Event) void {
        {
            Io.Threaded.mutexLock(&c.mutex);
            defer Io.Threaded.mutexUnlock(&c.mutex);
            switch (e) {
                .serving => |base| c.say("serving at {s}", .{base}),
                .loaded => |l| {
                    c.state.phase = .playing;
                    c.say("loaded on {f} as {s}", .{ l.address, l.content_type });
                },
                .state => |m| {
                    c.state.player = m.playerState;
                    c.state.position = m.currentTime;
                    c.state.rate = m.playbackRate;
                    if (m.duration()) |d| c.state.duration = d;
                },
                .falling_back => {
                    c.state.phase = .preparing;
                    c.say("the receiver refused HLS; preparing a seekable mp4", .{});
                },
                .finished => |reason| {
                    c.state.phase = .over;
                    c.say("finished ({t})", .{reason orelse .UNKNOWN});
                },
                .closed => {
                    c.state.phase = .over;
                    c.say("the receiver closed the connection", .{});
                },
            }
        }
        dvui.refresh(c.win, @src(), null);
    }

    /// The caller holds the mutex. A note longer than the buffer is cut.
    fn say(c: *Cast, comptime fmt: []const u8, args: anytype) void {
        const written = std.fmt.bufPrint(&c.state.note_buf, fmt, args) catch c.state.note_buf[0..];
        c.state.note_len = written.len;
    }
};

test {
    std.testing.refAllDecls(@This());
}
