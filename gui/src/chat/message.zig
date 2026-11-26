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
            // A break reads as one only with room on both sides of it; drawn
            // flush against the text above and below it looks like a stray
            // underline.
            const pad = ui.div(c).column().wFull().py(design.Spacing.md);
            defer pad.end();
            _ = c.leaf(.{ .width = .fill, .height = .{ .px = 1 }, .background = s.palette.border }, .none, null);
        },
        .code => code_block.render(s, c, block, pal),
        .quote => quoted(s, c, block),
        .bullet => {
            const row = ui.div(c).row().wFull().gap(7);
            defer row.end();
            // Nested bullets step in, two spaces a level, as they were written.
            // A spacer rather than an empty box: a `ui.div` opened for its
            // width alone still has to be ended, and one left open is a panic.
            if (block.indent > 0) {
                const pad = ui.div(c).w(@as(f32, @floatFromInt(block.indent)) * 16);
                pad.end();
            }
            if (block.task) |done| {
                checkbox(s, c, done);
            } else {
                // A middle dot rather than "•": the bundled font has no glyph
                // for the bullet and fell back to a degree sign.
                ui.text(c, if (block.marker.len > 0) block.marker else "·", .{
                    .size = design.FontSize.md,
                    .color = s.palette.muted,
                });
            }
            anchoredText(s, c, block, if (block.task != null and block.task.?)
                taskDoneStyle(s, block)
            else
                blockStyle(s, block));
        },
        .table => renderTable(s, c, block, pal),
        .image => renderImage(s, c, block, pal),
        .footnote => {
            const row = ui.div(c).row().wFull().gap(6);
            defer row.end();
            ui.icon(c, "text.quote", .{ .size = 10, .color = s.palette.faint });
            ui.text(c, block.text, .{ .size = design.FontSize.xs, .color = s.palette.muted, .wrap = true, .leading = 1.4 });
        },
        .heading => {
            // Air above a heading, more for the higher ranks, so a section
            // starts rather than running on from the paragraph before it.
            if (block.level <= 3) {
                const pad = ui.div(c).column().wFull().pt(if (block.level <= 2) 10 else 4);
                defer pad.end();
                anchoredText(s, c, block, headingStyle(s, block.level));
            } else {
                anchoredText(s, c, block, headingStyle(s, block.level));
            }
        },
        .paragraph => anchoredText(s, c, block, blockStyle(s, block)),
    }
}

/// A quotation: a rule down its left edge for every level it is nested, so a
/// quote inside a quote reads as two, then the text.
/// A task item's box: a rounded square, filled and ticked when done, an
/// outline when not. Drawn rather than written as a character, because the
/// bundled font has no box glyph and a checkbox carries its state in shape as
/// well as in weight.
fn checkbox(s: *AppState, c: *ui.Context, done: bool) void {
    // As tall as the first line of the text beside it, and pushed down by the
    // leading so the box sits on the line rather than over it.
    const size: f32 = 14;
    const wrap = ui.div(c).row().w(size).minW(size).h(size).pt(2.5).center();
    defer wrap.end();
    const box = ui.div(c).w(size).h(size).rounded(4);
    if (done) {
        box.c.node(box.index).style.background = s.palette.accent;
    } else {
        box.c.node(box.index).style.border = s.palette.faint;
        box.c.node(box.index).style.border_width = 1.5;
    }
    defer box.end();
    if (done) ui.icon(c, "checkmark", .{ .size = 9, .weight = .bold, .color = s.palette.accent_text });
}

/// A task item that is done reads as done: its text is quieter and struck
/// through, the way a checklist shows its finished lines.
fn taskDoneStyle(s: *AppState, block: md.Block) ui.TextStyle {
    var style = blockStyle(s, block);
    style.color = s.palette.muted;
    return style;
}

fn quoted(s: *AppState, c: *ui.Context, block: md.Block) void {
    const depth: usize = @as(usize, block.indent) + 1;
    const row = ui.div(c).row().wFull().gap(design.Spacing.sm);
    defer row.end();
    // The deeper a quote is, the quieter its outermost rule: the innermost is
    // the one the eye follows.
    for (0..depth) |i| {
        const level: f32 = @floatFromInt(i);
        const alpha = 0.6 - level * 0.15;
        _ = c.leaf(.{
            .width = .{ .px = 2 },
            .height = .fill,
            .background = s.palette.accent.alpha(if (alpha > 0.2) alpha else 0.2),
        }, .none, null);
    }
    anchoredText(s, c, block, blockStyle(s, block));
}

/// A block's text with its anchors live: a footnote reference jumps to its
/// note, a link opens in the browser. The text is one leaf, so the anchors
/// are found by measuring it — the same wrap the text system laid out —
/// and an invisible box is placed over each range, as a link on a page.
fn anchoredText(s: *AppState, c: *ui.Context, block: md.Block, style: ui.TextStyle) void {
    anchoredRun(s, c, block.text, block.spans, block.anchors, style);
}

/// A run of text whose `anchors` are live: a footnote reference jumps to its
/// note, a link opens in the browser. The text is one leaf, so the ranges are
/// found by measuring it — the same wrap the text system laid out — and an
/// invisible box is placed over each, as a link on a page.
///
/// Split from `anchoredText` because a table cell is a run too, and a link in
/// a cell has to be as clickable as one in a paragraph.
fn anchoredRun(
    s: *AppState,
    c: *ui.Context,
    text: []const u8,
    spans: []const ui.Span,
    anchors: []const md.Anchor,
    style: ui.TextStyle,
) void {
    const box = ui.div(c).column().grow().minW(0);
    defer box.end();

    // Its own leaf rather than `ui.richText`, which discards the index the
    // anchors are measured from.
    const idx = c.leaf(.{ .width = .fill }, .{ .text = .{
        .str = text,
        .style = style,
        .color = style.color orelse s.palette.text,
        .spans = spans,
    } }, null);
    if (anchors.len == 0) return;

    const it = c.interact(idx, .{});
    const r = it.rect orelse return;
    // Wrap the text in the width it was given, so a range that crosses a
    // line break becomes one box per line.
    const lines = c.text.wrapAttributed(text, style, spans, r.w);
    if (lines.len == 0) return;
    const lh = c.text.lineHeight(style);

    for (anchors) |a| {
        const from = @min(a.start, text.len);
        const to = @min(a.end, text.len);
        for (lines, 0..) |line, i| {
            // A line that holds none of this range is skipped: the wrap's
            // lines do not overlap, and a range can span several.
            if (to <= line.start or from >= line.end) continue;
            const lo = @max(from, line.start);
            const hi = @min(to, line.end);
            const x0 = c.text.caretX(text[line.start..line.end], style, lo - line.start);
            const x1 = c.text.caretX(text[line.start..line.end], style, hi - line.start);
            if (x1 <= x0) continue;
            const y = @as(f32, @floatFromInt(i)) * lh;
            // A point of slack on each side: a one-character link (`a`) would
            // otherwise be a hit box a few points wide and nearly unclickable.
            const hit = ui.div(c).absolute().offset(x0 - 1, y).w(x1 - x0 + 2).h(lh);
            const target = hit.interaction();
            if (target.clicked) switch (a.mark) {
                .footnote => s.jumpToFootnote(a.number),
                .link => s.openLink(a.target),
            };
            if (target.hovered) c.cursor_hand = true;
            // A reader coming back from a note: its reference's place on the
            // screen is what the transcript needs to scroll to. Only the
            // first line of it, which is where the eye should land.
            if (a.mark == .footnote and s.reveal_reference != null and
                s.reveal_reference.? == a.number and s.reveal_reference_y == null)
            {
                s.reveal_reference_y = r.y + y;
            }
            hit.end();
        }
    }
}

/// A picture an answer pointed at. A local file is decoded and drawn; a
/// remote one is a link, because a frame may not wait on the network. What
/// cannot be shown still says what it was and where it is, so the reply does
/// not lose a sentence to a broken path.
fn renderImage(s: *AppState, c: *ui.Context, block: md.Block, pal: *const design.SemanticColor) void {
    const entry = s.image(block.image_url);
    const card = ui.div(c).column().wFull().gap(6).rounded(design.Radius.md).p(design.Spacing.sm)
        .bg(pal.code_bg).borderW(1).border(pal.code_border);
    defer card.end();

    var drawn = false;
    if (entry.bytes.len > 0) {
        // Keyed by the URL so the toolkit decodes each picture once, and sized
        // to the reading measure so a screenshot does not fill the window.
        drawn = ui.image(c, .{
            .key = block.image_url,
            .bytes = entry.bytes,
            .max_width = design.Spacing.content_max - design.Spacing.sm * 2,
            .max_height = 420,
            .radius = design.Radius.sm,
        });
    }

    // The caption: its alt text, and the path under it. For a picture that
    // was drawn that is the whole of it; for one that was not, it is the
    // explanation.
    {
        const row = ui.div(c).row().wFull().gap(6).itemsCenter();
        defer row.end();
        ui.icon(c, if (drawn) "photo" else "photo.badge.exclamationmark", .{
            .size = 11,
            .color = if (drawn) pal.text_muted else s.palette.warning,
        });
        ui.text(c, if (block.image_alt.len > 0) block.image_alt else "image", .{
            .size = design.FontSize.xs,
            .color = if (drawn) pal.text_secondary else s.palette.warning,
            .wrap = true,
        });
        ui.spacer(c);
        if (!drawn) {
            ui.text(c, entry.failure orelse "unsupported format", .{
                .size = design.FontSize.xs,
                .color = s.palette.faint,
                .mono = true,
            });
        }
    }

    // The reference itself, so a path or a URL in a reply can be used.
    {
        const response = ui.pressable(c, .{
            .direction = .row,
            .width = .fill,
            .gap = 6,
            .padding = .xy(4, 2),
            .radius = design.Radius.sm,
            .align_items = .center,
        }, s.palette.hover);
        defer ui.end(c);
        _ = response;
        ui.text(c, block.image_url, .{
            .size = design.FontSize.xs,
            .color = pal.text_link,
            .mono = true,
            .truncate = .middle,
        });
    }
}

fn renderTable(s: *AppState, c: *ui.Context, block: md.Block, pal: *const design.SemanticColor) void {
    if (block.table_header.len == 0) return;
    const n = block.table_header.len;

    const layout = measureColumns(c, block, n);
    if (layout.width <= 0) return;
    // The room the table has is its column's, not the window's: the
    // transcript caps its measure, so a table measured against the window
    // would think it fits and then paint over the margin.
    const avail = @max(160, @min(design.Spacing.content_max, c.size.w - 88));
    const scrolls = layout.width > avail;

    // The frame around the table, and the viewport that scrolls it: the
    // scroller is as wide as the room there is, and the table inside keeps
    // its own width whatever that room turns out to be.
    const frame = ui.div(c).column().wFull().rounded(design.Radius.md)
        .bg(pal.code_bg).borderW(1).border(pal.code_border).clip();
    defer frame.end();

    // The viewport that scrolls the table: as wide as the room there is when
    // the table is wider than it, and full width otherwise. Chosen before the
    // box opens — a box opened and then replaced is a box left open.
    const viewport = if (scrolls) blk: {
        const v = ui.div(c).column().w(avail).minW(avail).maxW(avail);
        v.c.node(v.index).style.scroll_x = true;
        v.c.node(v.index).style.clip = true;
        // The bar at the foot says there is more to the right without a
        // pointer over the table to find out.
        v.c.node(v.index).style.scroll_bar = true;
        v.c.node(v.index).style.scroll_bar_fades = false;
        break :blk v;
    } else ui.div(c).column().wFull();
    defer viewport.end();

    const table = if (scrolls)
        ui.div(c).column().w(layout.width).minW(layout.width).maxW(layout.width)
    else
        ui.div(c).column().wFull();
    defer table.end();

    {
        const head = ui.div(c).row().wFull().px(design.Spacing.md).py(design.Spacing.sm).gap(design.Spacing.md);
        head.c.node(head.index).style.background = pal.bg_tertiary;
        defer head.end();
        for (block.table_header, 0..) |cell, i| {
            tableCell(s, c, cell, layout.widths[i], .{
                .size = design.FontSize.sm,
                .weight = .semibold,
                .color = pal.text_primary,
                .wrap = true,
            }, alignOf(block, i));
        }
    }

    for (block.table_rows) |row| {
        const body = ui.div(c).row().wFull().px(design.Spacing.md).py(design.Spacing.sm).gap(design.Spacing.md).borderW(1).border(pal.code_border);
        defer body.end();
        for (0..n) |i| {
            tableCell(s, c, if (i < row.len) row[i] else .{ .text = "" }, layout.widths[i], .{
                .size = design.FontSize.sm,
                .color = pal.text_primary,
                .wrap = true,
            }, alignOf(block, i));
        }
    }
}

const ColumnLayout = struct {
    /// Each column's width in points, padding included.
    widths: []f32,
    /// The table's own width: every column, the gaps between them and the
    /// padding at its edges.
    width: f32,
};

/// What each column asks for: its widest cell, capped so one long paragraph
/// in a cell does not make a column a page wide on its own.
fn measureColumns(c: *ui.Context, block: md.Block, n: usize) ColumnLayout {
    const a = c.alloc();
    // The frame's own arena: both arrays go away with the frame.
    const widths = a.alloc(f32, n) catch return .{ .widths = &.{}, .width = 0 };
    @memset(widths, 0);
    const header_style: ui.TextStyle = .{ .size = design.FontSize.sm, .weight = .semibold };
    const body_style: ui.TextStyle = .{ .size = design.FontSize.sm };
    for (block.table_header, 0..) |cell, i| {
        if (i < n) widths[i] = c.text.layout(cell.text, header_style).width;
    }
    for (block.table_rows) |row| {
        for (row, 0..) |cell, i| {
            if (i >= n) break;
            widths[i] = @max(widths[i], c.text.layout(cell.text, body_style).width);
        }
    }
    // A cell wraps rather than pushing its column past this, which keeps a
    // table of prose readable when it has to scroll.
    const widest: f32 = 360;
    const edges: f32 = design.Spacing.md * 2;
    var total: f32 = edges;
    for (widths, 0..) |w, i| {
        widths[i] = @min(w, widest) + edges;
        total += widths[i];
    }
    total += design.Spacing.md * @as(f32, @floatFromInt(n -| 1));
    return .{ .widths = widths, .width = total };
}

/// A column's alignment: the `Align` of the style it is drawn with.
const Align = @TypeOf(@as(ui.Style, .{}).align_items);

/// One cell: a row of its column's width, its text placed by the separator's
/// colons. The room the text leaves over becomes a leading gap, because a
/// wrapped leaf fills its box — `align_items` cannot move glyphs that start
/// at the leaf's own left edge.
fn tableCell(s: *AppState, c: *ui.Context, cell_in: md.Cell, width: f32, style: ui.TextStyle, side: Align) void {
    const cell = ui.div(c).row().w(width).minW(width).maxW(width);
    defer cell.end();
    const content = c.text.layout(cell_in.text, style).width;
    const slack = @max(0, width - content);
    const lead = switch (side) {
        .start, .stretch => 0,
        .center => slack / 2,
        .end => slack,
    };
    if (lead > 0) {
        const gap = ui.div(c).w(lead);
        gap.end();
    }
    // The same run the prose uses, so a code span or a link in a cell is
    // drawn and clickable exactly as it is in a paragraph.
    anchoredRun(s, c, cell_in.text, cell_in.spans, cell_in.anchors, style);
}

fn alignOf(block: md.Block, i: usize) Align {
    if (i >= block.table_align.len) return .start;
    return switch (block.table_align[i]) {
        .left => .start,
        .center => .center,
        .right => .end,
    };
}

/// A heading's size and weight, one step per level. The scale is the thing
/// that says what a heading is: a reply with `#`, `##` and `###` has to read as
/// three ranks, and the first two also carry a little air above them so a
/// heading that follows a paragraph starts a section rather than continuing
/// one.
fn headingStyle(s: *AppState, level: u8) ui.TextStyle {
    // Whole points, a step apart: a line box rounds to the point, so 13.5 and
    // 13 came out the same height and the last two ranks were one size.
    const size: f32 = switch (level) {
        1 => 21,
        2 => 18,
        3 => 16,
        4 => 15,
        5 => 14,
        else => 13,
    };
    const weight: ui.Weight = switch (level) {
        1, 2, 3 => .semibold,
        4, 5 => .medium,
        else => .regular,
    };
    return .{
        .size = size,
        .weight = weight,
        .color = if (level >= 6) s.palette.muted else s.palette.text,
        .wrap = true,
        // Bigger type needs proportionally less leading, so the block reads
        // as one line of a rank rather than as a paragraph that got louder.
        .leading = if (level <= 2) 1.22 else 1.3,
    };
}

fn blockStyle(s: *AppState, block: md.Block) ui.TextStyle {
    return switch (block.kind) {
        .heading => headingStyle(s, block.level),
        .code => .{ .size = design.FontSize.sm, .mono = true, .color = s.palette.text, .wrap = true, .leading = 1.45 },
        .quote => .{ .size = 13.5, .italic = true, .color = s.palette.muted, .wrap = true, .leading = 1.45 },
        .bullet => .{ .size = 13.5, .color = s.palette.text, .wrap = true, .leading = 1.45 },
        .rule => .{ .size = 13.5, .color = s.palette.faint, .wrap = true },
        .paragraph => .{ .size = 13.5, .color = s.palette.text, .wrap = true, .leading = 1.45 },
        .table => .{ .size = design.FontSize.sm, .color = s.palette.text, .wrap = true },
        .footnote => .{ .size = design.FontSize.xs, .color = s.palette.muted, .wrap = true, .leading = 1.4 },
        .image => .{ .size = design.FontSize.xs, .color = s.palette.muted, .wrap = true },
    };
}
