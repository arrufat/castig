const std = @import("std");
const Io = std.Io;

const castig = @import("castig");
const render = @import("render.zig");

const usage =
    \\usage: castig <command> [args]
    \\
    \\commands:
    \\  ls [--timeout <ms>]   discover cast devices on the local network (default 2000 ms)
    \\  probe <file>          print the streams of a media file and whether it can be cast directly
    \\  status <device>       show what the receiver is doing
    \\  cast <device> <file|url> [--title <t>] [--type <mime>] [--subs <file|url|auto>] [--remux <mode>]
    \\                        play a local file or a URL and follow playback.
    \\                        --subs adds a .srt or .vtt track (on by default);
    \\                        without it a sidecar <name>.srt / <name>.<lang>.srt
    \\                        next to the file is used, and `--subs auto` downloads
    \\                        a hash match from OpenSubtitles when there is none.
    \\                        Embedded text subtitles are offered too, pick one
    \\                        from the receiver's subtitle menu. When audio must
    \\                        be remuxed, --remux picks how: auto (default: hls,
    \\                        falling back to mp4 if the receiver refuses it),
    \\                        hls (seekable, instant), mp4 (seekable, no temp
    \\                        file, brief startup), or stream (instant, no seek)
    \\  pause <device>        pause the current item
    \\  play <device>         resume the current item
    \\  seek <device> <pos>   jump to <pos>: seconds, m:ss, h:mm:ss, or +N / -N relative
    \\  rate <device> <x>     set playback speed, 0.5 to 2.0
    \\  stop <device>         stop whatever app is running on the receiver
    \\  subs <file> [--lang en,ko] [--auto]
    \\                        download a subtitle from OpenSubtitles.com next to
    \\                        the file: pick from a ranked list, or with --auto
    \\                        take a trusted hash match only. Needs an API key
    \\                        and login in ~/.config/castig/config (see README)
    \\  help                  show this message
    \\
    \\<device> is an IP, IP:port, or part of a name shown by `ls`.
    \\
;

/// Debug logs (every cast message, every HTTP request) are printed only with
/// CASTIG_DEBUG set; the level is decided at runtime in `logFn`.
pub const std_options: std.Options = .{
    .log_level = .debug,
    .logFn = logFn,
};

var debug_enabled = false;

fn logFn(comptime level: std.log.Level, comptime scope: @EnumLiteral(), comptime format: []const u8, args: anytype) void {
    if (level == .debug and !debug_enabled) return;
    std.log.defaultLog(level, scope, format, args);
}

const Command = enum { ls, probe, status, stop, pause, play, seek, rate, cast, subs, help };

pub fn main(init: std.process.Init) u8 {
    run(init) catch |err| switch (err) {
        // Already explained on stderr by the library.
        error.InvalidRate, error.InvalidSeek, error.NoMedia, error.RequestFailed, error.DeviceNotFound, error.SourceUnreadable, error.NoCredentials, error.NoSubtitles => return 1,
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
    const env: castig.Env = .{ .io = io, .arena = arena, .gpa = init.gpa, .out = out, .environ = init.environ_map };

    if (args.len < 2) fail(usage);
    debug_enabled = if (init.environ_map.get("CASTIG_DEBUG")) |v| v.len > 0 else false;
    if (init.environ_map.get("CASTIG_AUDIO_JOBS")) |v| castig.vmp4.audio_jobs = std.fmt.parseInt(usize, v, 10) catch null;

    const cmd = if (std.mem.eql(u8, args[1], "--help") or std.mem.eql(u8, args[1], "-h"))
        Command.help
    else
        std.meta.stringToEnum(Command, args[1]) orelse fail(usage);

    switch (cmd) {
        .ls => {
            var timeout_ms: u32 = castig.discovery.default_timeout_ms;
            var i: usize = 2;
            while (i < args.len) : (i += 1) {
                if (std.mem.eql(u8, args[i], "--timeout") and i + 1 < args.len) {
                    i += 1;
                    timeout_ms = std.fmt.parseInt(u32, args[i], 10) catch fail("--timeout expects a number of milliseconds\n");
                } else fail(usage);
            }
            const found = try castig.discovery.discover(io, init.gpa, timeout_ms, null);
            defer init.gpa.free(found);
            defer castig.discovery.freeDevices(init.gpa, found);
            try render.devices(out, found, timeout_ms);
        },
        .probe => {
            if (args.len != 3) fail(usage);
            const r = castig.probe.inspect(arena, args[2]) catch |err| {
                std.debug.print("cannot open {s}: {s}\n", .{ args[2], @errorName(err) });
                return error.SourceUnreadable;
            };
            try render.report(out, r);
        },
        .status => {
            if (args.len != 3) fail(usage);
            try render.status(out, try castig.control.status(env, args[2]));
        },
        .stop => {
            if (args.len != 3) fail(usage);
            try render.stopped(out, try castig.control.stop(env, args[2]));
        },
        .pause, .play => {
            if (args.len != 3) fail(usage);
            const m = switch (cmd) {
                .pause => try castig.control.pause(env, args[2]),
                .play => try castig.control.play(env, args[2]),
                else => unreachable,
            };
            try render.media(out, m);
        },
        .seek => {
            if (args.len != 4) fail(usage);
            try render.media(out, try castig.control.seek(env, args[2], args[3]));
        },
        .rate => {
            if (args.len != 4) fail(usage);
            const value = std.fmt.parseFloat(f64, args[3]) catch {
                std.debug.print("rate must be a number\n", .{});
                return error.InvalidRate;
            };
            try render.media(out, try castig.control.rate(env, args[2], value));
        },
        .cast => {
            if (args.len < 4) fail(usage);
            var opts: castig.session.Options = .{ .source = args[3] };
            var i: usize = 4;
            while (i < args.len) : (i += 1) {
                const flag = args[i];
                if (i + 1 >= args.len) fail(usage);
                i += 1;
                if (std.mem.eql(u8, flag, "--title")) {
                    opts.title = args[i];
                } else if (std.mem.eql(u8, flag, "--type")) {
                    opts.content_type = args[i];
                } else if (std.mem.eql(u8, flag, "--subs")) {
                    opts.subtitles = if (std.mem.eql(u8, args[i], "auto")) .download else .{ .source = args[i] };
                } else if (std.mem.eql(u8, flag, "--remux")) {
                    opts.remux = std.meta.stringToEnum(castig.delivery.Remux, args[i]) orelse fail("--remux expects auto, hls, mp4, or stream\n");
                } else fail(usage);
            }
            const session = try castig.session.Session.start(env, args[2], opts);
            defer session.deinit();
            while (try session.next()) |e| try render.event(out, e);
        },
        .subs => {
            if (args.len < 3) fail(usage);
            var opts: castig.subs.Options = .{};
            var i: usize = 3;
            while (i < args.len) : (i += 1) {
                if (std.mem.eql(u8, args[i], "--auto")) {
                    opts.auto = true;
                } else if (std.mem.eql(u8, args[i], "--lang") and i + 1 < args.len) {
                    i += 1;
                    opts.languages = try castig.subs.config.splitLanguages(arena, args[i]);
                } else fail(usage);
            }
            _ = try castig.subs.fetch(env, args[2], opts);
        },
        .help => try out.writeAll(usage),
    }

    try out.flush();
}

fn fail(msg: []const u8) noreturn {
    std.debug.print("{s}", .{msg});
    std.process.exit(1);
}
