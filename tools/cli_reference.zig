//! Renders `castig help` as one HTML page, from the same strings the binary
//! prints.
//!
//! The command line is the tool's real interface, and autodoc has nowhere to
//! put it: those pages are generated from the library root, which is the
//! command line's absence. So this page is written beside them rather than
//! smuggled into a doc comment, and it is generated rather than written so
//! that a flag cannot be added without it appearing here.
//!
//! usage: cli-reference <out.html> <version>

const std = @import("std");
const Io = std.Io;

const help = @import("help");

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const arena = init.arena.allocator();
    const args = try init.minimal.args.toSlice(arena);
    if (args.len != 3) {
        std.log.err("usage: cli-reference <out.html> <version>", .{});
        return error.BadUsage;
    }

    var buf: [64 * 1024]u8 = undefined;
    const file = try Io.Dir.cwd().createFile(io, args[1], .{});
    defer file.close(io);
    var fw = file.writer(io, &buf);
    const w = &fw.interface;

    try w.print(head, .{args[2]});

    try w.writeAll("<h2>Synopsis</h2>\n<pre>");
    try escape(w, help.usage);
    try w.writeAll("</pre>\n<h2>Commands</h2>\n<nav>");

    // Driven by the enum, so a command cannot be added without landing here.
    const names = @typeInfo(help.Command).@"enum".field_names;
    inline for (names) |name| try w.print("<a href=\"#{s}\">{s}</a>", .{ name, name });
    try w.writeAll("</nav>\n");

    inline for (names) |name| {
        try w.print("<h3 id=\"{s}\">{s}</h3>\n<pre>", .{ name, name });
        try escape(w, help.help(@field(help.Command, name)));
        try w.writeAll("</pre>\n");
    }

    try w.writeAll(tail);
    try w.flush();
}

/// The five characters that would otherwise close a tag or start an entity.
/// `<device>` appears in nearly every usage line.
fn escape(w: *Io.Writer, text: []const u8) !void {
    for (text) |c| switch (c) {
        '&' => try w.writeAll("&amp;"),
        '<' => try w.writeAll("&lt;"),
        '>' => try w.writeAll("&gt;"),
        '"' => try w.writeAll("&quot;"),
        '\'' => try w.writeAll("&#39;"),
        else => try w.writeByte(c),
    };
}

const head =
    \\<!DOCTYPE html>
    \\<html lang="en">
    \\<head>
    \\<meta charset="utf-8">
    \\<meta name="viewport" content="width=device-width, initial-scale=1">
    \\<title>castig command line</title>
    \\<style>
    \\  :root {{ color-scheme: light dark; --fg: #111; --bg: #fff; --dim: #555; --line: #d0d0d0; --box: #f6f6f6; }}
    \\  @media (prefers-color-scheme: dark) {{
    \\    :root {{ --fg: #e6e6e6; --bg: #1b1b1b; --dim: #a0a0a0; --line: #3a3a3a; --box: #242424; }}
    \\  }}
    \\  body {{ margin: 0 auto; max-width: 46rem; padding: 2rem 1rem 4rem;
    \\         background: var(--bg); color: var(--fg);
    \\         font: 16px/1.55 system-ui, sans-serif; }}
    \\  h1 {{ margin-bottom: .2rem; }}
    \\  h2 {{ margin-top: 2.5rem; border-bottom: 1px solid var(--line); padding-bottom: .3rem; }}
    \\  h3 {{ margin-top: 2rem; font-family: ui-monospace, monospace; }}
    \\  pre {{ background: var(--box); border: 1px solid var(--line); border-radius: 6px;
    \\        padding: .8rem 1rem; overflow-x: auto; font-size: 14px; }}
    \\  .sub {{ color: var(--dim); margin-top: 0; }}
    \\  nav a {{ display: inline-block; margin: 0 .8rem .4rem 0; font-family: ui-monospace, monospace; }}
    \\</style>
    \\</head>
    \\<body>
    \\<h1>castig</h1>
    \\<p class="sub">Cast a local file or a URL to a Chromecast or a DLNA renderer,
    \\as a single static binary. Version {s}.</p>
    \\<p><a href="api/">Library API documentation</a> &middot;
    \\<a href="https://github.com/arrufat/castig">Source</a></p>
    \\
;

const tail =
    \\</body>
    \\</html>
    \\
;
