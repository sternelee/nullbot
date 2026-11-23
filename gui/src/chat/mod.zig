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
/// running. The box follows its end so the newest turn stays in view, and its
/// text is selectable so a passage can be copied out.
pub fn renderTranscript(s: *AppState, c: *ui.Context) void {
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
}
