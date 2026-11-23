//! Session row component — compact/detailed modes, hover actions, project icons.
//! Inspired by zeron's sidebar rows: status left, icons, name, badges, time right.

const std = @import("std");
const ui = @import("nanoui").ui;
const design = @import("../design.zig");

/// What a row needs to draw itself.
pub const RowData = struct {
    title: []const u8,
    preview: ?[]const u8 = null,
    last_active: []const u8,
    project_path: ?[]const u8 = null,
    is_pinned: bool = false,
    is_archived: bool = false,
    unseen: bool = false,
    indicator: Indicator = .idle,
};

pub const Indicator = enum {
    idle,
    working,
    awaiting_input,
    failed,
    waiting,
};

/// Row rendering mode.
pub const RowMode = enum {
    compact,
    detailed,

    pub fn height(self: RowMode) f32 {
        return switch (self) {
            .compact => design.Spacing.row_compact,
            .detailed => design.Spacing.row_detailed,
        };
    }
};

/// The hover action a row offers (the caller owns the behaviour).
pub const HoverAction = enum { none, archive, unarchive };

/// What a drawn row reported back this frame.
pub const Result = struct {
    clicked: bool = false,
    hovered: bool = false,
    action: HoverAction = .none,
};

/// Draw one session row. Returns what the pointer did over it.
pub fn render(
    ctx: *ui.Context,
    data: RowData,
    mode: RowMode,
    selected: bool,
    dark: bool,
    pal: *const design.SemanticColor,
) Result {
    const row_h = mode.height();

    const base = if (selected) pal.bg_selected else ui.Color.transparent;
    const it = ui.pressable(ctx, .{
        .direction = .row,
        .width = .fill,
        .height = .{ .px = row_h },
        .gap = design.Spacing.sm,
        .padding = .xy(design.Spacing.sm, 0),
        .radius = design.Radius.md,
        .align_items = .center,
        .background = base,
    }, pal.bg_hover);
    defer ui.end(ctx);

    const hovered = it.hovered;

    // Status dot.
    statusDot(ctx, data.indicator, pal);

    // Project monogram (detailed only, and only when we know a path).
    if (mode == .detailed) {
        if (data.project_path) |path| monogram(ctx, path, dark);
    }

    // Title + optional preview.
    {
        const center = ui.div(ctx).column().grow().minW(0).gap(1);
        defer center.end();

        ui.text(ctx, data.title, .{
            .size = design.FontSize.base,
            .weight = if (selected) .semibold else .regular,
            .color = if (selected) pal.accent else pal.text_primary,
            .truncate = .ellipsis,
        });

        if (mode == .detailed) {
            if (data.preview) |preview| {
                if (preview.len > 0) {
                    ui.text(ctx, preview, .{
                        .size = design.FontSize.xs,
                        .color = pal.text_muted,
                        .truncate = .ellipsis,
                    });
                }
            }
        }
    }

    // Right side: the stamp, an unseen dot, a pin, and the hover slot.
    var action: HoverAction = .none;
    {
        const right = ui.div(ctx).row().itemsCenter().gap(design.Spacing.xs);
        defer right.end();

        if (data.last_active.len > 0) {
            ui.text(ctx, data.last_active, .{
                .size = design.FontSize.xs,
                .color = pal.text_faint,
                .tabular = true,
            });
        }

        if (data.unseen) {
            const dot = ui.div(ctx).w(7).h(7).roundedFull().bg(pal.accent);
            dot.end();
        }

        if (data.is_pinned) {
            ui.icon(ctx, "pin.fill", .{ .size = 10, .color = pal.accent });
        }

        if (hovered) {
            if (data.is_archived) {
                action = .unarchive;
                ui.icon(ctx, "arrow.uturn.backward", .{ .size = 12, .color = pal.text_muted });
            } else {
                action = .archive;
                ui.icon(ctx, "archivebox", .{ .size = 12, .color = pal.text_muted });
            }
        }
    }

    return .{ .clicked = it.clicked, .hovered = hovered, .action = action };
}

fn statusDot(ctx: *ui.Context, indicator: Indicator, pal: *const design.SemanticColor) void {
    const color = switch (indicator) {
        .idle => pal.text_faint,
        .working => pal.accent,
        .awaiting_input => pal.warning,
        .failed => pal.danger,
        .waiting => pal.accent,
    };
    const dot = ui.div(ctx).w(7).h(7).roundedFull().bg(color);
    dot.end();
}

fn monogram(ctx: *ui.Context, path: []const u8, dark: bool) void {
    const mono = design.monogramColor(path, dark);
    const box = ui.div(ctx).w(20).h(20).rounded(design.Radius.sm).itemsCenter().justifyCenter().bg(mono.bg);
    defer box.end();

    const name = std.fs.path.basename(path);
    const letter = if (name.len > 0) name[0..1] else "P";
    ui.text(ctx, letter, .{
        .size = design.FontSize.xs,
        .weight = .semibold,
        .color = mono.fg,
    });
}

/// A section header with a collapse chevron and a count. Returns true when
/// the header was clicked (the caller flips its collapsed state).
pub fn renderSectionHeader(
    ctx: *ui.Context,
    name: []const u8,
    count: usize,
    collapsed: bool,
    is_pinned: bool,
    pal: *const design.SemanticColor,
) bool {
    const it = ui.pressable(ctx, .{
        .direction = .row,
        .width = .fill,
        .height = .{ .px = design.Spacing.row_compact },
        .gap = design.Spacing.sm,
        .padding = .xy(design.Spacing.sm, 0),
        .radius = design.Radius.sm,
        .align_items = .center,
    }, pal.bg_hover);
    defer ui.end(ctx);

    ui.icon(ctx, if (collapsed) "chevron.right" else "chevron.down", .{ .size = 10, .color = pal.text_faint });

    ui.text(ctx, name, .{
        .size = design.FontSize.sm,
        .weight = .semibold,
        .color = pal.text_secondary,
        .tracking = 0.4,
    });

    if (is_pinned) {
        ui.icon(ctx, "pin.fill", .{ .size = 9, .color = pal.accent });
    }

    ui.spacer(ctx);
    {
        const badge = ui.div(ctx).px(6).h(16).itemsCenter().rounded(design.Radius.full).bg(pal.bg_tertiary);
        defer badge.end();
        ui.textf(ctx, .{ .size = design.FontSize.xs, .color = pal.text_faint, .tabular = true }, "{d}", .{count});
    }

    return it.clicked;
}

/// The empty-list placeholder.
pub fn renderEmpty(ctx: *ui.Context, title: []const u8, hint: []const u8, pal: *const design.SemanticColor) void {
    const box = ui.div(ctx).column().wFull().p(design.Spacing.md).gap(design.Spacing.xs);
    defer box.end();
    ui.text(ctx, title, .{ .size = design.FontSize.sm, .color = pal.text_muted });
    ui.text(ctx, hint, .{ .size = design.FontSize.xs, .color = pal.text_faint });
}

test "RowMode heights come from the design system" {
    try std.testing.expectEqual(design.Spacing.row_compact, RowMode.compact.height());
    try std.testing.expectEqual(design.Spacing.row_detailed, RowMode.detailed.height());
}
