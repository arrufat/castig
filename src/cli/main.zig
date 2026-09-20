const std = @import("std");
const Io = std.Io;

const castig = @import("castig");
const commands = castig.commands;
const discovery = castig.discovery;
const probe = castig.probe;
const vmp4 = castig.vmp4;
const subs = castig.subs;

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
    \\
    \\<device> is an IP, IP:port, or part of a name shown by `ls`.
    \\  help                  show this message
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
        // Already explained on stderr by the command.
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
    if (init.environ_map.get("CASTIG_AUDIO_JOBS")) |v| vmp4.audio_jobs = std.fmt.parseInt(usize, v, 10) catch null;

    const cmd = if (std.mem.eql(u8, args[1], "--help") or std.mem.eql(u8, args[1], "-h"))
        Command.help
    else
        std.meta.stringToEnum(Command, args[1]) orelse fail(usage);

    switch (cmd) {
        .ls => {
            var timeout_ms: u32 = discovery.default_timeout_ms;
            var i: usize = 2;
            while (i < args.len) : (i += 1) {
                if (std.mem.eql(u8, args[i], "--timeout") and i + 1 < args.len) {
                    i += 1;
                    timeout_ms = std.fmt.parseInt(u32, args[i], 10) catch fail("--timeout expects a number of milliseconds\n");
                } else fail(usage);
            }
            try discovery.run(io, init.gpa, out, timeout_ms);
        },
        .probe => {
            if (args.len != 3) fail(usage);
            try probe.run(arena, out, args[2]);
        },
        .status, .stop, .pause, .play => {
            if (args.len != 3) fail(usage);
            switch (cmd) {
                inline .status, .stop, .pause, .play => |c| try @field(commands, @tagName(c))(env, args[2]),
                else => unreachable,
            }
        },
        .seek => {
            if (args.len != 4) fail(usage);
            try commands.seek(env, args[2], args[3]);
        },
        .rate => {
            if (args.len != 4) fail(usage);
            try commands.rate(env, args[2], args[3]);
        },
        .cast => {
            if (args.len < 4) fail(usage);
            var opts: commands.CastOptions = .{ .source = args[3] };
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
                    opts.remux = std.meta.stringToEnum(commands.Remux, args[i]) orelse fail("--remux expects auto, hls, mp4, or stream\n");
                } else fail(usage);
            }
            try commands.cast(env, args[2], opts);
        },
        .subs => {
            if (args.len < 3) fail(usage);
            var opts: subs.Options = .{};
            var i: usize = 3;
            while (i < args.len) : (i += 1) {
                if (std.mem.eql(u8, args[i], "--auto")) {
                    opts.auto = true;
                } else if (std.mem.eql(u8, args[i], "--lang") and i + 1 < args.len) {
                    i += 1;
                    opts.languages = try subs.config.splitLanguages(arena, args[i]);
                } else fail(usage);
            }
            _ = try subs.fetch(env, args[2], opts);
        },
        .help => try out.writeAll(usage),
    }

    try out.flush();
}

fn fail(msg: []const u8) noreturn {
    std.debug.print("{s}", .{msg});
    std.process.exit(1);
}
