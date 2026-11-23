//! A small markdown reader for what an agent actually writes back: headings,
//! bullets, numbered lists, quotes, fenced code, rules, `code`, **bold** and
//! *italic*. Anything it does not know stays literal text, so a reply that is
//! not markdown still reads correctly.
//!
//! `parse` keeps the source alive: every `Block.text` and `ui.Span` points into
//! buffers the returned `Doc` owns, and `Doc.deinit` frees them.
const std = @import("std");
const ui = @import("nanoui").ui;

pub const Kind = enum { paragraph, heading, bullet, code, rule, quote };

pub const Block = struct {
    kind: Kind,
    /// The line as drawn, with its markdown markers removed.
    text: []const u8,
    /// Styles over `text`, by byte offset.
    spans: []ui.Span = &.{},
    /// 1..6 for a heading, 0 otherwise.
    level: u8 = 0,
    /// A code block's fence info string (`zig` in ```zig), empty otherwise.
    lang: []const u8 = "",
};

pub const Doc = struct {
    arena: std.heap.ArenaAllocator,
    blocks: []Block = &.{},

    pub fn deinit(self: *Doc) void {
        self.arena.deinit();
        self.* = undefined;
    }

    /// The first plain line, for a session row's subtitle.
    pub fn firstLine(self: *const Doc) []const u8 {
        for (self.blocks) |b| {
            if (b.kind == .paragraph or b.kind == .heading) return b.text;
        }
        return "";
    }
};

pub fn parse(gpa: std.mem.Allocator, source: []const u8) !Doc {
    var arena = std.heap.ArenaAllocator.init(gpa);
    errdefer arena.deinit();
    const a = arena.allocator();

    var blocks: std.ArrayListUnmanaged(Block) = .empty;
    var lines = std.mem.splitScalar(u8, source, '\n');
    var fence: std.ArrayListUnmanaged(u8) = .empty;

    while (lines.next()) |raw| {
        const line = std.mem.trimEnd(u8, raw, " \t\r");
        const trimmed = std.mem.trimStart(u8, line, " \t");
        if (trimmed.len == 0) continue;

        if (std.mem.startsWith(u8, trimmed, "```")) {
            // The info string after the fence names the language (`zig`).
            const info = std.mem.trimStart(u8, trimmed[3..], " \t");
            const lang = if (info.len > 0) try a.dupe(u8, info) else "";
            // Everything up to the closing fence is literal.
            fence.clearRetainingCapacity();
            while (lines.next()) |body| {
                const body_trimmed = std.mem.trimStart(u8, body, " \t");
                if (std.mem.startsWith(u8, body_trimmed, "```")) break;
                if (fence.items.len > 0) try fence.append(a, '\n');
                try fence.appendSlice(a, std.mem.trimEnd(u8, body, "\r"));
            }
            try blocks.append(a, .{ .kind = .code, .text = fence.items, .lang = lang });
            continue;
        }

        if (isRule(trimmed)) {
            try blocks.append(a, .{ .kind = .rule, .text = "" });
            continue;
        }

        if (headingLevel(trimmed)) |level| {
            const rest = std.mem.trimStart(u8, trimmed[level..], " \t");
            const inlined = try emphasize(a, rest);
            try blocks.append(a, .{ .kind = .heading, .text = inlined.text, .spans = inlined.spans, .level = level });
            continue;
        }

        if (bulletRest(trimmed)) |rest| {
            const inlined = try emphasize(a, rest);
            try blocks.append(a, .{ .kind = .bullet, .text = inlined.text, .spans = inlined.spans });
            continue;
        }

        if (std.mem.startsWith(u8, trimmed, "> ")) {
            const inlined = try emphasize(a, trimmed[2..]);
            try blocks.append(a, .{ .kind = .quote, .text = inlined.text, .spans = inlined.spans });
            continue;
        }

        const inlined = try emphasize(a, trimmed);
        try blocks.append(a, .{ .kind = .paragraph, .text = inlined.text, .spans = inlined.spans });
    }

    return .{ .arena = arena, .blocks = blocks.items };
}

fn isRule(line: []const u8) bool {
    if (line.len < 3) return false;
    const ch = line[0];
    if (ch != '-' and ch != '*' and ch != '_' and ch != '=') return false;
    for (line) |c| {
        if (c != ch) return false;
    }
    return true;
}

fn headingLevel(line: []const u8) ?u8 {
    var n: u8 = 0;
    while (n < line.len and line[n] == '#' and n < 6) n += 1;
    if (n == 0) return null;
    // `#hashtag` is not a heading; a heading's marker is followed by a space.
    if (n >= line.len or (line[n] != ' ' and line[n] != '\t')) return null;
    return n;
}

/// The text after a bullet marker (`-`, `*`, `+`, `1.`), or null.
fn bulletRest(line: []const u8) ?[]const u8 {
    if (line.len >= 2 and (line[0] == '-' or line[0] == '*' or line[0] == '+') and line[1] == ' ') {
        return std.mem.trimStart(u8, line[2..], " \t");
    }
    var i: usize = 0;
    while (i < line.len and std.ascii.isDigit(line[i]) and i < 9) i += 1;
    if (i > 0 and i + 1 < line.len and (line[i] == '.' or line[i] == ')') and line[i + 1] == ' ') {
        return std.mem.trimStart(u8, line[i + 2 ..], " \t");
    }
    return null;
}

const Inline = struct { text: []const u8, spans: []ui.Span };

/// Strips `**`, `*`/`_` and backticks, recording the byte ranges they covered.
/// An unclosed marker is left as written.
fn emphasize(a: std.mem.Allocator, src: []const u8) !Inline {
    var b = Builder{ .a = a };
    var i: usize = 0;
    while (i < src.len) {
        const c = src[i];
        if (c == '`') {
            if (std.mem.indexOfScalarPos(u8, src, i + 1, '`')) |close| {
                try b.code(src[i + 1 .. close]);
                i = close + 1;
                continue;
            }
        }
        if (c == '*' and i + 1 < src.len and src[i + 1] == '*') {
            try b.flush();
            b.bold = !b.bold;
            i += 2;
            continue;
        }
        // A single `*` or `_` is emphasis when it hugs a word: `*this*` does,
        // `2 * 3` and `default_provider` do not.
        if (c == '*') {
            const prev_space = i == 0 or src[i - 1] == ' ' or src[i - 1] == '\t';
            const next_space = i + 1 >= src.len or src[i + 1] == ' ' or src[i + 1] == '\t';
            if (!prev_space or !next_space) {
                try b.flush();
                b.italic = !b.italic;
                i += 1;
                continue;
            }
        }
        if (c == '_') {
            const prev_word = i > 0 and std.ascii.isAlphanumeric(src[i - 1]);
            const next_word = i + 1 < src.len and std.ascii.isAlphanumeric(src[i + 1]);
            if (!(prev_word and next_word)) {
                try b.flush();
                b.italic = !b.italic;
                i += 1;
                continue;
            }
        }
        try b.out.append(a, c);
        i += 1;
    }
    try b.flush();
    return .{ .text = b.out.items, .spans = b.spans.items };
}

const Builder = struct {
    a: std.mem.Allocator,
    out: std.ArrayListUnmanaged(u8) = .empty,
    spans: std.ArrayListUnmanaged(ui.Span) = .empty,
    start: u32 = 0,
    bold: bool = false,
    italic: bool = false,

    /// Emits the run just closed. A run with no emphasis carries no span:
    /// the text style already paints it.
    fn flush(b: *Builder) !void {
        if (b.out.items.len <= b.start) return;
        if (b.bold or b.italic) {
            try b.spans.append(b.a, .{
                .start = b.start,
                .end = @intCast(b.out.items.len),
                .weight = if (b.bold) .bold else null,
                .italic = b.italic,
            });
        }
        b.start = @intCast(b.out.items.len);
    }

    /// A code span is one span of its own: no emphasis inside it applies.
    fn code(b: *Builder, s: []const u8) !void {
        try b.flush();
        const from: u32 = @intCast(b.out.items.len);
        try b.out.appendSlice(b.a, s);
        try b.spans.append(b.a, .{
            .start = from,
            .end = @intCast(b.out.items.len),
            .mono = true,
            .weight = if (b.bold) .bold else null,
            .italic = b.italic,
        });
        b.start = @intCast(b.out.items.len);
    }
};

// --------------------------------------------------------------------- tests

const testing = std.testing;

fn textOf(doc: *const Doc, i: usize) []const u8 {
    return doc.blocks[i].text;
}

test "headings, bullets and rules are recognized" {
    const src =
        \\# Title
        \\Some **bold** and `code` and *italic*.
        \\
        \\- one
        \\- two
        \\
        \\---
        \\
        \\## Second
    ;
    var doc = try parse(testing.allocator, src);
    defer doc.deinit();

    try testing.expectEqual(@as(usize, 6), doc.blocks.len);
    try testing.expectEqual(Kind.heading, doc.blocks[0].kind);
    try testing.expectEqual(@as(u8, 1), doc.blocks[0].level);
    try testing.expectEqualStrings("Title", textOf(&doc, 0));

    try testing.expectEqual(Kind.paragraph, doc.blocks[1].kind);
    try testing.expectEqualStrings("Some bold and code and italic.", textOf(&doc, 1));

    try testing.expectEqual(Kind.bullet, doc.blocks[2].kind);
    try testing.expectEqualStrings("one", textOf(&doc, 2));
    try testing.expectEqual(Kind.bullet, doc.blocks[3].kind);

    try testing.expectEqual(Kind.rule, doc.blocks[4].kind);
    try testing.expectEqual(Kind.heading, doc.blocks[5].kind);
    try testing.expectEqual(@as(u8, 2), doc.blocks[5].level);
}

test "spans point at the emphasized ranges" {
    var doc = try parse(testing.allocator, "a **b** c");
    defer doc.deinit();
    const block = doc.blocks[0];
    try testing.expectEqualStrings("a b c", block.text);
    try testing.expectEqual(@as(usize, 1), block.spans.len);
    const bold = block.spans[0];
    try testing.expectEqual(@as(u32, 2), bold.start);
    try testing.expectEqual(@as(u32, 3), bold.end);
    try testing.expect(bold.weight != null);
}

test "italics close and snake_case stays literal" {
    var doc = try parse(testing.allocator, "say *hi* now, set default_provider here");
    defer doc.deinit();
    const block = doc.blocks[0];
    try testing.expectEqualStrings("say hi now, set default_provider here", block.text);
    try testing.expectEqual(@as(usize, 1), block.spans.len);
    try testing.expectEqual(@as(u32, 4), block.spans[0].start);
    try testing.expectEqual(@as(u32, 6), block.spans[0].end);
}

test "a fenced block keeps its body literal" {
    const src =
        \\before
        \\```
        \\let x = **1**;
        \\```
        \\after
    ;
    var doc = try parse(testing.allocator, src);
    defer doc.deinit();
    try testing.expectEqual(@as(usize, 3), doc.blocks.len);
    try testing.expectEqual(Kind.code, doc.blocks[1].kind);
    try testing.expectEqualStrings("let x = **1**;", textOf(&doc, 1));
    try testing.expectEqual(@as(usize, 0), doc.blocks[1].spans.len);
}

test "a fenced block keeps its info string as the language" {
    const src =
        \\```zig
        \\const x = 1;
        \\```
    ;
    var doc = try parse(testing.allocator, src);
    defer doc.deinit();
    try testing.expectEqual(@as(usize, 1), doc.blocks.len);
    try testing.expectEqual(Kind.code, doc.blocks[0].kind);
    try testing.expectEqualStrings("zig", doc.blocks[0].lang);
    try testing.expectEqualStrings("const x = 1;", textOf(&doc, 0));
}

test "an unclosed marker stays literal" {
    var doc = try parse(testing.allocator, "2 * 3 * 4 and a lone ` tick");
    defer doc.deinit();
    try testing.expectEqualStrings("2 * 3 * 4 and a lone ` tick", textOf(&doc, 0));
}

test "numbered lists are bullets" {
    var doc = try parse(testing.allocator, "1. first\n2. second");
    defer doc.deinit();
    try testing.expectEqual(Kind.bullet, doc.blocks[0].kind);
    try testing.expectEqualStrings("first", textOf(&doc, 0));
    try testing.expectEqualStrings("second", textOf(&doc, 1));
}

test "a hashtag is not a heading" {
    var doc = try parse(testing.allocator, "#notaheading");
    defer doc.deinit();
    try testing.expectEqual(Kind.paragraph, doc.blocks[0].kind);
}

test "empty and whitespace-only input has no blocks" {
    var doc = try parse(testing.allocator, "\n\n   \n");
    defer doc.deinit();
    try testing.expectEqual(@as(usize, 0), doc.blocks.len);
    try testing.expectEqualStrings("", doc.firstLine());
}
