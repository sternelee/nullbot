//! Everything the window draws.
//!
//! A view is rebuilt every frame, so nothing here keeps state of its own: it
//! reads `AppState`, calls the actions on it, and lays out boxes. Strings that
//! outlive the call go through `c.print` / `c.alloc`, which live until the
//! frame ends.

const std = @import("std");
const ui = @import("nanoui").ui;
const kit = @import("nanoui").kit;
const backend = @import("backend.zig");
const theme = @import("theme.zig");
const design = @import("design.zig");
const state = @import("state.zig");
const sidebar_mod = @import("sidebar/mod.zig");
const chat_mod = @import("chat/mod.zig");
const composer_mod = @import("composer/mod.zig");
const AppState = state.AppState;
const Page = state.Page;

/// The hairline icon strip at the far left, like the web client's nav rail.
/// The strip the window's traffic lights sit in, from the window's top. The
/// window is created with a hidden title bar and the buttons placed at
/// `y = 26`, which makes the bar 52 points tall (`main.zig`). The sidebar's
/// first row starts below it, so nothing is drawn under the buttons.
pub const title_bar_height: f32 = 52;

/// The gap between that strip and the sidebar's first row. The traffic lights
/// end at 52, and a row starting exactly there reads as crowding them.
const title_bar_gap: f32 = 8;

pub const rail_width: f32 = design.Spacing.rail_width;
/// Wide enough for a session key and its stamp.
pub const sidebar_width: f32 = design.Spacing.sidebar_width;
/// A comfortable measure for prose, as the runtime's own output is long.
const content_max: f32 = design.Spacing.content_max;
/// The circular role marker at the head of each message row.
const avatar_size: f32 = design.Spacing.avatar_size;
/// The label column in the configuration form: wide enough that a hint about
/// a dotted path stays on two lines instead of three.
const label_w: f32 = design.Spacing.label_w;
/// Every control in the configuration form is this wide, so the card reads as
/// one column instead of a select at one width and fields stretched to the
/// card's edge. `kit.select` measures in points, so this is a fixed number.
const field_w: f32 = design.Spacing.field_w;

const suggestions = [_][]const u8{
    "What can you do?",
    "Summarise this project",
    "Which providers are configured?",
};

pub fn root(s: *AppState, c: *ui.Context) void {
    s.pump();
    c.theme = s.uiTheme();

    const shell = ui.div(c).row().sizeFull().bg(s.palette.bg);
    defer shell.end();
    sidebar(s, c);
    _ = c.leaf(.{
        .width = .{ .px = 1 },
        .height = .fill,
        .background = s.palette.border,
    }, .none, null);
    body(s, c);
}

// --- the sidebar ---------------------------------------------------------

/// The window's one sidebar: a conversation list, or the settings menu while
/// that is open. Zeron's shell has no icon rail beside it — the sidebar runs to
/// the window's top, its own top holds the two things you start (a new chat and
/// search), and its foot holds you and the way into settings.
fn sidebar(s: *AppState, c: *ui.Context) void {
    const bar = ui.div(c).column().w(sidebar_width).hFull().bg(s.palette.shell);
    defer bar.end();
    if (s.settings_open) {
        settingsSidebar(s, c);
        return;
    }

    // Semantic colours the new sidebar draws with.
    const semantic = theme.buildSemantic(s.palette);
    const dark = s.palette.dark;

    brand(s, c);
    _ = s.sidebar.renderHeader(c, &semantic);

    // The list itself, grouped under the channel each session came from.
    const picked = s.sidebar.renderList(c, s.sessions.items, s.selected, dark, &semantic, &s.folded_groups);
    if (picked.clicked) |i| s.select(i);
    if (picked.fold) |name| {
        // A heading press folds its group: the first press records it, the
        // second forgets it again.
        if (s.folded_groups.contains(name)) {
            _ = s.folded_groups.remove(name);
        } else {
            s.folded_groups.put(s.gpa, name, {}) catch {};
        }
        c.changed = true;
    }

    sidebarFooter(s, c);
}

// The sidebar while the settings menu is open: a header that says so and a way
// back to the conversation, then the settings pages grouped by what they
// change. It replaces the conversation list rather than sitting beside it, the
// way the web client swaps the sidebar when you open Settings.
fn settingsSidebar(s: *AppState, c: *ui.Context) void {
    settingsHeader(s, c);
    settingsSearchField(s, c);

    // The scroller is closed before the footer is drawn. A `defer` here would
    // leave it open for the rest of the function, so the footer — the account
    // row and the palette switcher — would be a child of the scrolling box and
    // scroll away with the list, leaving it off-screen on a short window. The
    // conversation sidebar pins its footer the same way.
    const query = s.settings_search.text();
    {
        ui.key(c, "settings-scroll");
        const box = ui.div(c).column().grow().wFull().minW(0).scrollY().gap(2).px(8).pb(6);
        defer box.end();

        if (query.len == 0) {
            for (state.settings_groups) |group| {
                settingsGroupHeading(s, c, group.title);
                for (group.pages) |page| settingsRow(s, c, page, null);
            }
        } else {
            // A query flattens the menu: only the pages it matches, each with
            // the group it belongs to beneath its name.
            var shown: usize = 0;
            for (state.settings_groups) |group| {
                for (group.pages) |page| {
                    if (!settingsMatches(page, query)) continue;
                    settingsRow(s, c, page, group.title);
                    shown += 1;
                }
            }
            if (shown == 0) settingsEmpty(s, c);
        }
    }
    settingsFooter(s, c);
}

/// The settings menu's foot: the palette picker, and the way back to the
/// conversation. Zeron's settings list ends with the same account row its
/// sidebar has; here the account is the diagnostics panel's, so the foot holds
/// the one window-wide setting the conversation list does not.
fn settingsFooter(s: *AppState, c: *ui.Context) void {
    _ = c.leaf(.{
        .width = .fill,
        .height = .{ .px = 1 },
        .background = s.palette.border,
    }, .none, null);

    const wrap = ui.div(c).row().wFull().p(10).gap(6).itemsCenter();
    defer wrap.end();

    ui.key(c, "theme-anchor");
    const anchor_id = c.peekId(null);
    const palette = ui.button(c, theme.choices[s.palette_index].name, .{
        .variant = .ghost,
        .icon = "circle.lefthalf.filled",
        .size = 12,
    });
    if (palette.clicked) {
        s.theme_menu_open = !s.theme_menu_open;
        c.changed = true;
    }
    themeMenu(s, c, c.rects.get(anchor_id));
}

/// The settings menu's search field, under the header. Typing filters the
/// pages by label and keyword; ⌘F is not wired (there is no global keymap
/// here), but the field is one Tab from the Back button.
fn settingsSearchField(s: *AppState, c: *ui.Context) void {
    const wrap = ui.div(c).column().wFull().px(10).pb(8);
    defer wrap.end();
    const field = ui.div(c).row().wFull().h(30).itemsCenter().gap(6)
        .px(9).rounded(8).bg(s.palette.raised).borderW(1).border(s.palette.border);
    defer field.end();
    ui.icon(c, "magnifyingglass", .{ .size = 12, .color = s.palette.faint });
    _ = ui.textField(c, &s.settings_search, .{
        .placeholder = "Search settings",
        .width = .fill,
        .size = 12,
        .bare = true,
        .color = s.palette.text,
        .placeholder_color = s.palette.faint,
        .caret_color = s.palette.accent,
    });
}

/// Whether a page answers a query: its label or its keywords contain it,
/// ignoring case.
fn settingsMatches(page: Page, query: []const u8) bool {
    return containsIgnoreCase(page.label(), query) or containsIgnoreCase(page.keywords(), query);
}

fn containsIgnoreCase(haystack: []const u8, needle: []const u8) bool {
    if (needle.len == 0) return true;
    if (needle.len > haystack.len) return false;
    var i: usize = 0;
    while (i + needle.len <= haystack.len) : (i += 1) {
        var same = true;
        for (needle, 0..) |ch, j| {
            if (std.ascii.toLower(ch) != std.ascii.toLower(haystack[i + j])) {
                same = false;
                break;
            }
        }
        if (same) return true;
    }
    return false;
}

/// The menu's header: a back button to the conversation, and the word that says
/// what this list is.
fn settingsHeader(s: *AppState, c: *ui.Context) void {
    // The same strip the conversation sidebar leaves: the settings menu swaps
    // in under the same traffic lights.
    const row = ui.div(c).row().wFull().px(10).pt(title_bar_height + title_bar_gap).pb(8).gap(8).itemsCenter();
    defer row.end();
    const back = ui.button(c, "Back", .{
        .variant = .ghost,
        .icon = "chevron.left",
        .size = 12.5,
    });
    if (back.clicked) s.openPage(.chat);
    ui.text(c, "Settings", .{ .size = 14, .weight = .semibold, .color = s.palette.text });
}

/// One group's heading, in the same quiet style as the session list's day
/// headings so the two sidebars read as one design.
fn settingsGroupHeading(s: *AppState, c: *ui.Context, title: []const u8) void {
    const row = ui.div(c).row().wFull().px(10).pt(12).pb(3);
    defer row.end();
    ui.text(c, title, .{
        .size = 10.5,
        .weight = .semibold,
        .color = s.palette.faint,
        .tracking = 0.8,
    });
}

/// One settings entry: an icon, the page's label, an optional group subtitle,
/// and a lit row when it is the page on screen.
fn settingsRow(s: *AppState, c: *ui.Context, page: Page, group: ?[]const u8) void {
    const active = s.page == page;
    const it = ui.pressable(c, .{
        .direction = .row,
        .width = .fill,
        .gap = 10,
        .align_items = .center,
        .padding = .xy(10, 7),
        .radius = 7,
        .background = if (active) s.palette.raised else s.palette.shell,
    }, s.palette.hover);
    defer ui.end(c);

    ui.icon(c, page.icon(), .{
        .size = 13,
        .frame = 16,
        .color = if (active) s.palette.accent else s.palette.muted,
    });

    if (group) |g| {
        const col = ui.div(c).column().grow().minW(0).gap(1);
        defer col.end();
        ui.text(c, page.label(), .{
            .size = 12.5,
            .weight = .medium,
            .color = if (active) s.palette.text else s.palette.muted,
        });
        ui.text(c, g, .{ .size = 9.5, .color = s.palette.faint });
    } else {
        ui.text(c, page.label(), .{
            .size = 12.5,
            .weight = if (active) .medium else .regular,
            .color = if (active) s.palette.text else s.palette.muted,
        });
    }

    if (it.clicked) s.openPage(page);
}

/// The empty state when a query matches no page.
fn settingsEmpty(s: *AppState, c: *ui.Context) void {
    const box = ui.div(c).column().wFull().p(10).gap(4);
    defer box.end();
    ui.text(c, "No matching settings", .{ .size = 12, .color = s.palette.faint });
    ui.text(c, "Try a different word.", .{ .size = 11, .color = s.palette.faint });
}

/// The sidebar's top: the two things you start, as zeron has them — a new chat
/// and a search, each a full-width row with its glyph and its shortcut. The
/// brand used to sit here as a dropdown holding every page; that menu is the
/// settings button's foot now, so this strip is only ever about starting work.
fn brand(s: *AppState, c: *ui.Context) void {
    // Below the traffic lights, not under them: the window's title bar is
    // hidden, so the buttons float over the view and the sidebar's first row
    // has to start past them.
    const wrap = ui.div(c).column().wFull().px(10).pt(title_bar_height + title_bar_gap).pb(4).gap(2);
    defer wrap.end();

    topRow(s, c, "square.and.pencil", "New chat", "⌘N", .new_chat);
    topRow(s, c, "magnifyingglass", "Search", "⌘K", .search);
}

const TopAction = enum { new_chat, search };

fn topRow(s: *AppState, c: *ui.Context, icon: []const u8, label: []const u8, key: []const u8, action: TopAction) void {
    const it = ui.pressable(c, .{
        .direction = .row,
        .width = .fill,
        .height = .{ .px = 30 },
        .gap = 8,
        .padding = .xy(8, 0),
        .radius = 7,
        .align_items = .center,
    }, s.palette.hover);
    defer ui.end(c);

    ui.icon(c, icon, .{ .size = 15, .frame = 18, .color = s.palette.muted });
    ui.text(c, label, .{ .size = 13, .weight = .medium, .color = s.palette.text });
    ui.spacer(c);
    ui.text(c, key, .{ .size = 10.5, .color = s.palette.faint, .tabular = true });

    if (!it.clicked) return;
    switch (action) {
        .new_chat => s.newChat(),
        .search => s.focusSearch(),
    }
}

/// The sidebar's foot, as zeron's: you on the left (your avatar and the
/// runtime's name), and beside you the button into settings. That button is the
/// one entry to every page but the conversation — it swaps this sidebar to the
/// settings menu — which is what the user asked for: settings behind a button
/// at the foot of the sidebar, not a permanent strip of icons.
fn sidebarFooter(s: *AppState, c: *ui.Context) void {
    // The foot asks for a minimum height of its own. nanoui has no flex-shrink,
    // so a column hands each child the height it measured — and the list's
    // `grow` was taking the foot's room with it, leaving the account row cut in
    // half at the window's edge.
    const foot = ui.div(c).column().wFull();
    c.node(foot.index).style.min_height = 46;
    defer foot.end();

    _ = c.leaf(.{
        .width = .fill,
        .height = .{ .px = 1 },
        .background = s.palette.border,
    }, .none, null);

    const wrap = ui.div(c).row().wFull().p(10).gap(6).itemsCenter();
    defer wrap.end();

    const row = ui.pressable(c, .{
        .direction = .row,
        .grow = 1,
        .min_width = 0,
        .gap = 8,
        .align_items = .center,
        .padding = .xy(6, 5),
        .radius = 8,
    }, s.palette.hover);
    defer ui.end(c);
    {
        const disc = ui.div(c).w(24).h(24).roundedFull().bg(s.palette.accent).center();
        defer disc.end();
        ui.text(c, "N", .{ .size = 11, .weight = .semibold, .color = s.palette.accent_text });
    }
    // The name column takes the room the disc and the settings button leave.
    // `grow` is enough here: a `minW(0)` minimum collapsed the column and the
    // row's leftover room came out negative, which placed the name at a
    // negative x and pushed the settings button past the window's edge.
    {
        // Closed here rather than by a `defer`: a deferred `end` runs at the end
        // of the function, so the settings button below would have been laid
        // out inside this column instead of beside it.
        const who = ui.div(c).column().grow().gap(1);
        defer who.end();
        clipped(c, "nullclaw", .{ .size = 12, .color = s.palette.text, .truncate = .ellipsis });
        ui.text(c, "local runtime", .{ .size = 10, .color = s.palette.faint });
    }
    if (row.clicked) s.diagnostics_open = true;

    // The settings button, lit while its menu is open: the state it is the
    // entry to, not just the page it lands on.
    const gear = ui.button(c, "", .{
        .variant = if (s.settings_open) .secondary else .ghost,
        .icon = "gearshape",
        .size = 14,
        .width = .{ .px = 30 },
    });
    kit.tooltip(c, gear, "Settings", .{});
    if (gear.clicked) s.toggleSettings();
}

/// The palette list, hung off the settings sidebar's foot. A menu rather than
/// a select: the choice is a window-wide setting, not a field of the page.
fn themeMenu(s: *AppState, c: *ui.Context, anchor: ?ui.Rect) void {
    var items: [theme.choices.len]kit.MenuItem = undefined;
    for (theme.choices, 0..) |choice, i| {
        items[i] = .{
            .label = choice.name,
            // The checkmark already says which one is on; a glyph repeated down
            // every row would only add noise.
            .checked = s.palette_index == i,
        };
    }
    if (kit.menu(c, "theme-menu-popover", &s.theme_menu_open, anchor, &items, .{
        .width = 180,
        .placement = .top_start,
    })) |picked| {
        s.setPalette(picked);
    }
}

/// What the window knows about itself: where it looks for the runtime, which
/// session is open, and what the managed gateway is doing. Every line is read
/// from state — nothing here is a placeholder for a value the runtime has not
/// given us.
fn diagnosticsPanel(s: *AppState, c: *ui.Context) void {
    var open = s.diagnostics_open;
    defer s.diagnostics_open = open;
    const d = kit.dialog(c, "diagnostics", &open, .{
        .title = "Diagnostics",
        .description = "What this window is connected to, and where it reads from.",
        .width = 520,
        .ok = "",
        .cancel = "Close",
    }) orelse return;
    defer _ = d.end();

    diagLine(s, c, "Runtime", s.exe, true);
    diagLine(s, c, "Config", s.paths.config, true);
    diagLine(s, c, "Workspace", s.paths.workspace, true);
    kit.separator(c, .{});
    diagLine(s, c, "Gateway", if (s.gatewayRunning()) "running" else "stopped", false);
    diagLine(s, c, "Session", sessionKey(s) orelse "none selected", true);
    diagLine(s, c, "Turns", turnCount(s, c), false);
    kit.separator(c, .{});
    diagLine(s, c, "Theme", theme.choices[s.palette_index].name, false);
}

fn sessionKey(s: *AppState) ?[]const u8 {
    const i = s.selected orelse return null;
    if (i >= s.sessions.items.len) return null;
    return s.sessions.items[i].key;
}

/// The selected session's turn count, formatted into the frame's memory: the
/// view is rebuilt every frame, and a string allocated on the app's allocator
/// here would be a leak per frame.
fn turnCount(s: *AppState, c: *ui.Context) []const u8 {
    const i = s.selected orelse return "—";
    if (i >= s.sessions.items.len) return "—";
    return std.fmt.allocPrint(c.alloc(), "{d}", .{s.sessions.items[i].turns()}) catch "—";
}

/// One `Label   value` row of the diagnostics panel.
fn diagLine(s: *AppState, c: *ui.Context, label: []const u8, value: []const u8, mono: bool) void {
    const row = ui.div(c).row().wFull().gap(12).itemsCenter();
    defer row.end();
    {
        const slot = ui.div(c).w(84).minW(84);
        defer slot.end();
        ui.text(c, label, .{ .size = 11.5, .color = s.palette.faint });
    }
    {
        const slot = ui.div(c).grow().minW(0);
        defer slot.end();
        clipped(c, value, .{
            .size = 11.5,
            .color = s.palette.text,
            .mono = mono,
            .truncate = .middle,
        });
    }
}

// --- the body ------------------------------------------------------------

fn body(s: *AppState, c: *ui.Context) void {
    // `grow` takes the width the sidebar leaves; `hFull` pins the column to
    // the window's height, which is what lets a page split into a scrolling
    // band and a bar under it. With only `grow` the column is as tall as its
    // content, so a page's own `grow` has no free room to take and the bar
    // ends up at the bottom of the content instead of the bottom of the window.
    const area = ui.div(c).column().minW(0).wFull().hFull().bg(s.palette.bg);
    defer area.end();
    header(s, c);
    switch (s.page) {
        .chat => chat(s, c),
        else => if (s.page.configBoard() != null) configBoardPage(s, c) else jsonPage(s, c),
    }
    banner(s, c);
    diagnosticsPanel(s, c);
}

fn header(s: *AppState, c: *ui.Context) void {
    // Level with the sidebar's first row: the traffic lights sit over both
    // columns, so the page's title starts at the same y as New chat.
    const bar = ui.div(c).row().wFull().px(22).pt(title_bar_height + title_bar_gap).pb(10).gap(12).itemsCenter();
    defer bar.end();

    {
        const titles = ui.div(c).column().grow().minW(0).gap(2);
        defer titles.end();
        ui.text(c, s.page.label(), .{ .size = 15, .weight = .semibold, .color = s.palette.text });
        clipped(c, subtitle(s, c), .{ .size = 11, .color = s.palette.faint, .truncate = .middle });
    }

    // The chat / work switch, centred like the web client's mode tabs, and only
    // on the conversation. Once a settings page is open the sidebar's own menu
    // is where you move between pages, so a second switch beside the title only
    // repeats what the sidebar already says.
    if (s.page == .chat) modeTabs(s, c);

    ui.spacer(c);
    if (s.busy()) {
        ui.text(c, "working…", .{ .size = 11, .color = s.palette.accent });
    }
    if (s.page.configBoard() != null) {
        configStatusChip(s, c);
    } else if (s.page == .chat) {
        if (ui.button(c, "", .{ .variant = .ghost, .size = 13, .icon = "arrow.clockwise" }).clicked) {
            s.refreshSessions();
        }
    } else {
        // A page that reads state hands over to the board that sets it: the
        // same word in the menu should not be the only way to find it.
        if (s.page.settingsPage()) |settings| {
            if (ui.button(c, "Edit settings", .{ .variant = .ghost, .size = 12, .icon = "gearshape" }).clicked) {
                s.openPage(settings);
            }
        }
        if (ui.button(c, "Run", .{ .variant = .primary, .size = 12, .icon = "play.fill" }).clicked) {
            s.runPage();
        }
    }
}

fn modeTabs(s: *AppState, c: *ui.Context) void {
    const tabs = ui.div(c).row().gap(2).p(3).roundedFull().bg(s.palette.raised);
    defer tabs.end();
    const in_chat = s.page == .chat;
    if (ui.button(c, "Chat", .{
        .variant = if (in_chat) .secondary else .ghost,
        .size = 12,
    }).clicked) {
        s.active_tab = .chat;
        s.openPage(.chat);
    }
    if (ui.button(c, "Work", .{
        .variant = if (!in_chat) .secondary else .ghost,
        .size = 12,
    }).clicked) {
        s.active_tab = .work;
        s.openPage(.cfg_model);
    }
}

fn subtitle(s: *AppState, c: *ui.Context) []const u8 {
    if (s.page == .chat) {
        if (s.selected) |i| {
            if (i < s.sessions.items.len) return s.sessions.items[i].key;
        }
        return "a new conversation";
    }
    if (s.page.configBoard() != null) return "the runtime's own config.json";
    if (s.page.command()) |words| {
        var line: []const u8 = "nullclaw";
        for (words) |word| {
            line = std.fmt.allocPrint(c.alloc(), "{s} {s}", .{ line, word }) catch line;
        }
        return line;
    }
    return "nullclaw";
}

// --- chat ----------------------------------------------------------------

fn chat(s: *AppState, c: *ui.Context) void {
    const column = ui.div(c).column().grow().minW(0).wFull();
    defer column.end();
    if (s.messages.items.len == 0 and !s.streaming()) {
        // On the empty state the composer sits right under the question, with
        // the suggestions below it — the web client's arrangement.
        emptyChat(s, c);
    } else {
        chat_mod.renderTranscript(s, c);
        composer_mod.render(s, c);
        disclaimer(s, c);
    }
}

/// The quiet line at the foot of the chat, as the web client has it.
fn disclaimer(s: *AppState, c: *ui.Context) void {
    const row = ui.div(c).row().wFull().justifyCenter().pb(10);
    defer row.end();
    ui.text(c, "nullclaw can make mistakes. Workspace data is not used to train models.", .{
        .size = 10.5,
        .color = s.palette.faint,
    });
}

/// The first thing you see. The web client centres one question, puts the
/// composer directly under it, and offers a short vertical list of prompts —
/// no hero icon, no cards. That is the shape reproduced here.
fn emptyChat(s: *AppState, c: *ui.Context) void {
    const box = ui.div(c).column().grow().wFull().center().px(22);
    defer box.end();

    const inner = ui.div(c).column().wFull().maxW(content_max).center().gap(20);
    defer inner.end();

    ui.text(c, "Where should we start?", .{
        .size = 28,
        .weight = .semibold,
        .color = s.palette.text,
    });

    // The composer sits directly under the question, then the suggestions.
    composer_mod.render(s, c);

    const list = ui.div(c).column().wFull().gap(2).pt(4);
    defer list.end();
    for (suggestions) |prompt| suggestionRow(s, c, prompt);
}

/// A single suggested prompt, as a quiet text row under the composer.
fn suggestionRow(s: *AppState, c: *ui.Context, prompt: []const u8) void {
    const row = ui.pressable(c, .{
        .direction = .row,
        .width = .fill,
        .gap = 10,
        .padding = .xy(10, 7),
        .radius = 9,
        .align_items = .center,
    }, s.palette.hover);
    defer ui.end(c);
    ui.icon(c, "sparkles", .{ .size = 13, .color = s.palette.faint });
    ui.text(c, prompt, .{ .size = 12.5, .color = s.palette.muted });
    if (row.clicked) {
        s.composer.set(prompt);
        s.send();
    }
}

/// How wide a bubble wants to be: as wide as its widest line, up to a share of
/// the column. Measuring before laying out keeps a short reply a short bubble
/// instead of a full-width band.
// --- the runtime pages ---------------------------------------------------

fn jsonPage(s: *AppState, c: *ui.Context) void {
    // The same measure the transcript and the configuration page use: a page
    // that hugged the window's padding while the chat was centred read as a
    // different application. Centred with `itemsCenter` on a column, not a
    // row: the row list needs a column parent to take its height from.
    // Aligned to the header's own left edge rather than centred: a data page
    // reads against its title, and the chat's centred transcript is the
    // exception, not the rule. A column parent, because `ui.list` takes its
    // height from one, and `hFull` so the list has a height to fill.
    const outer = ui.div(c).column().grow().minW(0).wFull().px(22).pb(16);
    defer outer.end();
    // A fixed measure, as the transcript uses: `wFull().maxW(...)` inside a
    // column left the box with no width of its own, and its rows were laid out
    // at a few points wide.
    const box = ui.div(c).column().hFull().w(content_max).gap(10);
    defer box.end();
    jsonView(s, c);
}

fn jsonView(s: *AppState, c: *ui.Context) void {
    // A page that knows the shape of its answer draws rows; one that does not
    // falls through to the tree below.
    if (s.rows) |*rows| {
        rowsView(s, c, rows);
        return;
    }
    if (s.json_lines == null) {
        const empty = ui.div(c).column().grow().wFull().center().gap(8);
        defer empty.end();
        ui.icon(c, "doc.text", .{ .size = 22, .color = s.palette.faint });
        ui.text(c, if (s.json_running) "Reading…" else "Nothing loaded yet", .{
            .size = 13,
            .color = s.palette.faint,
        });
        return;
    }

    jsonToolbar(s, c);

    // The toolbar's buttons can start a command that replaces the lines, so
    // the borrow happens only after they have had their say.
    const lines = if (s.json_lines) |*l| l else return;

    if (lines.problem != null) {
        const prose = std.mem.eql(u8, lines.problem.?, "prose");
        // The command failed: its own words are the content, so they get a
        // card that says so rather than a blank pane with a toast that
        // disappears. The card hugs its text instead of filling the window.
        const card = ui.div(c).column().wFull().gap(8).p(14).rounded(10)
            .bg(if (prose) s.palette.panel else s.palette.danger.alpha(0.08))
            .border(if (prose) s.palette.border else s.palette.danger.alpha(0.35)).borderW(1);
        defer card.end();
        {
            const head = ui.div(c).row().wFull().gap(7).itemsCenter();
            defer head.end();
            ui.icon(c, if (prose) "doc.text" else "exclamationmark.triangle.fill", .{ .size = 12, .color = if (prose) s.palette.accent else s.palette.danger });
            ui.text(c, if (prose) "The runtime's answer" else "The runtime's command failed", .{
                .size = 12.5,
                .weight = .semibold,
                .color = s.palette.danger,
            });
        }
        ui.text(c, if (s.json_text.len > 0) s.json_text else "It printed nothing.", .{
            .size = 12,
            .mono = true,
            .color = s.palette.text,
            .wrap = true,
            .leading = 1.5,
        });
        return;
    }

    const rows = lines.slice();
    var list = ui.list(c, .{
        .count = rows.len,
        .row_height = 22,
        .width = .fill,
        .height = .fill,
        .padding = .{ .top = 6, .bottom = 10 },
    });
    // A click rebuilds the line list, which frees the slice being iterated, so
    // the toggle is remembered and applied once the loop is done with it.
    var toggled: ?[]u8 = null;
    defer if (toggled) |path| s.gpa.free(path);
    while (list.next()) |i| {
        const line = rows[i];
        const indent = 4 + @as(f32, @floatFromInt(line.depth)) * 15;
        const clickable = line.path != null;
        const it = ui.pressable(c, .{
            .direction = .row,
            .width = .fill,
            .height = .{ .px = 22 },
            .align_items = .center,
            .padding = .{ .left = indent, .right = 10 },
            .radius = 5,
            .background = s.palette.bg,
        }, if (clickable) s.palette.hover else null);
        defer ui.end(c);

        jsonRow(s, c, line);

        if (clickable and it.clicked and toggled == null) {
            toggled = s.gpa.dupe(u8, line.path.?) catch null;
        }
    }
    list.end();
    if (toggled) |path| s.togglePath(path);
}

/// One line of the JSON tree: the key (or array index) in the accent colour,
/// then its value in the colour of its type, on the same line.
///
/// A pair is drawn as one string with two spans rather than as two widgets:
/// `"key":` and `"value"` on separate rows read as fragments, not as a
/// document, and the eye cannot scan a column of values that is not a column.
fn jsonRow(s: *AppState, c: *ui.Context, line: backend.JsonLine) void {
    const key_color = switch (line.kind) {
        .key => s.palette.accent,
        .number => s.palette.warning,
        .punct => s.palette.faint,
        .summary => s.palette.muted,
        else => s.palette.text,
    };
    const value = line.value orelse {
        clipped(c, line.text, .{
            .size = 12,
            .mono = true,
            .truncate = .ellipsis,
            .color = key_color,
        });
        return;
    };

    const value_color = switch (value.kind) {
        .string => s.palette.success,
        .number => s.palette.warning,
        .boolean => s.palette.accent,
        .null_ => s.palette.faint,
        .punct => s.palette.faint,
        .summary => s.palette.muted,
        .key => s.palette.accent,
    };
    const joined = line.painted(c.alloc());
    const spans = c.alloc().alloc(ui.Span, 2) catch {
        clipped(c, joined, .{ .size = 12, .mono = true, .truncate = .ellipsis, .color = key_color });
        return;
    };
    spans[0] = .{ .start = 0, .end = @intCast(line.text.len), .color = key_color };
    spans[1] = .{ .start = @intCast(line.text.len + 1), .end = @intCast(joined.len), .color = value_color };

    // The leaf fills the row so `truncate` has an edge to cut at.
    _ = c.leaf(.{ .width = .fill }, .{ .text = .{
        .str = joined,
        .style = .{ .size = 12, .mono = true, .truncate = .ellipsis },
        .color = key_color,
        .spans = spans,
    } }, null);
}

/// The answer as a list: one group per kind of thing, one row per record,
/// with its state at the right edge. This is what the page asked for, so it
/// can say more than the tree can — which channel is configured, which memory
/// engine is active, which tool the runtime loaded.
fn rowsView(s: *AppState, c: *ui.Context, rows: *backend.Rows) void {
    ui.key(c, "rows-scroll");
    const scroller = ui.div(c).column().grow().minW(0).wFull().scrollY().clip().gap(14);
    defer scroller.end();

    if (rows.totalRows() == 0) {
        // The command answered, and the answer was nothing. Say that, with
        // the command that would change it, rather than drawing an empty
        // pair of brackets. A reader that still set a note — the workspace
        // audit's verdict, "no findings above the threshold" — has the better
        // sentence, so it leads.
        const empty = ui.div(c).column().wFull().center().gap(7).py(40);
        defer empty.end();
        ui.icon(c, "doc.text", .{ .size = 22, .color = s.palette.faint });
        if (rows.note.len > 0) {
            ui.text(c, rows.note, .{ .size = 13, .color = s.palette.muted, .mono = true });
        } else {
            ui.text(c, emptyTitle(s.page), .{ .size = 13, .color = s.palette.muted });
        }
        ui.text(c, emptyHint(s.page), .{ .size = 11.5, .color = s.palette.faint });
        return;
    }

    if (rows.note.len > 0) {
        ui.text(c, rows.note, .{ .size = 11.5, .color = s.palette.faint, .mono = true });
    }

    for (rows.groups.items) |group| {
        const block = ui.div(c).column().wFull().gap(6);
        defer block.end();

        {
            const head = ui.div(c).row().wFull().gap(8).itemsCenter();
            defer head.end();
            ui.text(c, group.title, .{ .size = 11, .weight = .semibold, .color = s.palette.muted, .tracking = 0.6 });
            ui.spacer(c);
            ui.textf(c, .{ .size = 10.5, .color = s.palette.faint, .tabular = true }, "{d}", .{group.rows.items.len});
        }

        const card = ui.div(c).column().wFull().rounded(10)
            .bg(s.palette.panel).border(s.palette.border).borderW(1);
        defer card.end();
        for (group.rows.items, 0..) |row, i| {
            if (i > 0) {
                _ = c.leaf(.{
                    .width = .fill,
                    .height = .{ .px = 1 },
                    .background = s.palette.border.alpha(0.5),
                }, .none, null);
            }
            rowLine(s, c, row);
        }
    }
}

/// What an empty page is empty of.
fn emptyTitle(page: Page) []const u8 {
    return switch (page) {
        .skills => "No skills installed",
        .channels => "No channels configured",
        .cron => "No scheduled tasks",
        .mcp => "No MCP servers configured",
        else => "Nothing to show",
    };
}

/// The command that would put something on the page.
fn emptyHint(page: Page) []const u8 {
    return switch (page) {
        .skills => "nullclaw skills install <source>",
        .channels => "nullclaw channel add <name>",
        .cron => "nullclaw cron add",
        .mcp => "add a server under `mcp` in config.json",
        else => "",
    };
}

/// One record: its name, what it is, and its state.
fn rowLine(s: *AppState, c: *ui.Context, row: backend.Row) void {
    const line = ui.div(c).row().wFull().gap(12).itemsCenter().px(12).py(8);
    defer line.end();

    {
        const name = ui.div(c).column().grow().minW(0).gap(1);
        defer name.end();
        clipped(c, row.title, .{ .size = 12.5, .color = s.palette.text, .mono = true, .truncate = .ellipsis });
        if (row.detail.len > 0) {
            clipped(c, row.detail, .{ .size = 11, .color = s.palette.faint, .truncate = .ellipsis });
        }
    }

    switch (row.state) {
        .none => {},
        .on => kit.tag(c, "on", .{ .status = .success, .pill = true }),
        .off => kit.tag(c, "off", .{ .status = .neutral, .pill = true }),
        .warn => kit.tag(c, "no key", .{ .status = .warning, .pill = true }),
        .bad => kit.tag(c, "error", .{ .status = .danger, .pill = true }),
    }
}

/// The toolbar owns its row, opening and closing it, so the rows below are its
/// siblings rather than its children. A `defer` here would put the whole page
/// inside a 27-point row and clip it away.
fn jsonToolbar(s: *AppState, c: *ui.Context) void {
    const bar = ui.div(c).row().wFull().gap(8).itemsCenter();
    defer bar.end();
    // No Run button here: the page header owns it, and two controls for one
    // action is one too many. The fold controls only exist when there is a
    // tree to fold.
    const has_tree = if (s.json_lines) |l| l.problem == null else false;
    if (has_tree) {
        if (ui.button(c, "Expand all", .{ .size = 12, .icon = "chevron.down" }).clicked) s.expandAll();
        if (ui.button(c, "Collapse all", .{ .size = 12, .icon = "chevron.right" }).clicked) s.collapseAll();
    }
    ui.spacer(c);
    if (s.json_running) {
        ui.text(c, "working…", .{ .size = 11, .color = s.palette.accent });
    }
}

/// A board of the configuration, as its own page. The settings menu is the
/// list of boards, so the page is the board and nothing else: no second list
/// of decisions inside the page, folded or otherwise.
fn configBoardPage(s: *AppState, c: *ui.Context) void {
    const board = s.page.configBoard() orelse return;

    // Two bands: the board scrolls, and the action bar is pinned under it.
    // `hFull` on the outer column is what makes that work — without it the
    // column grows to its content, the scroller never has less room than it
    // needs, and the bar lands below the fold.
    const outer = ui.div(c).column().grow().minW(0).wFull().px(22).pt(16);
    defer outer.end();

    // Both bands are closed before the bar is drawn: a `defer` here would
    // leave them open, the bar would be drawn inside the scroller, and it
    // would scroll away with the form instead of staying put.
    {
        ui.key(c, "config-scroll");
        // `hFull` as well as `grow`: in a column `grow` is the height, but the
        // next reader of this line should not have to know that.
        const scroller = ui.div(c).column().grow().minW(0).wFull().hFull().scrollY().clip().pb(24);
        defer scroller.end();

        if (s.config == null) configMissingNotice(s, c);
        configBoard(s, c, board);
    }

    configActions(s, c);
}

/// One board: its sentence, then its card. The page's title names the board,
/// so the heading here is the sentence that says what it decides.
fn configBoard(s: *AppState, c: *ui.Context, board: state.ConfigBoard) void {
    const column = ui.div(c).column().wFull().maxW(design.Spacing.settings_measure).gap(10);
    defer column.end();

    if (board.note().len > 0) {
        ui.text(c, board.note(), .{
            .size = 11.5,
            .color = s.palette.faint,
            .wrap = true,
            .leading = 1.4,
        });
    }

    const card = settingsCard(c, s);
    defer card.end();

    switch (board) {
        .model => modelBoard(s, c),
        .agent => agentBoard(s, c),
        .autonomy => autonomyBoard(s, c),
        .workspace => workspaceBoard(s, c),
        .memory => memoryBoard(s, c),
        .server => serverBoard(s, c),
        .execution => executionBoard(s, c),
        .gateway => gatewayBoard(s, c),
        .mcp => mcpBoard(s, c),
        .schedules => schedulesBoard(s, c),
        .reliability => reliabilityBoard(s, c),
        .diagnostics => diagnosticsBoard(s, c),
        .security => securityBoard(s, c),
        .tools => toolsBoard(s, c),
        .session => sessionBoard(s, c),
        .logs => logsBoard(s, c),
        .hardware => hardwareBoard(s, c),
        .advanced => advancedBoard(s, c),
    }
}

/// The state of the loaded file, as one chip: what the header shows in
/// place of the Run button the other pages have.
fn configStatusChip(s: *AppState, c: *ui.Context) void {
    const status: kit.Status, const label: []const u8 = blk: {
        if (s.config_running) break :blk .{ .info, "Validating…" };
        if (s.config == null) break :blk .{ .warning, "No config loaded" };
        if (s.config_dirty) break :blk .{ .warning, "Unsaved changes" };
        break :blk .{ .success, "Saved" };
    };
    kit.tag(c, label, .{ .status = status, .pill = true, .icon = kit.statusIcon(status) });
}

/// nanoterm-style runtime card: title, state and controls on one line, the
/// explanation under them, then the facts.
fn runtimeStatusCard(s: *AppState, c: *ui.Context) void {
    const running = s.gatewayRunning();
    const section = settingsSection(c, s, "Runtime server", "The HTTP gateway this window serves in-process, for external clients. Chat and the pages are answered directly, not through it.");
    defer section.end();
    const card = settingsCard(c, s);
    defer card.end();

    {
        const row = settingRow(s, c, "Built-in nullclaw runtime", if (running) "Serving on the gateway's port." else "Not running.");
        defer row.end();
        const field = ui.div(c).row().w(design.Spacing.settings_control).minW(design.Spacing.settings_control)
            .gap(8).itemsCenter().justifyEnd();
        defer field.end();
        kit.tag(c, if (running) "running" else "stopped", .{
            .status = if (running) .success else .neutral,
            .pill = true,
        });
        if (ui.button(c, if (running) "Restart" else "Start", .{ .size = 12, .icon = "arrow.clockwise" }).clicked) {
            s.restartDaemon();
            s.say("runtime restarted");
        }
        if (running) {
            if (ui.button(c, "Stop", .{ .size = 12, .variant = .secondary }).clicked) {
                s.stopGateway();
                s.say("runtime stopped");
            }
        }
    }
    settingsRule(c, s);
    {
        const row = settingRow(s, c, "Status", "");
        defer row.end();
        const field = ui.div(c).row().w(design.Spacing.settings_control).minW(design.Spacing.settings_control)
            .itemsCenter().justifyEnd();
        defer field.end();
        ui.text(c, s.daemonStatusText(c.alloc()), .{
            .size = 11.5,
            .color = if (running) s.palette.success else s.palette.muted,
        });
    }
    settingsRule(c, s);
    {
        const row = settingRow(s, c, "Binary", "");
        defer row.end();
        const field = ui.div(c).row().w(design.Spacing.settings_control).minW(design.Spacing.settings_control)
            .itemsCenter().justifyEnd();
        defer field.end();
        clipped(c, s.exe, .{ .size = 11, .mono = true, .color = s.palette.faint, .truncate = .middle });
    }
}

/// One `Label   value` line inside a card, with the label held to a fixed
/// width so a stack of them lines up.
fn configFact(s: *AppState, c: *ui.Context, label: []const u8, value: []const u8, color: ui.Color, mono: bool) void {
    const row = ui.div(c).row().wFull().gap(10).itemsCenter();
    defer row.end();
    {
        const slot = ui.div(c).w(52).minW(52);
        defer slot.end();
        ui.text(c, label, .{ .size = 11, .color = s.palette.faint });
    }
    // The value needs a box that grows: `clipped` fills its parent, and a
    // bare leaf in a row is given no width to fill, which drew a tofu box
    // instead of the text.
    {
        const slot = ui.div(c).grow().minW(0);
        defer slot.end();
        clipped(c, value, .{ .size = 11.5, .color = color, .mono = mono, .truncate = .middle });
    }
}

fn configMissingNotice(s: *AppState, c: *ui.Context) void {
    const card = ui.div(c).column().wFull().gap(4).p(12).rounded(10).bg(s.palette.panel).border(s.palette.warning).borderW(1);
    defer card.end();
    ui.text(c, "No configuration file yet", .{ .size = 12.5, .weight = .semibold, .color = s.palette.warning });
    ui.textf(c, .{ .size = 11.5, .color = s.palette.muted, .wrap = true }, "The form is ready, but Apply and Save stay disabled until {s} exists. Run `nullclaw onboard`, then Reload from disk.", .{s.paths.config});
}

// --- settings, after zeron's own design system ---------------------------
//
// A settings page is a column of sections. A section is a title, a sentence
// about what the section changes, and one card. A card is a run of rows with a
// hairline between each, from the card's edge to its edge — the rule splits the
// card, it does not underline the text. A row is a name and a sentence on the
// left, its control on the right, washed edge to edge under the pointer.

/// A section: its title, what it changes, and the card its rows live in.
/// Returns an open column the caller must `end`.
fn settingsSection(c: *ui.Context, s: *AppState, title: []const u8, note: []const u8) ui.Div {
    const col = ui.div(c).column().wFull().gap(8);
    const head = ui.div(c).column().wFull().gap(3);
    defer head.end();
    ui.text(c, title, .{ .size = 14, .weight = .semibold, .color = s.palette.text });
    if (note.len > 0) {
        ui.text(c, note, .{ .size = 11.5, .color = s.palette.faint, .wrap = true, .leading = 1.4 });
    }
    return col;
}

/// The card a section's rows sit in: one rounded box, clipped, with a hairline
/// between rows. Returns an open column the caller must `end`.
fn settingsCard(c: *ui.Context, s: *AppState) ui.Div {
    return ui.div(c).column().wFull().rounded(design.Radius.lg)
        .bg(s.palette.panel).border(s.palette.border).borderW(1).clip();
}

/// The hairline between two rows: from the card's edge to its edge.
fn settingsRule(c: *ui.Context, s: *AppState) void {
    _ = c.leaf(.{ .width = .fill, .height = .{ .px = 1 }, .background = s.palette.border }, .none, null);
}

/// One row: the name and its sentence on the left, the control on the right.
/// `control` is built by the caller between the row's open and its end, so a
/// field, a switch and a select all sit in the same place.
fn settingRow(s: *AppState, c: *ui.Context, label: []const u8, hint: []const u8) ui.Div {
    const row = ui.div(c).row().wFull()
        .px(14).py(9).gap(16).itemsCenter();
    c.node(row.index).style.min_height = design.Spacing.settings_row;
    const text = ui.div(c).column().grow().minW(0).gap(2);
    defer text.end();
    ui.text(c, label, .{ .size = 12.5, .color = s.palette.text });
    if (hint.len > 0) {
        ui.text(c, hint, .{ .size = 11, .color = s.palette.faint, .wrap = true, .leading = 1.35 });
    }
    return row;
}

/// How a settings text field is drawn: a secret as bullets, a value in the
/// mono face. Named rather than inline, because Zig 0.17 has no default value
/// for an anonymous struct parameter.
const TextFieldOpts = struct {
    password: bool = false,
    mono: bool = true,
};

/// A row whose control is a text field.
fn settingsTextField(
    s: *AppState,
    c: *ui.Context,
    label: []const u8,
    hint: []const u8,
    placeholder: []const u8,
    buf: *ui.TextBuffer,
) void {
    settingsTextFieldOpts(s, c, label, hint, placeholder, buf, .{});
}

fn settingsTextFieldOpts(
    s: *AppState,
    c: *ui.Context,
    label: []const u8,
    hint: []const u8,
    placeholder: []const u8,
    buf: *ui.TextBuffer,
    opts: TextFieldOpts,
) void {
    const row = settingRow(s, c, label, hint);
    defer row.end();
    // Zeron's 240, fixed: every control in a card sits in the same column, so
    // a short value (a temperature) and a long one (a path) start at the same
    // edge. A path too long for it scrolls inside the field rather than
    // stretching the row.
    const field = ui.div(c).row().w(design.Spacing.settings_control).minW(design.Spacing.settings_control);
    defer field.end();
    _ = ui.textField(c, buf, .{
        .placeholder = placeholder,
        .width = .fill,
        .size = 12,
        .mono = opts.mono,
        .password = opts.password,
        .color = c.theme.text,
    });
}

/// The same, for a value that is a path or an address: the control takes the
/// room the label leaves instead of zeron's 240, because a workspace path cut
/// at 240 is a path nobody can read.
fn settingsTextFieldWide(
    s: *AppState,
    c: *ui.Context,
    label: []const u8,
    hint: []const u8,
    placeholder: []const u8,
    buf: *ui.TextBuffer,
) void {
    const row = settingRow(s, c, label, hint);
    defer row.end();
    const field = ui.div(c).row().grow().minW(design.Spacing.settings_control);
    defer field.end();
    _ = ui.textField(c, buf, .{
        .placeholder = placeholder,
        .width = .fill,
        .size = 12,
        .mono = true,
        .color = c.theme.text,
    });
}

/// A row whose control is a switch, with its state said beside it.
fn settingsSwitch(s: *AppState, c: *ui.Context, label: []const u8, hint: []const u8, value: *bool) void {
    const row = settingRow(s, c, label, hint);
    defer row.end();
    const field = ui.div(c).row().w(design.Spacing.settings_control).minW(design.Spacing.settings_control)
        .gap(8).itemsCenter();
    defer field.end();
    _ = ui.toggle(c, "", value);
    ui.text(c, if (value.*) "On" else "Off", .{
        .size = 11.5,
        .color = if (value.*) s.palette.text else s.palette.faint,
    });
}

/// A row whose control is a segmented choice over a fixed set of values.
fn settingsSegmented(
    s: *AppState,
    c: *ui.Context,
    label: []const u8,
    hint: []const u8,
    names: []const []const u8,
    picked: *usize,
) void {
    const row = settingRow(s, c, label, hint);
    defer row.end();
    const field = ui.div(c).row().w(design.Spacing.settings_control).minW(design.Spacing.settings_control)
        .justifyEnd();
    defer field.end();
    _ = ui.segmented(c, names, picked);
}

/// A row whose control is a select over a fixed set of values.
fn settingsSelect(
    s: *AppState,
    c: *ui.Context,
    key: []const u8,
    label: []const u8,
    hint: []const u8,
    options: []const []const u8,
    picked: *?usize,
    placeholder: []const u8,
) void {
    const row = settingRow(s, c, label, hint);
    defer row.end();
    const field = ui.div(c).row().w(design.Spacing.settings_control).minW(design.Spacing.settings_control);
    defer field.end();
    _ = kit.select(c, key, options, picked, .{
        .placeholder = placeholder,
        .width = design.Spacing.settings_control,
    });
}

/// A provider pick: the ids the runtime knows, plus the one the config
/// names if it is not in that list. A select rather than free text, so the
/// value can only be one the runtime actually understands.
fn providerField(s: *AppState, c: *ui.Context) void {
    if (s.cfg_provider_options.len == 0) {
        const row = settingRow(s, c, "Provider", "Before the slash in `agents.defaults.model.primary`.");
        defer row.end();
        ui.text(c, "No providers known to the runtime.", .{ .size = 11.5, .color = s.palette.muted });
        return;
    }
    var picked: ?usize = @as(?usize, s.cfg_default_provider);
    settingsSelect(s, c, "default-provider", "Provider", "Before the slash in `agents.defaults.model.primary`.", s.cfg_provider_options, &picked, "Choose…");
    if (picked) |p| s.cfg_default_provider = p;
}

/// A segmented choice instead of free text: nanoterm uses this for the
/// handful of settings that have a fixed set of values.
fn autonomyField(s: *AppState, c: *ui.Context) void {
    const names = [_][]const u8{ "Supervised", "Full", "Yolo" };
    const values = [_][]const u8{ "supervised", "full", "yolo" };
    const current = std.mem.trim(u8, s.cfg_autonomy_level.text(), " \t\r\n");
    var picked: usize = 0;
    for (values, 0..) |value, i| {
        if (std.ascii.eqlIgnoreCase(current, value)) picked = i;
    }
    settingsSegmented(s, c, "Level", "`autonomy.level`: how much the agent does on its own.", &names, &picked);
    if (!std.ascii.eqlIgnoreCase(current, values[picked])) {
        s.cfg_autonomy_level.set(values[picked]);
    }
    if (picked == 2) {
        const row = ui.div(c).row().wFull().px(14).pb(10);
        defer row.end();
        ui.text(c, "Yolo removes confirmations. Only use it on a workspace you trust.", .{
            .size = 11,
            .color = s.palette.danger,
            .wrap = true,
        });
    }
}

/// The settings worth a control on this page: what answers, where it works,
/// which servers it can call, and whether it runs on a schedule. The rest of
/// `config.json` stays in the advanced fold — a form that mirrors every key is
/// a worse editor than the file itself.
fn modelBoard(s: *AppState, c: *ui.Context) void {
    providerField(s, c);
    settingsRule(c, s);
    settingsTextField(s, c, "Default model", "After the slash in `agents.defaults.model.primary`.", "glm-4.6, claude-sonnet-4", &s.cfg_default_model);
    settingsRule(c, s);
    // A key is a secret: bullets, not the value on screen and in every
    // screenshot of this page.
    settingsTextFieldOpts(s, c, "API key", "`models.providers.<name>.api_key`.", "the provider's key", &s.cfg_api_key, .{ .password = true });
    settingsRule(c, s);
    settingsTextFieldWide(s, c, "Base URL", "`models.providers.<name>.base_url`.", "https://api.example.com/v1", &s.cfg_api_base_url);
    settingsRule(c, s);
    settingsTextField(s, c, "Temperature", "`default_temperature`: how much variation the model may take.", "0.7", &s.cfg_temperature);
    settingsRule(c, s);
    var picked: ?usize = s.cfg_reasoning_effort;
    settingsSelect(s, c, "reasoning-effort", "Reasoning effort", "`reasoning_effort`: how hard a reasoning model thinks.", &state.reasoning_efforts, &picked, "not set");
    s.cfg_reasoning_effort = picked;
}

fn agentBoard(s: *AppState, c: *ui.Context) void {
    settingsTextField(s, c, "Max tool iterations", "`agent.max_tool_iterations`: tool calls one turn may make.", "1000", &s.cfg_max_tool_iterations);
    settingsRule(c, s);
    settingsTextField(s, c, "Max history messages", "`agent.max_history_messages`: how much of the conversation is sent.", "100", &s.cfg_max_history);
    settingsRule(c, s);
    settingsSwitch(s, c, "Compact context", "`agent.compact_context`: summarise long turns instead of dropping them.", &s.cfg_compact_context);
    settingsRule(c, s);
    settingsTextField(s, c, "Timezone", "`agent.timezone`: the zone the agent reasons about times in.", "UTC", &s.cfg_timezone);
    settingsRule(c, s);
    settingsTextField(s, c, "Message timeout", "`agent.message_timeout_secs`: how long one turn may take.", "600", &s.cfg_message_timeout);
}

fn autonomyBoard(s: *AppState, c: *ui.Context) void {
    autonomyField(s, c);
    settingsRule(c, s);
    settingsSwitch(s, c, "Workspace only", "`autonomy.workspace_only`: hold the agent to the workspace.", &s.cfg_workspace_only);
    settingsRule(c, s);
    settingsTextField(s, c, "Max actions per hour", "`autonomy.max_actions_per_hour`: the rate the agent is held to.", "20", &s.cfg_max_actions);
    settingsRule(c, s);
    settingsSwitch(s, c, "Block high-risk commands", "`autonomy.block_high_risk_commands`: refuse the dangerous ones outright.", &s.cfg_block_high_risk);
    settingsRule(c, s);
    settingsSwitch(s, c, "Ask for medium risk", "`autonomy.require_approval_for_medium_risk`: confirm the middle ones.", &s.cfg_approve_medium);
}

fn workspaceBoard(s: *AppState, c: *ui.Context) void {
    settingsTextFieldWide(s, c, "Path", "`workspace`. Empty uses the runtime's default.", "~/.nullclaw/workspace", &s.cfg_workspace);
}

fn memoryBoard(s: *AppState, c: *ui.Context) void {
    memoryField(s, c);
    settingsRule(c, s);
    settingsSwitch(s, c, "Search by meaning", "`memory.search.enabled`: embed and search turns semantically.", &s.cfg_memory_search);
}

fn serverBoard(s: *AppState, c: *ui.Context) void {
    runtimeStatusCard(s, c);
}

fn executionBoard(s: *AppState, c: *ui.Context) void {
    var picked: usize = s.cfg_runtime_kind;
    const names = [_][]const u8{ "Native", "Docker" };
    settingsSegmented(s, c, "Kind", "`runtime.kind`: this process, or a container.", &names, &picked);
    s.cfg_runtime_kind = picked;
    settingsRule(c, s);
    settingsTextFieldWide(s, c, "Docker image", "`runtime.docker.image`: the container the agent runs in.", "alpine:3.24", &s.cfg_docker_image);
}

fn gatewayBoard(s: *AppState, c: *ui.Context) void {
    settingsTextField(s, c, "Host", "`gateway.host`.", "127.0.0.1", &s.cfg_gateway_host);
    settingsRule(c, s);
    settingsTextField(s, c, "Port", "`gateway.port`.", "3000", &s.cfg_gateway_port);
    settingsRule(c, s);
    settingsSwitch(s, c, "Require pairing", "`gateway.require_pairing`: a client must pair before it is served.", &s.cfg_gateway_require_pairing);
    settingsRule(c, s);
    settingsSwitch(s, c, "Allow public bind", "`gateway.allow_public_bind`: listen beyond this machine.", &s.cfg_gateway_allow_public_bind);
}

fn mcpBoard(s: *AppState, c: *ui.Context) void {
    mcpField(s, c);
}

fn schedulesBoard(s: *AppState, c: *ui.Context) void {
    settingsSwitch(s, c, "Run scheduled tasks", "`cron.enabled`.", &s.cfg_cron_enabled);
    settingsRule(c, s);
    settingsTextField(s, c, "Cron interval", "Minutes between ticks, `cron.interval_minutes`.", "30", &s.cfg_cron_interval);
    settingsRule(c, s);
    settingsSwitch(s, c, "Scheduler on", "`scheduler.enabled`: the task runner itself.", &s.cfg_scheduler_enabled);
    settingsRule(c, s);
    settingsTextField(s, c, "Max tasks", "`scheduler.max_tasks`: how many the runner holds.", "64", &s.cfg_scheduler_max_tasks);
}

fn reliabilityBoard(s: *AppState, c: *ui.Context) void {
    settingsTextField(s, c, "Provider retries", "`reliability.provider_retries`.", "2", &s.cfg_retries);
    settingsRule(c, s);
    settingsTextField(s, c, "Backoff", "`reliability.provider_backoff_ms`: wait between tries.", "500", &s.cfg_backoff_ms);
}

fn diagnosticsBoard(s: *AppState, c: *ui.Context) void {
    {
        var picked: ?usize = s.cfg_diagnostics_backend;
        settingsSelect(s, c, "diagnostics-backend", "Recorder", "`diagnostics.backend`: what records what the runtime does. `none` records nothing, and the Logs board then has nothing to write to.", &state.diagnostics_backends, &picked, "none");
        if (picked) |i| s.cfg_diagnostics_backend = i;
    }
    settingsRule(c, s);
    settingsTextFieldWide(s, c, "OTel endpoint", "`diagnostics.otel_endpoint`: where a `otel` recorder sends spans.", "https://otlp.example.com/v1/traces", &s.cfg_otel_endpoint);
    settingsRule(c, s);
    settingsTextField(s, c, "OTel service", "`diagnostics.otel_service_name`: the name the spans are filed under.", "nullclaw", &s.cfg_otel_service);
    settingsRule(c, s);
    settingsTextField(s, c, "Error text limit", "`diagnostics.api_error_max_chars`: how much of a provider's error is kept.", "auto", &s.cfg_api_error_max_chars);
    settingsRule(c, s);
    {
        // The flags themselves are on the Logs board, so this points there
        // rather than showing a second copy of the same four switches.
        const row = settingRow(s, c, "Log flags", "Tool calls, model traffic, receipts and payloads live on the Logs board.");
        defer row.end();
        if (ui.button(c, "Open Logs", .{ .variant = .ghost, .size = 11.5, .icon = "arrow.right" }).clicked) s.openPage(.cfg_logs);
    }
}

/// What the log is, how much of it is kept, and how much of it the token
/// ledger remembers. The backend that decides whether a log exists at all is
/// on the Diagnostics board, because a log with no backend is not a log.
fn logsBoard(s: *AppState, c: *ui.Context) void {
    settingsSwitch(s, c, "Log tool calls", "`diagnostics.log_tool_calls`: every tool call and its result.", &s.cfg_log_tool_calls);
    settingsRule(c, s);
    settingsSwitch(s, c, "Log model traffic", "`diagnostics.log_llm_io`: prompts and replies, in the log.", &s.cfg_log_llm_io);
    settingsRule(c, s);
    settingsSwitch(s, c, "Log receipts", "`diagnostics.log_message_receipts`: that a message arrived, not what it said.", &s.cfg_log_receipts);
    settingsRule(c, s);
    settingsSwitch(s, c, "Log payloads", "`diagnostics.log_message_payloads`: what the message said. Turn it on knowingly.", &s.cfg_log_payloads);
    settingsRule(c, s);
    settingsSwitch(s, c, "Token ledger", "`diagnostics.token_usage_ledger_enabled`: count what each turn spends.", &s.cfg_ledger_enabled);
    settingsRule(c, s);
    settingsTextField(s, c, "Ledger window", "`diagnostics.token_usage_ledger_window_hours`: how far back the counts go.", "24", &s.cfg_ledger_window_hours);
    settingsRule(c, s);
    settingsTextField(s, c, "Ledger bytes", "`diagnostics.token_usage_ledger_max_bytes`: the most the ledger file may take.", "0", &s.cfg_ledger_max_bytes);
    settingsRule(c, s);
    settingsTextField(s, c, "Ledger lines", "`diagnostics.token_usage_ledger_max_lines`: the most entries it may hold.", "0", &s.cfg_ledger_max_lines);
}

/// The one board the agent may talk to. A serial device or a probe target,
/// and nothing else: the agent cannot reach a device this does not name.
fn hardwareBoard(s: *AppState, c: *ui.Context) void {
    settingsSwitch(s, c, "Hardware access", "`hardware.enabled`: let the agent talk to a board.", &s.cfg_hardware_enabled);
    settingsRule(c, s);
    {
        var picked: ?usize = s.cfg_hardware_transport;
        settingsSelect(s, c, "hardware-transport", "Transport", "`hardware.transport`: how the board is reached.", &state.hardware_transports, &picked, "none");
        if (picked) |i| s.cfg_hardware_transport = i;
    }
    settingsRule(c, s);
    settingsTextFieldWide(s, c, "Serial port", "`hardware.serial_port`: the device node, e.g. `/dev/tty.usbmodem1101`.", "/dev/tty.usbmodem1101", &s.cfg_hardware_serial_port);
    settingsRule(c, s);
    settingsTextField(s, c, "Baud rate", "`hardware.baud_rate`: the speed of the serial line.", "115200", &s.cfg_hardware_baud_rate);
    settingsRule(c, s);
    settingsTextFieldWide(s, c, "Probe target", "`hardware.probe_target`: what `probe-rs` flashes, e.g. `stm32h7` or a chip name.", "stm32h7", &s.cfg_hardware_probe_target);
    settingsRule(c, s);
    settingsSwitch(s, c, "Workspace datasheets", "`hardware.workspace_datasheets`: let the agent read datasheets from the workspace.", &s.cfg_hardware_datasheets);
}

/// What contains a command, what it may use, and what is kept of it. The
/// backend select is the one control here whose value the runtime reads at
/// startup, so the note says that a save needs the restart the bar offers.
fn securityBoard(s: *AppState, c: *ui.Context) void {
    {
        // A select whose value is never "unset": the index always names a
        // backend, and `auto` is the one the runtime falls back to.
        var picked: ?usize = s.cfg_sandbox_backend;
        settingsSelect(s, c, "sandbox-backend", "Sandbox", "`security.sandbox.backend`: what contains a shell command. `auto` picks the best the machine has.", &state.sandbox_backends, &picked, "auto");
        if (picked) |i| s.cfg_sandbox_backend = i;
    }
    settingsRule(c, s);
    settingsSwitch(s, c, "Memory monitoring", "`security.resources.memory_monitoring`: watch a command's memory while it runs.", &s.cfg_memory_monitoring);
    settingsRule(c, s);
    settingsTextField(s, c, "Memory limit", "`security.resources.max_memory_mb`: the ceiling one command may reach.", "512", &s.cfg_max_memory_mb);
    settingsRule(c, s);
    settingsTextField(s, c, "CPU seconds", "`security.resources.max_cpu_time_seconds`: how long it may compute.", "60", &s.cfg_max_cpu_seconds);
    settingsRule(c, s);
    settingsTextField(s, c, "Subprocesses", "`security.resources.max_subprocesses`: how many children it may make.", "10", &s.cfg_max_subprocesses);
    settingsRule(c, s);
    settingsSwitch(s, c, "Audit log", "`security.audit.enabled`: keep a record of what was run.", &s.cfg_audit_enabled);
    settingsRule(c, s);
    settingsTextFieldWide(s, c, "Audit path", "`security.audit.log_path`: where the record is written.", "audit.log", &s.cfg_audit_log_path);
    settingsRule(c, s);
    settingsTextField(s, c, "Audit size limit", "`security.audit.max_size_mb`: the point at which the record is rotated.", "100", &s.cfg_audit_max_size_mb);
    settingsRule(c, s);
    settingsSwitch(s, c, "Sign audit events", "`security.audit.sign_events`: a keyed signature on every entry.", &s.cfg_audit_sign_events);
}

/// The limits one tool call is held to: how long a shell may run, how much it
/// may print, and how much a file or a page may cost.
fn toolsBoard(s: *AppState, c: *ui.Context) void {
    settingsTextField(s, c, "Shell timeout", "`tools.shell_timeout_secs`: how long one command may run.", "60", &s.cfg_shell_timeout_secs);
    settingsRule(c, s);
    settingsTextField(s, c, "Shell output limit", "`tools.shell_max_output_bytes`: the most one command may print.", "1048576", &s.cfg_shell_max_output_bytes);
    settingsRule(c, s);
    settingsTextField(s, c, "File size limit", "`tools.max_file_size_bytes`: the largest file the agent may read or write.", "10485760", &s.cfg_max_file_size_bytes);
    settingsRule(c, s);
    settingsTextField(s, c, "Web page limit", "`tools.web_fetch_max_chars`: how much of a fetched page is kept.", "100000", &s.cfg_web_fetch_max_chars);
}

/// How a direct message is keyed to a conversation, how long one lives, and
/// how work on it is claimed.
fn sessionBoard(s: *AppState, c: *ui.Context) void {
    {
        // The four scopes are the runtime's own; the note says what the
        // difference between them turns into.
        var picked: usize = s.cfg_dm_scope;
        settingsSegmented(s, c, "Direct message scope", "`session.dm_scope`: which conversations share a session.", &[_][]const u8{ "main", "per peer", "per channel", "per account" }, &picked);
        s.cfg_dm_scope = picked;
    }
    settingsRule(c, s);
    settingsTextField(s, c, "Idle timeout", "`session.idle_minutes`: how long a session waits before it is put away.", "60", &s.cfg_session_idle_minutes);
    settingsRule(c, s);
    settingsTextField(s, c, "Concurrent tasks", "`session.max_concurrent_tasks`: how many run in one session at once.", "4", &s.cfg_session_max_concurrent);
    settingsRule(c, s);
    settingsTextField(s, c, "Claim attempts", "`session.claim_max_attempts`: tries at taking over an existing session.", "5", &s.cfg_claim_max_attempts);
    settingsRule(c, s);
    settingsTextField(s, c, "Claim lockout", "`session.claim_lockout_secs`: how long a failed claim is held off.", "300", &s.cfg_claim_lockout_secs);
    settingsRule(c, s);
    settingsTextField(s, c, "Typing interval", "`session.typing_interval_secs`: how often a channel is told the agent is working.", "5", &s.cfg_typing_interval_secs);
}

/// The dotted-path editor: the one place a key the boards do not cover can be
/// set. There is no JSON tree beside it any more — a form of thirteen boards
/// plus a second, unstructured copy of the same file was two answers to the
/// same question, and the tree was the slower one.
fn advancedBoard(s: *AppState, c: *ui.Context) void {
    configEditor(s, c);
}

/// The MCP list: one `name command` per line, in a box that grows with it.
fn mcpField(s: *AppState, c: *ui.Context) void {
    const row = ui.div(c).column().wFull().px(14).py(12).gap(6);
    defer row.end();
    ui.text(c, "Servers", .{ .size = 12.5, .color = s.palette.text });
    // `bare = false`: the area draws its own box, so a list of servers reads
    // as a field rather than as loose text on the card.
    _ = ui.textArea(c, &s.cfg_mcp_servers, .{
        .placeholder = "filesystem npx -y @modelcontextprotocol/server-filesystem",
        .min_lines = 3,
        .max_lines = 10,
        .size = 12,
        .bare = false,
        .color = s.palette.text,
        .caret_color = s.palette.accent,
    });
    ui.text(c, "Editing this list writes `mcp_servers`; a server's other keys are kept.", .{
        .size = 11,
        .color = s.palette.faint,
        .wrap = true,
    });
}

/// Skills are files in the workspace, not config keys. The page says how many
/// there are and where they live, and leaves installing to the CLI.
fn skillsSummary(s: *AppState, c: *ui.Context) void {
    const count = s.skills_count;
    const row = ui.div(c).row().wFull().gap(12).itemsCenter();
    defer row.end();
    {
        const label = ui.div(c).column().w(260).minW(260).gap(2);
        defer label.end();
        ui.text(c, "Installed", .{ .size = 12.5, .color = s.palette.text });
        ui.text(c, "`<workspace>/skills`.", .{ .size = 11, .color = s.palette.faint });
    }
    if (count == null) {
        ui.text(c, "Not read yet — open the Skills page.", .{ .size = 11.5, .color = s.palette.faint });
    } else if (count.? == 0) {
        ui.text(c, "None installed.", .{ .size = 11.5, .color = s.palette.muted });
    } else {
        ui.textf(c, .{ .size = 12, .color = s.palette.text, .tabular = true }, "{d} installed", .{count.?});
    }
}

/// Capabilities are a property of the build plus the config, so the page
/// shows the counts rather than offering controls for them.
fn capabilitiesSummary(s: *AppState, c: *ui.Context) void {
    const caps = s.caps_summary orelse {
        const row = ui.div(c).row().wFull().gap(12).itemsCenter();
        defer row.end();
        ui.text(c, "Not read yet — open the Capabilities page.", .{ .size = 11.5, .color = s.palette.faint });
        return;
    };
    const row = ui.div(c).row().wFull().gap(20).itemsCenter();
    defer row.end();
    capsFact(s, c, "Channels", caps.channels_configured, caps.channels_total);
    capsFact(s, c, "Tools", caps.tools, caps.tools);
    capsFact(s, c, "Memory engines", caps.memory_active, caps.memory_total);
}

/// One count: the number, then what it counts. `1 / Channels of 2` read as
/// three fragments; the label leads and the ratio follows it on one line.
fn capsFact(s: *AppState, c: *ui.Context, label: []const u8, on: usize, total: usize) void {
    const col = ui.div(c).column().gap(3);
    defer col.end();
    {
        const row = ui.div(c).row().gap(6).itemsEnd();
        defer row.end();
        ui.textf(c, .{ .size = 16, .weight = .semibold, .color = s.palette.text, .tabular = true }, "{d}", .{on});
        ui.textf(c, .{ .size = 11, .color = s.palette.faint, .tabular = true }, "of {d}", .{total});
    }
    ui.text(c, label, .{ .size = 10.5, .color = s.palette.muted });
}

/// The memory engine pick. A select rather than free text, for the same reason
/// the provider is one: only an engine the registry registers can load.
fn memoryField(s: *AppState, c: *ui.Context) void {
    var picked: ?usize = @as(?usize, s.cfg_memory_backend);
    settingsSelect(s, c, "memory-backend", "Engine", "`memory.backend`: which store keeps the turns.", &state.memory_backends, &picked, "Choose…");
    if (picked) |p| s.cfg_memory_backend = p;
    settingsRule(c, s);
    settingsSwitch(s, c, "Save automatically", "`memory.auto_save`: write each turn without being asked.", &s.cfg_memory_auto_save);
}

/// The pinned action bar: a hairline, the buttons, and one sentence saying
/// what the primary button will do. The state itself lives in the header
/// chip, so it is not repeated here.
fn configActions(s: *AppState, c: *ui.Context) void {
    // Room under the buttons: at `pb(14)` the row sat against the window's
    // last pixel, and the primary button's label was cut by the edge.
    const band = ui.div(c).column().wFull().pt(10).pb(20).gap(6);
    defer band.end();

    _ = c.leaf(.{
        .width = .fill,
        .height = .{ .px = 1 },
        .background = s.palette.border,
    }, .none, null);

    // No `maxW` here: the bar spans the window, and a capped column inside a
    // row squeezes the buttons until their labels are cut off.
    const inner = ui.div(c).column().wFull().gap(5);
    defer inner.end();

    const row = ui.div(c).row().wFull().gap(8).itemsCenter();
    defer row.end();
    const ready = s.config != null and !s.config_running;
    // An explicit width: `.auto` measured the label at 82 points and left the
    // box 2 points of slack, and the last glyph was drawn past the edge.
    if (ui.button(c, "Save & restart", .{ .variant = .primary, .size = 12, .icon = "square.and.arrow.up", .width = .{ .px = 168 }, .disabled = !ready }).clicked) s.saveConfig();
    if (ui.button(c, "Apply", .{ .size = 12, .icon = "checkmark", .disabled = !ready }).clicked) s.applyConfigForm();
    if (ui.button(c, "Reload", .{ .variant = .ghost, .size = 12, .icon = "arrow.clockwise", .disabled = s.config_running }).clicked) s.loadConfig();
    ui.spacer(c);
    configStatusLine(s, c);
}

/// The sentence under the buttons: nanoterm keeps the meaning of a setting
/// and the consequence of an action next to the control, not in a toast that
/// disappears after a few seconds.
fn configStatusLine(s: *AppState, c: *ui.Context) void {
    const text: []const u8 = if (s.config_running)
        "reading the file on disk…"
    else if (s.config_dirty)
        "edits are in memory only"
    else if (s.config != null)
        "read from config.json"
    else
        "";
    if (text.len == 0) return;
    ui.text(c, text, .{ .size = 11, .color = s.palette.faint });
}

/// A clickable heading that hides the raw editor until asked for, instead
/// of a bare switch that leaves the page's longest section always open.
fn configEditor(s: *AppState, c: *ui.Context) void {
    const wrap = ui.div(c).column().wFull().gap(8);
    defer wrap.end();

    // The file itself, said plainly: which one, how big, and whether the
    // runtime would take it. Advanced is where a key the boards do not cover
    // is set, and the first thing to know is which file that lands in.
    {
        const row = ui.div(c).row().wFull().gap(8).itemsCenter().px(14).py(10);
        defer row.end();
        ui.icon(c, "doc.text", .{ .size = 11, .color = s.palette.faint });
        ui.text(c, s.paths.config, .{
            .size = 11.5,
            .color = s.palette.muted,
            .mono = true,
            .truncate = .middle,
        });
        ui.spacer(c);
        ui.textf(c, .{ .size = 11, .color = s.palette.faint, .tabular = true }, "{d} top-level keys", .{
            if (s.config) |doc| if (doc.object()) |map| map.count() else 0 else 0,
        });
    }

    settingsRule(c, s);

    // The keys the file has, one press away from the path field: a dotted path
    // typed from memory is where this editor went wrong, and the list of what
    // the file actually holds is the smallest thing that fixes it. A press
    // fills the path; the value is typed beside it.
    if (s.config) |*doc| {
        if (doc.object()) |map| {
            // A column of rows rather than one long row: nanoui has no
            // wrapping row, and a row of twenty keys would run off the card.
            const keys = ui.div(c).column().wFull().gap(4).px(14).py(10);
            defer keys.end();
            var it = map.iterator();
            while (it.next()) |entry| {
                const name = entry.key_ptr.*;
                const row = ui.pressable(c, .{
                    .direction = .row,
                    .width = .fill,
                    .gap = 8,
                    .padding = .xy(8, 4),
                    .radius = design.Radius.sm,
                    .align_items = .center,
                }, s.palette.hover);
                defer ui.end(c);
                ui.text(c, name, .{
                    .size = 11.5,
                    .color = s.palette.accent,
                    .mono = true,
                });
                if (row.clicked) s.edit_path.set(name);
            }
        }
    }

    settingsRule(c, s);

    {
        const hint = ui.div(c).column().wFull().px(14).pt(10);
        defer hint.end();
        ui.text(c, "Set a dotted path directly", .{ .size = 11.5, .color = s.palette.faint });
    }
    {
        const editor = ui.div(c).row().wFull().gap(8).itemsCenter().px(14).pb(12);
        defer editor.end();
        _ = ui.textField(c, &s.edit_path, .{
            .placeholder = "default_model or gateway.host",
            .width = .{ .px = 280 },
            .size = 12.5,
            .mono = true,
            .color = s.palette.text,
        });
        _ = ui.textField(c, &s.edit_value, .{
            .placeholder = "a value (true/false/numbers auto-typed)",
            .width = .fill,
            .size = 12.5,
            .mono = true,
            .color = s.palette.text,
        });
        if (ui.button(c, "Set path", .{ .size = 12, .icon = "equal.square" }).clicked) s.applyEdit();
        if (ui.button(c, "", .{ .variant = .ghost, .icon = "xmark", .size = 12 }).clicked) {
            s.edit_value.clear();
        }
    }
}

// --- the toast -----------------------------------------------------------

fn banner(s: *AppState, c: *ui.Context) void {
    if (s.toast.len == 0) return;
    if (!s.toastVisible(c.time)) return;

    const row = ui.div(c).row().wFull().justifyCenter().px(22).pb(10);
    defer row.end();
    const card = ui.div(c).row().wFull().maxW(content_max).gap(9).itemsCenter().px(13).py(10)
        .rounded(10)
        .bg(s.palette.danger.alpha(0.14))
        .border(s.palette.danger.alpha(0.4))
        .borderW(1);
    defer card.end();

    ui.icon(c, "exclamationmark.triangle.fill", .{ .size = 12, .color = s.palette.danger });
    clipped(c, s.toast, .{ .size = 12, .color = s.palette.text, .truncate = .ellipsis });
    ui.spacer(c);
    if (ui.button(c, "", .{ .variant = .ghost, .icon = "xmark", .size = 11 }).clicked) {
        s.dismissToast();
    }
}

// --- helpers -------------------------------------------------------------

/// Text in a box that fills its parent, so `truncate` has an edge to cut at.
/// `ui.text` sizes itself to its content, which never truncates.
fn clipped(c: *ui.Context, str: []const u8, style: ui.TextStyle) void {
    // `.auto` rather than `.fill`: a filled leaf inside a growing column is
    // measured before that column has a width, so the text was laid out one
    // character per line and the row grew to sixty points tall.
    _ = c.leaf(.{ .width = .auto }, .{ .text = .{
        .str = str,
        .style = style,
        .color = style.color orelse c.theme.text,
    } }, null);
}
