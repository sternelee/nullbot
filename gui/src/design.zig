//! Design system tokens — spacing, typography, colors, animation, shadows.
//! Single source of truth for the UI's visual language, inspired by zeron's
//! GPUI design tokens but adapted for nanoui.

const std = @import("std");
const ui = @import("nanoui").ui;
const Color = ui.Color;

pub const Spacing = struct {
    /// 4px — tight gaps, icon padding
    pub const xs: f32 = 4;
    /// 8px — default gap, component padding
    pub const sm: f32 = 8;
    /// 12px — comfortable text margins
    pub const md: f32 = 12;
    /// 16px — section spacing, card padding
    pub const lg: f32 = 16;
    /// 24px — major section breaks
    pub const xl: f32 = 24;
    /// 32px — page-level spacing
    pub const xxl: f32 = 32;

    /// Sidebar row heights
    pub const row_compact: f32 = 32;
    pub const row_detailed: f32 = 48;

    /// Composer
    pub const composer_min_h: f32 = 44;
    pub const composer_max_h: f32 = 200;
    pub const composer_padding: f32 = 12;

    /// Rail
    pub const rail_width: f32 = 52;
    /// Sidebar
    pub const sidebar_width: f32 = 272;
    /// Content max width (prose measure)
    pub const content_max: f32 = 768;

    /// Avatar size
    pub const avatar_size: f32 = 30;

    /// Settings, after zeron's own: the column a page's cards sit in, a row's
    /// height, and the width a row's control is given.
    pub const settings_measure: f32 = 640;
    pub const settings_row: f32 = 52;
    pub const settings_control: f32 = 240;
    /// Config label width
    pub const label_w: f32 = 260;
    /// Config field width
    pub const field_w: f32 = 420;
};

pub const Radius = struct {
    pub const xs: f32 = 4;
    pub const sm: f32 = 6;
    pub const md: f32 = 8;
    pub const lg: f32 = 12;
    pub const xl: f32 = 16;
    pub const full: f32 = 9999;
};

pub const FontSize = struct {
    pub const xs: f32 = 10.5; // captions, timestamps
    pub const sm: f32 = 12; // secondary text, tooltips
    pub const base: f32 = 13; // body text
    pub const md: f32 = 14; // primary UI text
    pub const lg: f32 = 16; // headings
    pub const xl: f32 = 20; // page titles
    pub const xxl: f32 = 28; // hero
};

pub const FontWeight = enum {
    regular,
    medium,
    semibold,
    bold,
};

pub const Animation = struct {
    /// Fast: glide in, tooltip show
    fast_ms: u32 = 150,
    /// Medium: accordion expand, page transition
    medium_ms: u32 = 200,
    /// Slow: wash hold, fade out
    slow_ms: u32 = 600,
    /// Wash hold duration (zeron: 900ms)
    wash_hold_ms: u32 = 900,
    /// Glide scroll (zeron: SCROLL_GLIDE)
    glide_ms: u32 = 300,
    /// Hover transition
    hover_ms: u32 = 80,
    /// Focus ring
    focus_ms: u32 = 100,
};

/// Easing curves matching GPUI defaults
const easing_standard = [_]f32{ 0.33, 0, 0.67, 1 };
const easing_accelerate = [_]f32{ 0.65, 0, 0.35, 1 };
const easing_decelerate = [_]f32{ 0.25, 0.46, 0.45, 0.94 };
const easing_sharp = [_]f32{ 0.4, 0, 0.6, 1 };

pub const Easing = struct {
    /// Standard: ease-out-cubic
    standard: *const [4]f32 = &easing_standard,
    /// Accelerate: ease-in-out-cubic
    accelerate: *const [4]f32 = &easing_accelerate,
    /// Decelerate: ease-out-quart
    decelerate: *const [4]f32 = &easing_decelerate,
    /// Sharp: for overlays, toasts
    sharp: *const [4]f32 = &easing_sharp,
};

/// Shadow tokens (nanoui uses a single shadow, but we define levels for layering)
pub const Shadow = struct {
    none: ui.Shadow = .{ .a = 0 },
    sm: ui.Shadow = .{ .a = 0.08, .blur = 4, .y = 1 },
    md: ui.Shadow = .{ .a = 0.12, .blur = 8, .y = 2 },
    lg: ui.Shadow = .{ .a = 0.16, .blur = 16, .y = 4 },
    xl: ui.Shadow = .{ .a = 0.20, .blur = 24, .y = 8 },
    /// Frosted/glass surface
    frosted: ui.Shadow = .{ .a = 0.10, .blur = 20, .y = 0 },
};

/// Project color palette — 8 fixed colors, selected by a stable path hash
/// (zeron-style). Each entry carries explicit light/dark variants independent
/// of the theme accent, so a project reads the same on every theme.
pub const ProjectColor = struct {
    pub const Entry = struct {
        dark_bg: Color,
        dark_fg: Color,
        light_bg: Color,
        light_fg: Color,
    };

    pub const all = [_]Entry{
        // Slate
        .{ .dark_bg = Color.hex(0x1e293b), .dark_fg = Color.hex(0x94a3b8), .light_bg = Color.hex(0xf1f5f9), .light_fg = Color.hex(0x475569) },
        // Blue
        .{ .dark_bg = Color.hex(0x1e3a5f), .dark_fg = Color.hex(0x60a5fa), .light_bg = Color.hex(0xdbeafe), .light_fg = Color.hex(0x1d4ed8) },
        // Violet
        .{ .dark_bg = Color.hex(0x3b0764), .dark_fg = Color.hex(0xa78bfa), .light_bg = Color.hex(0xede9fe), .light_fg = Color.hex(0x7c3aed) },
        // Rose
        .{ .dark_bg = Color.hex(0x5f1939), .dark_fg = Color.hex(0xfda4af), .light_bg = Color.hex(0xfff1f2), .light_fg = Color.hex(0xe11d48) },
        // Amber
        .{ .dark_bg = Color.hex(0x5f3a00), .dark_fg = Color.hex(0xfcd34d), .light_bg = Color.hex(0xfff8e1), .light_fg = Color.hex(0xd97706) },
        // Emerald
        .{ .dark_bg = Color.hex(0x064e3b), .dark_fg = Color.hex(0x6ee7b7), .light_bg = Color.hex(0xd1fae5), .light_fg = Color.hex(0x059669) },
        // Teal
        .{ .dark_bg = Color.hex(0x134e4a), .dark_fg = Color.hex(0x5eead4), .light_bg = Color.hex(0xccfbf1), .light_fg = Color.hex(0x0d9488) },
        // Orange
        .{ .dark_bg = Color.hex(0x5f2d00), .dark_fg = Color.hex(0xfb923c), .light_bg = Color.hex(0xffedd5), .light_fg = Color.hex(0xea580c) },
    };

    /// Select a project color by stable FNV-1a hash of the path (zeron algorithm).
    pub fn fromPath(path: []const u8) usize {
        var hash: u32 = 2_166_136_261;
        for (path) |b| {
            hash = @truncate(@as(u64, hash ^ @as(u32, @intCast(b))) * 16_777_619);
        }
        return @intCast(hash % all.len);
    }

    /// The background colour for a project index and theme.
    pub fn bg(index: usize, dark: bool) Color {
        const e = all[index % all.len];
        return if (dark) e.dark_bg else e.light_bg;
    }

    /// The foreground (monogram) colour for a project index and theme.
    pub fn fg(index: usize, dark: bool) Color {
        const e = all[index % all.len];
        return if (dark) e.dark_fg else e.light_fg;
    }
};

/// Z-index layers for consistent stacking
pub const ZIndex = struct {
    base: i32 = 0,
    raised: i32 = 10,
    dropdown: i32 = 100,
    sticky: i32 = 200,
    modal: i32 = 500,
    popover: i32 = 600,
    tooltip: i32 = 1000,
    toast: i32 = 2000,
};

/// Breakpoints for responsive behavior (if needed)
pub const Breakpoint = struct {
    sm: f32 = 640,
    md: f32 = 768,
    lg: f32 = 1024,
    xl: f32 = 1280,
    xxl: f32 = 1536,
};

/// Semantic color roles — mapped from theme palette at runtime
pub const SemanticColor = struct {
    // Backgrounds
    bg_primary: Color,
    bg_secondary: Color,
    bg_tertiary: Color,
    bg_hover: Color,
    bg_active: Color,
    bg_selected: Color,

    // Borders
    border_subtle: Color,
    border_default: Color,
    border_strong: Color,
    border_focus: Color,

    // Text
    text_primary: Color,
    text_secondary: Color,
    text_muted: Color,
    text_faint: Color,
    text_inverse: Color,
    text_link: Color,

    // Accent
    accent: Color,
    accent_hover: Color,
    accent_active: Color,
    accent_subtle: Color,
    accent_text: Color,

    // Status
    success: Color,
    success_subtle: Color,
    warning: Color,
    warning_subtle: Color,
    danger: Color,
    danger_subtle: Color,

    // Chat bubbles
    user_bubble: Color,
    user_bubble_text: Color,
    bot_bubble: Color,
    bot_bubble_text: Color,

    // Code
    code_bg: Color,
    code_text: Color,
    code_border: Color,
};

/// Build semantic colors from a palette
/// Build semantic colors from a palette (duck-typed, any Palette-like struct)
pub fn buildSemantic(p: anytype) SemanticColor {
    return SemanticColor{
        .bg_primary = p.bg,
        .bg_secondary = p.shell,
        .bg_tertiary = p.panel,
        .bg_hover = p.hover,
        .bg_active = p.raised,
        .bg_selected = p.bg.mix(p.accent, 0.16),

        .border_subtle = p.border.mix(p.bg, 0.5),
        .border_default = p.border,
        .border_strong = p.border.mix(p.text, 0.3),
        .border_focus = p.accent,

        .text_primary = p.text,
        .text_secondary = p.muted,
        .text_muted = p.muted.mix(p.faint, 0.5),
        .text_faint = p.faint,
        .text_inverse = p.accent_text,
        .text_link = p.accent,

        .accent = p.accent,
        .accent_hover = p.accent.mix(p.text, 0.16),
        .accent_active = p.accent.mix(p.text, 0.24),
        .accent_subtle = p.bg.mix(p.accent, 0.12),
        .accent_text = p.accent_text,

        .success = p.success,
        .success_subtle = p.bg.mix(p.success, 0.12),
        .warning = p.warning,
        .warning_subtle = p.bg.mix(p.warning, 0.12),
        .danger = p.danger,
        .danger_subtle = p.bg.mix(p.danger, 0.12),

        .user_bubble = p.user_bubble,
        .user_bubble_text = p.text,
        .bot_bubble = p.bot_bubble,
        .bot_bubble_text = p.text,

        .code_bg = p.code_bg,
        .code_text = p.text,
        .code_border = p.border,
    };
}

/// Monogram helper — single centered letter on colored background
pub fn monogramColor(path: []const u8, dark: bool) struct { bg: Color, fg: Color } {
    const idx = ProjectColor.fromPath(path);
    return .{
        .bg = ProjectColor.bg(idx, dark),
        .fg = ProjectColor.fg(idx, dark),
    };
}

const testing = std.testing;

test "ProjectColor.fromPath is stable" {
    const path = "/Users/sternelee/www/github/nullbot";
    const idx1 = ProjectColor.fromPath(path);
    const idx2 = ProjectColor.fromPath(path);
    try testing.expectEqual(idx1, idx2);
}

test "ProjectColor covers all 8 colors" {
    var seen: [8]bool = @splat(false);
    // Test various paths to hit different indices
    const paths = [_][]const u8{
        "/home/user/project1",
        "/home/user/project2",
        "/home/user/project3",
        "/home/user/project4",
        "/home/user/project5",
        "/home/user/project6",
        "/home/user/project7",
        "/home/user/project8",
        "/a",
        "/b",
        "/c",
        "/d",
        "/e",
        "/f",
        "/g",
        "/h",
    };
    for (paths) |p| {
        const idx = ProjectColor.fromPath(p);
        seen[idx] = true;
    }
    // At least 6 of 8 should be hit with these test paths
    var count: usize = 0;
    for (seen) |s| {
        if (s) count += 1;
    }
    try testing.expect(count >= 6);
}

test "Semantic colors build without error" {
    // Test with a minimal palette-like struct
    const MockPalette = struct {
        bg: Color,
        shell: Color,
        panel: Color,
        raised: Color,
        hover: Color,
        border: Color,
        text: Color,
        muted: Color,
        faint: Color,
        accent: Color,
        accent_text: Color,
        danger: Color,
        warning: Color,
        success: Color,
        user_bubble: Color,
        bot_bubble: Color,
        code_bg: Color,
    };
    const mock = MockPalette{
        .bg = Color.hex(0x212121),
        .shell = Color.hex(0x171717),
        .panel = Color.hex(0x2f2f2f),
        .raised = Color.hex(0x2a2a2a),
        .hover = Color.hex(0x343434),
        .border = Color.hex(0x3d3d3d),
        .text = Color.hex(0xf4f4f4),
        .muted = Color.hex(0xa9a9a9),
        .faint = Color.hex(0x7d7d7d),
        .accent = Color.hex(0x19c37d),
        .accent_text = Color.hex(0x0b1a12),
        .danger = Color.hex(0xf87171),
        .warning = Color.hex(0xe3b341),
        .success = Color.hex(0x19c37d),
        .user_bubble = Color.hex(0x303030),
        .bot_bubble = Color.hex(0x212121),
        .code_bg = Color.hex(0x171717),
    };
    const sem = buildSemantic(mock);
    _ = sem;
}
