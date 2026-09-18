const std = @import("std");
const Io = std.Io;

const discovery = @import("discovery.zig");
const probe = @import("probe.zig");

const usage =
    \\usage: castig <command> [args]
    \\
    \\commands:
    \\  ls [--timeout <ms>]   discover cast devices on the local network (default 2000 ms)
    \\  probe <file>          print the streams of a media file and whether it can be cast directly
    \\  help                  show this message
    \\
;

pub fn main(init: std.process.Init) !void {
    const arena = init.arena.allocator();
    const io = init.io;
    const args = try init.minimal.args.toSlice(arena);

    var stdout_buffer: [4096]u8 = undefined;
    var stdout_writer: Io.File.Writer = .init(.stdout(), io, &stdout_buffer);
    const out = &stdout_writer.interface;

    if (args.len < 2) fail(usage);
    const cmd = args[1];

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
    _ = @import("av_extra.zig");
    _ = @import("cast/proto.zig");
    _ = @import("cast/channel.zig");
    _ = @import("http/server.zig");
    _ = @import("media/pipeline.zig");
}
