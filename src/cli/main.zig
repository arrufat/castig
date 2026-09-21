const std = @import("std");
const Io = std.Io;

const castig = @import("castig");
const render = @import("render.zig");
const prompt = @import("prompt.zig");
const progress = @import("progress.zig");

const usage =
    \\usage: castig <command> [args]
    \\
    \\commands:
    \\  ls        discover cast receivers and DLNA renderers on the network
    \\  probe     print a file's streams and whether it can be cast directly
    \\  status    show what the receiver is doing
    \\  watch     follow what is playing, whoever started it
    \\  cast      play a local file or a URL and follow playback
    \\  pause     pause the current item
    \\  play      resume the current item
    \\  seek      jump to a position
    \\  rate      set playback speed
    \\  stop      stop whatever app is running on the receiver
    \\  ui        open the window
    \\  subs      download a subtitle next to a video
    \\  version   print the version
    \\  help      show this message
    \\
    \\<device> is an IP, IP:port, a renderer URL, or part of a name shown\n    \\by `ls`. Prefix it with `cast:` or `dlna:` to settle an ambiguous name.
    \\
    \\Run `castig help <command>` for what a command takes.
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

const Command = enum { ls, probe, status, watch, stop, pause, play, seek, rate, cast, subs, ui, version, help };

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

    if (args.len < 2) fail(usage);
    castig.av_extra.quietLibav();
    debug_enabled = if (init.environ_map.get("CASTIG_DEBUG")) |v| v.len > 0 else false;

    const cmd = if (std.mem.eql(u8, args[1], "--help") or std.mem.eql(u8, args[1], "-h"))
        Command.help
    else
        std.meta.stringToEnum(Command, args[1]) orelse fail(usage);

    // `castig help <command>` and `castig <command> --help` print one page.
    if (helpTopic(cmd, args)) |topic| {
        try out.writeAll(help(topic));
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
                } else fail(help(cmd));
            }
            const timeout_ms = query.timeout_ms;
            const found = try castig.discovery.discover(io, init.gpa, query);
            defer init.gpa.free(found);
            defer castig.discovery.freeDevices(init.gpa, found);
            try render.devices(out, found, timeout_ms);
        },
        .probe => {
            if (args.len < 3) fail(help(cmd));
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
                } else fail(help(cmd));
            }
            const r = castig.probe.inspect(arena, args[2], profile) catch |err| {
                std.debug.print("cannot open {s}: {s}\n", .{ args[2], @errorName(err) });
                return error.SourceUnreadable;
            };
            try render.report(out, r, device);
        },
        .status => {
            if (args.len != 3) fail(help(cmd));
            try render.status(out, try castig.control.status(env, args[2]));
        },
        .watch => {
            if (args.len != 3) fail(help(cmd));
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
            if (args.len != 3) fail(help(cmd));
            try render.stopped(out, try castig.control.stop(env, args[2]));
        },
        .pause, .play => {
            if (args.len != 3) fail(help(cmd));
            try render.media(out, try castig.control.command(env, args[2], if (cmd == .pause) .pause else .play));
        },
        .seek => {
            if (args.len != 4) fail(help(cmd));
            try render.media(out, try castig.control.seek(env, args[2], args[3]));
        },
        .rate => {
            if (args.len != 4) fail(help(cmd));
            const value = std.fmt.parseFloat(f64, args[3]) catch {
                std.debug.print("rate must be a number\n", .{});
                return error.InvalidRate;
            };
            try render.media(out, try castig.control.rate(env, args[2], value));
        },
        .cast => {
            if (args.len < 4) fail(help(cmd));
            var opts: castig.session.Options = .{ .source = args[3] };
            var i: usize = 4;
            while (i < args.len) : (i += 1) {
                const flag = args[i];
                if (i + 1 >= args.len) fail(help(cmd));
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
                } else fail(help(cmd));
            }
            const session = try castig.session.Session.start(env, args[2], opts);
            defer session.deinit();
            while (try session.next()) |e| try render.event(out, e);
        },
        .subs => {
            if (args.len < 3) fail(help(cmd));
            var opts: castig.subs.Options = .{};
            var auto = false;
            var i: usize = 3;
            while (i < args.len) : (i += 1) {
                if (std.mem.eql(u8, args[i], "--auto")) {
                    auto = true;
                } else if (std.mem.eql(u8, args[i], "--lang") and i + 1 < args.len) {
                    i += 1;
                    opts.languages = try castig.subs.config.splitLanguages(arena, args[i]);
                } else fail(help(cmd));
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
            if (args.len != 2) fail(help(cmd));
            try out.flush();
            return openWindow(env);
        },
        .version => try out.print("{s}\n", .{castig.version}),
        .help => try out.writeAll(usage),
    }

    try out.flush();
}

/// The command a help request is about, or null when this is real work.
fn helpTopic(cmd: Command, args: []const []const u8) ?Command {
    if (cmd == .help) {
        if (args.len < 3) return null;
        return std.meta.stringToEnum(Command, args[2]) orelse fail(usage);
    }
    for (args[2..]) |arg| {
        if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) return cmd;
    }
    return null;
}

/// What a command takes. The index in `usage` stays one line per command, so
/// everything a command needs explaining goes here.
fn help(cmd: Command) []const u8 {
    return switch (cmd) {
        .ls =>
        \\usage: castig ls [--timeout <ms>] [--protocol cast|dlna]
        \\
        \\Find the devices castig can drive: Cast receivers over mDNS and
        \\UPnP AV renderers over SSDP. Both rounds run at once.
        \\
        \\The last column is what to pass as <device>: an id for a Cast
        \\receiver, a description URL for a renderer. Part of a name works
        \\too, and `cast:name` or `dlna:name` settles one that matches both.
        \\
        \\  --timeout <ms>       how long to listen for replies (default 2000)
        \\  --protocol cast|dlna only look for one kind
        \\
        ,
        .watch =>
        \\usage: castig watch <device>
        \\
        \\Follow what the device is playing until it stops, whoever started
        \\it. A Cast receiver reports as it goes; a DLNA renderer is asked
        \\once a second, since UPnP AV tells nobody anything by itself.
        \\
        ,
        .probe =>
        \\usage: castig probe <file> [--device <device>]
        \\
        \\Print the streams of a media file, and whether a device can play it
        \\as it is or the audio has to be transcoded.
        \\
        \\  --device <d>  judge it against this device rather than against a
        \\                Cast receiver. A Cast receiver answers the same as
        \\                the default, since that is already its own list.
        \\                A DLNA renderer is asked what it accepts, and
        \\                usually accepts more than the default assumes.
        \\
        ,
        .status =>
        \\usage: castig status <device>
        \\
        \\Show what the receiver is playing, and where it is in the item.
        \\
        ,
        .cast =>
        \\usage: castig cast <device> <file|url> [--title <t>] [--type <mime>]
        \\                                       [--subs <file|url|auto>] [--remux <mode>]
        \\                                       [--protocol cast|dlna]
        \\
        \\Play a local file or a URL and follow playback until it ends. Local
        \\files are served from a built-in HTTP server, so seeking works.
        \\
        \\  --title <t>     what the receiver shows as the title
        \\  --type <mime>   override the media type sent to the receiver
        \\  --subs <arg>    add a .srt or .vtt track. On by default: without it
        \\                  a sidecar <name>.srt or <name>.<lang>.srt next to
        \\                  the file is used. `auto` downloads a hash match
        \\                  from OpenSubtitles when there is none. Embedded
        \\                  text subtitles are offered too, pick one from the
        \\                  receiver's subtitle menu.
        \\  --protocol <p>  which kind of device the name means, when it
        \\                  matches one of each. A `cast:` or `dlna:` prefix
        \\                  on <device> says the same thing.
        \\  --remux <mode>  how transcoded audio is delivered:
        \\                    auto    hls, falling back to mp4 if refused
        \\                    hls     seekable, starts at once
        \\                    mp4     seekable, no temp file, brief startup
        \\                    stream  starts at once, no seeking
        \\
        ,
        .pause =>
        \\usage: castig pause <device>
        \\
        \\Pause the current item, whoever started it.
        \\
        ,
        .play =>
        \\usage: castig play <device>
        \\
        \\Resume the current item, whoever started it.
        \\
        ,
        .seek =>
        \\usage: castig seek <device> <pos>
        \\
        \\Jump to <pos>: seconds, m:ss or h:mm:ss, or +N / -N to move relative
        \\to where playback is now.
        \\
        ,
        .rate =>
        \\usage: castig rate <device> <x>
        \\
        \\Set playback speed, between 0.5 and 2.0.
        \\
        ,
        .stop =>
        \\usage: castig stop <device>
        \\
        \\Stop whatever app is running on the receiver.
        \\
        ,
        .subs =>
        \\usage: castig subs <file> [--lang en,ko] [--auto]
        \\
        \\Download a subtitle from OpenSubtitles.com next to the file. Needs an
        \\API key and login in ~/.config/castig/config (see the README).
        \\
        \\  --lang <list>   comma separated languages to look for
        \\  --auto          take a trusted hash match only, without asking
        \\
        ,
        .ui =>
        \\usage: castig ui
        \\
        \\Open the window. Runs castigui, which `zig build gui` builds.
        \\
        ,
        .version =>
        \\usage: castig version
        \\
        \\Print the version: the tag on a release, otherwise a dev version
        \\carrying the commit count and hash.
        \\
        ,
        .help => usage,
    };
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
