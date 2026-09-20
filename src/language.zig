//! ISO 639 language code to a display name, for naming a subtitle track.
//!
//! Both code systems appear: ffmpeg reports three-letter 639-2 codes from
//! container metadata (usually the bibliographic variant), while
//! OpenSubtitles and sidecar file names use two-letter 639-1 codes.

const std = @import("std");

/// The name for `code`, or the code itself when it is not listed.
pub fn name(code: []const u8) []const u8 {
    return names.get(code) orelse code;
}

/// What to call a subtitle track in the receiver's menu. An unknown or
/// missing language leaves it generic rather than showing "und".
pub fn trackName(code: ?[]const u8) []const u8 {
    const c = code orelse return "Subtitles";
    if (std.mem.eql(u8, c, "und")) return "Subtitles";
    return name(c);
}

const names = std.StaticStringMap([]const u8).initComptime(.{
    .{ "eng", "English" },    .{ "en", "English" },    .{ "ger", "German" },
    .{ "deu", "German" },     .{ "de", "German" },     .{ "fre", "French" },
    .{ "fra", "French" },     .{ "fr", "French" },     .{ "spa", "Spanish" },
    .{ "es", "Spanish" },     .{ "ita", "Italian" },   .{ "it", "Italian" },
    .{ "dut", "Dutch" },      .{ "nld", "Dutch" },     .{ "nl", "Dutch" },
    .{ "por", "Portuguese" }, .{ "pt", "Portuguese" }, .{ "rus", "Russian" },
    .{ "ru", "Russian" },     .{ "pol", "Polish" },    .{ "pl", "Polish" },
    .{ "vie", "Vietnamese" }, .{ "vi", "Vietnamese" }, .{ "jpn", "Japanese" },
    .{ "ja", "Japanese" },    .{ "chi", "Chinese" },   .{ "zho", "Chinese" },
    .{ "zh", "Chinese" },     .{ "kor", "Korean" },    .{ "ko", "Korean" },
    .{ "ara", "Arabic" },     .{ "ar", "Arabic" },     .{ "hin", "Hindi" },
    .{ "hi", "Hindi" },       .{ "swe", "Swedish" },   .{ "sv", "Swedish" },
    .{ "nor", "Norwegian" },  .{ "no", "Norwegian" },  .{ "dan", "Danish" },
    .{ "da", "Danish" },      .{ "fin", "Finnish" },   .{ "fi", "Finnish" },
    .{ "tur", "Turkish" },    .{ "tr", "Turkish" },    .{ "gre", "Greek" },
    .{ "ell", "Greek" },      .{ "el", "Greek" },      .{ "heb", "Hebrew" },
    .{ "he", "Hebrew" },      .{ "tha", "Thai" },      .{ "th", "Thai" },
    .{ "cze", "Czech" },      .{ "ces", "Czech" },     .{ "cs", "Czech" },
    .{ "hun", "Hungarian" },  .{ "hu", "Hungarian" },  .{ "rum", "Romanian" },
    .{ "ron", "Romanian" },   .{ "ro", "Romanian" },   .{ "ukr", "Ukrainian" },
    .{ "uk", "Ukrainian" },   .{ "cat", "Catalan" },   .{ "ca", "Catalan" },
    .{ "ind", "Indonesian" }, .{ "id", "Indonesian" },
});

test "names from both code systems" {
    try std.testing.expectEqualStrings("English", name("eng"));
    try std.testing.expectEqualStrings("English", name("en"));
    try std.testing.expectEqualStrings("German", name("ger"));
    try std.testing.expectEqualStrings("German", name("de"));
    try std.testing.expectEqualStrings("Catalan", name("cat"));
    try std.testing.expectEqualStrings("xyz", name("xyz"));
}
