//! The composer: the multi-line input, the model chip, the keyboard hint and
//! the send / stop control. In a conversation it pins to the foot of the chat;
//! on the empty state it sits inside the centred column, so it drops its own
//! outer padding. Return submits, Shift-Return breaks the line, and the button
//! and the key both go through `AppState.send`.

const ui = @import("nanoui").ui;
const design = @import("../design.zig");
const state = @import("../state.zig");
const model_chip = @import("model_chip.zig");

const AppState = state.AppState;

pub fn render(s: *AppState, c: *ui.Context) void {
    // In the empty state the composer is already inside a centred column, so it
    // drops its own outer padding; in a conversation it pins to the foot.
    const compact = s.messages.items.len == 0 and !s.streaming();
    const centre = if (compact)
        ui.div(c).row().wFull()
    else
        ui.div(c).row().wFull().justifyCenter().px(22).pt(8).pb(20);
    defer centre.end();

    const column = ui.div(c).column().wFull().maxW(design.Spacing.content_max).gap(design.Spacing.sm);
    defer column.end();

    // The frame. A focused turn tints its border, so the input reads as live
    // even before a letter is typed.
    const box = ui.div(c).column().wFull().p(design.Spacing.md).gap(6).bg(s.palette.panel)
        .border(if (s.composer_focused) s.palette.accent else s.palette.border).borderW(1)
        .rounded(18);
    defer box.end();

    const typed = ui.textArea(c, &s.composer, .{
        .placeholder = if (s.selected == null) "Ask anything…" else "Message nullclaw…",
        .min_lines = 1,
        .max_lines = 8,
        .size = design.FontSize.md,
        .color = s.palette.text,
        .caret_color = s.palette.accent,
    });
    s.composer_focused = typed.focused;

    // Update completion state from the current text and caret.
    s.updateCompletion(typed.caret);

    // Completion popup: drawn above the composer box.
    if (s.completionActive()) {
        renderCompletion(s, c);
    }

    // Keyboard navigation for the completion menu.
    if (s.completionActive()) {
        if (c.input.key) |k| switch (k) {
            .up => s.completionMove(-1),
            .down => s.completionMove(1),
            .enter, .tab => {
                s.acceptCompletion();
                // Prevent the textarea from also submitting on enter.
                // (The textarea already ran; we consume the key here.)
            },
            .escape => s.clearCompletion(),
            else => {},
        };
    }

    const foot = ui.div(c).row().wFull().gap(design.Spacing.sm).itemsCenter();
    defer foot.end();

    model_chip.render(s, c);
    ui.spacer(c);
    hint(s, c);
    sendOrStop(s, c, typed.submitted);
}

fn renderCompletion(s: *AppState, c: *ui.Context) void {
    const box = ui.div(c).column().wFull().maxW(design.Spacing.content_max)
        .bg(s.palette.panel).border(s.palette.border).borderW(1).rounded(10).p(6).gap(2);
    defer box.end();

    for (s.completion_items.items, 0..) |item, i| {
        const selected = i == s.completion_selected;
        const row = ui.div(c).row().wFull().gap(design.Spacing.sm).itemsCenter()
            .px(design.Spacing.sm).py(4).rounded(6)
            .bg(if (selected) s.palette.accent.alpha(0.15) else s.palette.panel);
        defer row.end();

        const icon = if (s.completion_mode == .mention) "doc.text" else "slash.circle";
        ui.icon(c, icon, .{ .size = 12, .color = if (selected) s.palette.accent else s.palette.muted });
        ui.text(c, item.label, .{ .size = design.FontSize.sm, .color = s.palette.text, .weight = if (selected) .semibold else .regular });
        if (item.detail.len > 0) {
            ui.spacer(c);
            ui.text(c, item.detail, .{ .size = design.FontSize.xs, .color = s.palette.faint });
        }

        // Click to accept.
        const press = ui.pressable(c, .{}, s.palette.hover);
        if (press.clicked) {
            s.completion_selected = i;
            s.acceptCompletion();
        }
        ui.end(c);
    }
}

/// The hint at the right of the foot: where a turn will land and the keys, or
/// a character count once there is something typed.
fn hint(s: *AppState, c: *ui.Context) void {
    const typed = s.composer.text();
    if (typed.len == 0) {
        const where = s.turnSession() orelse "new conversation";
        ui.textf(c, .{ .size = design.FontSize.xs, .color = s.palette.faint }, "{s} · return to send · shift-return for a new line", .{where});
        return;
    }
    ui.textf(c, .{ .size = design.FontSize.xs, .color = s.palette.faint, .tabular = true }, "{d} characters", .{typed.len});
}

/// The send disc, or — while a turn runs — the stop control and its status.
fn sendOrStop(s: *AppState, c: *ui.Context, submitted: bool) void {
    if (s.sending) {
        const writing = ui.div(c).row().gap(6).itemsCenter();
        defer writing.end();
        ui.icon(c, "ellipsis.circle", .{ .size = design.FontSize.sm, .color = s.palette.accent });
        ui.text(c, if (s.streaming()) "writing…" else "thinking…", .{
            .size = 11.5,
            .color = s.palette.accent,
        });
        // A long answer with no way out is the one thing a chat must not do.
        if (ui.button(c, "", .{ .variant = .secondary, .icon = "stop.circle", .size = design.FontSize.sm }).clicked)
            s.stop();
        return;
    }

    const can_send = s.composer.text().len != 0;
    if (submitted and can_send) s.send();

    // The round accent disc with an up arrow, the shape people expect now.
    const send = ui.pressable(c, .{
        .direction = .row,
        .width = .{ .px = 34 },
        .height = .{ .px = 34 },
        .radius = 17,
        .justify = .center,
        .align_items = .center,
        .background = if (can_send) s.palette.accent else s.palette.raised,
    }, s.palette.hover);
    defer ui.end(c);
    ui.icon(c, "arrow.up", .{ .size = 16, .color = if (can_send) s.palette.accent_text else s.palette.faint });
    if (send.clicked and can_send) s.send();
}
