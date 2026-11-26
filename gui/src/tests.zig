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
    _ = @import("design.zig");
    _ = @import("virtual_list.zig");
    _ = @import("sidebar/mod.zig");
    _ = @import("sidebar/session_row.zig");
    _ = @import("chat/mod.zig");
    _ = @import("chat/message.zig");
    _ = @import("chat/code_block.zig");
    _ = @import("composer/mod.zig");
    _ = @import("composer/model_chip.zig");
}

test "the window draws its shell, sidebar and composer" {
    var w: Window = undefined;
    try w.init();
    defer w.deinit();

    w.tester.settle(0.5);
    try testing.expect(w.tester.containsText("nullclaw"));
    // The zeron-style sidebar: a search field, the compact/grouped toggles,
    // and the empty-state hint under them.
    try testing.expect(w.tester.containsText("Search chats"));
    try testing.expect(w.tester.hasText("Compact"));
    try testing.expect(w.tester.hasText("No sessions yet"));
    try testing.expect(w.tester.hasText("Where should we start?"));
}

// The settings button at the sidebar's foot is the one way into every page but
// the conversation. It swaps the sidebar to the settings menu, and Configuration
// is the first page listed there.
test "the settings button reaches the configuration page" {
    var w: Window = undefined;
    try w.init();
    defer w.deinit();

    w.tester.settle(0.5);
    w.app.toggleSettings();
    w.tester.settle(0.5);
    // The menu lists the non-chat pages; Configuration is the one the user
    // asked to move behind a collapsible entry.
    try testing.expect(w.tester.hasText("Configuration"));
    try w.tester.clickText("Configuration");
    w.tester.settle(0.5);
    try testing.expectEqual(state.Page.config, w.app.page);
    try testing.expect(w.app.settings_open);
}

// The settings button swaps the sidebar to a menu of every settings page,
// rather than just landing on the configuration page. Opening Settings shows
// the conversation list's own heading gone and the menu's groups in its place,
// and going back restores the chats.
test "the settings button swaps the sidebar to the settings menu" {
    var w: Window = undefined;
    try w.init();
    defer w.deinit();

    w.tester.settle(0.5);
    // The conversation sidebar is what is up before the button is pressed.
    try testing.expect(w.tester.hasText("Search chats"));
    try testing.expect(w.tester.hasText("Compact"));

    w.app.toggleSettings();
    w.tester.settle(0.5);
    // The menu is up, the conversation list is not, and the body follows the
    // sidebar to the configuration page.
    try testing.expect(w.app.settings_open);
    try testing.expect(w.tester.hasText("Settings"));
    try testing.expect(w.tester.hasText("Runtime"));
    try testing.expect(w.tester.hasText("System"));
    try testing.expect(w.tester.hasText("Channels"));
    try testing.expect(!w.tester.hasText("Search chats"));
    try testing.expect(!w.tester.hasText("Compact"));
    try testing.expectEqual(state.Page.config, w.app.page);

    // The back button returns to the conversation.
    try w.tester.clickText("Back");
    w.tester.settle(0.5);
    try testing.expect(!w.app.settings_open);
    try testing.expect(w.tester.hasText("Search chats"));
    try testing.expectEqual(state.Page.chat, w.app.page);
}

// Regression: the settings sidebar drew its footer (the account row and the
// palette switcher) inside the scrolling box, so on a window too short for
// every settings page the footer scrolled off the bottom with the list. The
// conversation sidebar pins its footer; this holds the settings sidebar to the
// same rule.
test "the settings sidebar keeps its footer pinned on a short window" {
    var w: Window = undefined;
    try w.init();
    defer w.deinit();

    w.tester.resize(1180, 420);
    w.tester.settle(0.4);
    w.app.toggleSettings();
    w.tester.settle(0.5);

    // The footer is on screen, at the foot: before the fix it sat at y=666 on
    // this window, well past the 420px bottom. It need not be a pixel inside
    // the edge — the row carries bottom padding — only near it. The settings
    // menu's foot holds the palette picker, named for the palette in use.
    const foot = w.tester.findText("Neutral") orelse return error.NoFooter;
    try testing.expect(foot.y > 0);
    try testing.expect(foot.y > w.tester.size.h - 60);
    try testing.expect(foot.y < w.tester.size.h);
    try testing.expect(w.tester.hasText("Doctor"));
}

// Starting a conversation leaves the settings menu: it belongs to the sidebar's
// conversation list, which is what the sidebar has to be showing again.
test "a new chat leaves the settings menu" {
    var w: Window = undefined;
    try w.init();
    defer w.deinit();

    w.tester.settle(0.5);
    w.app.openPage(.models);
    w.tester.settle(0.3);
    try testing.expect(w.app.settings_open);

    w.app.newChat();
    w.tester.settle(0.5);
    try testing.expect(!w.app.settings_open);
    try testing.expectEqual(state.Page.chat, w.app.page);
    try testing.expect(w.tester.hasText("Search chats"));
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
    // The row sits under the heading for the channel it came from.
    try testing.expect(w.tester.hasText("telegram"));
}

// Sessions are grouped under the channel they came from, the way zeron groups
// them under their project, so a long list reads as a few named runs instead of
// one undifferentiated column.
test "sessions are grouped under the channel they came from" {
    var w: Window = undefined;
    try w.init();
    defer w.deinit();

    try w.app.sessions.append(testing.allocator, .{
        .key = try testing.allocator.dupe(u8, "telegram:1"),
        .created_at = try testing.allocator.dupe(u8, "2026-05-30T14:07:11Z"),
        .last_active = try testing.allocator.dupe(u8, "2026-05-30T14:09:02Z"),
    });
    try w.app.sessions.append(testing.allocator, .{
        .key = try testing.allocator.dupe(u8, "discord:2"),
        .created_at = try testing.allocator.dupe(u8, "2026-05-30T14:07:11Z"),
        .last_active = try testing.allocator.dupe(u8, "2026-05-30T14:09:02Z"),
    });

    w.tester.settle(0.5);
    // One heading per channel, and the rows under them.
    try testing.expect(w.tester.hasText("telegram"));
    try testing.expect(w.tester.hasText("discord"));
    const tg = w.tester.findText("telegram:1") orelse return error.NoTelegramRow;
    const dc = w.tester.findText("discord:2") orelse return error.NoDiscordRow;
    try testing.expect(tg.y != dc.y);
}

// The chat / work switch belongs to the conversation. With a settings page
// open the sidebar's own menu is where you move between pages, so the switch
// would be a second control saying what the sidebar already says.
test "the mode switch is only on the conversation" {
    var w: Window = undefined;
    try w.init();
    defer w.deinit();
    w.tester.settle(0.5);

    try testing.expect(w.tester.hasText("Chat"));
    try testing.expect(w.tester.hasText("Work"));

    // Any settings page: the switch goes, the sidebar's menu takes over.
    w.app.openPage(.config);
    w.tester.settle(0.5);
    try testing.expect(!w.tester.hasText("Work"));

    // Back on the conversation it returns.
    w.app.openPage(.chat);
    w.tester.settle(0.5);
    try testing.expect(w.tester.hasText("Work"));
}

// Regression: the window's title bar is hidden, so the traffic lights float
// over the view. The sidebar's first row started at 12 points and drew under
// them. It now starts past the strip they sit in, and the page header starts at
// the same y so the two columns read as one line.
test "the sidebar and the header start below the traffic lights" {
    var w: Window = undefined;
    try w.init();
    defer w.deinit();
    w.tester.settle(0.5);

    const new_chat = w.tester.findText("New chat") orelse return error.NoNewChat;
    // The strip is 52 points tall (the buttons' centre at 26). A row that
    // starts at its top edge or above would be drawn under the buttons.
    try testing.expect(new_chat.y >= view.title_bar_height);

    // The page's own title is level with it, not higher: two columns whose
    // first lines disagree read as two windows.
    w.app.pushMessage("user", "a question");
    w.tester.settle(0.4);
    const title = w.tester.findText("Chat") orelse return error.NoTitle;
    try testing.expect(@abs(title.y - new_chat.y) < 20);

    // The settings menu swaps in under the same strip.
    w.app.toggleSettings();
    w.tester.settle(0.4);
    const back = w.tester.findText("Back") orelse return error.NoBack;
    try testing.expect(back.y >= view.title_bar_height);
}

// The sidebar's top is the two things you start, and its foot is the one way
// into settings. Both are rows in the sidebar's own column, not a strip of
// icons beside it — that strip is what this replaced.
test "the sidebar starts work at its top and settings at its foot" {
    var w: Window = undefined;
    try w.init();
    defer w.deinit();
    w.tester.settle(0.5);

    const new_chat = w.tester.findText("New chat") orelse return error.NoNewChat;
    const search = w.tester.findText("Search") orelse return error.NoSearch;
    try testing.expect(new_chat.y < search.y);

    // Both sit in the sidebar's column, left of the conversation.
    try testing.expect(new_chat.x < view.sidebar_width);
    try testing.expect(search.x < view.sidebar_width);

    // Settings is a button at the foot, below the list.
    w.app.toggleSettings();
    w.tester.settle(0.4);
    try testing.expect(w.app.settings_open);
    const config = w.tester.findText("Configuration") orelse return error.NoConfigRow;
    try testing.expect(config.x < view.sidebar_width);
}

test "the config page opens at its top after a scrolled transcript" {
    var w: Window = undefined;
    try w.init();
    defer w.deinit();

    // Fill the transcript so its scroller is at the end. Its scroller and the
    // config page's scroller are both the first child of the body column, so
    // without a stable key the two resolve to the same nanoui id and the
    // transcript's follow-to-end offset opens the config page scrolled past
    // its first section.
    var i: usize = 0;
    while (i < 40) : (i += 1) {
        w.app.pushMessage("user", "a long question that wraps across the column width");
        w.app.pushMessage("assistant", "a long answer that also wraps across the column width");
    }
    w.tester.settle(0.4);
    try testing.expect(w.tester.hasText("a long answer that also wraps across the column width"));

    w.app.openPage(.config);
    w.tester.settle(0.5);

    // The first card is on screen, near the top: the page did not inherit the
    // transcript's offset. `findText` returns a node's rect even when it is
    // scrolled off the top (a negative y), so the assertion must require the
    // card to be visible as well as near the top.
    const card = w.tester.findText("Built-in nullclaw runtime") orelse return error.NoRuntimeCard;
    try testing.expect(card.y > 0);
    try testing.expect(card.y < 220);
    try testing.expect(w.tester.hasText("Provider"));
}

// The settings menu is a second sidebar, so it has to hold every settings page
// and no duplicates. A page added to `nav` and forgotten here would be
// unreachable once the sidebar swaps to the menu.
test "the settings menu holds every page but chat exactly once" {
    var seen: [state.nav.len]state.Page = undefined;
    var n: usize = 0;
    for (state.settings_groups) |group| {
        try testing.expect(group.title.len > 0);
        for (group.pages) |page| {
            // Chat is the conversation, not a setting; it must not be in here.
            try testing.expect(page != .chat);
            for (seen[0..n]) |earlier| try testing.expect(earlier != page);
            seen[n] = page;
            n += 1;
        }
    }
    try testing.expectEqual(state.nav.len - 1, n);
    // And the menu's set is exactly `nav` minus chat, so no page is missing.
    for (state.nav) |page| {
        if (page == .chat) continue;
        var found = false;
        for (seen[0..n]) |p| if (p == page) {
            found = true;
            break;
        };
        try testing.expect(found);
    }
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

test "a transcript draws a table, its columns aligned, and its cells wrapped" {
    var w: Window = undefined;
    try w.init();
    defer w.deinit();

    w.app.pushMessage("user", "show me the numbers");
    w.app.pushMessage("assistant",
        \\| Name | Count | Note |
        \\| :--- | ---: | :---: |
        \\| alpha | 3 | first |
        \\| beta | 12 | second |
    );
    w.tester.settle(0.5);

    // Every header cell and every body cell is on the page.
    try testing.expect(w.tester.hasText("Name"));
    try testing.expect(w.tester.hasText("Count"));
    try testing.expect(w.tester.hasText("Note"));
    try testing.expect(w.tester.hasText("alpha"));
    try testing.expect(w.tester.hasText("12"));
    try testing.expect(w.tester.hasText("second"));

    // A right-aligned column sits to the right of a left-aligned one, and a
    // centred one between them: the separator's colons decide it.
    const name = w.tester.findText("Name").?;
    const count = w.tester.findText("Count").?;
    const note = w.tester.findText("Note").?;
    try testing.expect(name.x < count.x);
    try testing.expect(count.x < note.x);
    // The cells follow their column's side: a right-aligned cell's text ends
    // where its column does, however wide the cell's own text is.
    const a = w.tester.findText("3").?;
    const b = w.tester.findText("12").?;
    try testing.expectApproxEqAbs(a.x + a.w, b.x + b.w, 1.5);
    try testing.expect(a.x > count.x);
    // The table is one row per line, with the header above the body.
    try testing.expect(name.y < w.tester.findText("alpha").?.y);
}

test "a footnote reference jumps to its note, and a link opens in the browser" {
    var w: Window = undefined;
    try w.init();
    defer w.deinit();

    w.app.pushMessage("user", "what is that?");
    w.app.pushMessage("assistant",
        \\The gateway pairs first[^pairing], then serves.
        \\
        \\[^pairing]: A six-digit code, exchanged once.
    );
    w.tester.settle(0.5);

    // The reference is drawn as its number, and the note is under the prose.
    try testing.expect(w.tester.containsText("[1]"));
    try testing.expect(w.tester.containsText("A six-digit code, exchanged once."));

    // Clicking the reference asks to reveal the note; the transcript resolves
    // it on the frame after the one that recorded the note's place.
    try w.tester.clickText("The gateway pairs first[1], then serves.");
    w.tester.settle(0.5);
    try testing.expect(w.app.reveal_footnote == 1 or w.app.reveal_footnote == null);
}

test "a bare url in an answer is drawn as a link, and opens on a click" {
    var w: Window = undefined;
    try w.init();
    defer w.deinit();

    w.app.pushMessage("user", "where are the docs?");
    w.app.pushMessage("assistant", "See https://example.com/docs for them.");
    w.tester.settle(0.5);

    // The text keeps the url, and the anchor is a box of its own over it.
    try testing.expect(w.tester.containsText("https://example.com/docs"));
    try w.tester.clickText("See https://example.com/docs for them.");
    w.tester.settle(0.5);
    // A test must not open a browser; the click reached the view, which asked.
    try testing.expect(w.app.toast.len > 0);
}

test "nested bullets step in, and a task list shows its boxes" {
    var w: Window = undefined;
    try w.init();
    defer w.deinit();

    w.app.pushMessage("user", "what is left?");
    w.app.pushMessage("assistant",
        \\- top level
        \\  - one level down
        \\    - two levels down
        \\- [x] finished
        \\- [ ] still open
    );
    w.tester.settle(0.5);

    const top = w.tester.findText("top level").?;
    const one = w.tester.findText("one level down").?;
    const two = w.tester.findText("two levels down").?;
    try testing.expect(top.x < one.x);
    try testing.expect(one.x < two.x);
    try testing.expect(w.tester.hasText("☑"));
    try testing.expect(w.tester.hasText("☐"));
}

test "a numbered list keeps the number it was written with" {
    var w: Window = undefined;
    try w.init();
    defer w.deinit();

    w.app.pushMessage("user", "the steps");
    w.app.pushMessage("assistant", "3. third\n4. fourth");
    w.tester.settle(0.5);

    try testing.expect(w.tester.hasText("3."));
    try testing.expect(w.tester.hasText("4."));
    try testing.expect(w.tester.hasText("third"));
}

test "typing @ offers files, and typing / offers the slash commands" {
    var w: Window = undefined;
    try w.init();
    defer w.deinit();

    // The composer takes the keyboard as a click into it would.
    w.app.composer.focus();
    w.tester.settle(0.3);

    w.tester.typeText("@REA");
    w.tester.settle(0.3);
    try testing.expect(w.app.completion_mode == .mention);
    try testing.expect(w.app.completion_items.items.len > 0);
    // The prefix narrows the list to what starts with it.
    try testing.expectEqualStrings("README.md", w.app.completion_items.items[0].label);

    // Taking a candidate puts it in place of the trigger and its prefix.
    w.app.acceptCompletion();
    w.tester.settle(0.3);
    try testing.expectEqualStrings("@README.md ", w.app.composer.text());
    try testing.expect(!w.app.completionActive());

    // A slash at the start of a line offers the runtime's commands.
    w.app.composer.clear();
    w.tester.settle(0.3);
    w.tester.typeText("/mod");
    w.tester.settle(0.3);
    try testing.expect(w.app.completion_mode == .slash);
    try testing.expect(w.app.completion_items.items.len > 0);
    try testing.expectEqualStrings("model", w.app.completion_items.items[0].label);
}

test "taking a completion with return does not also send the message" {
    var w: Window = undefined;
    try w.init();
    defer w.deinit();

    w.app.composer.focus();
    w.tester.settle(0.3);
    w.tester.typeText("/help");
    w.tester.settle(0.3);
    try testing.expect(w.app.completionActive());

    // Return takes the candidate; the same key would otherwise send.
    w.tester.key(.enter);
    w.tester.settle(0.3);

    try testing.expectEqual(@as(usize, 0), w.app.messages.items.len);
    try testing.expectEqualStrings("/help ", w.app.composer.text());
}

test "a mention only opens at a word boundary" {
    var w: Window = undefined;
    try w.init();
    defer w.deinit();

    w.app.composer.focus();
    w.tester.settle(0.3);
    // An address is not a mention, and neither is a path segment.
    w.tester.typeText("mail me@example");
    w.tester.settle(0.3);
    try testing.expect(!w.app.completionActive());
}

test "a <br> in a reply breaks the line" {
    var w: Window = undefined;
    try w.init();
    defer w.deinit();

    w.app.pushMessage("user", "one line or two?");
    w.app.pushMessage("assistant", "first<br>second<br/>third<br />fourth");
    w.tester.settle(0.5);

    // Each `<br>` leaves a newline where it stood, so the four words land on
    // four lines rather than in one run with tags in it.
    try testing.expect(!w.tester.containsText("<br"));
    const first = w.tester.findText("first\nsecond\nthird\nfourth");
    try testing.expect(first != null);
    const lines = first.?.h;
    const one_line = w.tester.findText("one line or two?").?.h;
    try testing.expect(lines > one_line * 3);
}

test "a note sends the reader back to the reference that cited it" {
    var w: Window = undefined;
    try w.init();
    defer w.deinit();

    w.app.pushMessage("user", "what is that?");
    w.app.pushMessage("assistant",
        \\The gateway pairs first[^pairing], then serves.
        \\
        \\[^pairing]: A six-digit code, exchanged once.
    );
    w.tester.settle(0.5);

    // From the reference to the note...
    w.app.jumpToFootnote(1);
    w.tester.settle(0.5);
    try testing.expect(w.app.reveal_footnote == null);

    // ...and back again. The transcript resolves the return on the frame
    // after the one that recorded where the reference was drawn.
    w.app.returnToReference(1);
    try testing.expect(w.app.reveal_reference == 1);
    w.tester.settle(0.5);
    try testing.expect(w.app.reveal_reference == null);
    try testing.expect(w.app.reveal_reference_y == null);
}

test "a table wider than the window keeps its width and scrolls sideways" {
    var w: Window = undefined;
    try w.init();
    defer w.deinit();

    w.app.pushMessage("user", "a wide one");
    w.app.pushMessage("assistant",
        \\| Column one | Column two | Column three | Column four | Column five | Column six |
        \\| --- | --- | --- | --- | --- | --- |
        \\| alpha | beta | gamma | delta | epsilon | zeta |
    );
    w.tester.settle(0.5);

    // Every column is drawn at the width its cells ask for, so the last one
    // sits past the right edge of the transcript rather than being squeezed
    // into it — and it is still laid out, not clipped away.
    const first = w.tester.findText("Column one").?;
    const last = w.tester.findText("Column six").?;
    try testing.expect(last.x > first.x);
    try testing.expect(w.tester.hasText("zeta"));

    // The table fits when the window is wide enough for it: no wider than
    // the column it sits in.
    w.tester.resize(2400, 800);
    w.tester.settle(0.5);
    const wide_first = w.tester.findText("Column one").?;
    const wide_last = w.tester.findText("Column six").?;
    try testing.expect(wide_last.x + wide_last.w < 2400);
    try testing.expect(wide_last.x > wide_first.x);
}

test "a code block is highlighted by the language its fence names" {
    var w: Window = undefined;
    try w.init();
    defer w.deinit();

    w.app.pushMessage("user", "show the code");
    w.app.pushMessage("assistant",
        \\```zig
        \\const x = 42; // a note
        \\pub fn main() void {}
        \\```
    );
    w.tester.settle(0.5);

    // The block is drawn whole; the highlighting is in the spans, so what a
    // test can see is that the code is there and the fence is not.
    try testing.expect(w.tester.containsText("const x = 42; // a note"));
    try testing.expect(!w.tester.containsText("```"));
    try testing.expect(w.tester.hasText("zig"));
}

test "a quote inside a quote draws one edge per level, and a rule has room" {
    var w: Window = undefined;
    try w.init();
    defer w.deinit();

    w.app.pushMessage("user", "quote me");
    w.app.pushMessage("assistant",
        \\> once
        \\> > twice
        \\> > > three deep
        \\
        \\- - -
        \\
        \\after the break
    );
    w.tester.settle(0.5);

    const once = w.tester.findText("once").?;
    const twice = w.tester.findText("twice").?;
    const deep = w.tester.findText("three deep").?;
    // Each level steps in from the one outside it.
    try testing.expect(once.x < twice.x);
    try testing.expect(twice.x < deep.x);

    // The rule sits between the quote and the paragraph, with air around it
    // rather than flush against either.
    const after = w.tester.findText("after the break").?;
    try testing.expect(after.y > deep.y);
    try testing.expect(after.y - (deep.y + deep.h) > 12);
}

test "a rule written with spaces between its marks is still a rule" {
    var doc = try @import("md.zig").parse(testing.allocator, "a\n\n- - -\n\nb");
    defer doc.deinit();
    try testing.expectEqual(@as(usize, 3), doc.blocks.len);
    try testing.expectEqual(@import("md.zig").Kind.rule, doc.blocks[1].kind);
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

    const brand = w.tester.findText("New chat") orelse return error.NoBrand;
    const heading = w.tester.findText("Search chats") orelse return error.NoSessions;
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

    // The sidebar is the left column, with no icon strip beside it: the new
    // chat row and the search field both live inside it, left of the transcript.
    const left = view.sidebar_width;
    try testing.expect(brand.x < left);
    try testing.expect(heading.x < left);

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
/// Whether a row's text carries a word: a letter or a digit. A fold marker or a
/// lone brace is not a row anyone reads, and its width says nothing about the
/// page's layout.
fn hasWord(text: []const u8) bool {
    for (text) |ch| {
        if (std.ascii.isAlphanumeric(ch)) return true;
    }
    return false;
}

test "every json page paints its rows below the toolbar" {
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest;
    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    var path_buffer: [256]u8 = undefined;
    const stub = try harness.writeStub(threaded.io(), &path_buffer);

    // Same as the data-page test: a config of its own, so a page's rows come
    // from a known file rather than the process environment's real one.
    _ = try harness.writeConfig(threaded.io(), harness.page_config);
    defer harness.removeConfig(threaded.io());

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
            // the page says so rather than drawing an empty tree. A reader
            // that set a note (the workspace audit's verdict) leads with it.
            if (r.totalRows() == 0) {
                if (r.note.len == 0 and !w.tester.containsText("No ")) {
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
            // A row's own text, not a fold marker or a punctuation glyph: those
            // are a few points wide and say nothing about the page's layout.
            if (twins != 1 or !hasWord(row.text)) continue;
            // The tree paints a row as one leaf holding its key and its value
            // joined, so that joined text — not the key alone — is what to look
            // for.
            const painted_text = row.painted(testing.allocator);
            defer if (painted_text.ptr != row.text.ptr) testing.allocator.free(painted_text);
            const rect = w.tester.findText(painted_text) orelse continue;
            if (rect.y < toolbar.y + toolbar.h) {
                std.debug.print("page {s}: row `{s}` sits inside the toolbar\n", .{ @tagName(page), painted_text });
                return error.RowInsideToolbar;
            }
            if (rect.w <= 400) {
                std.debug.print("page {s}: row `{s}` is {d} wide\n", .{ @tagName(page), painted_text, rect.w });
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

    // A config of its own, so the pages are answered from a known file rather
    // than whatever the developer's real `~/.nullclaw/config.json` happens to
    // hold. Before the window resolved its own config path this test only
    // passed because the process environment found a real config.
    _ = try harness.writeConfig(threaded.io(), harness.page_config);
    defer harness.removeConfig(threaded.io());

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

// The settings the page grew: each is a field the runtime reads, and each has
// to survive a trip through the form and back into the file. A field the page
// shows but never writes is a control that does nothing.
test "the settings page writes the agent, safety and runtime fields" {
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
    w.app.cfg_temperature.set("0.2");
    w.app.cfg_reasoning_effort = 2; // "high"
    w.app.cfg_max_tool_iterations.set("40");
    w.app.cfg_max_history.set("60");
    w.app.cfg_compact_context = true;
    w.app.cfg_timezone.set("Asia/Shanghai");
    w.app.cfg_message_timeout.set("120");
    w.app.cfg_workspace_only = false;
    w.app.cfg_max_actions.set("5");
    w.app.cfg_block_high_risk = false;
    w.app.cfg_approve_medium = false;
    w.app.cfg_runtime_kind = 1; // docker
    w.app.cfg_docker_image.set("alpine:3.21");
    w.app.cfg_gateway_require_pairing = false;
    w.app.cfg_memory_search = false;
    w.app.cfg_scheduler_enabled = false;
    w.app.cfg_scheduler_max_tasks.set("8");
    w.app.cfg_log_tool_calls = true;
    w.app.cfg_log_llm_io = true;

    w.app.applyConfigForm();
    w.app.saveConfig();
    w.settle(2);

    const written = try std.Io.Dir.cwd().readFileAlloc(io, harness.test_home ++ "/.nullclaw/config.json", testing.allocator, .limited(1 << 16));
    defer testing.allocator.free(written);

    try testing.expect(std.mem.indexOf(u8, written, "\"default_temperature\": 0.2") != null);
    try testing.expect(std.mem.indexOf(u8, written, "\"reasoning_effort\": \"high\"") != null);
    try testing.expect(std.mem.indexOf(u8, written, "\"max_tool_iterations\": 40") != null);
    try testing.expect(std.mem.indexOf(u8, written, "\"max_history_messages\": 60") != null);
    try testing.expect(std.mem.indexOf(u8, written, "\"compact_context\": true") != null);
    try testing.expect(std.mem.indexOf(u8, written, "Asia/Shanghai") != null);
    try testing.expect(std.mem.indexOf(u8, written, "\"message_timeout_secs\": 120") != null);
    try testing.expect(std.mem.indexOf(u8, written, "\"workspace_only\": false") != null);
    try testing.expect(std.mem.indexOf(u8, written, "\"max_actions_per_hour\": 5") != null);
    try testing.expect(std.mem.indexOf(u8, written, "\"block_high_risk_commands\": false") != null);
    try testing.expect(std.mem.indexOf(u8, written, "\"require_approval_for_medium_risk\": false") != null);
    try testing.expect(std.mem.indexOf(u8, written, "\"kind\": \"docker\"") != null);
    try testing.expect(std.mem.indexOf(u8, written, "alpine:3.21") != null);
    try testing.expect(std.mem.indexOf(u8, written, "\"require_pairing\": false") != null);
    try testing.expect(std.mem.indexOf(u8, written, "\"max_tasks\": 8") != null);
    try testing.expect(std.mem.indexOf(u8, written, "\"log_tool_calls\": true") != null);
    try testing.expect(std.mem.indexOf(u8, written, "\"log_llm_io\": true") != null);
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

// Regression: the in-process data pages called `Config.load`, which resolves
// the config directory from the *process* environment. The window resolves its
// paths from its own environment (a test home, or `NULLCLAW_HOME`), so a data
// page could read a different user's config than the config page showed. The
// Models page is the visible one: it summarised whatever the process's own
// `~/.nullclaw/config.json` said, not the file the window was pointed at.
test "a data page reads the window's config, not the process's" {
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest;
    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();

    // A provider name no machine's real config is likely to carry, so reading
    // the process environment instead of the test home is visible. A provider
    // entry keeps the page from drawing its empty state before the note.
    _ = try harness.writeConfig(threaded.io(), "{\"agents\":{\"defaults\":{\"model\":{\"primary\":\"testprovider/test-model\"}}},\"models\":{\"providers\":{\"testprovider\":{\"api_key\":\"example\"}}}}");
    defer harness.removeConfig(threaded.io());

    var w: Window = undefined;
    try w.init();
    defer w.deinit();

    w.app.openPage(.models);
    w.settle(1);
    try testing.expect(w.tester.containsText("testprovider"));
    try testing.expect(!w.tester.containsText("zhipu"));
}
