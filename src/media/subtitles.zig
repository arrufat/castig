//! Subtitle conversion for the receiver, which only plays WebVTT sidecars.

const std = @import("std");

/// Converts SubRip text to WebVTT. Input that is already WebVTT is returned
/// as a copy. Cue numbers are dropped, `,` becomes `.` in timestamps, ASS
/// override tags such as `{\an8}` are removed, and line endings are
/// normalised.
pub fn srtToVtt(gpa: std.mem.Allocator, srt: []const u8) ![]u8 {
    var text = srt;
    if (std.mem.startsWith(u8, text, "\xEF\xBB\xBF")) text = text[3..];
    if (std.mem.startsWith(u8, text, "WEBVTT")) return gpa.dupe(u8, text);

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    try out.appendSlice(gpa, "WEBVTT\n\n");

    var lines = std.mem.splitScalar(u8, text, '\n');
    var previous_blank = true;
    while (lines.next()) |raw| {
        const line = std.mem.trimEnd(u8, raw, "\r");
        if (line.len == 0) {
            if (!previous_blank) try out.append(gpa, '\n');
            previous_blank = true;
            continue;
        }
        // A cue number is a line of digits right before a timing line.
        if (previous_blank and isNumber(line)) {
            if (lines.peek()) |next| if (isTiming(std.mem.trimEnd(u8, next, "\r"))) continue;
        }
        previous_blank = false;
        if (isTiming(line)) {
            try appendTiming(gpa, &out, line);
        } else {
            try appendText(gpa, &out, line);
        }
        try out.append(gpa, '\n');
    }
    // One newline ends the last cue; drop the blank lines a trailing CRLF adds.
    while (std.mem.endsWith(u8, out.items, "\n\n")) out.items.len -= 1;
    return out.toOwnedSlice(gpa);
}

/// Whether a libav subtitle codec name is a text format we can turn into
/// WebVTT from its packets alone. Bitmap subtitles (PGS, DVB, VOBSUB, DVD)
/// are images and cannot become text tracks.
pub fn textIsSupported(codec: []const u8) bool {
    return text_codecs.has(codec);
}

const text_codecs = std.StaticStringMap(void).initComptime(.{
    .{"subrip"}, .{"srt"}, .{"text"}, .{"ass"}, .{"ssa"}, .{"mov_text"}, .{"webvtt"},
});

/// A human-readable name for an ISO 639 language code (as ffmpeg reports it,
/// usually 639-2/B), falling back to the code itself for anything unlisted.
pub fn languageName(code: []const u8) []const u8 {
    const table = std.StaticStringMap([]const u8).initComptime(.{
        .{ "eng", "English" },    .{ "ger", "German" },   .{ "deu", "German" },
        .{ "fre", "French" },     .{ "fra", "French" },   .{ "spa", "Spanish" },
        .{ "ita", "Italian" },    .{ "dut", "Dutch" },    .{ "nld", "Dutch" },
        .{ "por", "Portuguese" }, .{ "rus", "Russian" },  .{ "pol", "Polish" },
        .{ "vie", "Vietnamese" }, .{ "jpn", "Japanese" }, .{ "chi", "Chinese" },
        .{ "zho", "Chinese" },    .{ "kor", "Korean" },   .{ "ara", "Arabic" },
        .{ "hin", "Hindi" },      .{ "swe", "Swedish" },  .{ "nor", "Norwegian" },
        .{ "dan", "Danish" },     .{ "fin", "Finnish" },  .{ "tur", "Turkish" },
        .{ "gre", "Greek" },      .{ "ell", "Greek" },    .{ "heb", "Hebrew" },
        .{ "tha", "Thai" },       .{ "cze", "Czech" },    .{ "ces", "Czech" },
        .{ "hun", "Hungarian" },  .{ "rum", "Romanian" }, .{ "ron", "Romanian" },
        .{ "ukr", "Ukrainian" },  .{ "cat", "Catalan" },  .{ "ind", "Indonesian" },
    });
    return table.get(code) orelse code;
}

/// Starts a WebVTT document.
pub fn writeVttHeader(gpa: std.mem.Allocator, out: *std.ArrayList(u8)) !void {
    try out.appendSlice(gpa, "WEBVTT\n\n");
}

/// Appends one cue from a demuxed subtitle packet: `data` is the packet
/// payload, `codec` its libav name, times in milliseconds. Empty cues (a
/// clear event) are skipped.
pub fn writeVttCue(gpa: std.mem.Allocator, out: *std.ArrayList(u8), start_ms: i64, end_ms: i64, codec: []const u8, data: []const u8) !void {
    // Clean the text in place after the timing line; roll back an empty cue.
    const cue_start = out.items.len;
    try appendTime(gpa, out, start_ms);
    try out.appendSlice(gpa, " --> ");
    try appendTime(gpa, out, end_ms);
    try out.append(gpa, '\n');
    const text_start = out.items.len;
    try appendCleanText(gpa, out, cueText(codec, data));
    const text = std.mem.trim(u8, out.items[text_start..], " \t\r\n");
    if (text.len == 0) {
        out.items.len = cue_start;
        return;
    }
    std.mem.copyForwards(u8, out.items[text_start..], text);
    out.items.len = text_start + text.len;
    try out.appendSlice(gpa, "\n\n");
}

/// The text portion of a subtitle packet, per codec.
fn cueText(codec: []const u8, data: []const u8) []const u8 {
    if (std.mem.eql(u8, codec, "ass") or std.mem.eql(u8, codec, "ssa")) {
        // Matroska ASS: "ReadOrder,Layer,Style,Name,MarginL,MarginR,MarginV,
        // Effect,Text"; the text is everything after the 8th comma.
        var i: usize = 0;
        var commas: usize = 0;
        while (i < data.len and commas < 8) : (i += 1) {
            if (data[i] == ',') commas += 1;
        }
        return if (commas == 8) data[i..] else data;
    }
    if (std.mem.eql(u8, codec, "mov_text")) {
        // MP4 tx3g: a 16-bit big-endian length then that many UTF-8 bytes.
        if (data.len < 2) return "";
        const n = std.mem.readInt(u16, data[0..2], .big);
        return data[2..@min(2 + @as(usize, n), data.len)];
    }
    return data; // subrip / srt / text / webvtt: raw text
}

/// Copies text, dropping `{...}` override blocks and CRs, and turning the ASS
/// line breaks `\N` and `\n` into newlines and `\h` into a space.
fn appendCleanText(gpa: std.mem.Allocator, out: *std.ArrayList(u8), text: []const u8) !void {
    var i: usize = 0;
    while (i < text.len) {
        const c = text[i];
        if (c == '\r') {
            i += 1;
            continue;
        }
        if (c == '{') {
            if (std.mem.findScalarPos(u8, text, i, '}')) |close| {
                i = close + 1;
                continue;
            }
        }
        if (c == '\\' and i + 1 < text.len) {
            switch (text[i + 1]) {
                'N', 'n' => {
                    try out.append(gpa, '\n');
                    i += 2;
                    continue;
                },
                'h' => {
                    try out.append(gpa, ' ');
                    i += 2;
                    continue;
                },
                else => {},
            }
        }
        try out.append(gpa, c);
        i += 1;
    }
}

fn appendTime(gpa: std.mem.Allocator, out: *std.ArrayList(u8), ms_in: i64) !void {
    const ms: u64 = if (ms_in < 0) 0 else @intCast(ms_in);
    var buf: [16]u8 = undefined;
    const t = try std.mem.print(&buf, "{d:0>2}:{d:0>2}:{d:0>2}.{d:0>3}", .{
        ms / 3_600_000,
        (ms / 60_000) % 60,
        (ms / 1000) % 60,
        ms % 1000,
    });
    try out.appendSlice(gpa, t);
}

fn isNumber(line: []const u8) bool {
    for (line) |c| if (!std.ascii.isDigit(c)) return false;
    return true;
}

fn isTiming(line: []const u8) bool {
    return std.mem.find(u8, line, "-->") != null;
}

fn appendTiming(gpa: std.mem.Allocator, out: *std.ArrayList(u8), line: []const u8) !void {
    const start = out.items.len;
    try out.appendSlice(gpa, line);
    std.mem.replaceScalar(u8, out.items[start..], ',', '.');
}

fn appendText(gpa: std.mem.Allocator, out: *std.ArrayList(u8), line: []const u8) !void {
    var i: usize = 0;
    while (i < line.len) {
        if (line[i] == '{' and i + 1 < line.len and line[i + 1] == '\\') {
            if (std.mem.findScalarPos(u8, line, i, '}')) |close| {
                i = close + 1;
                continue;
            }
        }
        try out.append(gpa, line[i]);
        i += 1;
    }
}

test "srt to vtt" {
    const srt =
        "\xEF\xBB\xBF1\r\n00:00:01,000 --> 00:00:02,500\r\nHello\r\n\r\n2\r\n00:01:00,000 --> 00:01:03,000\r\n{\\an8}<i>Two</i>\r\nlines\r\n";
    const vtt = try srtToVtt(std.testing.allocator, srt);
    defer std.testing.allocator.free(vtt);
    try std.testing.expectEqualStrings(
        "WEBVTT\n\n00:00:01.000 --> 00:00:02.500\nHello\n\n00:01:00.000 --> 00:01:03.000\n<i>Two</i>\nlines\n",
        vtt,
    );
}

test "vtt passes through" {
    const vtt = try srtToVtt(std.testing.allocator, "WEBVTT\n\n00:00.000 --> 00:01.000\nx\n");
    defer std.testing.allocator.free(vtt);
    try std.testing.expect(std.mem.startsWith(u8, vtt, "WEBVTT"));
}

test "language names" {
    try std.testing.expectEqualStrings("English", languageName("eng"));
    try std.testing.expectEqualStrings("German", languageName("ger"));
    try std.testing.expectEqualStrings("xyz", languageName("xyz"));
}

test "text codec detection" {
    try std.testing.expect(textIsSupported("subrip"));
    try std.testing.expect(textIsSupported("ass"));
    try std.testing.expect(textIsSupported("mov_text"));
    try std.testing.expect(!textIsSupported("hdmv_pgs_subtitle"));
    try std.testing.expect(!textIsSupported("dvb_subtitle"));
}

test "vtt cue from ass packet" {
    const gpa = std.testing.allocator;
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(gpa);
    try writeVttHeader(gpa, &out);
    // Fields: ReadOrder,Layer,Style,Name,MarginL,MarginR,MarginV,Effect,Text.
    try writeVttCue(gpa, &out, 1000, 2500, "ass", "0,0,Default,,0,0,0,,{\\an8}Hello\\NWorld");
    try std.testing.expectEqualStrings(
        "WEBVTT\n\n00:00:01.000 --> 00:00:02.500\nHello\nWorld\n\n",
        out.items,
    );
}

test "vtt cue from mov_text packet" {
    const gpa = std.testing.allocator;
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(gpa);
    // A 16-bit length (5) then "Hello".
    try writeVttCue(gpa, &out, 0, 1000, "mov_text", "\x00\x05Hello");
    try std.testing.expectEqualStrings("00:00:00.000 --> 00:00:01.000\nHello\n\n", out.items);
}

test "empty cue skipped" {
    const gpa = std.testing.allocator;
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(gpa);
    try writeVttCue(gpa, &out, 0, 1000, "mov_text", "\x00\x00");
    try std.testing.expectEqual(@as(usize, 0), out.items.len);
}

test "subrip cue keeps line breaks" {
    const gpa = std.testing.allocator;
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(gpa);
    try writeVttCue(gpa, &out, 3_723_500, 3_725_000, "subrip", "Line one\r\nLine two");
    try std.testing.expectEqualStrings(
        "01:02:03.500 --> 01:02:05.000\nLine one\nLine two\n\n",
        out.items,
    );
}
