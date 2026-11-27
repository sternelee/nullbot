//! The model the next turn will use, as a chip at the composer's left — where
//! zeron puts its model picker. It names a setting, so clicking it opens the
//! page that sets it rather than a picker of its own; a config that names no
//! model draws no chip rather than a guess.

const std = @import("std");
const ui = @import("nanoui").ui;
const kit = @import("nanoui").kit;
const design = @import("../design.zig");
const state = @import("../state.zig");

const AppState = state.AppState;

pub fn render(s: *AppState, c: *ui.Context) void {
    const full = s.modelLabel();
    if (full.len == 0) return;

    // The config names the model `provider/model`; the chip shows the model and
    // keeps the provider for the tooltip, where a name like "openrouter" belongs.
    const model = if (std.mem.indexOfScalar(u8, full, '/')) |slash| full[slash + 1 ..] else full;
    if (model.len == 0) return;

    const it = ui.pressable(c, .{
        .direction = .row,
        .gap = 6,
        .min_width = 0,
        .max_width = 220,
        .padding = .xy(9, 4),
        .radius = 999,
        .align_items = .center,
        .background = s.palette.raised,
    }, s.palette.hover);
    defer ui.end(c);

    ui.icon(c, "cpu", .{ .size = design.FontSize.xs, .color = s.palette.faint });
    ui.text(c, model, .{
        .size = design.FontSize.xs,
        .color = s.palette.muted,
        .truncate = .ellipsis,
    });
    kit.tooltip(c, it, c.print("{s} · open Configuration", .{full}), .{});
    if (it.clicked) s.openPage(.cfg_model);
}
