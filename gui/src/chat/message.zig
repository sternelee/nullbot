//! One message row and the markdown it draws. A full-width row: a role marker
//! on the left, the answer on the right. Nothing is right-aligned, and the
//! assistant's prose has no bubble, so a long answer reads like a page.

const std = @import("std");
const ui = @import("nanoui").ui;
const design = @import("../design.zig");
const theme = @import("../theme.zig");
const state = @import("../state.zig");
const backend = @import("../backend.zig");
const md = @import("../md.zig");
const code_block = @import("code_block.zig");

const AppState = state.AppState;

/// The circular marker at the head of a row.
fn avatar(s: *AppState, c: *ui.Context, is_user: bool, is_error: bool) void {
    const bg = if (is_error)
        s.palette.danger.alpha(0.18)
    else if (is_user)
        s.palette.raised
    else
        s.palette.accent.alpha(0.16);
    const dot = ui.div(c).w(design.Spacing.avatar_size).h(design.Spacing.avatar_size)
        .roundedFull().bg(bg).center();
    defer dot.end();
    if (is_user) {
        ui.icon(c, "person.fill", .{ .size = 15, .color = s.palette.muted });
    } else if (is_error) {
        ui.icon(c, "exclamationmark.triangle.fill", .{ .size = 15, .color = s.palette.danger });
    } else {
        ui.icon(c, "sparkles", .{ .size = 15, .color = s.palette.accent });
    }
}

/// One whole message row: avatar, name, copy affordance, body, stamp.
pub fn renderMessage(s: *AppState, c: *ui.Context, message: backend.Message, doc: ?*const md.Doc) void {
    const is_user = message.isUser();
    const is_error = std.mem.eql(u8, message.role, "error");

    const row = ui.div(c).row().wFull().gap(design.Spacing.md).itemsStart();
    defer row.end();

    avatar(s, c, is_user, is_error);

    // `grow` + `minW(0)`, as the working version had it: the grow factor takes
    // the width the avatar leaves, and the zero minimum lets a long word be
    // clipped rather than widening the row.
    const content = ui.div(c).column().grow().minW(0).gap(design.Spacing.sm).pt(3);
    defer content.end();

    // The name row, with a copy affordance at its right.
    {
        const head = ui.div(c).row().wFull().itemsCenter().gap(design.Spacing.sm);
        defer head.end();

        ui.text(c, if (is_user) "You" else if (is_error) "Error" else "nullclaw", .{
            .size = design.FontSize.sm,
            .weight = .semibold,
            .color = if (is_error) s.palette.danger else s.palette.muted,
        });

        if (is_error) {
            ui.icon(c, "exclamationmark.triangle.fill", .{ .size = 12, .color = s.palette.danger });
            ui.text(c, "could not run", .{ .size = design.FontSize.sm, .weight = .medium, .color = s.palette.danger });
        }

        ui.spacer(c);

        if (ui.button(c, "", .{ .variant = .ghost, .icon = "doc.on.doc", .size = design.FontSize.sm }).clicked) {
            c.clipboard.write(c.clipboard.ctx, message.content);
            s.say("Copied message");
        }
    }

    // The body: the user's turn on a soft block, the assistant's on the page.
    const body = if (is_user)
        ui.div(c).column().wFull().p(design.Spacing.md).rounded(design.Radius.lg).bg(s.palette.user_bubble)
    else
        ui.div(c).column().wFull();
    defer body.end();

    if (doc) |d| {
        const pal = theme.buildSemantic(s.palette);
        for (d.blocks) |block| renderBlock(s, c, block, &pal);
    } else {
        ui.text(c, message.content, .{ .size = design.FontSize.md, .color = s.palette.text, .wrap = true, .leading = 1.55 });
    }

    if (message.created_at.len > 0) {
        ui.text(c, backend.formatStamp(c.alloc(), message.created_at), .{
            .size = design.FontSize.xs,
            .color = s.palette.faint,
            .tabular = true,
        });
    }
}

/// The answer as it arrives: the same row, with a blinking caret at the end.
pub fn renderStreaming(s: *AppState, c: *ui.Context) void {
    const doc: ?*const md.Doc = if (s.stream_doc) |*d| d else null;

    const row = ui.div(c).row().wFull().gap(design.Spacing.md).itemsStart();
    defer row.end();

    avatar(s, c, false, false);

    const content = ui.div(c).column().grow().minW(0).gap(design.Spacing.sm).pt(3);
    defer content.end();
    ui.text(c, "nullclaw", .{ .size = design.FontSize.sm, .weight = .semibold, .color = s.palette.muted });

    if (doc) |d| {
        const pal = theme.buildSemantic(s.palette);
        for (d.blocks) |block| renderBlock(s, c, block, &pal);
    } else {
        ui.text(c, s.stream_text.items, .{ .size = design.FontSize.md, .color = s.palette.text, .wrap = true, .leading = 1.55 });
    }

    const blink = @mod(c.time, 1.0) < 0.55;
    var caret = ui.div(c).w(7).h(15);
    if (blink) caret = caret.rounded(2).bg(s.palette.accent);
    caret.end();
}

/// One markdown block, as the transcript draws it.
fn renderBlock(s: *AppState, c: *ui.Context, block: md.Block, pal: *const design.SemanticColor) void {
    switch (block.kind) {
        .rule => {
            _ = c.leaf(.{ .width = .fill, .height = .{ .px = 1 }, .background = s.palette.border }, .none, null);
        },
        .code => code_block.render(s, c, block, pal),
        .quote => {
            const row = ui.div(c).row().wFull().gap(design.Spacing.sm);
            defer row.end();
            _ = c.leaf(.{ .width = .{ .px = 2 }, .height = .fill, .background = s.palette.accent.alpha(0.6) }, .none, null);
            ui.text(c, block.text, blockStyle(s, block));
        },
        .bullet => {
            const row = ui.div(c).row().wFull().gap(7);
            defer row.end();
            // Indent nested bullets.
            if (block.indent > 0) {
                _ = ui.div(c).w(@as(f32, @floatFromInt(block.indent)) * 16);
            }
            // A middle dot rather than "•": the bundled font has no glyph for
            // the bullet and fell back to a degree sign.
            ui.text(c, "·", .{ .size = 13.5, .color = s.palette.muted });
            ui.text(c, block.text, blockStyle(s, block));
        },
        .table => {
            renderTable(s, c, block, pal);
        },
        .footnote => {
            const row = ui.div(c).row().wFull().gap(6);
            defer row.end();
            ui.icon(c, "text.quote", .{ .size = 10, .color = s.palette.faint });
            ui.text(c, block.text, .{ .size = design.FontSize.xs, .color = s.palette.muted, .wrap = true, .leading = 1.4 });
        },
        .heading, .paragraph => {
            ui.richText(c, block.text, block.spans, blockStyle(s, block));
        },
    }
}

fn renderTable(s: *AppState, c: *ui.Context, block: md.Block, pal: *const design.SemanticColor) void {
    _ = s;
    const box = ui.div(c).column().wFull().rounded(design.Radius.md)
        .bg(pal.code_bg).borderW(1).border(pal.code_border).clip();
    defer box.end();

    // Header row.
    {
        const head = ui.div(c).row().wFull().gap(design.Spacing.sm).px(design.Spacing.md).py(design.Spacing.sm).bg(pal.bg_tertiary);
        defer head.end();
        for (block.table_header) |cell| {
            ui.text(c, cell, .{ .size = design.FontSize.sm, .weight = .semibold, .color = pal.text_primary, .wrap = true });
        }
    }

    // Body rows: each line of block.text is a row of pipe-separated cells.
    var lines = std.mem.splitScalar(u8, block.text, '\n');
    while (lines.next()) |row_line| {
        if (row_line.len == 0) continue;
        const row = ui.div(c).row().wFull().gap(design.Spacing.sm).px(design.Spacing.md).py(design.Spacing.sm).borderW(1).border(pal.code_border);
        defer row.end();
        var cells = std.mem.splitScalar(u8, row_line, '|');
        while (cells.next()) |cell_raw| {
            const cell = std.mem.trim(u8, cell_raw, " \t");
            ui.text(c, cell, .{ .size = design.FontSize.sm, .color = pal.text_primary, .wrap = true });
        }
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
        .code => .{ .size = design.FontSize.sm, .mono = true, .color = s.palette.text, .wrap = true, .leading = 1.45 },
        .quote => .{ .size = 13.5, .italic = true, .color = s.palette.muted, .wrap = true, .leading = 1.45 },
        .bullet => .{ .size = 13.5, .color = s.palette.text, .wrap = true, .leading = 1.45 },
        .rule => .{ .size = 13.5, .color = s.palette.faint, .wrap = true },
        .paragraph => .{ .size = 13.5, .color = s.palette.text, .wrap = true, .leading = 1.45 },
        .table => .{ .size = design.FontSize.sm, .color = s.palette.text, .wrap = true },
        .footnote => .{ .size = design.FontSize.xs, .color = s.palette.muted, .wrap = true, .leading = 1.4 },
    };
}
