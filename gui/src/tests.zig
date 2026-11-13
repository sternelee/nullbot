const std = @import("std");
const testing = std.testing;

const state = @import("state.zig");
const view = @import("view.zig");
const harness = @import("harness.zig");
const Window = harness.Window;

test {
    _ = @import("backend.zig");
    _ = @import("md.zig");
    _ = @import("runtime.zig");
    _ = @import("state.zig");
    _ = @import("theme.zig");
    _ = @import("view.zig");
    _ = @import("contract.zig");
    _ = @import("shot.zig");
}

test "the window draws its shell, sidebar and composer" {
    var w: Window = undefined;
    try w.init();
    defer w.deinit();

    w.tester.settle(0.5);
    try testing.expect(w.tester.hasText("nullclaw"));
    try testing.expect(w.tester.hasText("Sessions"));
    try testing.expect(w.tester.hasText("No sessions yet"));
    try testing.expect(w.tester.hasText("Ask nullclaw anything"));
}

test "every page names itself in the sidebar and the header" {
    var w: Window = undefined;
    try w.init();
    defer w.deinit();

    for (state.nav) |page| {
        w.app.openPage(page);
        w.tester.settle(0.3);
        try testing.expect(w.tester.hasText(page.label()));
    }
}

test "a session row shows its key and its turns" {
    var w: Window = undefined;
    try w.init();
    defer w.deinit();

    try w.app.sessions.append(testing.allocator, .{
        .key = try testing.allocator.dupe(u8, "telegram:42"),
        .message_count = 6,
        .turn_count = 0,
        .created_at = try testing.allocator.dupe(u8, "2026-05-30T14:07:11Z"),
        .last_active = try testing.allocator.dupe(u8, "2026-05-30T14:09:02Z"),
    });

    w.tester.settle(0.5);
    try testing.expect(w.tester.hasText("telegram:42"));
    try testing.expect(w.tester.hasText("3 turns"));
}

test "a transcript draws markdown and retires the empty state" {
    var w: Window = undefined;
    try w.init();
    defer w.deinit();

    w.app.pushMessage("user", "hello there");
    w.app.pushMessage("assistant", "# Answer\n\nUse `nullclaw status` for that.\n\n- one\n- two");
    w.tester.settle(0.5);

    try testing.expect(w.tester.hasText("hello there"));
    try testing.expect(w.tester.hasText("Answer"));
    try testing.expect(w.tester.containsText("nullclaw status"));
    try testing.expect(w.tester.hasText("one"));
    try testing.expect(w.tester.hasText("two"));
    try testing.expect(!w.tester.hasText("Ask nullclaw anything"));
}

test "a toast appears and goes away" {
    var w: Window = undefined;
    try w.init();
    defer w.deinit();

    w.app.say("no config found");
    w.tester.settle(0.4);
    try testing.expect(w.tester.hasText("no config found"));

    w.app.dismissToast();
    w.tester.settle(0.4);
    try testing.expect(!w.tester.hasText("no config found"));
}

test "the config page draws its own controls" {
    var w: Window = undefined;
    try w.init();
    defer w.deinit();

    w.app.openPage(.config);
    w.tester.settle(0.5);

    // nanoterm-style page: a heading, a runtime card and one section per
    // group. The raw JSON editor is folded away until it is asked for.
    try testing.expect(w.tester.hasText("Configuration"));
    try testing.expect(w.tester.hasText("Built-in nullclaw runtime"));
    try testing.expect(w.tester.hasText("Provider"));
    try testing.expect(w.tester.hasText("Gateway"));
    try testing.expect(w.tester.hasText("Agent"));
    try testing.expect(w.tester.hasText("Memory"));
    try testing.expect(w.tester.hasText("Reliability"));
    try testing.expect(w.tester.containsText("Reload"));
    try testing.expect(w.tester.containsText("Save & restart"));
    try testing.expect(w.tester.containsText("model.primary"));
    try testing.expect(w.tester.containsText("Show advanced"));
    try testing.expect(!w.tester.containsText("Hide advanced"));
}

test "a json page folds what it is told to" {
    var w: Window = undefined;
    try w.init();
    defer w.deinit();

    w.app.openPage(.models);
    w.app.setJson(
        \\{"models":["glm-4.6","claude-sonnet-4-5"]}
    );
    w.tester.settle(0.4);
    try testing.expect(w.tester.containsText("models"));

    w.app.collapseAll();
    w.tester.settle(0.4);
    try testing.expect(w.tester.containsText("models"));
}

// The window is the deliverable; the tests above keep it drawable.

test "the shell puts the sidebar on the left, the transcript beside it, and the composer under it" {
    var w: Window = undefined;
    try w.init();
    defer w.deinit();

    w.app.pushMessage("user", "a question");
    w.app.pushMessage("assistant", "an answer");
    w.tester.settle(0.5);

    const brand = w.tester.findText("nullclaw") orelse return error.NoBrand;
    const heading = w.tester.findText("Sessions") orelse return error.NoSessions;
    const question = w.tester.findText("a question") orelse return error.NoQuestion;
    const answer = w.tester.findText("an answer") orelse return error.NoAnswer;
    const hint = w.tester.findText("return to send · shift-return for a new line") orelse return error.NoComposer;

    // The sidebar is the left column: its section heading starts at the
    // sidebar's own padding, and the brand sits in from there, past its icon.
    try testing.expect(heading.x < brand.x);
    try testing.expect(brand.x < view.sidebar_width);
    try testing.expect(heading.x < view.sidebar_width / 2);

    // The transcript is the other column: both bubbles are right of the
    // sidebar, and neither is in the sidebar's half of the window.
    try testing.expect(question.x > view.sidebar_width);
    try testing.expect(answer.x > view.sidebar_width);
    try testing.expect(question.x > view.sidebar_width + 120);

    // A short exchange is short bubbles: the question hugs the right edge of
    // the transcript, the answer its left edge, and neither spans the width.
    try testing.expect(question.x > answer.x);
    try testing.expect(question.x + question.w > 1100);
    try testing.expect(answer.x < view.sidebar_width + 100);
    try testing.expect(answer.w < 400);

    // The composer sits under the transcript, at the foot of the window.
    try testing.expect(hint.y > answer.y);
    try testing.expect(hint.y > 700);
}

test "the window drives the runtime and shows what it answers" {
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest;
    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    var path_buffer: [256]u8 = undefined;
    const stub = try harness.writeStub(threaded.io(), &path_buffer);

    var w: Window = undefined;
    try w.initWith(.{ .runtime = stub });
    defer w.deinit();

    // The sidebar fills from `agent sessions list`.
    w.app.refreshSessions();
    w.settle(2);
    try testing.expectEqual(@as(usize, 1), w.app.sessions.items.len);
    try testing.expectEqualStrings("s1", w.app.sessions.items[0].key);
    try testing.expect(w.tester.containsText("s1"));
    try testing.expect(w.tester.containsText("3 turns"));

    // Selecting a session loads it with `history show`, and the markdown comes
    // out as text rather than asterisks.
    w.app.select(0);
    w.settle(2);
    try testing.expectEqual(@as(usize, 2), w.app.messages.items.len);
    try testing.expect(w.tester.containsText("what is nullclaw"));
    try testing.expect(w.tester.containsText("is a Zig runtime"));
    try testing.expect(!w.tester.containsText("**nullclaw**"));

    // Sending goes through `agent invoke` and lands in the transcript.
    w.app.composer.set("hello runtime");
    w.app.send();
    try testing.expectEqual(@as(usize, 3), w.app.messages.items.len);
    w.settle(2);
    try testing.expectEqual(@as(usize, 4), w.app.messages.items.len);
    try testing.expect(w.tester.containsText("hello runtime"));
    try testing.expect(w.tester.containsText("stub reply"));
    try testing.expect(!w.app.sending);
    try testing.expectEqualStrings("", w.app.composer.text());
}

test "a page shows the runtime's rows, and its complaint when there is none" {
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest;
    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    var path_buffer: [256]u8 = undefined;
    const stub = try harness.writeFailingStub(threaded.io(), &path_buffer);

    var w: Window = undefined;
    try w.initWith(.{ .runtime = stub });
    defer w.deinit();

    // The runtime answers nothing, so the page reports what it said and keeps
    // its own chrome.
    w.app.openPage(.status);
    w.settle(2);
    // The complaint is on the page, not only in a toast that expires: the
    // panel used to say "the runtime said nothing" while the real message
    // vanished after six seconds.
    try testing.expect(w.tester.containsText("no answer for: status"));
    try testing.expect(w.tester.containsText("The runtime's command failed"));
    // The page header owns Run; the fold controls are gone, because there is
    // no tree to fold.
    try testing.expect(w.tester.hasText("Run"));
    try testing.expect(!w.tester.containsText("Expand all"));
}

// Regression: 14 of the 16 pages painted nothing, because the toolbar's `defer`
// made the whole page a child of a 27-point row and clipped the rows inside it.
// The single-page test above only covered one page; this walks every page that
// asks for json and checks its rows are painted below the toolbar, across the
// pane — geometry that a node-existence query cannot see.
test "every json page paints its rows below the toolbar" {
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest;
    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    var path_buffer: [256]u8 = undefined;
    const stub = try harness.writeStub(threaded.io(), &path_buffer);

    var w: Window = undefined;
    try w.initWith(.{ .runtime = stub });
    defer w.deinit();

    var checked: usize = 0;
    for (state.nav) |page| {
        // Chat runs no command, and the config page has its own test.
        if (page == .chat or page == .config) continue;
        if (!page.takesJson()) continue;

        w.app.openPage(page);
        w.settle(2);

        const lines = w.app.json_lines orelse {
            std.debug.print("page {s}: no rows at all\n", .{@tagName(page)});
            return error.NoLines;
        };
        const rows = lines.slice();
        if (rows.len == 0) {
            std.debug.print("page {s}: the tree is empty\n", .{@tagName(page)});
            return error.EmptyTree;
        }

        const toolbar = w.tester.findText("Expand all") orelse {
            std.debug.print("page {s}: no toolbar\n", .{@tagName(page)});
            return error.NoToolbar;
        };

        // The first row whose text appears only once, so a lookup can find it.
        var painted = false;
        for (rows) |row| {
            var twins: usize = 0;
            for (rows) |other| {
                if (std.mem.eql(u8, other.text, row.text)) twins += 1;
            }
            if (twins != 1) continue;
            const rect = w.tester.findText(row.text) orelse continue;
            if (rect.y < toolbar.y + toolbar.h) {
                std.debug.print("page {s}: row `{s}` sits inside the toolbar\n", .{ @tagName(page), row.text });
                return error.RowInsideToolbar;
            }
            if (rect.w <= 400) {
                std.debug.print("page {s}: row `{s}` is {d} wide\n", .{ @tagName(page), row.text, rect.w });
                return error.RowTooNarrow;
            }
            painted = true;
            break;
        }
        if (!painted) {
            std.debug.print("page {s}: no row was painted\n", .{@tagName(page)});
            return error.RowNotPainted;
        }
        checked += 1;
    }
    // The ten pages that ask for json: status, capabilities, doctor, models,
    // memory, skills, channels, cron, mcp and workspace. The other four page
    // commands (auth, hardware, service, update) print prose, and chat and
    // config are covered by their own tests. A number that is written down
    // fails if a page quietly stops asking for json.
    try testing.expectEqual(@as(usize, 10), checked);
}

// Regression: the JSON page's toolbar was closed with a `defer`, so the rows
// below it became children of the 27-point toolbar row and were laid out
// inside it. `containsText` cannot see that — the nodes exist either way —
// so this asserts the geometry the user actually gets.
test "a page's rows are laid out below its toolbar, across the page" {
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest;
    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    var path_buffer: [256]u8 = undefined;
    const stub = try harness.writeStub(threaded.io(), &path_buffer);

    var w: Window = undefined;
    try w.initWith(.{ .runtime = stub });
    defer w.deinit();

    w.app.openPage(.models);
    w.settle(2);
    const lines = w.app.json_lines orelse return error.NoLines;
    const rows = lines.slice();
    try testing.expect(rows.len >= 2);

    const toolbar = w.tester.findText("Expand all") orelse return error.NoToolbar;
    var checked: usize = 0;
    for (rows) |row| {
        // Rows that share a line's text cannot be told apart by a lookup.
        var twins: usize = 0;
        for (rows) |other| {
            if (std.mem.eql(u8, other.text, row.text)) twins += 1;
        }
        if (twins != 1) continue;
        const painted = row.painted(testing.allocator);
        defer if (painted.ptr != row.text.ptr) testing.allocator.free(painted);
        const rect = w.tester.findText(painted) orelse return error.RowNotPainted;
        try testing.expect(rect.y >= toolbar.y + toolbar.h);
        try testing.expect(rect.w > 400);
        try testing.expect(rect.y + rect.h <= 800);
        checked += 1;
    }
    try testing.expect(checked >= 2);
}

test "the diagnostics panel names what the window is connected to" {
    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var path_buffer: [256]u8 = undefined;
    const stub = try harness.writeStub(io, &path_buffer);

    var w: Window = undefined;
    try w.initWith(.{ .runtime = stub });
    defer w.deinit();

    w.app.refreshSessions();
    w.settle(1);
    w.app.select(0);
    w.settle(1);

    // Closed by default: the panel is a thing you ask for.
    try testing.expect(!w.tester.containsText("Diagnostics"));

    w.app.diagnostics_open = true;
    w.tester.settle(0.5);
    try testing.expect(w.tester.containsText("Diagnostics"));
    // The paths it reads, and the session it has open — all from state.
    try testing.expect(w.tester.containsText("Runtime"));
    try testing.expect(w.tester.containsText("Config"));
    try testing.expect(w.tester.containsText("Workspace"));
    try testing.expect(w.tester.containsText("s1"));
    // The theme it is drawn in, so a screenshot can be traced to a palette.
    try testing.expect(w.tester.containsText("Matrix"));
}

// Regression: `gotConfig` loaded the file but never handed it to the tree, so
// the config page drew its toolbar over an empty pane and `03-config.png`
// showed nothing at all. It runs without a runtime on purpose: reading the
// file must not depend on one being installed.
test "the config page paints the file it loaded" {
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest;
    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    _ = try harness.writeConfig(io, "{\n  \"agents\": { \"defaults\": { \"model\": { \"primary\": \"openrouter/stub-model\" } } }\n}\n");
    defer harness.removeConfig(io);

    var w: Window = undefined;
    try w.initWith(.{});
    defer w.deinit();

    w.app.openPage(.config);
    w.settle(2);
    try testing.expect(w.app.config != null);
    try testing.expectEqualStrings("openrouter/stub-model", w.app.config.?.get("agents.defaults.model.primary").?);
    // The runtime is missing, and the page says so without losing the file.
    try testing.expect(std.mem.indexOf(u8, w.app.toast, "FileNotFound") != null);

    // The raw JSON tree lives behind the Advanced fold; open it and draw a
    // frame so the rows exist to be measured.
    w.app.show_advanced_config = true;
    // Every container open, so the value is a row rather than a summary.
    w.app.expandAll();
    w.tester.frame();

    // Both keys are painted. The tree lives in the scrolling band, so its
    // rows can sit past the fold once the form above them is long; what
    // matters is that the band ends above the pinned bar, not that every row
    // is on screen.
    const bar = w.tester.findText("Reload") orelse return error.NoToolbar;
    const lines = w.app.json_lines orelse return error.NoRowsLoaded;
    var found: usize = 0;
    for (lines.slice()) |row| {
        if (w.tester.findText(row.text) == null) continue;
        found += 1;
    }
    // The bar is pinned to the window, not to the end of the content.
    try testing.expect(bar.y < w.tester.size.h);
    try testing.expect(found >= 2);
    // The tree holds the file's keys. It scrolls inside the band, so a row
    // past the fold is still in the list even when it is not on screen; the
    // value itself sits under `agents.defaults.model.primary`, three levels
    // down, so the tree is checked for the top-level key it starts from.
    var saw_agents = false;
    for (lines.slice()) |row| {
        if (std.mem.indexOf(u8, row.text, "agents") != null) saw_agents = true;
    }
    try testing.expect(saw_agents);
}
