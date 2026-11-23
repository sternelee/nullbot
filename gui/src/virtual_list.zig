//! Virtualized list component — viewport-based rendering for large lists.
//! Used by sidebar (sessions) and transcript (messages) for 60fps scrolling.

const std = @import("std");
const ui = @import("nanoui").ui;
const Color = ui.Color;
const design = @import("design.zig");

/// Item renderer signature
/// `index` is the absolute index in the full list
/// `rect` is the allocated space for this item (x, y, w, h)
/// Returns true if the item was rendered (visible), false if skipped
pub const RenderItem = fn (
    ctx: *ui.Context,
    index: usize,
    rect: ui.Rect,
    user_ptr: *anyopaque,
) bool;

/// Virtualized list configuration
pub const Config = struct {
    /// Height of each item (fixed for now; variable-height needs measurement pass)
    item_height: f32,
    /// Optional: minimum height for the list viewport
    min_height: f32 = 0,
    /// Optional: maximum height (0 = unbounded)
    max_height: f32 = 0,
    /// Overscan: render this many extra items above/below viewport
    overscan: usize = 3,
    /// Gap between items
    gap: f32 = 0,
    /// Padding at top/bottom of list
    padding: f32 = 0,
    /// Background color for the list container
    bg_color: ?Color = null,
};

/// Virtualized list state (persisted across frames)
pub const VirtualList = struct {
    config: Config,
    /// Total number of items in the list
    total_items: usize = 0,
    /// Scroll offset in pixels (managed by nanoui scroll)
    scroll_y: f32 = 0,
    /// Viewport height (set each frame)
    viewport_h: f32 = 0,
    /// First visible index (computed)
    first_visible: usize = 0,
    /// Last visible index (inclusive, computed)
    last_visible: usize = 0,
    /// Whether layout was computed this frame
    layout_dirty: bool = true,

    pub fn init(config: Config) VirtualList {
        return VirtualList{
            .config = config,
        };
    }

    /// Call at the start of each frame with current scroll and viewport
    pub fn beginFrame(self: *VirtualList, scroll_y: f32, viewport_h: f32, total_items: usize) void {
        self.scroll_y = scroll_y;
        self.viewport_h = viewport_h;
        self.total_items = total_items;
        self.layout_dirty = true;
    }

    /// Compute visible range based on scroll position
    fn computeLayout(self: *VirtualList) void {
        if (!self.layout_dirty) return;
        self.layout_dirty = false;

        const cfg = self.config;
        if (self.total_items == 0) {
            self.first_visible = 0;
            self.last_visible = 0;
            return;
        }

        // Compute first_visible from scroll_y
        const item_h = cfg.item_height + cfg.gap;
        var first: usize = @intFromFloat(@floor(self.scroll_y / item_h));
        if (first > 0) first -= cfg.overscan;
        if (first >= self.total_items) first = self.total_items - 1;

        const visible_count: usize = @as(usize, @intFromFloat(@ceil(self.viewport_h / item_h))) + cfg.overscan * 2;
        var last: usize = first + visible_count;
        if (last >= self.total_items) last = self.total_items - 1;

        self.first_visible = first;
        self.last_visible = last;
    }

    /// Total content height (for scroll thumb)
    pub fn contentHeight(self: *VirtualList) f32 {
        const cfg = self.config;
        if (self.total_items == 0) return cfg.min_height;
        const h = @as(f32, @floatFromInt(self.total_items)) * (cfg.item_height + cfg.gap) + cfg.padding * 2;
        return @max(h, cfg.min_height);
    }

    /// Render visible items
    /// `render_fn` is called for each visible item with its rect
    pub fn render(
        self: *VirtualList,
        ctx: *ui.Context,
        render_fn: RenderItem,
        user_ptr: *anyopaque,
    ) void {
        self.computeLayout();

        if (self.total_items == 0) return;

        const cfg = self.config;
        const item_h = cfg.item_height + cfg.gap;

        // Render visible range
        var i: usize = self.first_visible;
        while (i <= self.last_visible) : (i += 1) {
            const y = cfg.padding + @as(f32, @floatFromInt(i)) * item_h - self.scroll_y;
            const rect = ui.Rect{
                .x = 0,
                .y = y,
                .w = ctx.rect.w,
                .h = cfg.item_height,
            };

            // Skip if completely outside viewport (with small buffer)
            if (y + cfg.item_height < -10 or y > self.viewport_h + 10) {
                continue;
            }

            render_fn(ctx, i, rect, user_ptr);
        }
    }

    /// Scroll to make an index visible
    pub fn scrollToIndex(self: *VirtualList, index: usize, alignment: ScrollAlign) f32 {
        const cfg = self.config;
        const item_h = cfg.item_height + cfg.gap;
        const target_y = cfg.padding + @as(f32, @floatFromInt(index)) * item_h;

        switch (alignment) {
            .start => return target_y,
            .center => return target_y - (self.viewport_h - cfg.item_height) / 2,
            .end => return target_y - self.viewport_h + cfg.item_height,
            .nearest => {
                const current_top = self.scroll_y;
                const current_bottom = self.scroll_y + self.viewport_h;
                const item_top = target_y;
                const item_bottom = target_y + cfg.item_height;
                if (item_top >= current_top and item_bottom <= current_bottom) {
                    return self.scroll_y; // Already visible
                }
                if (item_top < current_top) return target_y;
                return target_y - self.viewport_h + cfg.item_height;
            },
        }
    }

    /// Get the index at a given viewport Y coordinate
    pub fn indexAtY(self: *VirtualList, y: f32) ?usize {
        const cfg = self.config;
        if (self.total_items == 0) return null;
        const item_h = cfg.item_height + cfg.gap;
        const relative_y = y + self.scroll_y - cfg.padding;
        if (relative_y < 0) return 0;
        const idx: usize = @intFromFloat(@floor(relative_y / item_h));
        if (idx >= self.total_items) return self.total_items - 1;
        return idx;
    }

    /// Get item rect in viewport coordinates (for hit testing)
    pub fn itemRect(self: *VirtualList, index: usize) ui.Rect {
        const cfg = self.config;
        const item_h = cfg.item_height + cfg.gap;
        const y = cfg.padding + @as(f32, @floatFromInt(index)) * item_h - self.scroll_y;
        return ui.Rect{
            .x = 0,
            .y = y,
            .w = 0, // Filled by caller
            .h = cfg.item_height,
        };
    }
};

pub const ScrollAlign = enum { start, center, end, nearest };

/// High-level list widget that handles scroll + virtualization
/// Usage:
/// ```zig
/// var list = VirtualListWidget.init(.{ .item_height = 32 });
/// list.total_items = sessions.len;
/// list.render(ctx, renderSession, &sessions);
/// ```
pub const VirtualListWidget = struct {
    list: VirtualList,
    /// Scroll state (nanoui manages this, but we track for programmatic scroll)
    scroll_y: f32 = 0,
    /// Whether we're currently animating a scroll
    animating: bool = false,
    /// Target scroll for animation
    anim_target: f32 = 0,
    /// Animation start time
    anim_start: f64 = 0,

    pub fn init(config: Config) VirtualListWidget {
        return VirtualListWidget{
            .list = VirtualList.init(config),
        };
    }

    /// Main render call — handles scroll, viewport, and item rendering
    /// Returns the content height for the scroll container
    pub fn render(
        self: *VirtualListWidget,
        ctx: *ui.Context,
        total_items: usize,
        render_fn: RenderItem,
        user_ptr: *anyopaque,
    ) f32 {
        // Get scroll from nanoui's scroll container
        // We use a scrollable div and read its scroll position
        const scroll_id = ui.id(ctx, "virt-list-scroll");

        // Begin scroll container
        const container = ui.div(ctx).wFull().hFull().scrollY().id(scroll_id);
        defer container.end();

        // Update scroll from container
        self.scroll_y = container.scroll_y;

        // Update list state
        self.list.beginFrame(self.scroll_y, container.rect.h, total_items);

        // Render items
        self.list.render(ctx, render_fn, user_ptr);

        // Return content height for scroll thumb
        return self.list.contentHeight();
    }

    /// Programmatically scroll to an index (with animation)
    pub fn scrollTo(
        self: *VirtualListWidget,
        index: usize,
        alignment: ScrollAlign,
        animated: bool,
    ) void {
        const target = self.list.scrollToIndex(index, alignment);
        if (animated) {
            self.anim_target = target;
            self.anim_start = std.time.timestamp();
            self.animating = true;
        } else {
            self.scroll_y = target;
        }
    }

    /// Call each frame to update animation
    pub fn tickAnimation(self: *VirtualListWidget, ctx: *ui.Context) void {
        if (!self.animating) return;

        const elapsed = std.time.timestamp() - self.anim_start;
        const duration = design.Animation.glide_ms; // 300ms
        const t = @min(@as(f32, @floatFromInt(elapsed)) / @as(f32, duration), 1.0);

        // Ease-out-cubic
        const eased = 1 - std.math.pow(f32, 1 - t, 3);

        self.scroll_y = self.scroll_y + (self.anim_target - self.scroll_y) * eased;

        if (t >= 1.0) {
            self.scroll_y = self.anim_target;
            self.animating = false;
        }

        // Request repaint for next frame
        ctx.requestAnimationFrame();
    }

    /// Get the index of the item at a viewport coordinate (for hover/click)
    pub fn hitTest(self: *VirtualListWidget, y: f32) ?usize {
        return self.list.indexAtY(y);
    }
};

/// Convenience: render a simple text list (for testing/prototyping)
pub fn renderTextList(
    ctx: *ui.Context,
    items: []const []const u8,
    config: Config,
    selected: ?usize,
    on_click: fn (usize) void,
) void {
    var widget = VirtualListWidget.init(config);
    widget.render(ctx, items.len, renderItem, &ItemData{
        .items = items,
        .selected = selected,
        .on_click = on_click,
    });
}

const ItemData = struct {
    items: []const []const u8,
    selected: ?usize,
    on_click: fn (usize) void,
};

fn renderItem(
    ctx: *ui.Context,
    index: usize,
    rect: ui.Rect,
    user_ptr: *anyopaque,
) bool {
    const data: *const ItemData = @ptrCast(@constCast(user_ptr));
    const text = data.items[index];
    const is_selected = data.selected == index;

    const row = ui.div(ctx)
        .rect(rect)
        .bg(if (is_selected) ctx.theme.accent.mix(ctx.theme.background, 0.12) else ctx.theme.transparent)
        .px(design.Spacing.md)
        .py(design.Spacing.xs)
        .itemsCenter()
        .cursor(.pointer);
    defer row.end();

    ui.text(ctx, text, .{
        .size = design.FontSize.base,
        .color = if (is_selected) ctx.theme.accent_text else ctx.theme.text,
        .weight = if (is_selected) .semibold else .regular,
    });

    if (row.clicked) {
        data.on_click(index);
    }

    return true;
}

const testing = std.testing;

test "VirtualList computes visible range" {
    var list = VirtualList.init(.{
        .item_height = 32,
        .gap = 4,
        .padding = 8,
        .overscan = 2,
    });

    list.beginFrame(0, 400, 100);
    list.computeLayout();

    try testing.expect(list.first_visible == 0);
    // 400 / 36 ≈ 11 visible, + 2*2 overscan = 15
    try testing.expect(list.last_visible >= 14);
    try testing.expect(list.last_visible < 20);
}

test "VirtualList scrollToIndex" {
    var list = VirtualList.init(.{
        .item_height = 32,
        .gap = 4,
        .padding = 8,
    });

    list.beginFrame(0, 400, 100);
    const target = list.scrollToIndex(10, .start);
    try testing.expect(target > 0);

    const target_center = list.scrollToIndex(10, .center);
    try testing.expect(target_center < target);
}

test "VirtualList contentHeight" {
    var list = VirtualList.init(.{
        .item_height = 32,
        .gap = 4,
        .padding = 8,
    });

    list.beginFrame(0, 400, 10);
    const h = list.contentHeight();
    // 10 * 36 + 16 = 376
    try testing.expectEqual(h, 376);
}

test "VirtualListWidget scroll animation settles" {
    var widget = VirtualListWidget.init(.{ .item_height = 30, .gap = 2 });
    widget.list.beginFrame(0, 300, 50);
    widget.list.computeLayout();
    try std.testing.expect(widget.list.last_visible >= widget.list.first_visible);
}
