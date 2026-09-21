//! How the library reports progress on an operation long enough that a caller
//! may want to show it. Nothing here touches a terminal: the caller decides
//! whether that becomes a progress bar, a log line or nothing at all.

/// `step` marks one unit of `total` done. It may be called from several tasks
/// at once, so an implementation has to be safe to call concurrently.
pub const Reporter = struct {
    context: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        begin: *const fn (context: *anyopaque, label: []const u8, total: u64) void,
        step: *const fn (context: *anyopaque) void,
        end: *const fn (context: *anyopaque) void,
    };

    /// Announces a new operation of `total` steps, zero when unknown.
    pub fn begin(r: Reporter, label: []const u8, total: u64) void {
        r.vtable.begin(r.context, label, total);
    }

    /// Marks one step done.
    pub fn step(r: Reporter) void {
        r.vtable.step(r.context);
    }

    /// Ends the operation, whether it finished or failed.
    pub fn end(r: Reporter) void {
        r.vtable.end(r.context);
    }
};
