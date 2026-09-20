//! What every operation runs with. `arena` holds values that live as long as
//! the operation; `gpa` backs the subsystems that allocate and free while
//! they serve (channel, server, segmenter, mp4 assembler, subtitle cache).

const std = @import("std");
const Io = std.Io;

pub const Env = struct {
    io: Io,
    arena: std.mem.Allocator,
    gpa: std.mem.Allocator,
    out: *Io.Writer,
    /// The process environment, for XDG directories and credential overrides.
    environ: *const std.process.Environ.Map,
};
