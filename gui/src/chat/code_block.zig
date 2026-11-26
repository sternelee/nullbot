//! A fenced code block, drawn zeron-style: a quiet header carrying the
//! language and a copy affordance, then the code on the code surface.

const std = @import("std");
const ui = @import("nanoui").ui;
const design = @import("../design.zig");
const state = @import("../state.zig");
const md = @import("../md.zig");
const highlight = @import("../highlight.zig");

const AppState = state.AppState;

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
            s.say("Copied code");
        }
    }

    // The code itself, on the surface. Selectable so a fragment can be taken.
    {
        const body = ui.div(c).column().wFull().px(design.Spacing.md).py(design.Spacing.sm);
        body.c.node(body.index).style.selectable = true;
        defer body.end();
        // Coloured by the language the fence named. The spans are the frame's
        // to free: the whole block is tokenized again on every frame, which
        // is cheap at a code block's size and keeps nothing to invalidate.
        const spans = highlight.spans(c.alloc(), block.lang, block.text, s.palette) catch &.{};
        ui.richText(c, block.text, spans, .{
            .size = design.FontSize.sm,
            .mono = true,
            .color = pal.text_primary,
            .wrap = true,
            .leading = 1.5,
        });
    }
}
