//! A fenced code block, drawn zeron-style: a quiet header carrying the
//! language and a copy affordance, then the code on the code surface.

const std = @import("std");
const ui = @import("nanoui").ui;
const design = @import("../design.zig");
const state = @import("../state.zig");
const md = @import("../md.zig");
const highlight = @import("../highlight.zig");

const AppState = state.AppState;

/// How many lines the source has: one more than its newlines, and none for an
/// empty block.
fn countLines(text: []const u8) usize {
    if (text.len == 0) return 0;
    var n: usize = 1;
    for (text) |c| {
        if (c == '\n') n += 1;
    }
    return n;
}

/// The text up to the end of its `n`th line — the part a folded block shows.
fn firstLines(text: []const u8, n: usize) []const u8 {
    var seen: usize = 0;
    for (text, 0..) |c, i| {
        if (c != '\n') continue;
        seen += 1;
        if (seen == n) return text[0..i];
    }
    return text;
}

/// Draw a code block. `block.lang` names the language when the fence had one.
pub fn render(s: *AppState, c: *ui.Context, block: md.Block, pal: *const design.SemanticColor) void {
    const box = ui.div(c).column().wFull().rounded(design.Radius.md)
        .bg(pal.code_bg).borderW(1).border(pal.code_border).clip();
    defer box.end();

    // The header: language on the left, copy on the right.
    {
        const head = ui.div(c).row().wFull().itemsCenter().gap(design.Spacing.sm)
            .px(design.Spacing.md).h(30).borderW(1).border(pal.code_border);
        // Only the bottom hairline would be ideal; nanoui has one border colour
        // per box, so the header borrows a faint fill instead.
        head.c.node(head.index).style.background = pal.bg_tertiary;
        defer head.end();

        const lang = if (block.lang.len > 0) block.lang else "code";
        ui.text(c, lang, .{
            .size = design.FontSize.xs,
            .color = pal.text_muted,
            .mono = true,
        });
        ui.spacer(c);

        const copy = ui.button(c, "Copy", .{
            .variant = .ghost,
            .icon = "doc.on.doc",
            .size = design.FontSize.xs,
        });
        if (copy.clicked) {
            c.clipboard.write(c.clipboard.ctx, block.text);
            // What went on the clipboard, said back: a reply can hold several
            // blocks, and "Copied code" alone does not say which.
            s.sayf("Copied the {s} block", .{if (block.lang.len > 0) block.lang else "code"});
        }
    }

    // A long block folds: the first lines are drawn, the rest is behind a
    // control that says how much is behind it. A reply can carry a whole
    // file, and a reader scrolling past it to reach the next message is the
    // reason a chat is worse than a diff for this.
    const key = AppState.codeKey(block.text, block.lang);
    const lines = countLines(block.text);
    const folds = lines > state.code_fold_lines;
    const open = s.codeOpen(key, lines);
    const shown = if (folds and !open) firstLines(block.text, state.code_fold_lines) else block.text;

    // The code itself, on the surface. Selectable so a fragment can be taken.
    {
        const body = ui.div(c).column().wFull().px(design.Spacing.md).py(design.Spacing.sm);
        body.c.node(body.index).style.selectable = true;
        defer body.end();
        // Coloured by the language the fence named. The spans are the frame's
        // to free: the whole block is tokenized again on every frame, which
        // is cheap at a code block's size and keeps nothing to invalidate.
        const spans = highlight.spans(c.alloc(), block.lang, shown, s.palette) catch &.{};
        ui.richText(c, shown, spans, .{
            .size = design.FontSize.sm,
            .mono = true,
            .color = pal.text_primary,
            .wrap = true,
            .leading = 1.5,
        });
    }

    if (folds) {
        // The control sits at the foot of the block, over the surface: the
        // count is the point of it — "Show all 42 lines" says what unfolding
        // costs, which a bare chevron does not.
        const foot = ui.div(c).row().wFull().px(design.Spacing.md).pb(design.Spacing.sm).pt(2);
        defer foot.end();
        const remaining = lines - state.code_fold_lines;
        const label = if (open)
            c.print("Show fewer ({d} more lines)", .{remaining})
        else
            c.print("Show all {d} lines", .{lines});
        const more = ui.button(c, label, .{
            .variant = .ghost,
            .icon = if (open) "chevron.up" else "chevron.down",
            .size = design.FontSize.xs,
        });
        if (more.clicked) s.toggleCode(key, lines);
    }
}
