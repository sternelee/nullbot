//! Every colour the GUI uses, in one place, so the dark and light variants
//! cannot drift apart. `uiTheme` folds a palette into the nanoui theme the
//! widgets read (`c.theme`).
const ui = @import("nanoui").ui;
const Color = ui.Color;

pub const Palette = struct {
    dark: bool,
    /// The window behind everything.
    bg: Color,
    /// The sidebar.
    shell: Color,
    /// Cards and the chat header.
    panel: Color,
    /// A raised surface inside a panel: a row on hover, a chip.
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
    /// What the user typed, and what the runtime answered.
    user_bubble: Color,
    bot_bubble: Color,
    code_bg: Color,
};

/// The default: a cool near-black, blue accent.
pub const midnight = Palette{
    .dark = true,
    .bg = Color.hex(0x15151a),
    .shell = Color.hex(0x1a1a20),
    .panel = Color.hex(0x1e1e25),
    .raised = Color.hex(0x272730),
    .hover = Color.hex(0x2d2d38),
    .border = Color.hex(0x32323d),
    .text = Color.hex(0xecedf2),
    .muted = Color.hex(0x9b9baa),
    .faint = Color.hex(0x6a6a78),
    .accent = Color.hex(0x7aa2f7),
    .accent_text = Color.hex(0x101218),
    .danger = Color.hex(0xf7768e),
    .warning = Color.hex(0xe0af68),
    .success = Color.hex(0x9ece6a),
    .user_bubble = Color.hex(0x26304c),
    .bot_bubble = Color.hex(0x1e1e25),
    .code_bg = Color.hex(0x111116),
};

/// Daylight: warm paper, deeper blue accent.
pub const paper = Palette{
    .dark = false,
    .bg = Color.hex(0xf6f6f8),
    .shell = Color.hex(0xececf0),
    .panel = Color.hex(0xffffff),
    .raised = Color.hex(0xf1f1f5),
    .hover = Color.hex(0xe7e7ee),
    .border = Color.hex(0xd8d8e0),
    .text = Color.hex(0x1b1b22),
    .muted = Color.hex(0x63636f),
    .faint = Color.hex(0x8d8d99),
    .accent = Color.hex(0x2f6fed),
    .accent_text = Color.hex(0xffffff),
    .danger = Color.hex(0xd92f4b),
    .warning = Color.hex(0xa86a00),
    .success = Color.hex(0x2f8f4e),
    .user_bubble = Color.hex(0xdfe8ff),
    .bot_bubble = Color.hex(0xf1f1f5),
    .code_bg = Color.hex(0xf2f2f6),
};

pub const Named = struct {
    name: []const u8,
    palette: Palette,
};

pub const choices = [_]Named{
    .{ .name = "Midnight", .palette = midnight },
    .{ .name = "Paper", .palette = paper },
};

/// The nanoui theme for a palette: the system theme's own values for
/// everything this app does not name.
pub fn uiTheme(p: Palette) ui.Theme {
    var t: ui.Theme = if (p.dark) .dark_theme else .light;
    t.dark = p.dark;
    t.background = p.bg;
    t.surface = p.panel;
    t.surface_hover = p.hover;
    t.text = p.text;
    t.muted = p.muted;
    t.border = p.border;
    t.accent = p.accent;
    t.accent_hover = p.accent.mix(p.text, 0.16);
    t.accent_text = p.accent_text;
    t.track = p.border;
    t.knob = p.text;
    t.danger = p.danger;
    t.success = p.success;
    t.shadow = .{ .a = if (p.dark) 0.45 else 0.14 };
    return t;
}

const std = @import("std");
const testing = std.testing;

test "uiTheme keeps the palette's own colours" {
    const t = uiTheme(midnight);
    try testing.expectEqual(midnight.bg, t.background);
    try testing.expectEqual(midnight.accent, t.accent);
    try testing.expectEqual(midnight.danger, t.danger);
    try testing.expect(t.dark);
}

test "paper is the light variant" {
    const t = uiTheme(paper);
    try testing.expect(!t.dark);
    try testing.expectEqual(paper.text, t.text);
}

test "choices name both palettes" {
    try testing.expectEqualStrings("Midnight", choices[0].name);
    try testing.expectEqualStrings("Paper", choices[1].name);
}
