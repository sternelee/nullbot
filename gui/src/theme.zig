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

/// ChatGPT-like: neutral warm greys, a restrained green accent, and no
/// coloured bubbles. Assistant answers sit on the page background, so long
/// prose reads like a document rather than a chat log. This is the default.
pub const neutral = Palette{
    .dark = true,
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
    // The user's turn gets a subtle raised block; the assistant's stays on
    // the page background. Both are near-neutral so neither shouts.
    .user_bubble = Color.hex(0x303030),
    .bot_bubble = Color.hex(0x212121),
    .code_bg = Color.hex(0x171717),
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

/// Matrix: the terminal green the web client opens on. Every colour is the
/// one `nullclaw-chat-ui`'s `theme-matrix` uses, so the two clients look like
/// the same product.
pub const matrix = Palette{
    .dark = true,
    .bg = Color.hex(0x030a05),
    .shell = Color.hex(0x04120a),
    .panel = Color.hex(0x061a0c),
    .raised = Color.hex(0x0a2412),
    .hover = Color.hex(0x0d2e18),
    .border = Color.hex(0x1d5c2e),
    .text = Color.hex(0x00ff41),
    .muted = Color.hex(0x00aa2a),
    .faint = Color.hex(0x007a1e),
    .accent = Color.hex(0x00ff41),
    .accent_text = Color.hex(0x030a05),
    .danger = Color.hex(0xff2a2a),
    .warning = Color.hex(0xffaa00),
    .success = Color.hex(0x00ff41),
    .user_bubble = Color.hex(0x0a2412),
    .bot_bubble = Color.hex(0x061a0c),
    .code_bg = Color.hex(0x020704),
};

/// Dracula: the editor palette of the same name.
pub const dracula = Palette{
    .dark = true,
    .bg = Color.hex(0x282a36),
    .shell = Color.hex(0x21222c),
    .panel = Color.hex(0x2c2e3b),
    .raised = Color.hex(0x343746),
    .hover = Color.hex(0x44475a),
    .border = Color.hex(0x4a4d61),
    .text = Color.hex(0xf8f8f2),
    .muted = Color.hex(0xbbbbbb),
    .faint = Color.hex(0x7b7d8f),
    .accent = Color.hex(0xbd93f9),
    .accent_text = Color.hex(0x282a36),
    .danger = Color.hex(0xff5555),
    .warning = Color.hex(0xf1fa8c),
    .success = Color.hex(0x50fa7b),
    .user_bubble = Color.hex(0x3a3352),
    .bot_bubble = Color.hex(0x2c2e3b),
    .code_bg = Color.hex(0x21222c),
};

/// Synthwave: magenta on deep violet.
pub const synthwave = Palette{
    .dark = true,
    .bg = Color.hex(0x1a0b2e),
    .shell = Color.hex(0x21103a),
    .panel = Color.hex(0x271345),
    .raised = Color.hex(0x36175e),
    .hover = Color.hex(0x431d73),
    .border = Color.hex(0x5c2a8a),
    .text = Color.hex(0x00ffff),
    .muted = Color.hex(0x36c5c5),
    .faint = Color.hex(0x2a8f8f),
    .accent = Color.hex(0xff00ff),
    .accent_text = Color.hex(0x1a0b2e),
    .danger = Color.hex(0xff3366),
    .warning = Color.hex(0xf7e018),
    .success = Color.hex(0x00ffff),
    .user_bubble = Color.hex(0x3d1a63),
    .bot_bubble = Color.hex(0x271345),
    .code_bg = Color.hex(0x140823),
};

/// Amber: a monochrome phosphor terminal.
pub const amber = Palette{
    .dark = true,
    .bg = Color.hex(0x1c0f00),
    .shell = Color.hex(0x241300),
    .panel = Color.hex(0x2b1700),
    .raised = Color.hex(0x3d2100),
    .hover = Color.hex(0x4a2800),
    .border = Color.hex(0x6b3d00),
    .text = Color.hex(0xffb000),
    .muted = Color.hex(0xcc8d00),
    .faint = Color.hex(0x996a00),
    .accent = Color.hex(0xffb000),
    .accent_text = Color.hex(0x1c0f00),
    .danger = Color.hex(0xff4400),
    .warning = Color.hex(0xffea00),
    .success = Color.hex(0xffb000),
    .user_bubble = Color.hex(0x3d2100),
    .bot_bubble = Color.hex(0x2b1700),
    .code_bg = Color.hex(0x140b00),
};

pub const Named = struct {
    name: []const u8,
    palette: Palette,
};

/// The palettes the switcher offers, in the order it lists them. The first is
/// the default, and it is the one the web client opens on.
pub const choices = [_]Named{
    .{ .name = "Neutral", .palette = neutral },
    .{ .name = "Matrix", .palette = matrix },
    .{ .name = "Midnight", .palette = midnight },
    .{ .name = "Dracula", .palette = dracula },
    .{ .name = "Synthwave", .palette = synthwave },
    .{ .name = "Amber", .palette = amber },
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
    // The knob is the surface colour, not the text colour: on a monochrome
    // palette (Matrix, Amber) the text is the accent, so an off switch drew a
    // bright knob on a dark track and read as on.
    t.knob = p.panel.mix(p.text, 0.15);
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

test "choices name the palettes the switcher offers" {
    try testing.expectEqualStrings("Neutral", choices[0].name);
    try testing.expectEqualStrings("Paper", choices[choices.len - 1].name);
    // Every palette is distinguishable, so a switch is visible. `Color` is a
    // struct of floats and has no equality operator, so the comparison is on
    // the channels.
    for (choices, 0..) |a, i| {
        for (choices[i + 1 ..]) |b| {
            try testing.expect(!sameColor(a.palette.accent, b.palette.accent) or
                !sameColor(a.palette.bg, b.palette.bg));
        }
    }
}

fn sameColor(a: Color, b: Color) bool {
    return a.r == b.r and a.g == b.g and a.b == b.b and a.a == b.a;
}

test "matrix is the terminal green the web client uses" {
    try testing.expectEqual(Color.hex(0x00ff41), matrix.accent);
    try testing.expectEqual(Color.hex(0x030a05), matrix.bg);
    try testing.expect(matrix.dark);
}
