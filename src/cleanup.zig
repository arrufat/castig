//! Deletes a temp file if the process is killed by SIGINT (Ctrl-C) or SIGTERM.
//!
//! `defer` cleanup does not run when a signal terminates the process, so a
//! `--remux mp4` transcode would otherwise leave its (source-sized) temp file
//! behind. This installs a handler that unlinks the file, then restores the
//! default disposition and re-raises the signal so the exit status stays the
//! one the shell expects (terminated by the signal, not a clean exit).
//!
//! The handler touches only async-signal-safe calls (`unlink`, `sigaction`,
//! `tkill`) and a single global pointer. That pointer must outlive the process,
//! which an arena allocation does.

const std = @import("std");
const posix = std.posix;
const linux = std.os.linux;
const SIG = posix.SIG;

var target: ?[*:0]const u8 = null;

fn onSignal(sig: SIG) callconv(.c) void {
    if (target) |path| _ = linux.unlink(path);
    const dfl: posix.Sigaction = .{
        .handler = .{ .handler = SIG.DFL },
        .mask = posix.sigemptyset(),
        .flags = 0,
    };
    posix.sigaction(sig, &dfl, null);
    _ = linux.tkill(linux.gettid(), sig);
}

/// Arranges for `path` to be unlinked on SIGINT/SIGTERM. `path` must stay
/// valid until the process exits.
pub fn deleteOnSignal(path: [*:0]const u8) void {
    target = path;
    const act: posix.Sigaction = .{
        .handler = .{ .handler = onSignal },
        .mask = posix.sigemptyset(),
        .flags = 0,
    };
    posix.sigaction(.INT, &act, null);
    posix.sigaction(.TERM, &act, null);
}
