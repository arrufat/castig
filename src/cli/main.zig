const std = @import("std");
const Io = std.Io;

const castig = @import("castig");
const help_text = @import("help.zig");
const render = @import("render.zig");
const prompt = @import("prompt.zig");
const progress = @import("progress.zig");


/// Debug logs (every cast message, every HTTP request) are printed only with
/// CASTIG_DEBUG set; the level is decided at runtime in `logFn`.
pub const std_options: std.Options = .{
    .log_level = .debug,
    .logFn = logFn,
};

var debug_enabled = false;

fn logFn(comptime level: std.log.Level, comptime scope: @EnumLiteral(), comptime format: []const u8, args: anytype) void {
    if (level == .debug) {
        if (!debug_enabled) return;
        return std.log.defaultLog(level, scope, format, args);
    }
    const prefix = switch (level) {
        .err => "error: ",
        .warn => "warning: ",
        .info => "",
        .debug => unreachable,
    };
    std.debug.print(prefix ++ format ++ "\n", args);
}


/// Turns whatever `run` raises into an exit code, explaining it once.
pub fn main(init: std.process.Init) u8 {
    run(init) catch |err| switch (err) {
        // Already explained on stderr by whoever raised them.
        error.InvalidRate,
        error.InvalidSeek,
        error.NoMedia,
        error.NothingPlaying,
        error.ReceiverRefused,
        error.BadReply,
        error.ApiFailed,
        error.DeviceNotFound,
        error.ProtocolNotSupported,
        error.SourceUnreadable,
        error.SaveFailed,
        error.NoCredentials,
        error.NoSubtitles,
        error.NoConfidentMatch,
        error.NoWindow,
        => return 1,
        error.ConnectionClosed => {
            std.debug.print("the receiver closed the connection\n", .{});
            return 1;
        },
        else => {
            std.debug.print("error: {s}\n", .{@errorName(err)});
            return 1;
        },
    };
    return 0;
}

fn run(init: std.process.Init) !void {
    const arena = init.arena.allocator();
    const io = init.io;
    const args = try init.minimal.args.toSlice(arena);

    var stdout_buffer: [4096]u8 = undefined;
    var stdout_writer: Io.File.Writer = .init(.stdout(), io, &stdout_buffer);
    const out = &stdout_writer.interface;
    var bar: progress.Bar = .{ .io = io };
    const env: castig.Env = .{
        .io = io,
        .arena = arena,
        .gpa = init.gpa,
        .environ = init.environ_map,
        .progress = bar.reporter(),
    };

    if (args.len < 2) fail(help_text.usage);
    castig.av_extra.quietLibav();
    debug_enabled = if (init.environ_map.get("CASTIG_DEBUG")) |v| v.len > 0 else false;

    const cmd = if (std.mem.eql(u8, args[1], "--help") or std.mem.eql(u8, args[1], "-h"))
        help_text.Command.help
    else
        std.meta.stringToEnum(help_text.Command, args[1]) orelse fail(help_text.usage);

    // `castig help <command>` and `castig <command> --help` print one page.
    if (helpTopic(cmd, args)) |topic| {
        try out.writeAll(help_text.help(topic));
        try out.flush();
        return;
    }

    switch (cmd) {
        .ls => {
            var query: castig.discovery.Query = .{};
            var i: usize = 2;
            while (i < args.len) : (i += 1) {
                if (std.mem.eql(u8, args[i], "--timeout") and i + 1 < args.len) {
                    i += 1;
                    query.timeout_ms = std.fmt.parseInt(u32, args[i], 10) catch fail("--timeout expects a number of milliseconds\n");
                } else if (std.mem.eql(u8, args[i], "--protocol") and i + 1 < args.len) {
                    i += 1;
                    query.protocol = std.meta.stringToEnum(castig.discovery.Protocol, args[i]) orelse
                        fail("--protocol expects cast or dlna\n");
                } else fail(help_text.help(cmd));
            }
            const timeout_ms = query.timeout_ms;
            const found = try castig.discovery.discover(io, init.gpa, query);
            defer init.gpa.free(found);
            defer castig.discovery.freeDevices(init.gpa, found);
            try render.devices(out, found, timeout_ms);
        },
        .probe => {
            if (args.len < 3) fail(help_text.help(cmd));
            // Without a device named, the answer is the Cast receiver's,
            // whose abilities are fixed. A renderer has to be asked: what
            // it plays is what it says it plays.
            var profile = castig.support.cast;
            var device: ?[]const u8 = null;
            var i: usize = 3;
            while (i < args.len) : (i += 1) {
                if (std.mem.eql(u8, args[i], "--device") and i + 1 < args.len) {
                    i += 1;
                    device = args[i];
                    profile = try castig.player.profileOf(env, args[i]);
                } else fail(help_text.help(cmd));
            }
            var r = castig.probe.inspect(arena, args[2]) catch |err| {
                std.debug.print("cannot open {s}: {s}\n", .{ args[2], @errorName(err) });
                return error.SourceUnreadable;
            };
            r.judgeAgainst(profile);
            try render.report(out, r, device);
        },
        .status => {
            if (args.len != 3) fail(help_text.help(cmd));
            try render.status(out, try castig.control.status(env, args[2]));
        },
        .watch => {
            if (args.len != 3) fail(help_text.help(cmd));
            // Watching an idle device is answered, not failed: nothing
            // playing is what it is doing.
            var following = castig.control.Follow.start(env, args[2]) catch |err| switch (err) {
                error.NothingPlaying, error.NoMedia => {
                    try out.print("nothing is playing on {s}\n", .{args[2]});
                    try out.flush();
                    return;
                },
                else => return err,
            };
            defer following.deinit();
            // Flushed per line: this follows until the item ends, so a
            // buffer that only empties at the end shows nothing at all.
            while (try following.next(env)) |now| {
                try render.media(out, now);
                try out.flush();
            }
            try out.writeAll("nothing playing any more\n");
            try out.flush();
        },
        .stop => {
            if (args.len != 3) fail(help_text.help(cmd));
            try render.stopped(out, try castig.control.stop(env, args[2]));
        },
        .pause, .play => {
            if (args.len != 3) fail(help_text.help(cmd));
            try render.media(out, try castig.control.command(env, args[2], if (cmd == .pause) .pause else .play));
        },
        .seek => {
            if (args.len != 4) fail(help_text.help(cmd));
            try render.media(out, try castig.control.seek(env, args[2], args[3]));
        },
        .rate => {
            if (args.len != 4) fail(help_text.help(cmd));
            const value = std.fmt.parseFloat(f64, args[3]) catch {
                std.debug.print("rate must be a number\n", .{});
                return error.InvalidRate;
            };
            try render.media(out, try castig.control.rate(env, args[2], value));
        },
        .cast => {
            if (args.len < 4) fail(help_text.help(cmd));
            var opts: castig.session.Options = .{ .source = args[3] };
            var i: usize = 4;
            while (i < args.len) : (i += 1) {
                const flag = args[i];
                if (i + 1 >= args.len) fail(help_text.help(cmd));
                i += 1;
                if (std.mem.eql(u8, flag, "--title")) {
                    opts.title = args[i];
                } else if (std.mem.eql(u8, flag, "--type")) {
                    opts.content_type = args[i];
                } else if (std.mem.eql(u8, flag, "--subs")) {
                    opts.subtitles = if (std.mem.eql(u8, args[i], "auto")) .download else .{ .source = args[i] };
                } else if (std.mem.eql(u8, flag, "--protocol")) {
                    opts.protocol = std.meta.stringToEnum(castig.discovery.Protocol, args[i]) orelse
                        fail("--protocol expects cast or dlna\n");
                } else if (std.mem.eql(u8, flag, "--remux")) {
                    opts.remux = std.meta.stringToEnum(castig.delivery.Remux, args[i]) orelse fail("--remux expects auto, hls, mp4, or stream\n");
                } else fail(help_text.help(cmd));
            }
            const session = try castig.session.Session.start(env, args[2], opts);
            defer session.deinit();
            while (try session.next()) |e| try render.event(out, e);
        },
        .subs => {
            if (args.len < 3) fail(help_text.help(cmd));
            var opts: castig.subs.Options = .{};
            var auto = false;
            var i: usize = 3;
            while (i < args.len) : (i += 1) {
                if (std.mem.eql(u8, args[i], "--auto")) {
                    auto = true;
                } else if (std.mem.eql(u8, args[i], "--lang") and i + 1 < args.len) {
                    i += 1;
                    opts.languages = try castig.subs.config.splitLanguages(arena, args[i]);
                } else fail(help_text.help(cmd));
            }
            if (!auto and !prompt.interactive(io)) {
                std.debug.print("stdin is not a terminal, picking automatically\n", .{});
                auto = true;
            }

            var lookup = try castig.subs.Lookup.open(env, args[2], opts);
            defer lookup.deinit();
            const index = if (auto) lookup.confident() orelse {
                std.debug.print("{s}; {d} result(s) to pick from\n", .{ lookup.doubt(), lookup.candidates.len });
                return error.NoConfidentMatch;
            } else (try prompt.pick(io, out, lookup)) orelse return;

            const saved = try lookup.take(index);
            try out.print("saved {s}", .{saved.path});
            if (saved.remaining) |n| try out.print(" ({d} downloads left today)", .{n});
            try out.writeAll("\n");
        },
        .ui => {
            if (args.len != 2) fail(help_text.help(cmd));
            try out.flush();
            return openWindow(env);
        },
        .version => try out.print("{s}\n", .{castig.version}),
        .help => try out.writeAll(help_text.usage),
    }

    try out.flush();
}

/// The command a help request is about, or null when this is real work.
fn helpTopic(cmd: help_text.Command, args: []const []const u8) ?help_text.Command {
    if (cmd == .help) {
        if (args.len < 3) return null;
        return std.meta.stringToEnum(help_text.Command, args[2]) orelse fail(help_text.usage);
    }
    for (args[2..]) |arg| {
        if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) return cmd;
    }
    return null;
}

const gui_exe = "castigui";

/// `castig ui` runs the window as a separate program, so the CLI links
/// nothing of it: the copy next to this binary first, else one on PATH.
fn openWindow(env: castig.Env) !void {
    const io = env.io;
    const sibling = sibling: {
        const dir = std.process.executableDirPathAlloc(io, env.arena) catch break :sibling null;
        break :sibling try Io.Dir.path.join(env.arena, &.{ dir, gui_exe });
    };

    var spawned: ?std.process.Child = null;
    for ([_]?[]const u8{ sibling, gui_exe }) |candidate| {
        const path = candidate orelse continue;
        spawned = std.process.spawn(io, .{ .argv = &.{path} }) catch continue;
        break;
    }
    var child = spawned orelse {
        std.debug.print("cannot run {s}: build it with `zig build gui`\n", .{gui_exe});
        return error.NoWindow;
    };

    const term = try child.wait(io);
    if (!term.success()) {
        std.debug.print("{s} {f}\n", .{ gui_exe, term });
        return error.NoWindow;
    }
}

fn fail(msg: []const u8) noreturn {
    std.debug.print("{s}", .{msg});
    std.process.exit(1);
}

test {
    _ = @import("render.zig");
    _ = @import("prompt.zig");
    _ = @import("progress.zig");
}
