//! Turning what the library returns into lines on a terminal.

const std = @import("std");
const Io = std.Io;
const castig = @import("castig");

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

pub fn report(out: *Io.Writer, r: castig.probe.Report) !void {
    try out.print("{s}\n", .{r.path});
    try out.print("  container: {s}", .{r.container});
    if (r.duration) |secs| try out.print(", duration: {d:.1} s", .{secs});
    try out.writeAll("\n");

    for (r.streams) |s| {
        try out.print("  #{d} {s} {s}", .{ s.index, s.type_name, s.codec });
        if (s.language) |l| try out.print(" [{s}]", .{l});
        if (s.video) |v| try out.print(" {d}x{d} {d:.3} fps", .{ v.width, v.height, v.fps });
        if (s.audio) |a| try out.print(" {d} ch {d} Hz", .{ a.channels, a.sample_rate });
        if (s.support) |sup| try out.print(" -> {s}", .{sup.label()});
        if (s.kind == .subtitle) try out.writeAll(if (s.text) " -> webvtt" else " -> bitmap, burn-in only");
        try out.writeAll("\n");
    }

    try out.writeAll("  verdict: ");
    if (!r.castable()) return out.writeAll("nothing to cast\n");
    if (r.video) |v| try out.print("video {s}", .{v.label()});
    if (r.audio) |a| {
        if (r.video != null) try out.writeAll(", ");
        try out.print("audio {s}", .{a.label()});
    }
    if (r.text_subs > 0) try out.print(", {d} text subtitle track(s)", .{r.text_subs});
    if (r.bitmap_subs > 0) try out.print(", {d} bitmap subtitle track(s)", .{r.bitmap_subs});
    try out.writeAll("\n");
}

pub fn status(out: *Io.Writer, s: castig.control.Status) !void {
    try out.print("{f}\n", .{s.address});
    try out.print("  volume: {d:.0}%{s}\n", .{ s.receiver.volume.level * 100, if (s.receiver.volume.muted) " (muted)" else "" });
    if (s.receiver.applications.len == 0) try out.writeAll("  no app running\n");
    for (s.receiver.applications) |a| {
        try out.print("  app: {s} ({s}){s}", .{ a.displayName, a.appId, if (a.isIdleScreen) " idle screen" else "" });
        if (a.statusText.len > 0) try out.print(" - {s}", .{a.statusText});
        try out.print("\n       session {s}, transport {s}\n", .{ a.sessionId, a.transportId });
    }
}

pub fn stopped(out: *Io.Writer, names: []const []const u8) !void {
    for (names) |n| try out.print("stopped {s}\n", .{n});
    if (names.len == 0) try out.writeAll("nothing to stop\n");
}

pub fn media(out: *Io.Writer, m: castig.channel.Channel.MediaStatus) !void {
    try out.print("  {t} at {d:.1} s", .{ m.playerState, m.currentTime });
    if (m.duration()) |d| try out.print(" of {d:.1} s", .{d});
    if (m.playbackRate != 1) try out.print(" x{d:.2}", .{m.playbackRate});
    if (m.idleReason) |r| try out.print(" ({t})", .{r});
    try out.writeAll("\n");
}

/// One line per event of a cast. Progress notes go to stderr, so stdout stays
/// the record of what played.
pub fn event(out: *Io.Writer, e: castig.session.Event) !void {
    switch (e) {
        .serving => |base| try out.print("serving at {s}\n", .{base}),
        .loaded => |l| try out.print("loaded on {f} as {s}\n", .{ l.address, l.content_type }),
        .state => |m| try media(out, m),
        .falling_back => {
            try out.flush();
            std.debug.print("receiver refused HLS; falling back to seekable mp4 ...\n", .{});
        },
        .finished => |reason| try out.print("finished: {s}\n", .{if (reason) |r| @tagName(r) else "?"}),
        .closed => try out.writeAll("receiver closed the session\n"),
    }
    try out.flush();
}

/// One subtitle row: tags, download count, frame rate when it disagrees with
/// the video, and the release (with the feature when results span several).
pub fn candidate(out: *Io.Writer, c: castig.subs.Candidate, multi_feature: bool) !void {
    if (c.hash == 2) try out.writeAll("[HASH] ");
    if (c.hash == 1) try out.writeAll("[HASH?] ");
    try out.print("[{s}]", .{c.lang});
    if (c.hi) try out.writeAll(" [HI]");
    if (c.ai) try out.writeAll(" [AI]");
    try out.print(" {d} dl", .{c.downloads});
    if (c.fps_mismatch) if (c.fps) |f| {
        try out.writeAll(", ");
        try fps(out, f);
        try out.writeAll(" fps");
    };
    try out.writeAll(" \u{b7} ");
    if (multi_feature) if (c.feature) |f| try out.print("{s} \u{b7} ", .{f});
    try out.writeAll(c.release);
}

/// Two decimals with the trailing zeros dropped: 23.98, 24.
pub fn fps(out: *Io.Writer, value: f64) !void {
    var buf: [32]u8 = undefined;
    const s = try std.fmt.bufPrint(&buf, "{d:.2}", .{value});
    try out.writeAll(std.mem.trimEnd(u8, std.mem.trimEnd(u8, s, "0"), "."));
}

test "subtitle rows" {
    var buf: [128]u8 = undefined;
    var w: Io.Writer = .fixed(&buf);
    var c: castig.subs.Candidate = .{
        .file_id = 1,
        .file_name = "",
        .lang = "en",
        .release = "rel",
        .feature_id = 7,
        .feature = null,
        .season = null,
        .episode = null,
        .downloads = 1200,
        .hash = 2,
        .hi = true,
        .ai = false,
        .fps = null,
    };
    try candidate(&w, c, false);
    try std.testing.expectEqualStrings("[HASH] [en] [HI] 1200 dl \u{b7} rel", w.buffered());

    w = .fixed(&buf);
    c = .{
        .file_id = 2,
        .file_name = "",
        .lang = "ko",
        .release = "rel",
        .feature_id = 9,
        .feature = "Show S01E02",
        .season = null,
        .episode = null,
        .downloads = 0,
        .hash = 1,
        .hi = false,
        .ai = true,
        .fps = 25,
        .fps_mismatch = true,
    };
    try candidate(&w, c, true);
    try std.testing.expectEqualStrings("[HASH?] [ko] [AI] 0 dl, 25 fps \u{b7} Show S01E02 \u{b7} rel", w.buffered());

    w = .fixed(&buf);
    try fps(&w, 23.976);
    try std.testing.expectEqualStrings("23.98", w.buffered());
}
