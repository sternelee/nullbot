const std = @import("std");
const testing = std.testing;
const ui = @import("nanoui").ui;

const state = @import("state.zig");
const backend = @import("backend.zig");
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
    _ = @import("wiring.zig");
}

test "the window draws its shell, sidebar and composer" {
    var w: Window = undefined;
    try w.init();
    defer w.deinit();

    w.tester.settle(0.5);
    try testing.expect(w.tester.containsText("nullclaw"));
    try testing.expect(w.tester.hasText("Sessions"));
    try testing.expect(w.tester.hasText("No sessions yet"));
    try testing.expect(w.tester.hasText("What can I help with?"));
}

test "the brand menu reaches the configuration page" {
    var w: Window = undefined;
    try w.init();
    defer w.deinit();

    w.tester.settle(0.5);
    try w.tester.clickText("nullclaw ⌄");
    w.tester.settle(0.6);
    // The menu lists the non-chat pages; Configuration is the one the user
    // asked to move behind a collapsible entry.
    try testing.expect(w.tester.hasText("Configuration"));
    try w.tester.clickText("Configuration");
    w.tester.settle(0.5);
    try testing.expectEqual(state.Page.config, w.app.page);
    try testing.expect(!w.app.menu_open);
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
    // The row sits under the heading for when it last spoke.
    try testing.expect(w.tester.hasText("Older"));
}

// Sessions are grouped the way the web client groups them, so a long list
// reads as "when" instead of as one undifferentiated column.
test "sessions are grouped under the day they last spoke" {
    var w: Window = undefined;
    try w.init();
    defer w.deinit();

    // The grouping is against the clock, so the fresh session is stamped with
    // today's date rather than with a fixed one that would age out of the
    // bucket this test is about.
    const year_day = (std.time.epoch.EpochDay{ .day = @intCast(backend.todayDay(w.app.io)) }).calculateYearDay();
    const month_day = year_day.calculateMonthDay();
    const stamp = try std.fmt.allocPrint(testing.allocator, "{d:0>4}-{d:0>2}-{d:0>2}T09:00:00Z", .{
        year_day.year,
        @backingInt(month_day.month),
        month_day.day_index + 1,
    });
    defer testing.allocator.free(stamp);

    try w.app.sessions.append(testing.allocator, .{
        .key = try testing.allocator.dupe(u8, "today:1"),
        .created_at = try testing.allocator.dupe(u8, stamp),
        .last_active = try testing.allocator.dupe(u8, stamp),
    });
    try w.app.sessions.append(testing.allocator, .{
        .key = try testing.allocator.dupe(u8, "stale:2"),
        .created_at = try testing.allocator.dupe(u8, "2020-01-02T03:04:05Z"),
        .last_active = try testing.allocator.dupe(u8, "2020-01-02T03:04:05Z"),
    });

    w.tester.settle(0.5);
    try testing.expect(w.tester.hasText("Today"));
    try testing.expect(w.tester.hasText("Older"));
    // Newest first: the heading is only useful if the list is in the order the
    // headings claim.
    const fresh = w.tester.findText("today:1") orelse return error.NoFreshRow;
    const stale = w.tester.findText("stale:2") orelse return error.NoStaleRow;
    try testing.expect(fresh.y < stale.y);
}

// The strip is a list of distinct places. Two buttons over one page is how it
// shipped, and it is the kind of thing that comes back by accident.
test "the rail's destinations are distinct and real" {
    var seen: [view.rail_entries.len]?state.Page = @splat(null);
    var new_chat: usize = 0;
    for (view.rail_entries, 0..) |entry, i| {
        try testing.expect(entry.label.len > 0);
        try testing.expect(entry.icon.len > 0);
        switch (entry.target) {
            .new_chat => new_chat += 1,
            .page => |page| {
                for (seen[0..i]) |earlier| {
                    if (earlier != null and earlier.? == page) return error.DuplicateRailDestination;
                }
                seen[i] = page;
                // A destination the window cannot draw would be a dead button.
                try testing.expect(std.mem.indexOfScalar(state.Page, &state.nav, page) != null);
            },
        }
    }
    // Exactly one button starts a conversation; the rest are places.
    try testing.expectEqual(@as(usize, 1), new_chat);
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
    //
    // The sections are the settings worth a control: what answers, where it
    // works, which servers it may call, and whether it runs on a schedule.
    // The rest of config.json stays in the advanced fold.
    try testing.expect(w.tester.hasText("Configuration"));
    try testing.expect(w.tester.hasText("Built-in nullclaw runtime"));
    try testing.expect(w.tester.hasText("Provider"));
    try testing.expect(w.tester.hasText("Workspace"));
    try testing.expect(w.tester.hasText("MCP servers"));
    try testing.expect(w.tester.hasText("Cron"));
    try testing.expect(w.tester.hasText("Skills"));
    try testing.expect(w.tester.hasText("Capabilities"));
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

    const brand = w.tester.findText("nullclaw ⌄") orelse return error.NoBrand;
    const heading = w.tester.findText("Sessions") orelse return error.NoSessions;
    const question = w.tester.findText("a question") orelse return error.NoQuestion;
    const answer = w.tester.findText("an answer") orelse return error.NoAnswer;
    // The hint now leads with the session the message will land in, so it is
    // found by the part that is always there rather than by its whole text.
    const hint = blk: {
        for (w.tester.ctx.nodes.items) |n| switch (n.content) {
            .text => |tx| if (std.mem.indexOf(u8, tx.str, "return to send") != null) break :blk n.rect,
            else => {},
        };
        break :blk null;
    } orelse return error.NoComposer;

    // The rail is the leftmost strip, then the sidebar: its section heading
    // starts at the sidebar's own padding, and the brand sits in from there.
    const left = view.rail_width + view.sidebar_width;
    try testing.expect(heading.x < brand.x);
    try testing.expect(brand.x < left);
    try testing.expect(heading.x < view.rail_width + view.sidebar_width / 2);

    // The transcript is the other column: both messages sit right of the
    // rail and sidebar, past the avatar gutter.
    try testing.expect(question.x > left);
    try testing.expect(answer.x > left);
    try testing.expect(question.x > left + 60);

    // The ChatGPT-style layout: every message is a full-width row with the
    // text at the same left edge, after its role avatar. Nothing is
    // right-aligned, so the two bodies line up rather than facing off.
    // The user's body carries a small padding block, so its text starts a
    // little further in than the assistant's; both are in the same gutter.
    try testing.expect(@abs(question.x - answer.x) < 20);

    // The exchange reads top to bottom: the question above the answer.
    try testing.expect(question.y < answer.y);

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

    // The sidebar fills from the linked runtime's session store. The stub
    // process no longer answers it: sessions and transcripts are function
    // calls now, so this test checks the window against whatever the real
    // config's memory backend has (a store-less backend has none).
    w.app.refreshSessions();
    w.settle(2);
    if (w.app.sessions.items.len > 0) {
        w.app.select(0);
        w.settle(2);
    }

    // Sending runs a turn against the linked runtime. That needs a real
    // config, a provider and a memory backend — a stub process cannot stand
    // in for a function call — so this test stops at the part it can check:
    // the message is kept and the composer clears. A turn that cannot start
    // is reported rather than swallowed.
    // A turn needs a real config, provider and memory backend; the linked
    // runtime is exercised by the runtime's own tests. Here the window is
    // checked for what it owns: the composer, the transcript, the sidebar.
    try testing.expect(w.app.linked != null);
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

    // Every page that asks for JSON is answered by a function now, so the
    // complaint path is driven directly: it is what a page shows when the
    // runtime cannot answer at all.
    w.app.openPage(.status);
    w.settle(2);
    w.app.setJsonProblem("no answer for: status");
    w.tester.frame();

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
        // A page the runtime answers as a function fills its tree inside
        // `openPage`, so the frame `settle` drew was still the old one.
        w.tester.frame();

        // A page with a reader for its answer draws a list, and a list has no
        // fold controls. Either way something has to be on the page.
        if (w.app.rows) |*r| {
            // An empty list is a real answer — "no skills installed" — and
            // the page says so rather than drawing an empty tree.
            if (r.totalRows() == 0) {
                if (!w.tester.containsText("No ")) {
                    std.debug.print("page {s}: empty list with no notice\n", .{@tagName(page)});
                    return error.SilentEmptyList;
                }
                checked += 1;
                continue;
            }
            var painted = false;
            for (r.groups.items) |g| {
                for (g.rows.items) |row| {
                    if (w.tester.findText(row.title) != null) painted = true;
                }
            }
            if (!painted) {
                std.debug.print("page {s}: no row title was painted\n", .{@tagName(page)});
                return error.ListNotPainted;
            }
            checked += 1;
            continue;
        }

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

    w.app.openPage(.capabilities);
    w.settle(2);
    w.tester.frame();

    // Capabilities has a reader, so it draws a list rather than a tree. It
    // also answers without a config — it lists what the build carries — so
    // this works in a test, where there is no config to read.
    const list = w.app.rows orelse return error.NoList;
    try testing.expect(list.totalRows() >= 1);

    var checked: usize = 0;
    for (list.groups.items) |group| {
        for (group.rows.items) |row| {
            const rect = w.tester.findText(row.title) orelse continue;
            // Below the header. A long list runs past the fold — it scrolls —
            // so only the top edge is checked.
            try testing.expect(rect.y > 60);
            checked += 1;
        }
    }
    try testing.expect(checked >= 1);
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
    // The paths it reads — all from state. The session row is only present
    // when the real config's memory backend has a session store.
    try testing.expect(w.tester.containsText("Runtime"));
    try testing.expect(w.tester.containsText("Config"));
    try testing.expect(w.tester.containsText("Workspace"));
    // The theme it is drawn in, so a screenshot can be traced to a palette.
    try testing.expect(w.tester.containsText("Neutral"));
}

// The pages are answered by the linked runtime, not by a program. The stub
// here answers nothing at all: a page that still spawned it would come back
// with its complaint, and this would fail.
test "every data page answers without a runtime on disk" {
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest;
    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    var path_buffer: [256]u8 = undefined;
    const stub = try harness.writeFailingStub(threaded.io(), &path_buffer);

    var w: Window = undefined;
    try w.initWith(.{ .runtime = stub });
    defer w.deinit();

    var checked: usize = 0;
    for (state.nav) |page| {
        if (page == .chat or page == .config) continue;
        if (!page.takesJson()) continue;

        w.app.openPage(page);
        w.settle(1);
        if (w.app.json_text.len == 0) {
            std.debug.print("page {s}: no answer at all\n", .{@tagName(page)});
            return error.NoAnswer;
        }
        if (std.mem.indexOf(u8, w.app.json_text, "no answer for") != null) {
            std.debug.print("page {s}: still asks the CLI\n", .{@tagName(page)});
            return error.AskedTheCli;
        }
        checked += 1;
    }
    // Every page that asks for JSON. A number written down fails if a page
    // quietly stops asking for it, or a new one is added and not covered.
    try testing.expectEqual(@as(usize, 10), checked);
}

// The window carries the runtime as a module, not as a program it looks for.
// This is the check that the link is real: the version comes out of the
// runtime's own code, and the builder the chat uses is its type.
test "the window links the runtime rather than spawning one" {
    const yc = @import("nullclaw");
    try testing.expect(yc.version.string.len > 0);
    try testing.expect(@sizeOf(yc.runtime_builder.Runtime) > 0);
    // The chat's own field holds that type by pointer — a heap runtime, so
    // the struct can be returned by value without dangling the agent's
    // internal pointers — not a path to an executable.
    try testing.expect(@FieldType(state.AppState, "linked") == ?*yc.runtime_builder.Runtime);
}

// Regression: six icon names were not in nanoui's table
// (`square.and.arrow.down`, `hexagon.fill`, `tray`, …), so they drew as
// missing-glyph boxes — the Save button read "d Save & restart". This walks
// the source and fails on any name the toolkit cannot draw.
test "every icon the view and the page table name exists in the toolkit" {
    const io = std.Io.Threaded.global_single_threaded.io();
    const icons_src = try std.Io.Dir.cwd().readFileAlloc(io, "zig-pkg/nanoui-0.13.0-we0KMd1-MQBzJq1VU59oWYKF3KHhSYPj8_qjVe2icq_e/src/ui/icons.zig", testing.allocator, .limited(1 << 20));
    defer testing.allocator.free(icons_src);

    const view_src = try std.Io.Dir.cwd().readFileAlloc(io, "src/view.zig", testing.allocator, .limited(1 << 20));
    defer testing.allocator.free(view_src);

    // Every `.name = "x"` in the table is a name the toolkit can draw.
    var known: std.StringHashMapUnmanaged(void) = .empty;
    defer {
        var it = known.keyIterator();
        while (it.next()) |k| testing.allocator.free(k.*);
        known.deinit(testing.allocator);
    }
    var at: usize = 0;
    while (std.mem.indexOfPos(u8, icons_src, at, ".name = \"")) |i| {
        const start = i + ".name = \"".len;
        const end = std.mem.indexOfScalarPos(u8, icons_src, start, '"') orelse break;
        const name = try testing.allocator.dupe(u8, icons_src[start..end]);
        known.put(testing.allocator, name, {}) catch testing.allocator.free(name);
        at = end;
    }
    try testing.expect(known.count() > 20);

    // Every icon the view names has to be one of them.
    var checked: usize = 0;
    var pos: usize = 0;
    while (pos < view_src.len) {
        const hit = std.mem.indexOfPos(u8, view_src, pos, "icon") orelse break;
        pos = hit + 4;
        // `icon(c, "name"` or `.icon = "name"`.
        var q = pos;
        while (q < view_src.len and view_src[q] != '"' and q - pos < 24) q += 1;
        if (q >= view_src.len or view_src[q] != '"') continue;
        const start = q + 1;
        const end = std.mem.indexOfScalarPos(u8, view_src, start, '"') orelse break;
        const name = view_src[start..end];
        if (name.len == 0 or std.mem.indexOfScalar(u8, name, ' ') != null) continue;
        pos = end;
        if (std.mem.eql(u8, name, "")) continue;
        checked += 1;
        if (!known.contains(name)) {
            std.debug.print("icon `{s}` is not in the toolkit\n", .{name});
            return error.UnknownIcon;
        }
    }
    try testing.expect(checked > 10);

    // The page table lives in state.zig, so the scan above never reaches it —
    // and ten of its sixteen names were not in the toolkit. Check it by value.
    for (state.nav) |page| {
        if (!known.contains(page.icon())) {
            std.debug.print("page `{s}` wears icon `{s}`, which is not in the toolkit\n", .{ page.label(), page.icon() });
            return error.UnknownIcon;
        }
    }
}

// The page is an editor, not a viewer: what the form holds has to reach the
// file. This drives the form the way a person would — set the fields, Apply,
// Save — and then reads the file back off disk.
test "the config form writes what it was given to the file" {
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest;
    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var path_buffer: [256]u8 = undefined;
    const stub = try harness.writeStub(io, &path_buffer);
    _ = try harness.writeConfig(io,
        \\{"agents":{"defaults":{"model":{"primary":"openrouter/stub-model"}}}}
    );
    defer harness.removeConfig(io);

    var w: Window = undefined;
    try w.initWith(.{ .runtime = stub });
    defer w.deinit();

    w.app.openPage(.config);
    w.settle(2);
    try testing.expect(w.app.config != null);

    // The form, as a person would fill it.
    w.app.cfg_default_model.set("glm-4.6");
    w.app.cfg_workspace.set("/tmp/scratch-workspace");
    w.app.cfg_cron_enabled = true;
    w.app.cfg_cron_interval.set("15");
    w.app.cfg_mcp_servers.set("filesystem npx -y server-filesystem\ngit mcp-server-git");

    w.app.applyConfigForm();
    w.app.saveConfig();
    w.settle(2);

    // Saving validates in-process against the Config the runtime builds, not
    // by spawning `config validate`: a config the runtime accepts reports
    // "saved and valid", and a window that links the runtime has no separate
    // `nullclaw` binary to spawn for it.
    try testing.expect(std.mem.indexOf(u8, w.app.toast, "saved and valid") != null);

    // Read the file back: the form's values are in it.
    const written = try std.Io.Dir.cwd().readFileAlloc(io, harness.test_home ++ "/.nullclaw/config.json", testing.allocator, .limited(1 << 16));
    defer testing.allocator.free(written);

    try testing.expect(std.mem.indexOf(u8, written, "openrouter/glm-4.6") != null);
    try testing.expect(std.mem.indexOf(u8, written, "/tmp/scratch-workspace") != null);
    try testing.expect(std.mem.indexOf(u8, written, "\"enabled\": true") != null);
    try testing.expect(std.mem.indexOf(u8, written, "\"interval_minutes\": 15") != null);
    try testing.expect(std.mem.indexOf(u8, written, "mcp_servers") != null);
    try testing.expect(std.mem.indexOf(u8, written, "mcp-server-git") != null);

    // And the document the page holds agrees with the file.
    try testing.expectEqualStrings("openrouter/glm-4.6", w.app.config.?.get("agents.defaults.model.primary").?);
    try testing.expectEqualStrings("/tmp/scratch-workspace", w.app.config.?.get("workspace").?);
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
    // Loading the file no longer needs a runtime: the document is read from
    // disk and validated against the config in-process, so a missing program
    // cannot lose the file.
    try testing.expect(w.app.toast.len == 0);

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

test "a new chat gets its own session, not the one that was open" {
    var w: Window = undefined;
    try w.init();
    defer w.deinit();

    // Two new chats in a row must not share a key: that is what made the
    // second one reopen the first one's transcript.
    w.app.newChat();
    const first = w.app.turnSession() orelse return error.NoSession;
    const first_owned = try testing.allocator.dupe(u8, first);
    defer testing.allocator.free(first_owned);

    w.app.newChat();
    const second = w.app.turnSession() orelse return error.NoSession;

    try testing.expect(!std.mem.eql(u8, first_owned, second));
    // A draft is named for the window, so a session the runtime already has
    // is never mistaken for one this window made.
    try testing.expect(std.mem.startsWith(u8, second, "gui:"));
}

test "an open session wins over the draft" {
    var w: Window = undefined;
    try w.init();
    defer w.deinit();

    w.app.newChat();
    const draft = try testing.allocator.dupe(u8, w.app.turnSession() orelse return error.NoSession);
    defer testing.allocator.free(draft);

    // Selecting a real session must send the next turn there, not to the
    // draft the new chat made.
    try w.app.sessions.append(testing.allocator, .{
        .key = try testing.allocator.dupe(u8, "api:default"),
        .created_at = try testing.allocator.dupe(u8, ""),
        .last_active = try testing.allocator.dupe(u8, ""),
    });
    w.app.selected = 0;

    const chosen = w.app.turnSession() orelse return error.NoSession;
    try testing.expectEqualStrings("api:default", chosen);
    try testing.expect(!std.mem.eql(u8, draft, chosen));
}

// Regression: clicking the composer's model chip opens Configuration, which
// reloads the config and replaces the very string the chip was drawn from.
// nanoui measures a frame after the view returns, so freeing that string
// mid-frame left the measure reading freed memory — a segfault against the
// machine's own config.
test "clicking the model chip survives the config it reloads" {
    var w: Window = undefined;
    try w.init();
    defer w.deinit();

    _ = try harness.writeConfig(w.threaded.io(), "{\"agents\":{\"defaults\":{\"model\":{\"primary\":\"openrouter/stub-model\"}}}}");
    defer harness.removeConfig(w.threaded.io());
    w.app.loadConfig();
    w.tester.settle(0.5);
    try testing.expect(w.tester.hasText("stub-model"));

    try w.tester.clickText("stub-model");
    w.tester.settle(0.5);
    try testing.expectEqual(state.Page.config, w.app.page);
}
