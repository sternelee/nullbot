//! The conversation body: a scrolling, centred transcript of message rows and
//! the live streaming row. Rendering is a plain function of `AppState`, so a
//! frame allocates nothing beyond what nanoui's own layout needs.

const ui = @import("nanoui").ui;
const design = @import("../design.zig");
const state = @import("../state.zig");
const md = @import("../md.zig");
const message = @import("message.zig");

const AppState = state.AppState;

/// Draw the transcript: every message, then the streaming answer if a turn is
/// running, and — when the answers cited anything — the notes they cited.
/// The box follows its end so the newest turn stays in view, and its text is
/// selectable so a passage can be copied out.
pub fn renderTranscript(s: *AppState, c: *ui.Context) void {
    // Its id, taken before the box opens, so a footnote row drawn inside it
    // can move it: the scroller's own offset is how far down it has come.
    const scroller_id = c.peekId("transcript-scroll");
    ui.key(c, "transcript-scroll");
    const box = ui.div(c).column().grow().minW(0).wFull().scrollY().px(22).py(18);
    box.c.node(box.index).style.follow_end = true;
    box.c.node(box.index).style.selectable = true;
    defer box.end();

    const centre = ui.div(c).row().wFull().justifyCenter();
    defer centre.end();
    const column = ui.div(c).column().wFull().maxW(design.Spacing.content_max).gap(22);
    defer column.end();

    for (s.messages.items, 0..) |msg, i| {
        const doc: ?*const md.Doc = if (i < s.docs.items.len) &s.docs.items[i] else null;
        message.renderMessage(s, c, msg, doc);
    }

    if (s.streaming()) message.renderStreaming(s, c);

    notes(s, c, scroller_id, c.rects.get(scroller_id));

    // Coming back from a note: the message that cites it recorded where its
    // reference landed on the screen, and this turns that into an offset.
    if (s.reveal_reference_y) |y| if (c.rects.get(scroller_id)) |sr| {
        const offset = c.scroll.get(scroller_id) orelse 0;
        // A little above the reference, so the sentence it sits in is read
        // whole rather than started under the header.
        const want = offset + (y - sr.y) - 28;
        c.scroll.put(c.gpa, scroller_id, @max(0, want)) catch {};
        s.reveal_reference = null;
        s.reveal_reference_y = null;
    };
}

/// The answer's footnotes, one row each, under a rule: what a reference in
/// the prose jumps to, and where a click on its number comes back from.
/// A reference whose note was never written has nothing to reach, so only
/// the notes a document defines are drawn.
fn notes(s: *AppState, c: *ui.Context, scroller_id: u64, scroller_rect: ?ui.Rect) void {
    const list = citedFootnotes(s);
    if (list.len == 0) return;

    _ = c.leaf(.{ .width = .fill, .height = .{ .px = 1 }, .background = s.palette.border }, .none, null);

    const block = ui.div(c).column().wFull().gap(6).pt(4);
    defer block.end();

    for (list) |note| {
        const row = ui.div(c).row().wFull().gap(8).itemsStart().rounded(6);
        defer row.end();

        // The number is the way back: it was the way here, and a reader who
        // has read the note wants the sentence they were on, not the top.
        const back = ui.button(c, "", .{
            .variant = .ghost,
            .icon = "arrow.uturn.backward",
            .size = design.FontSize.xs,
        });
        if (back.clicked) s.returnToReference(note.number);

        ui.textf(c, .{ .size = design.FontSize.xs, .color = s.palette.accent, .tabular = true }, "{d}", .{note.number});
        ui.richText(c, if (note.text.len > 0) note.text else "(no text)", message.deckInline(c, note.spans, s.palette.panel, s.palette.accent), .{
            .size = design.FontSize.xs,
            .color = s.palette.muted,
            .wrap = true,
            .leading = 1.45,
        });

        // A jump asked for from a reference in the prose lands here: the
        // row knows where it is, and the scroller how far down it has come,
        // so the offset that puts this row at the top is arithmetic.
        if (s.reveal_footnote) |want| {
            if (want == note.number) if (row.interaction().rect) |r| if (scroller_rect) |sr| {
                const offset = c.scroll.get(scroller_id) orelse 0;
                c.scroll.put(c.gpa, scroller_id, @max(0, offset + (r.y - sr.y) - 12)) catch {};
                s.reveal_footnote = null;
            };
        }
    }
}

/// The footnotes the answers cite: the first document that defined any.
fn citedFootnotes(s: *AppState) []const md.Footnote {
    for (s.docs.items) |*doc| {
        if (doc.footnotes.len > 0) return doc.footnotes;
    }
    return &.{};
}
