//! Draws the library's progress reports as a std.Progress bar.

const std = @import("std");
const Io = std.Io;
const castig = @import("castig");

pub const Bar = struct {
    io: Io,
    root: std.Progress.Node = .none,
    node: std.Progress.Node = .none,

    pub fn reporter(self: *Bar) castig.Reporter {
        return .{ .context = self, .vtable = &vtable };
    }

    const vtable: castig.Reporter.VTable = .{ .begin = begin, .step = step, .end = end };

    fn begin(context: *anyopaque, label: []const u8, total: u64) void {
        const self: *Bar = @ptrCast(@alignCast(context));
        self.root = std.Progress.start(self.io, .{});
        self.node = self.root.start(label, @intCast(total));
    }

    fn step(context: *anyopaque, units: u64) void {
        const self: *Bar = @ptrCast(@alignCast(context));
        for (0..units) |_| self.node.completeOne();
    }

    fn end(context: *anyopaque) void {
        const self: *Bar = @ptrCast(@alignCast(context));
        self.node.end();
        self.root.end();
        self.* = .{ .io = self.io };
    }
};
