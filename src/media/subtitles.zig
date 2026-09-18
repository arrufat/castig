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

fn isNumber(line: []const u8) bool {
    for (line) |c| if (!std.ascii.isDigit(c)) return false;
    return true;
}

fn isTiming(line: []const u8) bool {
    return std.mem.indexOf(u8, line, "-->") != null;
}

fn appendTiming(gpa: std.mem.Allocator, out: *std.ArrayList(u8), line: []const u8) !void {
    for (line) |c| try out.append(gpa, if (c == ',') '.' else c);
}

fn appendText(gpa: std.mem.Allocator, out: *std.ArrayList(u8), line: []const u8) !void {
    var i: usize = 0;
    while (i < line.len) {
        if (line[i] == '{' and i + 1 < line.len and line[i + 1] == '\\') {
            if (std.mem.indexOfScalarPos(u8, line, i, '}')) |close| {
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
