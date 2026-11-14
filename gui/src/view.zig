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
const md = @import("md.zig");
const state = @import("state.zig");

const AppState = state.AppState;
const Page = state.Page;

/// Wide enough for a session key and its stamp.
pub const sidebar_width: f32 = 268;
/// A comfortable measure for prose, as the runtime's own output is long.
const content_max: f32 = 860;
/// A bubble never takes the whole width; the eye needs the ragged edge.
const bubble_share: f32 = 0.84;
/// The label column in the configuration form: wide enough that a hint about
/// a dotted path stays on two lines instead of three.
const label_w: f32 = 260;
/// Every control in the configuration form is this wide, so the card reads as
/// one column instead of a select at one width and fields stretched to the
/// card's edge. `kit.select` measures in points, so this is a fixed number.
const field_w: f32 = 420;

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

fn sidebar(s: *AppState, c: *ui.Context) void {
    const bar = ui.div(c).column().w(sidebar_width).hFull().bg(s.palette.shell);
    defer bar.end();
    brand(s, c);
    sessionsHeading(s, c);
    sessionList(s, c);
    nav(s, c);
    themeSwitcher(s, c);
}

/// The palette picker, at the foot of the sidebar. The web client puts it in
/// its status bar; here the status bar is the page header, which belongs to
/// the page, so the sidebar's own foot is where a window-wide setting goes.
fn themeSwitcher(s: *AppState, c: *ui.Context) void {
    _ = c.leaf(.{
        .width = .fill,
        .height = .{ .px = 1 },
        .background = s.palette.border,
    }, .none, null);

    const wrap = ui.div(c).column().wFull().p(8).gap(4);
    defer wrap.end();

    {
        const row = ui.div(c).row().wFull().gap(6).itemsCenter();
        defer row.end();
        var picked: ?usize = @as(?usize, s.palette_index);
        const names = comptime blk: {
            var out: [theme.choices.len][]const u8 = undefined;
            for (theme.choices, 0..) |choice, i| out[i] = choice.name;
            break :blk out;
        };
        if (kit.select(c, "palette", &names, &picked, .{
            .placeholder = "Theme…",
            .width = sidebar_width - 16 - 34,
        })) {
            if (picked) |i| s.setPalette(i);
        }
        if (kit.iconButton(c, "info.circle", .{ .size = .sm }).clicked) {
            s.diagnostics_open = true;
        }
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
    diagLine(s, c, "Gateway", if (s.daemon.running()) "running" else "stopped", false);
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

fn brand(s: *AppState, c: *ui.Context) void {
    const row = ui.div(c).row().wFull().px(14).pt(14).pb(6).gap(9).itemsCenter();
    defer row.end();

    ui.icon(c, "cube", .{ .size = 17, .color = s.palette.accent });
    ui.text(c, "nullclaw", .{ .size = 14.5, .weight = .semibold, .color = s.palette.text });
    ui.spacer(c);

    if (ui.button(c, "", .{ .variant = .ghost, .icon = "square.and.pencil", .size = 13 }).clicked) {
        s.newChat();
    }
    if (ui.button(c, "", .{ .variant = .ghost, .icon = "arrow.clockwise", .size = 13 }).clicked) {
        s.refreshSessions();
    }
}

fn sessionsHeading(s: *AppState, c: *ui.Context) void {
    const row = ui.div(c).row().wFull().px(16).pt(10).pb(6).gap(8).itemsCenter();
    defer row.end();
    ui.text(c, "Sessions", .{
        .size = 10.5,
        .weight = .semibold,
        .color = s.palette.muted,
        .tracking = 0.7,
    });
    ui.spacer(c);
    if (s.sessions_running) {
        ui.text(c, "…", .{ .size = 11, .color = s.palette.faint });
    } else {
        ui.textf(c, .{ .size = 11, .color = s.palette.faint, .tabular = true }, "{d}", .{s.sessions.items.len});
    }
}

fn sessionList(s: *AppState, c: *ui.Context) void {
    const list = ui.div(c).column().grow().wFull().minW(0).scrollY().gap(2).px(8).pb(6);
    defer list.end();

    if (s.sessions.items.len == 0) {
        const empty = ui.div(c).column().wFull().p(10).gap(4);
        defer empty.end();
        if (s.sessions_running) {
            ui.text(c, "Reading sessions…", .{ .size = 12, .color = s.palette.faint });
        } else {
            ui.text(c, "No sessions yet", .{ .size = 12, .color = s.palette.faint });
            ui.text(c, "Send a message to start one.", .{ .size = 11, .color = s.palette.faint });
        }
        return;
    }

    for (s.sessions.items, 0..) |session, i| {
        sessionRow(s, c, session, i);
    }
}

fn sessionRow(s: *AppState, c: *ui.Context, session: backend.Session, index: usize) void {
    const selected = s.selected != null and s.selected.? == index;
    const it = ui.pressable(c, .{
        .direction = .column,
        .width = .fill,
        .gap = 3,
        .padding = .xy(10, 8),
        .radius = 8,
        .background = if (selected) s.palette.accent.alpha(0.17) else s.palette.shell,
        .border = if (selected) s.palette.accent.alpha(0.45) else null,
        .border_width = if (selected) 1 else 0,
    }, s.palette.hover);
    defer ui.end(c);

    clipped(c, session.key, .{
        .size = 12,
        .mono = true,
        .color = if (selected) s.palette.text else s.palette.muted,
        .truncate = .middle,
    });

    const meta = ui.div(c).row().wFull().gap(6).itemsCenter();
    defer meta.end();
    ui.textf(c, .{ .size = 10, .color = s.palette.faint, .tabular = true }, "{d} turns", .{session.turns()});
    ui.spacer(c);
    // Through `c.print`: the frame's memory outlives this call, and a local
    // buffer would be gone before the frame is drawn.
    ui.text(c, backend.formatStamp(c.alloc(), session.last_active), .{
        .size = 10,
        .color = s.palette.faint,
        .tabular = true,
    });

    if (it.clicked and !selected) s.select(index);
}

fn nav(s: *AppState, c: *ui.Context) void {
    _ = c.leaf(.{
        .width = .fill,
        .height = .{ .px = 1 },
        .background = s.palette.border,
    }, .none, null);

    // Sized to its rows rather than to a fixed height: sixteen pages do not
    // fit in the 318 points this used to reserve, and the list was cut off
    // mid-row at the bottom of the sidebar. The session list above it grows
    // into whatever room is left.
    const box = ui.div(c).column().wFull().gap(1).p(8);
    defer box.end();
    for (state.nav) |page| {
        navRow(s, c, page);
    }
}

fn navRow(s: *AppState, c: *ui.Context, page: Page) void {
    const active = s.page == page;
    const it = ui.pressable(c, .{
        .direction = .row,
        .width = .fill,
        .gap = 10,
        .align_items = .center,
        .padding = .xy(10, 7),
        .radius = 7,
        .background = if (active) s.palette.accent.alpha(0.18) else s.palette.shell,
    }, s.palette.hover);
    defer ui.end(c);

    ui.icon(c, page.icon(), .{
        .size = 13,
        .frame = 16,
        .color = if (active) s.palette.accent else s.palette.muted,
    });
    ui.text(c, page.label(), .{
        .size = 12.5,
        .weight = if (active) .medium else .regular,
        .color = if (active) s.palette.text else s.palette.muted,
    });

    if (it.clicked) s.openPage(page);
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
        .config => configPage(s, c),
        else => jsonPage(s, c),
    }
    banner(s, c);
    diagnosticsPanel(s, c);
}

fn header(s: *AppState, c: *ui.Context) void {
    const bar = ui.div(c).row().wFull().px(22).pt(16).pb(10).gap(12).itemsCenter();
    defer bar.end();

    // The title block is closed before the trailing controls are drawn: a
    // deferred `end` would keep the column open and stack them under the
    // subtitle instead of putting them on the right.
    {
        const titles = ui.div(c).column().grow().minW(0).gap(3);
        defer titles.end();
        ui.text(c, s.page.label(), .{ .size = 15.5, .weight = .semibold, .color = s.palette.text });
        clipped(c, subtitle(s, c), .{ .size = 11.5, .color = s.palette.faint, .truncate = .middle });
    }

    if (s.busy()) {
        ui.text(c, "working…", .{ .size = 11, .color = s.palette.accent });
    }
    // The configuration page has its own Reload and Save, and `config show`
    // is not what its form edits, so a Run button here would only replace
    // the page with an unrelated JSON dump.
    if (s.page == .config) {
        configStatusChip(s, c);
    } else if (s.page == .chat) {
        if (ui.button(c, "Refresh", .{ .size = 12, .icon = "arrow.clockwise" }).clicked) {
            s.refreshSessions();
        }
    } else {
        if (ui.button(c, "Run", .{ .variant = .primary, .size = 12, .icon = "play.fill" }).clicked) {
            s.runPage();
        }
    }
}

fn subtitle(s: *AppState, c: *ui.Context) []const u8 {
    if (s.page == .chat) {
        if (s.selected) |i| {
            if (i < s.sessions.items.len) return s.sessions.items[i].key;
        }
        return "a new conversation";
    }
    if (s.page == .config) return "the runtime's own config.json";
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
    if (s.messages.items.len == 0) {
        emptyChat(s, c);
    } else {
        transcript(s, c);
    }
    composer(s, c);
}

fn emptyChat(s: *AppState, c: *ui.Context) void {
    const box = ui.div(c).column().grow().wFull().center().gap(10).px(22);
    defer box.end();

    ui.icon(c, "sparkles", .{ .size = 26, .color = s.palette.accent });
    ui.text(c, "Ask nullclaw anything", .{ .size = 17, .weight = .semibold, .color = s.palette.text });
    ui.text(c, "Turns run through the same agent loop as the command line.", .{
        .size = 12.5,
        .color = s.palette.faint,
    });

    const chips = ui.div(c).row().gap(8).pt(6);
    defer chips.end();
    for (suggestions) |prompt| {
        if (ui.button(c, prompt, .{ .size = 12 }).clicked) {
            s.composer.set(prompt);
            s.send();
        }
    }
}

fn transcript(s: *AppState, c: *ui.Context) void {
    const box = ui.div(c).column().grow().minW(0).wFull().scrollY().px(22).py(6);
    // The newest turn is the one you want to read.
    box.c.node(box.index).style.follow_end = true;
    defer box.end();

    const centre = ui.div(c).row().wFull().justifyCenter();
    defer centre.end();
    const column = ui.div(c).column().wFull().maxW(content_max).gap(14);
    defer column.end();

    for (s.messages.items, 0..) |message, i| {
        const doc: ?*const md.Doc = if (i < s.docs.items.len) &s.docs.items[i] else null;
        messageBubble(s, c, message, doc);
    }

    // The answer being written, drawn where the finished one will land.
    if (s.streaming()) streamingBubble(s, c);
}

/// The assistant's answer as it arrives: the same bubble, with a caret at the
/// end so a pause reads as "still writing" rather than "done".
fn streamingBubble(s: *AppState, c: *ui.Context) void {
    const doc: ?*const md.Doc = if (s.stream_doc) |*d| d else null;
    const row = ui.div(c).row().wFull();
    defer row.end();

    const width = bubbleWidth(s, c, doc, s.stream_text.items);
    const bubble = ui.div(c).column().w(width).gap(8).p(13).rounded(13).bg(s.palette.bot_bubble);
    defer bubble.end();

    if (doc) |d| {
        for (d.blocks) |block| block_(s, c, block);
    } else {
        ui.text(c, s.stream_text.items, .{ .size = 13.5, .color = s.palette.text, .wrap = true, .leading = 1.4 });
    }

    // The caret: a small block that blinks with the clock, so a stalled
    // provider and a finished answer do not look the same.
    const caret = ui.div(c).row().gap(4).itemsCenter();
    defer caret.end();
    // The frame's own clock: no wall clock to read, and it stops when the
    // window stops drawing, which is exactly when the caret should stop.
    const blink = @mod(c.time, 1.0) < 0.55;
    // A block that is drawn or not: the same width either way, so the text
    // above it does not reflow when the caret blinks.
    var caret_box = ui.div(c).w(7).h(14);
    if (blink) caret_box = caret_box.rounded(2).bg(s.palette.accent);
    caret_box.end();
}

fn messageBubble(s: *AppState, c: *ui.Context, message: backend.Message, doc: ?*const md.Doc) void {
    const is_user = message.isUser();
    const is_error = std.mem.eql(u8, message.role, "error");

    var row = ui.div(c).row().wFull();
    row = if (is_user) row.justifyEnd() else row;
    defer row.end();

    const width = bubbleWidth(s, c, doc, message.content);
    const bubble = ui.div(c).column().w(width).gap(8).p(13).rounded(13).bg(if (is_user)
        s.palette.user_bubble
    else if (is_error)
        s.palette.danger.alpha(0.13)
    else
        s.palette.bot_bubble);
    defer bubble.end();

    if (is_error) {
        const lead = ui.div(c).row().gap(7).itemsCenter();
        defer lead.end();
        ui.icon(c, "exclamationmark.triangle.fill", .{ .size = 12, .color = s.palette.danger });
        ui.text(c, "could not run", .{ .size = 11.5, .weight = .medium, .color = s.palette.danger });
    }

    if (doc) |d| {
        for (d.blocks) |block| {
            block_(s, c, block);
        }
    } else {
        ui.text(c, message.content, .{ .size = 13.5, .color = s.palette.text, .wrap = true, .leading = 1.4 });
    }

    // The stamp the runtime recorded, when it recorded one. A message the
    // window made up (a failed turn, a local note) has none, and inventing
    // one would say the runtime wrote it.
    if (message.created_at.len > 0) {
        const foot = ui.div(c).row().wFull().gap(6).itemsCenter();
        defer foot.end();
        if (is_user) ui.spacer(c);
        ui.text(c, backend.formatStamp(c.alloc(), message.created_at), .{
            .size = 10,
            .color = s.palette.faint,
            .tabular = true,
        });
    }
}

fn block_(s: *AppState, c: *ui.Context, block: md.Block) void {
    switch (block.kind) {
        .rule => {
            _ = c.leaf(.{
                .width = .fill,
                .height = .{ .px = 1 },
                .background = s.palette.border,
            }, .none, null);
        },
        .code => {
            const box = ui.div(c).column().wFull().p(10).rounded(8).bg(s.palette.code_bg);
            defer box.end();
            ui.text(c, block.text, blockStyle(s, block));
        },
        .quote => {
            const row = ui.div(c).row().wFull().gap(9);
            defer row.end();
            _ = c.leaf(.{
                .width = .{ .px = 2 },
                .height = .fill,
                .background = s.palette.accent.alpha(0.6),
            }, .none, null);
            ui.text(c, block.text, blockStyle(s, block));
        },
        .bullet => {
            const row = ui.div(c).row().wFull().gap(7);
            defer row.end();
            ui.text(c, "•", .{ .size = 13.5, .color = s.palette.muted });
            ui.text(c, block.text, blockStyle(s, block));
        },
        .heading, .paragraph => {
            ui.richText(c, block.text, block.spans, blockStyle(s, block));
        },
    }
}

fn blockStyle(s: *AppState, block: md.Block) ui.TextStyle {
    return switch (block.kind) {
        .heading => .{
            .size = switch (block.level) {
                1 => 17,
                2 => 15.5,
                3 => 14.5,
                else => 13.5,
            },
            .weight = .semibold,
            .color = s.palette.text,
            .wrap = true,
            .leading = 1.35,
        },
        .code => .{ .size = 12, .mono = true, .color = s.palette.text, .wrap = true, .leading = 1.45 },
        .quote => .{ .size = 13.5, .italic = true, .color = s.palette.muted, .wrap = true, .leading = 1.45 },
        .bullet => .{ .size = 13.5, .color = s.palette.text, .wrap = true, .leading = 1.45 },
        .rule => .{ .size = 13.5, .color = s.palette.faint, .wrap = true },
        .paragraph => .{ .size = 13.5, .color = s.palette.text, .wrap = true, .leading = 1.45 },
    };
}

/// How wide a bubble wants to be: as wide as its widest line, up to a share of
/// the column. Measuring before laying out keeps a short reply a short bubble
/// instead of a full-width band.
fn bubbleWidth(s: *AppState, c: *ui.Context, doc: ?*const md.Doc, fallback: []const u8) f32 {
    var widest: f32 = 0;
    if (doc) |d| {
        for (d.blocks) |block| {
            if (block.kind == .rule) continue;
            var style = blockStyle(s, block);
            style.wrap = false;
            const extra: f32 = switch (block.kind) {
                .code => 20,
                .bullet => 18,
                .quote => 20,
                else => 0,
            };
            widest = @max(widest, c.text.width(block.text, style) + extra);
        }
    }
    if (widest == 0) {
        var style = ui.TextStyle{ .size = 13.5, .color = s.palette.text };
        style.wrap = false;
        widest = c.text.width(fallback, style);
    }
    const cap = content_max * bubble_share;
    return @max(140, @min(widest + 28, cap));
}

fn composer(s: *AppState, c: *ui.Context) void {
    const centre = ui.div(c).row().wFull().justifyCenter().px(22).pt(8).pb(18);
    defer centre.end();
    const column = ui.div(c).column().wFull().maxW(content_max).gap(7);
    defer column.end();

    const box = ui.div(c).column().wFull().p(10).gap(8).bg(s.palette.panel)
        .border(s.palette.border).borderW(1).rounded(12);
    defer box.end();

    const typed = ui.textArea(c, &s.composer, .{
        .placeholder = if (s.selected == null) "Start a new conversation…" else "Ask nullclaw…",
        .min_lines = 1,
        .max_lines = 8,
        .color = s.palette.text,
        .caret_color = s.palette.accent,
    });

    const foot = ui.div(c).row().wFull().gap(8).itemsCenter();
    defer foot.end();
    composerHint(s, c);
    ui.spacer(c);

    // Where this message will land. A new chat has a draft key the runtime
    // has not seen yet, so the line says which conversation is being opened
    // rather than leaving the person to guess.
    if (s.sending) {
        const writing = ui.div(c).row().gap(6).itemsCenter();
        defer writing.end();
        ui.icon(c, "ellipsis.circle", .{ .size = 11, .color = s.palette.accent });
        ui.text(c, if (s.streaming()) "writing…" else "thinking…", .{
            .size = 11.5,
            .color = s.palette.accent,
        });
    }

    // While a turn runs the primary button stops it: a long answer with no
    // way out is the one thing a chat window must not do.
    if (s.sending) {
        const halt = ui.button(c, "", .{
            .variant = .secondary,
            .icon = "stop.circle",
            .size = 12,
        });
        if (halt.clicked) s.stop();
        return;
    }

    const send = ui.button(c, "", .{
        .variant = .primary,
        .icon = "arrow.up",
        .size = 12,
        .disabled = s.composer.text().len == 0,
    });
    if (send.clicked or typed.submitted) s.send();
}

fn composerHint(s: *AppState, c: *ui.Context) void {
    const typed = s.composer.text();
    if (typed.len == 0) {
        // The session name, so a window with several chats open says which
        // one the next message belongs to.
        const where = s.turnSession() orelse "new conversation";
        ui.textf(c, .{ .size = 10.5, .color = s.palette.faint }, "{s} · return to send · shift-return for a new line", .{where});
        return;
    }
    ui.textf(c, .{ .size = 10.5, .color = s.palette.faint, .tabular = true }, "{d} characters", .{typed.len});
}

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
    const box = ui.div(c).column().hFull().wFull().maxW(content_max).gap(10);
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
        // The command failed: its own words are the content, so they get a
        // card that says so rather than a blank pane with a toast that
        // disappears. The card hugs its text instead of filling the window.
        const card = ui.div(c).column().wFull().gap(8).p(14).rounded(10)
            .bg(s.palette.danger.alpha(0.08))
            .border(s.palette.danger.alpha(0.35)).borderW(1);
        defer card.end();
        {
            const head = ui.div(c).row().wFull().gap(7).itemsCenter();
            defer head.end();
            ui.icon(c, "exclamationmark.triangle.fill", .{ .size = 12, .color = s.palette.danger });
            ui.text(c, "The runtime's command failed", .{
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
    const scroller = ui.div(c).column().grow().minW(0).wFull().scrollY().clip().gap(14);
    defer scroller.end();

    if (rows.totalRows() == 0) {
        // The command answered, and the answer was nothing. Say that, with
        // the command that would change it, rather than drawing an empty
        // pair of brackets.
        const empty = ui.div(c).column().wFull().center().gap(7).py(40);
        defer empty.end();
        ui.icon(c, "doc.text", .{ .size = 22, .color = s.palette.faint });
        ui.text(c, emptyTitle(s.page), .{ .size = 13, .color = s.palette.muted });
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

fn configPage(s: *AppState, c: *ui.Context) void {
    // Left-aligned with the header, like the JSON pages: the form is a column
    // of labelled rows, and a centred one would drift away from its own title.
    //
    // The page is two bands: the form scrolls, and the action bar is pinned
    // under it. Save used to sit after five sections, so on a short window it
    // was below the fold — the one control the page exists for, out of reach
    // until you scrolled to the end.
    // `hFull` on the band is what makes the split work: without it the column
    // grows to its content, the scroller never has less room than it needs,
    // and the action bar ends up below the fold — pinned to nothing.
    const outer = ui.div(c).column().grow().minW(0).wFull().px(22).pt(16);
    defer outer.end();

    // The scroller is closed before the bar is drawn. A `defer` here would
    // leave it open for the rest of the function, and the bar would be drawn
    // inside it — scrolling away with the form instead of staying put.
    {
        // `clip` as well as `scrollY`: a scrolling box does not cut its
        // content by itself, so the form ran on over the pinned bar and drew
        // through it.
        const scroller = ui.div(c).column().grow().minW(0).wFull().scrollY().clip();
        defer scroller.end();
        const page = ui.div(c).column().wFull().maxW(content_max).gap(16).pb(16);
        defer page.end();

        // The shell header already names the page and its file, so this page
        // starts with the runtime card rather than a second title.
        runtimeStatusCard(s, c);
        if (s.config == null) configMissingNotice(s, c);
        commonConfigForm(s, c);
        advancedSection(s, c);
    }

    configActions(s, c);
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
    const running = s.daemon.running();
    const card = configCard(c, s);
    defer card.end();
    {
        const row = ui.div(c).row().wFull().gap(10).itemsCenter();
        defer row.end();
        ui.icon(c, "circle.lefthalf.filled", .{ .size = 13, .color = if (running) s.palette.success else s.palette.warning });
        ui.text(c, "Built-in nullclaw runtime", .{ .size = 13.5, .weight = .semibold, .color = s.palette.text });
        kit.tag(c, if (running) "running" else "stopped", .{
            .status = if (running) .success else .neutral,
            .pill = true,
        });
        ui.spacer(c);
        if (ui.button(c, if (running) "Restart" else "Start", .{ .size = 12, .icon = "arrow.clockwise" }).clicked) {
            s.restartDaemon();
            s.say("runtime restarted");
        }
        if (running) {
            if (ui.button(c, "Stop", .{ .size = 12, .variant = .secondary }).clicked) {
                s.daemon.stop();
                s.say("runtime stopped");
            }
        }
    }
    ui.text(c, "The GUI starts a gateway for the chat and the JSON pages. Restart it after changing where it binds.", .{ .size = 11.5, .color = s.palette.muted, .wrap = true });
    kit.separator(c, .{});
    const status = s.daemonStatusText(c.alloc());
    configFact(s, c, "Status", status, if (running) s.palette.success else s.palette.muted, false);
    configFact(s, c, "Binary", s.exe, s.palette.faint, true);
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

/// A small muted heading above a card. Returns an open column the caller
/// must `end` — the same shape nanoterm uses for its settings sections.
fn configSection(c: *ui.Context, s: *AppState, title: []const u8, note: []const u8) ui.Div {
    const col = ui.div(c).column().wFull().gap(8);
    ui.text(c, title, .{ .size = 12, .weight = .semibold, .color = s.palette.muted });
    if (note.len > 0) ui.text(c, note, .{ .size = 11.5, .color = s.palette.faint, .wrap = true });
    return col;
}

fn configCard(c: *ui.Context, s: *AppState) ui.Div {
    return ui.div(c).column().wFull().gap(12).p(14).rounded(10).bg(s.palette.panel).border(s.palette.border).borderW(1);
}

/// Left column of a setting: its name and a short sentence about it.
fn fieldLabel(c: *ui.Context, s: *AppState, label: []const u8, hint: []const u8) void {
    const col = ui.div(c).column().w(label_w).minW(label_w).gap(2);
    defer col.end();
    ui.text(c, label, .{ .size = 12.5, .color = s.palette.text });
    if (hint.len > 0) ui.text(c, hint, .{ .size = 11, .color = s.palette.faint, .wrap = true });
}

fn formField(s: *AppState, c: *ui.Context, label: []const u8, hint: []const u8, placeholder: []const u8, buf: *ui.TextBuffer) void {
    formFieldOpt(s, c, label, hint, placeholder, buf, .{});
}

/// The same, with the field's own options: a secret is drawn as bullets.
fn formFieldOpt(
    s: *AppState,
    c: *ui.Context,
    label: []const u8,
    hint: []const u8,
    placeholder: []const u8,
    buf: *ui.TextBuffer,
    opts: struct { password: bool = false },
) void {
    const row = ui.div(c).row().wFull().gap(12).itemsCenter();
    defer row.end();
    fieldLabel(c, s, label, hint);
    const field = ui.div(c).column().grow().minW(0);
    defer field.end();
    _ = ui.textField(c, buf, .{
        .placeholder = placeholder,
        .width = .{ .px = field_w },
        .size = 12.5,
        .mono = true,
        .password = opts.password,
        .color = c.theme.text,
    });
}

/// A provider pick: the ids the runtime knows, plus the one the config
/// names if it is not in that list. A select rather than free text, so the
/// value can only be one the runtime actually understands.
fn providerField(s: *AppState, c: *ui.Context) void {
    const row = ui.div(c).row().wFull().gap(12).itemsCenter();
    defer row.end();
    fieldLabel(c, s, "Default provider", "Before the slash in `model.primary`.");
    if (s.cfg_provider_options.len == 0) {
        ui.text(c, "No providers known to the runtime.", .{ .size = 12, .color = s.palette.muted });
        return;
    }
    var picked: ?usize = @as(?usize, s.cfg_default_provider);
    // `kit.select` measures in points while the fields beside it fill, so it
    // is given the widest fixed width that still lines up with them.
    const field = ui.div(c).grow().minW(0);
    defer field.end();
    if (kit.select(c, "default-provider", s.cfg_provider_options, &picked, .{ .placeholder = "Choose…", .width = field_w })) {
        s.cfg_default_provider = picked orelse 0;
    }
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
    {
        const row = ui.div(c).row().wFull().gap(12).itemsCenter();
        defer row.end();
        fieldLabel(c, s, "Autonomy level", "`autonomy.level`.");
        if (ui.segmented(c, &names, &picked)) s.cfg_autonomy_level.set(values[picked]);
        ui.spacer(c);
    }
    if (picked == 2) {
        ui.text(c, "Yolo removes confirmations. Only use it on a workspace you trust.", .{ .size = 11, .color = s.palette.danger, .wrap = true });
    }
}

fn toggleField(s: *AppState, c: *ui.Context, label: []const u8, hint: []const u8, value: *bool) void {
    const row = ui.div(c).row().wFull().gap(12).itemsCenter();
    defer row.end();
    fieldLabel(c, s, label, hint);
    // In the field column, not pushed to the card's edge: a switch floating
    // a thousand points from its label reads as belonging to another row.
    const field = ui.div(c).row().w(field_w).minW(field_w).gap(8).itemsCenter();
    defer field.end();
    _ = ui.toggle(c, "", value);
    ui.text(c, if (value.*) "Enabled" else "Disabled", .{
        .size = 11.5,
        .color = if (value.*) s.palette.text else s.palette.faint,
    });
}

/// The settings worth a control on this page: what answers, where it works,
/// which servers it can call, and whether it runs on a schedule. The rest of
/// `config.json` stays in the advanced fold — a form that mirrors every key is
/// a worse editor than the file itself.
fn commonConfigForm(s: *AppState, c: *ui.Context) void {
    {
        const section = configSection(c, s, "Provider", "Which model answers, and the credentials used to reach it.");
        defer section.end();
        const card = configCard(c, s);
        defer card.end();
        providerField(s, c);
        formField(s, c, "Default model", "After the slash in `model.primary`.", "anthropic/claude-sonnet-4, openai/gpt-5.3-codex", &s.cfg_default_model);
        // A key is a secret: bullets, not the value on screen and in every
        // screenshot of this page.
        formFieldOpt(s, c, "Provider API key", "`models.providers.<name>.api_key`.", "API key for the default provider", &s.cfg_api_key, .{ .password = true });
        formField(s, c, "Provider base URL", "`models.providers.<name>.base_url`.", "https://api.example.com/v1", &s.cfg_api_base_url);
    }
    {
        const section = configSection(c, s, "Workspace", "The directory the agent may read and write.");
        defer section.end();
        const card = configCard(c, s);
        defer card.end();
        formField(s, c, "Workspace path", "`workspace`. Empty uses the runtime's default.", "~/.nullclaw/workspace", &s.cfg_workspace);
    }
    {
        const section = configSection(c, s, "MCP servers", "One per line: `name command`. The agent can call these.");
        defer section.end();
        const card = configCard(c, s);
        defer card.end();
        mcpField(s, c);
    }
    {
        const section = configSection(c, s, "Cron", "Whether scheduled tasks run, and how often the scheduler wakes.");
        defer section.end();
        const card = configCard(c, s);
        defer card.end();
        toggleField(s, c, "Run scheduled tasks", "`cron.enabled`.", &s.cfg_cron_enabled);
        formField(s, c, "Scheduler interval", "Minutes between ticks, `cron.interval_minutes`.", "30", &s.cfg_cron_interval);
    }
    {
        const section = configSection(c, s, "Skills", "Installed skills, read from the workspace. Manage them with `nullclaw skills`.");
        defer section.end();
        const card = configCard(c, s);
        defer card.end();
        skillsSummary(s, c);
    }
    {
        const section = configSection(c, s, "Capabilities", "What this build has, and what the config turns on.");
        defer section.end();
        const card = configCard(c, s);
        defer card.end();
        capabilitiesSummary(s, c);
    }
}

/// The MCP list: one `name command` per line, in a box that grows with it.
fn mcpField(s: *AppState, c: *ui.Context) void {
    const row = ui.div(c).row().wFull().gap(12).itemsStart();
    defer row.end();
    fieldLabel(c, s, "Servers", "`mcp_servers`. One `name command` per line.");
    const field = ui.div(c).column().grow().minW(0).gap(4);
    defer field.end();
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
    const row = ui.div(c).row().wFull().gap(12).itemsCenter();
    defer row.end();
    fieldLabel(c, s, "Memory engine", "`memory.backend`.");
    const field = ui.div(c).grow().minW(0);
    defer field.end();
    var picked: ?usize = @as(?usize, s.cfg_memory_backend);
    if (kit.select(c, "memory-backend", &state.memory_backends, &picked, .{
        .placeholder = "Choose…",
        .width = field_w,
    })) {
        s.cfg_memory_backend = picked orelse 0;
    }
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
fn advancedSection(s: *AppState, c: *ui.Context) void {
    {
        const head = ui.div(c).row().wFull().gap(8).itemsCenter();
        defer head.end();
        const label = if (s.show_advanced_config) "Hide advanced" else "Show advanced · raw JSON and dotted paths";
        const icon = if (s.show_advanced_config) "chevron.up" else "chevron.down";
        if (ui.button(c, label, .{ .variant = .ghost, .size = 12, .icon = icon }).clicked) {
            s.show_advanced_config = !s.show_advanced_config;
        }
        ui.spacer(c);
        if (s.config) |doc| {
            if (doc.object()) |map| {
                ui.textf(c, .{ .size = 11, .color = s.palette.faint, .tabular = true }, "{d} top-level keys", .{map.count()});
            }
        }
    }
    if (!s.show_advanced_config) return;
    {
        const section = configSection(c, s, "Advanced", "Set any dotted path directly, or read the whole file as a JSON tree.");
        defer section.end();
        configEditor(s, c);
        jsonView(s, c);
    }
}

fn configEditor(s: *AppState, c: *ui.Context) void {
    const wrap = ui.div(c).column().wFull().gap(6);
    defer wrap.end();
    ui.text(c, "Set a dotted path directly (advanced)", .{ .size = 11.5, .color = s.palette.faint });
    const editor = ui.div(c).row().wFull().gap(8).itemsCenter();
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
    _ = c.leaf(.{ .width = .fill }, .{ .text = .{
        .str = str,
        .style = style,
        .color = style.color orelse c.theme.text,
    } }, null);
}
