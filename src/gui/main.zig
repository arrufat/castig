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
    const library = comptime castig.ownScope(scope);
    if (library) messages.add(level, format, args);
    if (library or level != .info) dvui.App.logFn(level, scope, format, args);
}

var messages: Messages = .{};
var app: App = undefined;

/// What the library last said, oldest first, from whichever thread said it.
const Messages = struct {
    const capacity = 8;
    const width = 200;

    const Line = struct {
        buf: [width]u8 = @splat(0),
        len: usize = 0,

        fn text(l: *const Line) []const u8 {
            return l.buf[0..l.len];
        }
    };

    mutex: Io.Mutex = .init,
    lines: [capacity]Line = @splat(.{}),
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
        const written = std.fmt.bufPrint(&line.buf, prefix ++ format, args) catch line.buf[0..];
        line.len = written.len;
        m.next = (m.next + 1) % capacity;
        m.count = @min(m.count + 1, capacity);
    }

    /// Copies out, so a line cannot change while it is being drawn.
    fn read(m: *Messages, out: *[capacity]Line) usize {
        Io.Threaded.mutexLock(&m.mutex);
        defer Io.Threaded.mutexUnlock(&m.mutex);
        const first = (m.next + capacity - m.count) % capacity;
        for (0..m.count) |i| out[i] = m.lines[(first + i) % capacity];
        return m.count;
    }
};

/// The library's own choices, so a variant added there is a compile error
/// here instead of a row that maps to the wrong thing.
const Subtitles = std.meta.Tag(castig.session.Subtitles);

const subtitle_labels: std.EnumArray(Subtitles, []const u8) = .init(.{
    .sidecar = "sidecar next to the video",
    .download = "sidecar, else download",
    .source = "choose a file ...",
});

const remux_labels: std.EnumArray(castig.delivery.Remux, []const u8) = .init(.{
    .auto = "auto (hls, then mp4)",
    .hls = "hls (seekable, instant)",
    .mp4 = "mp4 (seekable, prepares)",
    .stream = "stream (instant, no seek)",
});

/// The same choices as a renderer sees them: it does not play HLS, so what
/// `auto` means differs and asking for HLS gets the mp4 anyway.
const renderer_remux_labels: std.EnumArray(castig.delivery.Remux, []const u8) = .init(.{
    .auto = "auto (mp4)",
    .hls = "hls (renderers cannot, sends mp4)",
    .mp4 = "mp4 (seekable, prepares)",
    .stream = "stream (instant, no seek)",
});

/// "English (en)" per code, laid out at compile time.
const language_names: [castig.language.codes.len][]const u8 = blk: {
    @setEvalBranchQuota(20000);
    var out: [castig.language.codes.len][]const u8 = undefined;
    for (castig.language.codes, &out) |code, *slot| {
        slot.* = castig.language.name(code) ++ " (" ++ code ++ ")";
    }
    break :blk out;
};

/// Filled once in `init`: a dropdown redraws every frame.
var language_entries: [castig.language.codes.len + 1][]const u8 = undefined;
var configured_label: [128]u8 = undefined;

const App = struct {
    io: Io,
    gpa: std.mem.Allocator,
    environ: *const std.process.Environ.Map,
    win: *dvui.Window,

    scan: work.Task(anyerror![]castig.discovery.Device),
    devices: []const castig.discovery.Device = &.{},
    /// The dropdown's rows, named when the scan lands rather than per frame.
    device_labels: []const []const u8 = &.{},
    device: ?usize = null,

    examine: work.Task(anyerror!castig.probe.Report),
    /// What the chosen device can play, asked of the device itself. Its
    /// strings live in this task's arena, so it outlives every probe until
    /// another device is chosen.
    capabilities: work.Task(anyerror!castig.support.Profile),
    profile: castig.support.Profile = castig.support.cast,
    /// Set when the verdict on screen was judged against another device and
    /// the reader was busy, so it is asked again once it is free.
    reprobe: bool = false,
    /// The probe as the panel shows it, empty when the file cannot be read.
    report: []const u8 = "",
    /// The video's frame rate, which ranks the subtitle candidates.
    fps: ?f64 = null,
    readable: bool = false,
    /// Owned here: the dialog's string outlives the task that probes it.
    path: ?[:0]const u8 = null,

    subtitles: Subtitles = .sidecar,
    subtitle_path: ?[:0]const u8 = null,
    remux: castig.delivery.Remux = .auto,

    /// Which language to search in: null takes the config's order.
    language: ?usize = null,
    /// What to search for, seeded from the file name and editable. The text
    /// entry keeps it NUL-terminated, so `query` reads it back.
    query_buf: [160]u8 = @splat(0),

    /// An OpenSubtitles search, open until the picker closes: the ranked
    /// candidates and the HTTP client live as long as the `Lookup` does.
    search: work.Task(anyerror!castig.subs.Lookup),
    lookup: ?castig.subs.Lookup = null,
    /// One row per candidate, written when the search lands.
    rows: []const []const u8 = &.{},
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

    /// The spec the calls take. A Cast receiver is an address, but a
    /// renderer is named by its description URL, which is much longer.
    device_spec: [192]u8 = @splat(0),
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
        .capabilities = .init(process.gpa),
        .cast = .init(process.gpa),
        .control = .init(process.gpa),
        .search = .init(process.gpa),
        .fetch = .init(process.gpa),
    };
    castig.av_extra.quietLibav();
    try nameLanguages();
    try startScan();
}

/// The chooser's first row names the configured order, which only a search
/// otherwise reads; the config is not kept past that one label.
fn nameLanguages() !void {
    var scratch: std.heap.ArenaAllocator = .init(app.gpa);
    defer scratch.deinit();

    var w: Io.Writer = .fixed(&configured_label);
    w.writeAll("as configured (") catch {};
    if (castig.subs.config.load(scratch.allocator(), app.io, app.environ)) |cfg| {
        for (cfg.languages, 0..) |l, i| {
            if (i > 0) w.writeAll(", ") catch {};
            w.writeAll(l) catch {};
        }
    } else |err| {
        std.log.warn("cannot read the config: {s}", .{@errorName(err)});
        w.writeAll("en") catch {};
    }
    w.writeAll(")") catch {};

    language_entries[0] = w.buffered();
    @memcpy(language_entries[1..], &language_names);
}

fn deinit(_: *dvui.Window) void {
    app.cast.deinit(app.io);
    app.scan.deinit(app.io);
    app.examine.deinit(app.io);
    app.capabilities.deinit(app.io);
    app.control.deinit(app.io);
    app.fetch.deinit(app.io);
    closeSearch();
    app.search.deinit(app.io);
    if (app.path) |p| app.gpa.free(p);
    if (app.subtitle_path) |p| app.gpa.free(p);
}

fn startScan() !void {
    // The devices are about to be replaced, so a watch on one of them is
    // pointing at a row that will not exist.
    app.cast.stopFollowing(app.io);
    app.devices = &.{};
    app.device_labels = &.{};
    app.device = null;
    app.device_spec_len = 0;
    try app.scan.start(app.io, app.win, castig.discovery.discover, .{
        app.io,
        app.scan.allocator(),
        castig.discovery.Query{},
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

/// Picks up whatever the background calls finished since the last frame, and
/// writes out what a panel would otherwise format again every frame.
fn collect() void {
    if (app.scan.collect(app.io)) |result| {
        if (result) |found| {
            app.devices = found;
            app.device_labels = nameDevices(app.scan.allocator(), found) catch &.{};
            if (found.len > 0) selectDevice(0);
        } else |err| std.log.err("discovery failed: {s}", .{@errorName(err)});
    }
    if (app.examine.collect(app.io)) |result| {
        app.report = "";
        app.fps = null;
        app.readable = false;
        if (result) |r| {
            app.readable = true;
            app.fps = videoFps(r);
            app.report = describeReport(app.examine.allocator(), r) catch "";
        } else |err| std.log.err("cannot read the file: {s}", .{@errorName(err)});
    }
    if (app.capabilities.collect(app.io)) |result| {
        // A device that will not say keeps the conservative reading.
        app.profile = result catch castig.support.cast;
        app.reprobe = true;
    }
    if (app.control.collect(app.io)) |result| {
        result catch |err| std.log.err("{s}", .{@errorName(err)});
    }
    if (app.search.collect(app.io)) |result| {
        // The library says on its way out why it found nothing.
        app.lookup = result catch null;
        if (app.lookup) |l| app.rows = describeCandidates(app.search.allocator(), l) catch &.{};
        // Closed while it searched: there is nothing to show it in.
        if (app.lookup == null or !app.picking) closePicker();
    }
    if (app.fetch.collect(app.io)) |result| {
        const outcome: anyerror!void = if (result) |saved| takeSaved(saved) else |err| err;
        outcome catch |err| std.log.err("{s}", .{@errorName(err)});
    }
    app.cast.poll(app.io);

    // Last, so a reader that finished this frame has freed its slot.
    if (app.reprobe and !app.examine.busy()) {
        app.reprobe = false;
        startProbe() catch {};
    }
}

fn nameDevices(arena: std.mem.Allocator, found: []const castig.discovery.Device) ![]const []const u8 {
    const entries = try arena.alloc([]const u8, found.len);
    for (found, entries) |d, *entry| {
        entry.* = switch (d.protocol) {
            .cast => try std.fmt.allocPrint(arena, "{s} ({s})", .{ d.friendly_name, d.model }),
            .dlna => try std.fmt.allocPrint(arena, "{s} ({s}, dlna)", .{ d.friendly_name, d.model }),
        };
    }
    return entries;
}

fn describeReport(arena: std.mem.Allocator, r: castig.probe.Report) ![]const u8 {
    var out: Io.Writer.Allocating = .init(arena);
    const w = &out.writer;
    try w.writeAll(r.container);
    if (r.duration) |secs| {
        var buf: [16]u8 = undefined;
        try w.print(", {s}", .{clock(&buf, secs)});
    }
    try w.writeAll("\n");
    for (r.streams) |st| {
        if (st.kind == .other) continue;
        try w.print("  {f}\n", .{st});
    }
    try r.writeVerdict(w);
    return out.written();
}

fn describeCandidates(arena: std.mem.Allocator, l: castig.subs.Lookup) ![]const []const u8 {
    const many = l.manyFeatures();
    const rows = try arena.alloc([]const u8, l.candidates.len);
    for (l.candidates, rows) |c, *row| {
        var out: Io.Writer.Allocating = .init(arena);
        try c.write(&out.writer, many);
        row.* = out.written();
    }
    return rows;
}

/// What the chosen device speaks, when one is chosen. Several controls
/// only make sense for one of the two.
fn selectedProtocol() ?castig.discovery.Protocol {
    const index = app.device orelse return null;
    if (index >= app.devices.len) return null;
    return app.devices[index].protocol;
}

fn selectDevice(index: usize) void {
    var w: Io.Writer = .fixed(&app.device_spec);
    app.devices[index].writeSpec(&w) catch {
        // A name that does not fit is a name we cannot use.
        app.device = null;
        app.device_spec_len = 0;
        return;
    };
    app.device = index;
    app.device_spec_len = w.buffered().len;
    startCapabilities();
    followSelected();
}

/// Joins whatever the chosen device is already playing, so the transport
/// controls work on a cast this window did not start. A session of our own
/// outranks it and is left running.
fn followSelected() void {
    if (app.cast.busy() and !app.cast.following) return;
    const index = app.device orelse return;
    if (index >= app.devices.len) return;
    app.cast.stopFollowing(app.io);
    app.cast.follow(
        app.io,
        app.win,
        app.gpa,
        app.environ,
        app.spec(),
        app.devices[index].friendly_name,
    ) catch {};
}

fn devicePanel() !void {
    var row = dvui.box(@src(), .{ .dir = .horizontal }, .{ .expand = .horizontal });
    defer row.deinit();

    dvui.label(@src(), "Device", .{}, .{ .gravity_y = 0.5 });

    if (app.scan.busy()) {
        // The default spinner is 50 across and would set the row's height.
        dvui.spinner(@src(), .{ .gravity_y = 0.5, .min_size_content = .{ .w = 20, .h = 20 } });
        dvui.label(@src(), "scanning ...", .{}, .{ .gravity_y = 0.5 });
    } else if (app.devices.len == 0) {
        dvui.label(@src(), "none found", .{}, .{ .gravity_y = 0.5 });
    } else {
        var choice = app.device orelse 0;
        if (dvui.dropdown(@src(), app.device_labels, .{ .choice = &choice }, .{}, .{ .min_size_content = .{ .w = 240 }, .gravity_y = 0.5 })) {
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

    if (app.examine.busy() or app.capabilities.busy()) {
        dvui.label(@src(), "reading the file ...", .{}, .{});
        return;
    }
    if (app.path == null) return;

    if (!app.readable) {
        dvui.label(@src(), "this file cannot be read", .{}, .{ .style = .err });
        return;
    }
    // Whose verdict this is: a renderer often plays what a receiver cannot,
    // so the same file reads differently depending on what is selected.
    if (app.device) |index| {
        if (index < app.devices.len) {
            dvui.label(@src(), "as {s} would play it:", .{app.devices[index].friendly_name}, .{});
        }
    }
    {
        var tl = dvui.textLayout(@src(), .{}, .{ .expand = .horizontal, .margin = dvui.Rect{ .y = 6, .h = 6 } });
        defer tl.deinit();
        tl.addText(app.report, .{});
    }

    {
        var row = dvui.box(@src(), .{ .dir = .horizontal }, .{ .expand = .horizontal, .margin = dvui.Rect{ .y = 6 } });
        defer row.deinit();

        dvui.label(@src(), "Subtitles", .{}, .{ .gravity_y = 0.5 });
        var subs: usize = @intFromEnum(app.subtitles);
        if (dvui.dropdown(@src(), &subtitle_labels.values, .{ .choice = &subs }, .{}, .{ .min_size_content = .{ .w = 180 }, .gravity_y = 0.5 })) {
            app.subtitles = @enumFromInt(subs);
            if (app.subtitles == .source) try openSubtitle();
        }
        if (app.subtitles == .source) {
            const name = if (app.subtitle_path) |p| Io.Dir.path.basename(p) else "none chosen";
            dvui.label(@src(), "{s}", .{name}, .{ .gravity_y = 0.5 });
        }
    }
    {
        var row = dvui.box(@src(), .{ .dir = .horizontal }, .{ .expand = .horizontal });
        defer row.deinit();

        dvui.label(@src(), "Language", .{}, .{ .gravity_y = 0.5 });
        var choice: usize = if (app.language) |i| i + 1 else 0;
        if (dvui.dropdown(@src(), &language_entries, .{ .choice = &choice }, .{}, .{ .min_size_content = .{ .w = 180 }, .gravity_y = 0.5 })) {
            app.language = if (choice == 0) null else choice - 1;
        }

        var entry = dvui.textEntry(@src(), .{
            .text = .{ .buffer = &app.query_buf },
            .placeholder = "title to search for",
        }, .{ .expand = .horizontal, .margin = dvui.Rect{ .x = 6, .w = 6 }, .gravity_y = 0.5 });
        const entered = entry.enter_pressed;
        entry.deinit();

        const searching = app.search.busy() or app.picking;
        const find = dvui.button(@src(), "Find ...", .{ .grayed = searching }, .{ .gravity_y = 0.5 });
        if ((find or entered) and !searching) try startSearch();
    }
    {
        var row = dvui.box(@src(), .{ .dir = .horizontal }, .{ .expand = .horizontal });
        defer row.deinit();

        dvui.label(@src(), "Remux", .{}, .{ .gravity_y = 0.5 });
        var mode: usize = @intFromEnum(app.remux);
        const labels = if (selectedProtocol() == .dlna) &renderer_remux_labels.values else &remux_labels.values;
        if (dvui.dropdown(@src(), labels, .{ .choice = &mode }, .{}, .{ .min_size_content = .{ .w = 180 }, .gravity_y = 0.5 })) {
            app.remux = @enumFromInt(mode);
        }

        const ready = app.readable and app.device != null and !app.cast.ours();
        if (dvui.button(@src(), "Cast", .{ .grayed = !ready }, .{ .gravity_x = 1, .gravity_y = 0.5 }) and ready) {
            try startCast();
        }
    }
}

fn playbackPanel() !void {
    const state = app.cast.snapshot();
    if (state.phase == .idle) {
        // The watch says what it found; without one there is nothing to say.
        const note = state.note();
        dvui.label(@src(), "{s}", .{if (note.len > 0) note else "no device chosen"}, .{});
        return;
    }

    dvui.label(@src(), "{s}", .{state.note()}, .{
        .expand = .horizontal,
        .style = if (state.phase == .failed) .err else .content,
    });

    if (app.cast.progress.fraction()) |done| {
        {
            var row = dvui.box(@src(), .{ .dir = .horizontal }, .{ .expand = .horizontal });
            defer row.deinit();

            dvui.label(@src(), "{s}", .{app.cast.progress.label}, .{ .gravity_y = 0.5 });
            const counted = app.cast.progress.done.load(.monotonic);
            const total = app.cast.progress.total.load(.monotonic);
            if (total > 0) {
                dvui.label(@src(), "{d} / {d}", .{ counted, total }, .{ .gravity_x = 1, .gravity_y = 0.5 });
            } else {
                dvui.label(@src(), "{d}", .{counted}, .{ .gravity_x = 1, .gravity_y = 0.5 });
            }
        }
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

        if (dvui.button(@src(), "-10", .{}, .{})) try dispatch(runSeek, .{"-10"});
        const paused = state.player == .paused;
        if (dvui.button(@src(), if (paused) "Play" else "Pause", .{}, .{ .min_size_content = .{ .w = 60 } })) {
            try dispatch(runCommand, .{if (paused) castig.control.Verb.play else .pause});
        }
        if (dvui.button(@src(), "+10", .{}, .{})) try dispatch(runSeek, .{"+10"});

        // Nothing worth having implements a speed other than 1 over UPnP
        // AV, so the renderers say no and the control says so first.
        if (selectedProtocol() == .dlna) {
            dvui.label(@src(), "x1 only", .{}, .{ .gravity_y = 0.5, .min_size_content = .{ .w = 90 } });
        } else {
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
                try dispatch(runRate, .{@as(f64, app.rate)});
            }
        }

        if (dvui.button(@src(), "Stop", .{}, .{ .gravity_x = 1 })) try dispatch(runStop, .{});
    }
}

fn messagePanel() void {
    var lines: [Messages.capacity]Messages.Line = undefined;
    const count = messages.read(&lines);
    if (count == 0) return;

    _ = dvui.separator(@src(), .{ .expand = .horizontal, .margin = dvui.Rect{ .y = 10, .h = 6 } });
    var tl = dvui.textLayout(@src(), .{}, .{ .expand = .horizontal, .font = .theme(.mono) });
    defer tl.deinit();
    for (lines[0..count]) |line| tl.format("{s}\n", .{line.text()}, .{});
}

/// A ranked OpenSubtitles search, shown as a list to pick from. The video's
/// frame rate comes from the probe, so a candidate that disagrees is ranked
/// down without reading the file twice.
fn startSearch() !void {
    const path = app.path orelse return;
    if (app.fetch.busy()) return;
    closePicker();
    app.picking = true;
    // The field stays editable while the search runs, so the title it held
    // when it started goes along with the call.
    const arena = app.search.begin();
    const title = if (query()) |typed| try arena.dupe(u8, typed) else null;
    try app.search.launch(app.io, app.win, castig.subs.Lookup.open, .{
        castig.Env{
            .io = app.io,
            .arena = arena,
            .gpa = app.gpa,
            .environ = app.environ,
        },
        @as([]const u8, path),
        castig.subs.Options{ .fps = app.fps, .languages = languageOverride(), .title = title },
    });
}

/// What the field holds, or null when it is empty: an empty field searches
/// for the title guessed from the file name, the way the CLI does.
fn query() ?[]const u8 {
    const typed = std.mem.trim(u8, std.mem.sliceTo(&app.query_buf, 0), " ");
    return if (typed.len == 0) null else typed;
}

/// Puts the guess in the field, for the next file to search for. A title too
/// long for the buffer is left out rather than cut in half.
fn seedQuery(path: []const u8) void {
    var scratch: std.heap.ArenaAllocator = .init(app.gpa);
    defer scratch.deinit();

    app.query_buf = @splat(0);
    const guess = castig.subs.guessTitle(scratch.allocator(), Io.Dir.path.stem(path)) catch return;
    if (guess.len >= app.query_buf.len) return;
    @memcpy(app.query_buf[0..guess.len], guess);
}

/// The one language to search in, or null to leave the config's order. The
/// codes are comptime, so the slice outlives the call by itself.
fn languageOverride() ?[]const []const u8 {
    const chosen = app.language orelse return null;
    return castig.language.codes[chosen..][0..1];
}

fn videoFps(r: castig.probe.Report) ?f64 {
    for (r.streams) |st| if (st.video) |v| return v.fps;
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
/// under the reply goes back now rather than at the next search, which may
/// never come. A download saves its path there, so callers wait for it.
fn closePicker() void {
    std.debug.assert(!app.fetch.busy());
    if (app.lookup) |*l| l.deinit();
    app.lookup = null;
    app.rows = &.{};
    app.picking = false;
    app.search.release();
}

/// What the download left behind: the file to side-load on the next cast.
fn takeSaved(saved: castig.subs.Saved) !void {
    const path = try app.gpa.dupeSentinel(u8, saved.path, 0);
    if (app.subtitle_path) |p| app.gpa.free(p);
    app.subtitle_path = path;
    app.subtitles = .source;
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

    if (pickerWait()) |note| {
        dvui.spinner(@src(), .{ .gravity_x = 0.5, .gravity_y = 0.5 });
        dvui.label(@src(), "{s}", .{note}, .{ .gravity_x = 0.5 });
        return;
    }
    if (app.lookup == null) return;

    dvui.label(@src(), "each download spends one of the day's allowance", .{}, .{ .expand = .horizontal });

    var scroll = dvui.scrollArea(@src(), .{}, .{ .expand = .both });
    defer scroll.deinit();

    for (app.rows, 0..) |row, i| {
        if (try candidateButton(row, i)) {
            try app.fetch.start(app.io, app.win, take, .{ &app.lookup.?, i });
        }
    }
}

/// What the picker is waiting for, or null when it can show the list. A
/// download mutates the `Lookup` it runs on, so this thread leaves the
/// candidates alone until it is over.
fn pickerWait() ?[]const u8 {
    if (app.search.busy()) return "searching OpenSubtitles ...";
    if (app.fetch.busy()) return "downloading ...";
    return null;
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
    seedQuery(chosen);
    try startProbe();
}

/// Reads the chosen file against the chosen device. Run again when either
/// changes: what a renderer plays is what it says it plays, so the same
/// file gets a different verdict on a different device.
fn startProbe() !void {
    const path = app.path orelse return;
    if (app.examine.busy()) {
        app.reprobe = true;
        return;
    }
    app.report = "";
    app.readable = false;
    app.fps = null;
    try app.examine.start(app.io, app.win, castig.probe.inspect, .{
        app.examine.allocator(),
        @as([]const u8, path),
        app.profile,
    });
}

/// Asks the chosen device what it plays, which for a renderer is the only
/// way to know. A Cast receiver answers from a table without being asked.
fn startCapabilities() void {
    if (app.capabilities.busy()) return;
    const arena = app.capabilities.begin();
    app.capabilities.launch(app.io, app.win, castig.player.profileOf, .{ castig.Env{
        .io = app.io,
        .arena = arena,
        .gpa = app.gpa,
        .environ = app.environ,
    }, arena.dupe(u8, app.spec()) catch return }) catch {};
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
    // A cast of our own takes the panel over from whatever it was watching.
    app.cast.stopFollowing(app.io);
    try app.cast.start(app.io, app.win, app.gpa, app.environ, app.spec(), .{
        .source = path,
        .remux = app.remux,
        .subtitles = switch (app.subtitles) {
            .sidecar => .sidecar,
            .download => .download,
            .source => if (app.subtitle_path) |p| .{ .source = p } else .sidecar,
        },
    });
}

/// One command at a time: a click while one is in flight is dropped. Every
/// command opens its own connection to whatever is playing.
fn dispatch(comptime func: anytype, extra: anytype) !void {
    if (app.control.busy()) return;
    try app.control.start(app.io, app.win, func, .{ controlEnv(), app.spec() } ++ extra);
}

/// An absolute seek. The busy check also keeps the buffer from changing
/// under a command in flight.
fn seekTo(seconds: f64) !void {
    if (app.control.busy() or !std.math.isFinite(seconds)) return;
    const spec = std.fmt.bufPrint(&app.seek_spec, "{d:.0}", .{seconds}) catch return;
    try dispatch(runSeek, .{spec});
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
fn runCommand(env: castig.Env, device: []const u8, verb: castig.control.Verb) anyerror!void {
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

