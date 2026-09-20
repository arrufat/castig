//! The castig window: the same library the CLI drives, with widgets in
//! place of arguments. It starts the calls that talk to a receiver and
//! draws what they report.

const std = @import("std");
const Io = std.Io;
const dvui = @import("dvui");
const castig = @import("castig");

const work = @import("work.zig");
const Cast = work.Cast;

pub const dvui_app: dvui.App = .{
    .config = .{ .options = .{
        .size = .{ .w = 560, .h = 700 },
        .min_size = .{ .w = 420, .h = 520 },
        .title = "castig",
        // An empty org keeps the remembered window geometry in
        // ~/.local/share/castig instead of a dvui/castig below it.
        .org = "",
    } },
    .initFn = init,
    .deinitFn = deinit,
    .frameFn = frame,
};
pub const main = dvui.App.main;
pub const panic = dvui.App.panic;
pub const std_options: std.Options = .{
    .log_level = .info,
    .logFn = logFn,
};

/// The library explains itself through `std.log`, which a window swallows,
/// so its lines feed the panel at the bottom. SDL and dvui talk about
/// themselves: only their warnings reach the terminal.
fn logFn(comptime level: std.log.Level, comptime scope: @EnumLiteral(), comptime format: []const u8, args: anytype) void {
    if (level == .debug) return;
    const library = switch (scope) {
        .cast, .subs, .http, .hls => true,
        else => false,
    };
    if (library) messages.add(level, format, args);
    if (library or level != .info) dvui.App.logFn(level, scope, format, args);
}

var messages: Messages = .{};
var app: App = undefined;

/// What the library last said, oldest first, from whichever thread said it.
const Messages = struct {
    const capacity = 8;
    const width = 200;

    mutex: Io.Mutex = .init,
    lines: [capacity][width]u8 = @splat(@splat(0)),
    lens: [capacity]usize = @splat(0),
    next: usize = 0,
    count: usize = 0,

    fn add(m: *Messages, comptime level: std.log.Level, comptime format: []const u8, args: anytype) void {
        Io.Threaded.mutexLock(&m.mutex);
        defer Io.Threaded.mutexUnlock(&m.mutex);
        const prefix = switch (level) {
            .err => "error: ",
            .warn => "warning: ",
            else => "",
        };
        const line = &m.lines[m.next];
        const written = std.fmt.bufPrint(line, prefix ++ format, args) catch line[0..];
        m.lens[m.next] = written.len;
        m.next = (m.next + 1) % capacity;
        m.count = @min(m.count + 1, capacity);
    }

    /// Copies out, so a line cannot change while it is being drawn.
    fn read(m: *Messages, out: *[capacity][width]u8, lens: *[capacity]usize) usize {
        Io.Threaded.mutexLock(&m.mutex);
        defer Io.Threaded.mutexUnlock(&m.mutex);
        const first = (m.next + capacity - m.count) % capacity;
        for (0..m.count) |i| {
            const slot = (first + i) % capacity;
            out[i] = m.lines[slot];
            lens[i] = m.lens[slot];
        }
        return m.count;
    }
};

const Subtitles = enum {
    sidecar,
    download,
    file,

    /// In the order of the enum, which is what the dropdown returns.
    const labels: []const []const u8 = &.{
        "sidecar next to the video",
        "sidecar, else download",
        "choose a file ...",
    };

    comptime {
        std.debug.assert(labels.len == @typeInfo(@This()).@"enum".field_names.len);
    }
};

const App = struct {
    io: Io,
    gpa: std.mem.Allocator,
    environ: *const std.process.Environ.Map,
    win: *dvui.Window,

    scan: work.Task(anyerror![]castig.discovery.Device),
    devices: []const castig.discovery.Device = &.{},
    device: ?usize = null,

    examine: work.Task(anyerror!castig.probe.Report),
    report: ?castig.probe.Report = null,
    /// Owned here: the dialog's string outlives the task that probes it.
    path: ?[:0]const u8 = null,

    subtitles: Subtitles = .sidecar,
    subtitle_path: ?[:0]const u8 = null,
    remux: castig.delivery.Remux = .auto,

    /// An OpenSubtitles search, open until the picker closes: the ranked
    /// candidates and the HTTP client live as long as the `Lookup` does.
    search: work.Task(anyerror!castig.subs.Lookup),
    lookup: ?castig.subs.Lookup = null,
    picking: bool = false,
    /// One download at a time: each spends one of the day's allowance.
    fetch: work.Task(anyerror!castig.subs.Saved),

    cast: Cast,
    /// Playback commands, each opening its own connection to whatever is
    /// playing.
    control: work.Task(anyerror!void),

    /// Where the slider was dragged to, until the drag ends.
    scrub: ?f32 = null,
    rate: f32 = 1,
    rate_pending: bool = false,

    /// Where a seek is formatted: the task reads it from another thread, so
    /// it cannot be a frame's stack buffer.
    seek_spec: [32]u8 = @splat(0),

    /// The spec the calls take; an address needs no allocation to name.
    device_spec: [32]u8 = @splat(0),
    device_spec_len: usize = 0,

    fn spec(a: *const App) []const u8 {
        return a.device_spec[0..a.device_spec_len];
    }
};

fn init(win: *dvui.Window) !void {
    const process = dvui.App.main_init.?;
    app = .{
        .io = process.io,
        .gpa = process.gpa,
        .environ = process.environ_map,
        .win = win,
        .scan = .init(process.gpa),
        .examine = .init(process.gpa),
        .cast = .init(process.gpa),
        .control = .init(process.gpa),
        .search = .init(process.gpa),
        .fetch = .init(process.gpa),
    };
    castig.av_extra.quietLibav();
    try startScan();
}

fn deinit(_: *dvui.Window) void {
    app.cast.deinit(app.io);
    app.scan.deinit(app.io);
    app.examine.deinit(app.io);
    app.control.deinit(app.io);
    app.fetch.deinit(app.io);
    closeSearch();
    app.search.deinit(app.io);
    if (app.path) |p| app.gpa.free(p);
    if (app.subtitle_path) |p| app.gpa.free(p);
}

fn startScan() !void {
    app.devices = &.{};
    app.device = null;
    app.device_spec_len = 0;
    try app.scan.start(app.io, app.win, castig.discovery.discover, .{
        app.io,
        app.scan.allocator(),
        castig.discovery.default_timeout_ms,
        null,
    });
}

fn frame() !dvui.App.Result {
    collect();

    var scroll = dvui.scrollArea(@src(), .{}, .{ .expand = .both, .style = .window });
    defer scroll.deinit();

    var page = dvui.box(@src(), .{ .dir = .vertical }, .{
        .expand = .horizontal,
        .margin = dvui.Rect.all(10),
    });
    defer page.deinit();

    try devicePanel();
    _ = dvui.separator(@src(), .{ .expand = .horizontal, .margin = dvui.Rect{ .y = 10, .h = 10 } });
    try sourcePanel();
    _ = dvui.separator(@src(), .{ .expand = .horizontal, .margin = dvui.Rect{ .y = 10, .h = 10 } });
    try playbackPanel();
    messagePanel();
    try subtitlePanel();

    return .ok;
}

/// Picks up whatever the background calls finished since the last frame.
fn collect() void {
    if (app.scan.collect(app.io)) |result| {
        if (result) |found| {
            app.devices = found;
            if (found.len > 0) selectDevice(0);
        } else |err| std.log.err("discovery failed: {s}", .{@errorName(err)});
    }
    if (app.examine.collect(app.io)) |result| {
        app.report = result catch |err| blk: {
            std.log.err("cannot read the file: {s}", .{@errorName(err)});
            break :blk null;
        };
    }
    if (app.control.collect(app.io)) |result| {
        result catch |err| std.log.err("{s}", .{@errorName(err)});
    }
    if (app.search.collect(app.io)) |result| {
        // The library says on its way out why it found nothing.
        app.lookup = result catch null;
        // Closed while it searched: there is nothing to show it in.
        if (app.lookup == null or !app.picking) closePicker();
    }
    if (app.fetch.collect(app.io)) |result| {
        if (result) |saved| takeSaved(saved) catch |err| std.log.err("{s}", .{@errorName(err)})
        else |err| std.log.err("{s}", .{@errorName(err)});
    }
    app.cast.poll(app.io);
}

fn selectDevice(index: usize) void {
    app.device = index;
    const written = std.fmt.bufPrint(&app.device_spec, "{f}", .{app.devices[index].address}) catch unreachable;
    app.device_spec_len = written.len;
}

fn devicePanel() !void {
    var row = dvui.box(@src(), .{ .dir = .horizontal }, .{ .expand = .horizontal });
    defer row.deinit();

    dvui.label(@src(), "Device", .{}, .{ .gravity_y = 0.5 });

    if (app.scan.busy()) {
        dvui.spinner(@src(), .{ .gravity_y = 0.5 });
        dvui.label(@src(), "scanning ...", .{}, .{ .gravity_y = 0.5 });
    } else if (app.devices.len == 0) {
        dvui.label(@src(), "none found", .{}, .{ .gravity_y = 0.5 });
    } else {
        const arena = dvui.currentWindow().arena();
        const entries = try arena.alloc([]const u8, app.devices.len);
        for (app.devices, entries) |d, *entry| {
            entry.* = try std.fmt.allocPrint(arena, "{s} ({s})", .{ d.friendly_name, d.model });
        }
        var choice = app.device orelse 0;
        if (dvui.dropdown(@src(), entries, .{ .choice = &choice }, .{}, .{ .min_size_content = .{ .w = 240 }, .gravity_y = 0.5 })) {
            selectDevice(choice);
        }
    }

    if (dvui.button(@src(), "Rescan", .{ .grayed = app.scan.busy() }, .{ .gravity_x = 1, .gravity_y = 0.5 }) and !app.scan.busy()) {
        try startScan();
    }
}

fn sourcePanel() !void {
    {
        var row = dvui.box(@src(), .{ .dir = .horizontal }, .{ .expand = .horizontal });
        defer row.deinit();

        if (dvui.button(@src(), "Open ...", .{ .grayed = app.examine.busy() }, .{ .gravity_y = 0.5 }) and !app.examine.busy()) {
            try openFile();
        }
        const name = if (app.path) |p| Io.Dir.path.basename(p) else "no file chosen";
        dvui.label(@src(), "{s}", .{name}, .{ .gravity_y = 0.5 });
    }

    if (app.examine.busy()) {
        dvui.label(@src(), "reading the file ...", .{}, .{});
        return;
    }
    if (app.path == null) return;

    if (app.report) |r| {
        reportPanel(r);
    } else {
        dvui.label(@src(), "this file cannot be read", .{}, .{ .style = .err });
        return;
    }

    {
        var row = dvui.box(@src(), .{ .dir = .horizontal }, .{ .expand = .horizontal, .margin = dvui.Rect{ .y = 6 } });
        defer row.deinit();

        dvui.label(@src(), "Subtitles", .{}, .{ .gravity_y = 0.5 });
        var subs: usize = @intFromEnum(app.subtitles);
        if (dvui.dropdown(@src(), Subtitles.labels, .{ .choice = &subs }, .{}, .{ .min_size_content = .{ .w = 180 }, .gravity_y = 0.5 })) {
            app.subtitles = @enumFromInt(subs);
            if (app.subtitles == .file) try openSubtitle();
        }
        if (app.subtitles == .file) {
            const name = if (app.subtitle_path) |p| Io.Dir.path.basename(p) else "none chosen";
            dvui.label(@src(), "{s}", .{name}, .{ .gravity_y = 0.5 });
        }

        const searching = app.search.busy() or app.picking;
        if (dvui.button(@src(), "Find ...", .{ .grayed = searching }, .{ .gravity_x = 1, .gravity_y = 0.5 }) and !searching) {
            try startSearch();
        }
    }
    {
        var row = dvui.box(@src(), .{ .dir = .horizontal }, .{ .expand = .horizontal });
        defer row.deinit();

        dvui.label(@src(), "Remux", .{}, .{ .gravity_y = 0.5 });
        var mode: usize = @intFromEnum(app.remux);
        if (dvui.dropdown(@src(), remux_labels, .{ .choice = &mode }, .{}, .{ .min_size_content = .{ .w = 180 }, .gravity_y = 0.5 })) {
            app.remux = @enumFromInt(mode);
        }

        const ready = app.report != null and app.device != null and !app.cast.busy();
        if (dvui.button(@src(), "Cast", .{ .grayed = !ready }, .{ .gravity_x = 1, .gravity_y = 0.5 }) and ready) {
            try startCast();
        }
    }
}

/// In the order of `castig.delivery.Remux`, which the dropdown returns.
const remux_labels: []const []const u8 = &.{
    "auto (hls, then mp4)",
    "hls (seekable, instant)",
    "mp4 (seekable, prepares)",
    "stream (instant, no seek)",
};

comptime {
    std.debug.assert(remux_labels.len == @typeInfo(castig.delivery.Remux).@"enum".field_names.len);
}

fn reportPanel(r: castig.probe.Report) void {
    var tl = dvui.textLayout(@src(), .{}, .{ .expand = .horizontal, .margin = dvui.Rect{ .y = 6, .h = 6 } });
    defer tl.deinit();

    tl.format("{s}", .{r.container}, .{});
    if (r.duration) |secs| {
        var buf: [16]u8 = undefined;
        tl.format(", {s}", .{clock(&buf, secs)}, .{});
    }
    tl.addText("\n", .{});

    for (r.streams) |s| {
        if (s.kind == .other) continue;
        tl.format("  {s} {s}", .{ s.type_name, s.codec }, .{});
        if (s.language) |l| tl.format(" [{s}]", .{l}, .{});
        if (s.video) |v| tl.format(" {d}x{d} {d:.3} fps", .{ v.width, v.height, v.fps }, .{});
        if (s.audio) |a| tl.format(" {d} ch {d} Hz", .{ a.channels, a.sample_rate }, .{});
        if (s.support) |sup| tl.format(" -> {s}", .{sup.label()}, .{});
        if (s.kind == .subtitle) tl.addText(if (s.text) " -> webvtt" else " -> bitmap, burn-in only", .{});
        tl.addText("\n", .{});
    }

    if (!r.castable()) tl.addText("nothing to cast", .{});
}

fn playbackPanel() !void {
    const state = app.cast.snapshot();
    if (state.phase == .idle) {
        dvui.label(@src(), "nothing playing from here", .{}, .{});
        return;
    }

    dvui.label(@src(), "{s}", .{state.note()}, .{ .expand = .horizontal });

    if (app.cast.progress.fraction()) |done| {
        dvui.label(@src(), "{s}", .{app.cast.progress.label}, .{});
        dvui.progress(@src(), .{ .percent = done }, .{ .expand = .horizontal, .min_size_content = .{ .h = 10 } });
        // Nothing arrives from the receiver while it prepares, so the bar
        // asks for the frames that move it.
        dvui.refresh(null, @src(), null);
    }

    if (state.phase != .playing) return;

    const duration = state.duration orelse 0;
    {
        var row = dvui.box(@src(), .{ .dir = .horizontal }, .{ .expand = .horizontal });
        defer row.deinit();

        var position: [16]u8 = undefined;
        var total: [16]u8 = undefined;
        const shown = if (app.scrub) |f| f * duration else @as(f32, @floatCast(state.position));
        dvui.label(@src(), "{t}", .{state.player}, .{ .gravity_y = 0.5 });
        dvui.label(@src(), "{s} / {s}", .{ clock(&position, shown), clock(&total, duration) }, .{ .gravity_y = 0.5 });
        dvui.label(@src(), "x{d:.2}", .{state.rate}, .{ .gravity_x = 1, .gravity_y = 0.5 });
    }

    // One seek at the end of the drag, not one a frame.
    if (duration > 0) {
        var fraction: f32 = app.scrub orelse std.math.clamp(@as(f32, @floatCast(state.position)) / @as(f32, @floatCast(duration)), 0, 1);
        if (dvui.slider(@src(), .{ .fraction = &fraction }, .{ .expand = .horizontal, .min_size_content = .{ .h = 16 } })) {
            app.scrub = fraction;
        } else if (app.scrub) |target| {
            app.scrub = null;
            try seekTo(target * duration);
        }
    }

    {
        var row = dvui.box(@src(), .{ .dir = .horizontal }, .{ .expand = .horizontal, .margin = dvui.Rect{ .y = 6 } });
        defer row.deinit();

        if (dvui.button(@src(), "-10", .{}, .{})) try seek("-10");
        const paused = state.player == .PAUSED;
        if (dvui.button(@src(), if (paused) "Play" else "Pause", .{}, .{ .min_size_content = .{ .w = 60 } })) {
            try command(if (paused) "PLAY" else "PAUSE");
        }
        if (dvui.button(@src(), "+10", .{}, .{})) try seek("+10");

        // The receiver's rate only when nobody is dragging: it would undo
        // the drag on the frame that sends it.
        if (!app.rate_pending) app.rate = @floatCast(state.rate);
        if (dvui.sliderEntry(@src(), "x{d:.2}", .{
            .value = &app.rate,
            .min = castig.control.rate_min,
            .max = castig.control.rate_max,
            .interval = 0.05,
        }, .{ .gravity_y = 0.5, .min_size_content = .{ .w = 90 } })) {
            app.rate_pending = true;
        } else if (app.rate_pending) {
            app.rate_pending = false;
            try setRate(app.rate);
        }

        if (dvui.button(@src(), "Stop", .{}, .{ .gravity_x = 1 })) try stop();
    }
}

fn messagePanel() void {
    var lines: [Messages.capacity][Messages.width]u8 = undefined;
    var lens: [Messages.capacity]usize = undefined;
    const count = messages.read(&lines, &lens);
    if (count == 0) return;

    _ = dvui.separator(@src(), .{ .expand = .horizontal, .margin = dvui.Rect{ .y = 10, .h = 6 } });
    var tl = dvui.textLayout(@src(), .{}, .{ .expand = .horizontal, .font = .theme(.mono) });
    defer tl.deinit();
    for (0..count) |i| {
        tl.format("{s}\n", .{lines[i][0..lens[i]]}, .{});
    }
}

/// A ranked OpenSubtitles search, shown as a list to pick from. The video's
/// frame rate comes from the probe, so a candidate that disagrees is ranked
/// down without reading the file twice.
fn startSearch() !void {
    const path = app.path orelse return;
    if (app.fetch.busy()) return;
    closePicker();
    app.picking = true;
    try app.search.start(app.io, app.win, castig.subs.Lookup.open, .{
        castig.Env{
            .io = app.io,
            .arena = app.search.allocator(),
            .gpa = app.gpa,
            .environ = app.environ,
        },
        @as([]const u8, path),
        castig.subs.Options{ .fps = videoFps() },
    });
}

/// The frame rate of the probed video, when it has one.
fn videoFps() ?f64 {
    const report = app.report orelse return null;
    for (report.streams) |st| if (st.video) |v| return v.fps;
    return null;
}

/// Everything the search owns: the call still running, then the `Lookup` it
/// left behind.
fn closeSearch() void {
    if (app.search.cancel(app.io)) |result| {
        if (result) |found| {
            var open = found;
            open.deinit();
        } else |_| {}
    }
    closePicker();
}

/// Ends the search: the client is the `Lookup`'s to close, and the arena
/// behind the candidates is reset by the next search.
fn closePicker() void {
    if (app.lookup) |*l| l.deinit();
    app.lookup = null;
    app.picking = false;
}

/// What the download left behind: the file to side-load on the next cast.
fn takeSaved(saved: castig.subs.Saved) !void {
    const path = try app.gpa.dupeSentinel(u8, saved.path, 0);
    if (app.subtitle_path) |p| app.gpa.free(p);
    app.subtitle_path = path;
    app.subtitles = .file;
    if (saved.remaining) |n| {
        std.log.info("saved {s} ({d} downloads left today)", .{ Io.Dir.path.basename(path), n });
    } else {
        std.log.info("saved {s}", .{Io.Dir.path.basename(path)});
    }
    closePicker();
}

fn subtitlePanel() !void {
    if (!app.picking) return;

    var win = dvui.floatingWindow(@src(), .{ .modal = true, .open_flag = &app.picking }, .{
        .min_size_content = .{ .w = 520, .h = 420 },
        .max_size_content = .{ .w = 760, .h = 640 },
    });
    defer win.deinit();

    const title = if (app.path) |p| Io.Dir.path.basename(p) else "subtitles";
    var open = true;
    // No way to close over a download: it is holding the `Lookup` this
    // would free.
    win.dragAreaSet(dvui.windowHeader(title, "", if (app.fetch.busy()) null else &open));
    if (!open) {
        closePicker();
        return;
    }

    if (app.search.busy()) {
        dvui.spinner(@src(), .{ .gravity_x = 0.5, .gravity_y = 0.5 });
        dvui.label(@src(), "searching OpenSubtitles ...", .{}, .{ .gravity_x = 0.5 });
        return;
    }
    // Before the candidates are read: the download mutates the `Lookup` it
    // runs on, so this thread leaves it alone until it is over.
    if (app.fetch.busy()) {
        dvui.spinner(@src(), .{ .gravity_x = 0.5, .gravity_y = 0.5 });
        dvui.label(@src(), "downloading ...", .{}, .{ .gravity_x = 0.5 });
        return;
    }
    const candidates = if (app.lookup) |l| l.candidates else return;

    dvui.label(@src(), "each download spends one of the day's allowance", .{}, .{ .expand = .horizontal });

    var scroll = dvui.scrollArea(@src(), .{}, .{ .expand = .both });
    defer scroll.deinit();

    // Only worth naming the film or episode when the results disagree about
    // which one it is.
    var feature: ?u64 = null;
    var many = false;
    for (candidates) |c| {
        const id = c.feature_id orelse continue;
        if (feature) |first| many = many or first != id else feature = id;
    }

    const arena = dvui.currentWindow().arena();
    for (candidates, 0..) |c, i| {
        if (try candidateButton(try describe(arena, c, many), i)) {
            try app.fetch.start(app.io, app.win, take, .{ &app.lookup.?, i });
        }
    }
}

/// A full-width button with its label on the left, which `dvui.button`
/// centres instead.
fn candidateButton(label: []const u8, index: usize) !bool {
    const opts: dvui.Options = .{ .id_extra = index, .expand = .horizontal };
    var bw: dvui.ButtonWidget = undefined;
    bw.init(@src(), .{}, opts);
    bw.processEvents();
    bw.drawBackground();
    const clicked = bw.clicked();
    dvui.labelNoFmt(@src(), label, .{ .align_x = 0 }, opts.strip().override(bw.style()).override(.{ .gravity_y = 0.5 }));
    bw.drawFocus();
    bw.deinit();
    return clicked;
}

/// One candidate on one line: what vouches for it, then what it is.
fn describe(arena: std.mem.Allocator, c: castig.subs.Candidate, many: bool) ![]const u8 {
    var out: std.Io.Writer.Allocating = .init(arena);
    const w = &out.writer;
    switch (c.hash) {
        .voted => try w.writeAll("[HASH] "),
        .match => try w.writeAll("[HASH?] "),
        .none => {},
    }
    try w.print("[{s}]", .{c.lang});
    if (c.hi) try w.writeAll(" [HI]");
    if (c.ai) try w.writeAll(" [AI]");
    try w.print(" {d} dl", .{c.downloads});
    if (c.fps_mismatch) if (c.fps) |f| try w.print(", {d} fps", .{f});
    try w.writeAll(" \u{b7} ");
    if (many) if (c.feature) |f| try w.print("{s} \u{b7} ", .{f});
    try w.writeAll(c.release);
    return out.written();
}

fn take(lookup: *castig.subs.Lookup, index: usize) anyerror!castig.subs.Saved {
    return lookup.take(index);
}

fn openFile() !void {
    const chosen = try dvui.dialogNativeFileOpen(app.gpa, .{
        .title = "Cast a file",
        .filters = &.{ "*.mkv", "*.mp4", "*.m4v", "*.webm", "*.avi", "*.mov", "*.mp3", "*.flac", "*.m4a" },
        .filter_description = "media files",
    }) orelse return;

    if (app.path) |p| app.gpa.free(p);
    app.path = chosen;
    app.report = null;
    try app.examine.start(app.io, app.win, castig.probe.inspect, .{ app.examine.allocator(), @as([]const u8, chosen) });
}

fn openSubtitle() !void {
    const chosen = try dvui.dialogNativeFileOpen(app.gpa, .{
        .title = "Subtitle track",
        .filters = &.{ "*.srt", "*.vtt" },
        .filter_description = "subtitles",
    }) orelse {
        app.subtitles = .sidecar;
        return;
    };
    if (app.subtitle_path) |p| app.gpa.free(p);
    app.subtitle_path = chosen;
}

fn startCast() !void {
    const path = app.path orelse return;
    try app.cast.start(app.io, app.win, app.gpa, app.environ, app.spec(), .{
        .source = path,
        .remux = app.remux,
        .subtitles = switch (app.subtitles) {
            .sidecar => .sidecar,
            .download => .download,
            .file => if (app.subtitle_path) |p| .{ .source = p } else .sidecar,
        },
    });
}

/// One command at a time: a click while one is in flight is dropped.
fn command(verb: []const u8) !void {
    if (app.control.busy()) return;
    try app.control.start(app.io, app.win, runCommand, .{ controlEnv(), app.spec(), verb });
}

fn seek(spec: []const u8) !void {
    if (app.control.busy()) return;
    try app.control.start(app.io, app.win, runSeek, .{ controlEnv(), app.spec(), spec });
}

/// An absolute seek. The busy check also keeps the buffer from changing
/// under a command in flight.
fn seekTo(seconds: f64) !void {
    if (app.control.busy() or !std.math.isFinite(seconds)) return;
    try seek(std.fmt.bufPrint(&app.seek_spec, "{d:.0}", .{seconds}) catch return);
}

fn setRate(value: f32) !void {
    if (app.control.busy()) return;
    try app.control.start(app.io, app.win, runRate, .{ controlEnv(), app.spec(), @as(f64, value) });
}

fn stop() !void {
    if (app.control.busy()) return;
    try app.control.start(app.io, app.win, runStop, .{ controlEnv(), app.spec() });
}

fn controlEnv() castig.Env {
    return .{
        .io = app.io,
        .arena = app.control.allocator(),
        .gpa = app.gpa,
        .environ = app.environ,
    };
}

// The session reports what these change, so only the failures matter here.
fn runCommand(env: castig.Env, device: []const u8, verb: []const u8) anyerror!void {
    _ = try castig.control.command(env, device, verb);
}

fn runSeek(env: castig.Env, device: []const u8, spec: []const u8) anyerror!void {
    _ = try castig.control.seek(env, device, spec);
}

fn runRate(env: castig.Env, device: []const u8, value: f64) anyerror!void {
    _ = try castig.control.rate(env, device, value);
}

fn runStop(env: castig.Env, device: []const u8) anyerror!void {
    _ = try castig.control.stop(env, device);
}

/// Seconds as h:mm:ss, or m:ss below an hour.
fn clock(buf: []u8, seconds: f64) []const u8 {
    if (!std.math.isFinite(seconds) or seconds < 0) return "--:--";
    const whole: u64 = @intFromFloat(seconds);
    const h = whole / 3600;
    const m = (whole % 3600) / 60;
    const s = whole % 60;
    return if (h > 0)
        std.fmt.bufPrint(buf, "{d}:{d:0>2}:{d:0>2}", .{ h, m, s }) catch "--:--"
    else
        std.fmt.bufPrint(buf, "{d}:{d:0>2}", .{ m, s }) catch "--:--";
}

test {
    _ = @import("work.zig");
    var buf: [16]u8 = undefined;
    try std.testing.expectEqualStrings("0:09", clock(&buf, 9.4));
    try std.testing.expectEqualStrings("12:03", clock(&buf, 723));
    try std.testing.expectEqualStrings("1:02:03", clock(&buf, 3723));
}

