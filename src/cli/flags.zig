//! The flags `castig cast` takes, shared by the CLI and the window.

const std = @import("std");
const castig = @import("castig");

pub const Error = error{ MissingValue, UnknownFlag, InvalidRemux };

/// Fills `opts` from the flags that follow the source.
pub fn cast(opts: *castig.session.Options, args: []const []const u8) Error!void {
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const flag = args[i];
        if (i + 1 >= args.len) return error.MissingValue;
        i += 1;
        if (std.mem.eql(u8, flag, "--title")) {
            opts.title = args[i];
        } else if (std.mem.eql(u8, flag, "--type")) {
            opts.content_type = args[i];
        } else if (std.mem.eql(u8, flag, "--subs")) {
            opts.subtitles = if (std.mem.eql(u8, args[i], "auto")) .download else .{ .source = args[i] };
        } else if (std.mem.eql(u8, flag, "--remux")) {
            opts.remux = std.meta.stringToEnum(castig.delivery.Remux, args[i]) orelse return error.InvalidRemux;
        } else return error.UnknownFlag;
    }
}

test cast {
    var opts: castig.session.Options = .{ .source = "a.mkv" };
    try cast(&opts, &.{ "--subs", "auto", "--remux", "mp4", "--title", "A" });
    try std.testing.expectEqual(.download, std.meta.activeTag(opts.subtitles));
    try std.testing.expectEqual(.mp4, opts.remux);
    try std.testing.expectEqualStrings("A", opts.title.?);

    try cast(&opts, &.{ "--subs", "a.srt" });
    try std.testing.expectEqualStrings("a.srt", opts.subtitles.source);

    try std.testing.expectError(error.MissingValue, cast(&opts, &.{"--title"}));
    try std.testing.expectError(error.UnknownFlag, cast(&opts, &.{ "--nope", "x" }));
    try std.testing.expectError(error.InvalidRemux, cast(&opts, &.{ "--remux", "x" }));
}
