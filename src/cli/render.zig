//! Turning what the library returns into lines on a terminal.

const std = @import("std");
const Io = std.Io;
const castig = @import("castig");

/// The `ls` table, or advice when nothing answered.
pub fn devices(out: *Io.Writer, found: []const castig.discovery.Device, timeout_ms: u32) !void {
    if (found.len == 0) {
        try out.print("no cast devices answered within {d} ms\n", .{timeout_ms});
        try out.writeAll("(check with `avahi-browse -rt _googlecast._tcp`; if devices show there, they ignore unicast-response queries)\n");
        return;
    }
    for (found) |d| {
        try out.print("{s}\t{s}\t{f}\t{s}\n", .{ d.friendly_name, d.model, d.address, d.id });
    }
}

/// The `probe` report: container, streams, and what casting them needs.
pub fn report(out: *Io.Writer, r: castig.probe.Report) !void {
    try out.print("{s}\n", .{r.path});
    try out.print("  container: {s}", .{r.container});
    if (r.duration) |secs| try out.print(", duration: {d:.1} s", .{secs});
    try out.writeAll("\n");

    for (r.streams) |s| try out.print("  #{d} {f}\n", .{ s.index, s });

    try out.writeAll("  verdict: ");
    try r.writeVerdict(out);
    try out.writeAll("\n");
}

/// The `status` view: volume, the running app, and what it plays.
pub fn status(out: *Io.Writer, s: castig.control.Status) !void {
    try out.print("{f}\n", .{s.address});
    if (s.device.volume) |v| {
        try out.print("  volume: {d:.0}%{s}\n", .{ v.level * 100, if (v.muted) " (muted)" else "" });
    }
    if (s.device.apps.len == 0) try out.writeAll("  no app running\n");
    for (s.device.apps) |a| {
        try out.print("  app: {s} ({s}){s}", .{ a.displayName, a.appId, if (a.isIdleScreen) " idle screen" else "" });
        if (a.statusText.len > 0) try out.print(" - {s}", .{a.statusText});
        try out.print("\n       session {s}, transport {s}\n", .{ a.sessionId, a.transportId });
    }
}

/// One line per app that was stopped.
pub fn stopped(out: *Io.Writer, names: []const []const u8) !void {
    for (names) |n| try out.print("stopped {s}\n", .{n});
    if (names.len == 0) try out.writeAll("nothing to stop\n");
}

/// The playback line: state, position, rate and why it ended.
pub fn media(out: *Io.Writer, p: castig.playback.Playback) !void {
    try out.print("  {t} at {d:.1} s", .{ p.state, p.position });
    if (p.duration) |d| try out.print(" of {d:.1} s", .{d});
    if (p.rate != 1) try out.print(" x{d:.2}", .{p.rate});
    if (p.ended) |r| try out.print(" ({t})", .{r});
    try out.writeAll("\n");
}

/// One line per event of a cast. Progress notes go to stderr, so stdout stays
/// the record of what played.
pub fn event(out: *Io.Writer, e: castig.session.Event) !void {
    switch (e) {
        .serving => |base| try out.print("serving at {s}\n", .{base}),
        .loaded => |l| try out.print("loaded on {f} as {s}\n", .{ l.address, l.content_type }),
        .state => |p| try media(out, p),
        .falling_back => {
            try out.flush();
            std.debug.print("receiver refused HLS; falling back to seekable mp4 ...\n", .{});
        },
        .finished => |reason| try out.print("finished: {s}\n", .{if (reason) |r| @tagName(r) else "?"}),
        .closed => try out.writeAll("receiver closed the session\n"),
    }
    try out.flush();
}
