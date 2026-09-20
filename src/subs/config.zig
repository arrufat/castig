//! The user's OpenSubtitles settings: `$XDG_CONFIG_HOME/castig/config` as
//! `key=value` lines, with the credentials overridable from the environment.

const std = @import("std");
const Io = std.Io;

const log = std.log.scoped(.subs);

pub const Config = struct {
    api_key: []const u8 = "",
    username: []const u8 = "",
    password: []const u8 = "",
    /// ISO 639-1 codes in priority order, as OpenSubtitles names them.
    languages: []const []const u8 = &.{"en"},
    /// Rank hearing-impaired subtitles first.
    prefer_hi: bool = false,
    /// Where downloads go when the video's directory is not writable.
    fallback_dir: []const u8 = "",
    /// The config file, for messages.
    path: []const u8 = "",
    /// `$XDG_CACHE_HOME/castig`: the login token and the last-resort subs dir.
    cache_dir: []const u8 = "",
};

/// The config file (absent is fine: defaults), then the env overrides.
pub fn load(arena: std.mem.Allocator, io: Io, environ: *const std.process.Environ.Map) !Config {
    var cfg: Config = .{
        .path = try std.fs.path.join(arena, &.{ try xdgDir(arena, environ, "XDG_CONFIG_HOME", ".config"), "castig", "config" }),
        .cache_dir = try std.fs.path.join(arena, &.{ try xdgDir(arena, environ, "XDG_CACHE_HOME", ".cache"), "castig" }),
    };
    const text = Io.Dir.cwd().readFileAlloc(io, cfg.path, arena, .limited(64 * 1024)) catch |err| switch (err) {
        error.FileNotFound => "",
        else => {
            std.debug.print("cannot read {s}: {s}\n", .{ cfg.path, @errorName(err) });
            return err;
        },
    };
    try parse(arena, text, &cfg);
    applyEnv(&cfg, environ);
    return cfg;
}

/// `$<name>` when set to an absolute path, else `$HOME/<fallback>`.
fn xdgDir(arena: std.mem.Allocator, environ: *const std.process.Environ.Map, name: []const u8, fallback: []const u8) ![]const u8 {
    if (environ.get(name)) |v| if (std.fs.path.isAbsolute(v)) return v;
    return std.fs.path.join(arena, &.{ environ.get("HOME") orelse ".", fallback });
}

pub fn parse(arena: std.mem.Allocator, text: []const u8, cfg: *Config) !void {
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0 or line[0] == '#') continue;
        const raw_key, const raw_value = std.mem.cutScalar(u8, line, '=') orelse {
            log.debug("config: ignoring line without '=': {s}", .{line});
            continue;
        };
        const key = std.mem.trim(u8, raw_key, " \t");
        const value = std.mem.trim(u8, raw_value, " \t");
        if (std.mem.eql(u8, key, "api_key")) {
            cfg.api_key = value;
        } else if (std.mem.eql(u8, key, "username")) {
            cfg.username = value;
        } else if (std.mem.eql(u8, key, "password")) {
            cfg.password = value;
        } else if (std.mem.eql(u8, key, "languages")) {
            const langs = try splitLanguages(arena, value);
            if (langs.len > 0) cfg.languages = langs;
        } else if (std.mem.eql(u8, key, "prefer_hi")) {
            cfg.prefer_hi = parseBool(value) orelse cfg.prefer_hi;
        } else if (std.mem.eql(u8, key, "fallback_dir")) {
            cfg.fallback_dir = value;
        } else {
            log.debug("config: unknown key {s}", .{key});
        }
    }
}

/// An empty value does not override, so `VAR= castig ...` is not a way to
/// blank a credential by accident.
pub fn applyEnv(cfg: *Config, environ: *const std.process.Environ.Map) void {
    inline for (.{
        .{ "OPENSUBTITLES_API_KEY", &cfg.api_key },
        .{ "OPENSUBTITLES_USERNAME", &cfg.username },
        .{ "OPENSUBTITLES_PASSWORD", &cfg.password },
    }) |over| {
        if (environ.get(over[0])) |v| if (v.len > 0) {
            over[1].* = v;
        };
    }
}

/// "en, KO" -> {"en", "ko"}.
pub fn splitLanguages(arena: std.mem.Allocator, text: []const u8) ![]const []const u8 {
    var langs: std.ArrayList([]const u8) = .empty;
    var it = std.mem.tokenizeAny(u8, text, ", \t");
    while (it.next()) |tok| try langs.append(arena, std.ascii.lowerString(try arena.alloc(u8, tok.len), tok));
    return langs.toOwnedSlice(arena);
}

fn parseBool(s: []const u8) ?bool {
    const yes = [_][]const u8{ "yes", "true", "1", "on" };
    const no = [_][]const u8{ "no", "false", "0", "off" };
    for (yes) |w| if (std.ascii.eqlIgnoreCase(s, w)) return true;
    for (no) |w| if (std.ascii.eqlIgnoreCase(s, w)) return false;
    return null;
}

test "config parsing" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var cfg: Config = .{};
    try parse(arena.allocator(),
        \\# comment
        \\api_key = KEY
        \\username=me
        \\
        \\languages = en, KO
        \\prefer_hi=yes
        \\unknown=1
        \\garbage
        \\fallback_dir=/tmp/subs
    , &cfg);
    try std.testing.expectEqualStrings("KEY", cfg.api_key);
    try std.testing.expectEqualStrings("me", cfg.username);
    try std.testing.expectEqualStrings("", cfg.password);
    try std.testing.expectEqual(@as(usize, 2), cfg.languages.len);
    try std.testing.expectEqualStrings("ko", cfg.languages[1]);
    try std.testing.expect(cfg.prefer_hi);
    try std.testing.expectEqualStrings("/tmp/subs", cfg.fallback_dir);
}

test "env overrides the file" {
    var map = std.process.Environ.Map.init(std.testing.allocator);
    defer map.deinit();
    try map.put("OPENSUBTITLES_API_KEY", "ENVKEY");
    try map.put("OPENSUBTITLES_PASSWORD", "");
    var cfg: Config = .{ .api_key = "filekey", .username = "me", .password = "pw" };
    applyEnv(&cfg, &map);
    try std.testing.expectEqualStrings("ENVKEY", cfg.api_key);
    try std.testing.expectEqualStrings("me", cfg.username);
    try std.testing.expectEqualStrings("pw", cfg.password);
}
