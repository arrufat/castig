//! Asking which subtitle to download.

const std = @import("std");
const Io = std.Io;
const castig = @import("castig");

/// A numbered list with the best match last, so it sits right above the
/// prompt. Enter takes it, `q` or end of input declines.
pub fn pick(io: Io, out: *Io.Writer, l: castig.subs.Lookup) !?usize {
    const cands = l.candidates;
    const multi_feature = l.manyFeatures();

    try out.print("subtitles for {s}", .{Io.Dir.path.basename(l.video)});
    if (l.fps) |f| try out.print(" (video {f} fps)", .{castig.subs.fmtFps(f)});
    try out.writeAll("\n");
    var i = cands.len;
    while (i > 0) {
        i -= 1;
        try out.print("{d:>3}) ", .{i + 1});
        try cands[i].write(out, multi_feature);
        try out.writeAll("\n");
    }

    var buf: [256]u8 = undefined;
    var stdin = Io.File.stdin().readerStreaming(io, &buf);
    var tries: u8 = 0;
    while (tries < 2) : (tries += 1) {
        try out.writeAll("pick [1]: ");
        try out.flush();
        const raw = stdin.interface.takeDelimiter('\n') catch |err| switch (err) {
            error.StreamTooLong => "x",
            else => return null,
        };
        const line = std.mem.trim(u8, raw orelse return null, " \t\r");
        if (line.len == 0) return 0;
        if (std.mem.eql(u8, line, "q")) return null;
        const n = std.fmt.parseInt(usize, line, 10) catch 0;
        if (n >= 1 and n <= cands.len) return n - 1;
        try out.print("enter a number from 1 to {d}, or q\n", .{cands.len});
    }
    return null;
}

/// Whether to ask at all: a pipe gets the confident match or nothing.
pub fn interactive(io: Io) bool {
    return Io.File.stdin().isTty(io) catch false;
}
