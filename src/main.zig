const std = @import("std");
const Io = std.Io;

const commands = @import("commands.zig");
const discovery = @import("discovery.zig");
const probe = @import("probe.zig");

const usage =
    \\usage: castig <command> [args]
    \\
    \\commands:
    \\  ls [--timeout <ms>]   discover cast devices on the local network (default 2000 ms)
    \\  probe <file>          print the streams of a media file and whether it can be cast directly
    \\  status <device>       show what the receiver is doing
    \\  cast <device> <file|url> [--title <t>] [--type <mime>] [--subs <file|url>] [--remux <mode>]
    \\                        play a local file or a URL and follow playback.
    \\                        --subs adds a .srt or .vtt track (on by default);
    \\                        embedded text subtitles are offered too, pick one
    \\                        from the receiver's subtitle menu. When audio must
    \\                        be remuxed, --remux picks how: hls (default,
    \\                        seekable, up to ~720p), mp4 (seekable, no temp
    \\                        file, brief startup), or stream (instant, no seek)
    \\  pause <device>        pause the current item
    \\  play <device>         resume the current item
    \\  seek <device> <pos>   jump to <pos>: seconds, m:ss, h:mm:ss, or +N / -N relative
    \\  rate <device> <x>     set playback speed, 0.5 to 2.0
    \\  stop <device>         stop whatever app is running on the receiver
    \\
    \\<device> is an IP, IP:port, or part of a name shown by `ls`.
    \\  help                  show this message
    \\
;

pub fn main(init: std.process.Init) u8 {
    run(init) catch |err| switch (err) {
        // Already explained on stderr by the command.
        error.InvalidRate, error.InvalidSeek, error.NoMedia, error.RequestFailed, error.DeviceNotFound => return 1,
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

    if (args.len < 2) fail(usage);
    const cmd = args[1];
    const options: commands.Options = .{
        .debug = if (init.environ_map.get("CASTIG_DEBUG")) |v| v.len > 0 else false,
    };

    if (std.mem.eql(u8, cmd, "ls")) {
        var timeout_ms: u32 = 2000;
        var i: usize = 2;
        while (i < args.len) : (i += 1) {
            if (std.mem.eql(u8, args[i], "--timeout") and i + 1 < args.len) {
                i += 1;
                timeout_ms = std.fmt.parseInt(u32, args[i], 10) catch fail("--timeout expects a number of milliseconds\n");
            } else fail(usage);
        }
        try discovery.run(io, arena, out, timeout_ms);
    } else if (std.mem.eql(u8, cmd, "probe")) {
        if (args.len != 3) fail(usage);
        try probe.run(arena, out, args[2]);
    } else if (std.mem.eql(u8, cmd, "status")) {
        if (args.len != 3) fail(usage);
        try commands.status(io, arena, out, args[2], options);
    } else if (std.mem.eql(u8, cmd, "stop")) {
        if (args.len != 3) fail(usage);
        try commands.stop(io, arena, out, args[2], options);
    } else if (std.mem.eql(u8, cmd, "pause")) {
        if (args.len != 3) fail(usage);
        try commands.pause(io, arena, out, args[2], options);
    } else if (std.mem.eql(u8, cmd, "play")) {
        if (args.len != 3) fail(usage);
        try commands.play(io, arena, out, args[2], options);
    } else if (std.mem.eql(u8, cmd, "seek")) {
        if (args.len != 4) fail(usage);
        try commands.seek(io, arena, out, args[2], args[3], options);
    } else if (std.mem.eql(u8, cmd, "rate")) {
        if (args.len != 4) fail(usage);
        try commands.rate(io, arena, out, args[2], args[3], options);
    } else if (std.mem.eql(u8, cmd, "cast")) {
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
                opts.subtitles = args[i];
            } else if (std.mem.eql(u8, flag, "--remux")) {
                opts.remux = if (std.mem.eql(u8, args[i], "hls"))
                    .hls
                else if (std.mem.eql(u8, args[i], "mp4"))
                    .mp4
                else if (std.mem.eql(u8, args[i], "stream"))
                    .stream
                else
                    fail("--remux expects hls, mp4, or stream\n");
            } else fail(usage);
        }
        try commands.cast(io, arena, out, args[2], opts, options);
    } else if (std.mem.eql(u8, cmd, "help") or std.mem.eql(u8, cmd, "--help") or std.mem.eql(u8, cmd, "-h")) {
        try out.writeAll(usage);
    } else {
        fail(usage);
    }

    try out.flush();
}

fn fail(msg: []const u8) noreturn {
    std.debug.print("{s}", .{msg});
    std.process.exit(1);
}

test {
    _ = @import("dns.zig");
    _ = @import("discovery.zig");
    _ = @import("probe.zig");
    _ = @import("commands.zig");
    _ = @import("media/subtitles.zig");
    _ = @import("av_extra.zig");
    _ = @import("cast/proto.zig");
    _ = @import("cast/channel.zig");
    _ = @import("http/server.zig");
    _ = @import("media/pipeline.zig");
    _ = @import("media/hls.zig");
    _ = @import("media/vmp4.zig");
}
