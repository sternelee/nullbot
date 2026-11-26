//! A small markdown reader for what an agent actually writes back: headings,
//! bullets, numbered lists, quotes, fenced code, rules, `code`, **bold** and
//! *italic*. Anything it does not know stays literal text, so a reply that is
//! not markdown still reads correctly.
//!
//! `parse` keeps the source alive: every `Block.text` and `ui.Span` points into
//! buffers the returned `Doc` owns, and `Doc.deinit` frees them.
const std = @import("std");
const ui = @import("nanoui").ui;

pub const Kind = enum { paragraph, heading, bullet, code, rule, quote, table, footnote };

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
    /// For bullets: nesting depth (0 = top level).
    indent: u8 = 0,
    /// For tables: the header row's cells; rows follow in `text` as lines.
    table_header: []const []const u8 = &.{},
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

        // Table: a line of pipes followed by a separator line of dashes/colons.
        if (isTableHeader(trimmed)) {
            const header_line = trimmed;
            const sep_line = lines.next() orelse break;
            if (!isTableSeparator(std.mem.trimStart(u8, std.mem.trimEnd(u8, sep_line, " \t\r"), " \t"))) {
                // Not a table after all: emit the header as a paragraph and reprocess the next line.
                const inlined = try emphasize(a, header_line);
                try blocks.append(a, .{ .kind = .paragraph, .text = inlined.text, .spans = inlined.spans });
                // Reprocess the line we just consumed as a normal line.
                var reprocess = std.mem.trimEnd(u8, sep_line, " \t\r");
                _ = &reprocess;
                // Simple approach: push it back by handling it in the next iteration via a flag.
                // Instead, we handle it inline here by falling through to the normal handlers.
                // We'll just treat it as a paragraph for now (rare case).
                const inlined2 = try emphasize(a, std.mem.trimStart(u8, reprocess, " \t"));
                try blocks.append(a, .{ .kind = .paragraph, .text = inlined2.text, .spans = inlined2.spans });
                continue;
            }
            // Collect rows until a non-table line.
            var rows_buf: std.ArrayListUnmanaged(u8) = .empty;
            while (lines.next()) |row_raw| {
                const row = std.mem.trimEnd(u8, row_raw, " \t\r");
                const row_trimmed = std.mem.trimStart(u8, row, " \t");
                if (row_trimmed.len == 0 or !isTableRow(row_trimmed)) {
                    // Put the line back? We can't easily; treat it as a paragraph after the table.
                    // We'll parse it as a normal block by falling through, but since we're in a loop,
                    // we handle it by appending a paragraph now.
                    if (row_trimmed.len > 0) {
                        const inlined = try emphasize(a, row_trimmed);
                        try blocks.append(a, .{ .kind = .paragraph, .text = inlined.text, .spans = inlined.spans });
                    }
                    break;
                }
                if (rows_buf.items.len > 0) try rows_buf.append(a, '\n');
                try rows_buf.appendSlice(a, row_trimmed);
            }
            const header_cells = try splitTableRow(a, header_line);
            try blocks.append(a, .{ .kind = .table, .text = rows_buf.items, .table_header = header_cells });
            continue;
        }

        // Footnote definition: [^label]: text
        if (std.mem.startsWith(u8, trimmed, "[^")) {
            if (std.mem.indexOf(u8, trimmed, "]:")) |close| {
                const label = trimmed[2..close];
                const text = std.mem.trimStart(u8, trimmed[close + 2 ..], " \t");
                const inlined = try emphasize(a, text);
                const full = try std.fmt.allocPrint(a, "[^{s}] {s}", .{ label, inlined.text });
                try blocks.append(a, .{ .kind = .footnote, .text = full, .spans = inlined.spans });
                continue;
            }
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
            // Nesting depth from leading spaces/tabs (2 spaces or 1 tab = 1 level).
            var indent: u8 = 0;
            var pos: usize = 0;
            while (pos < line.len and (line[pos] == ' ' or line[pos] == '\t')) {
                if (line[pos] == '\t') {
                    indent += 1;
                } else {
                    // Count spaces; every 2 spaces = 1 level.
                    var spaces: usize = 0;
                    while (pos < line.len and line[pos] == ' ') : (pos += 1) spaces += 1;
                    indent += @intCast(spaces / 2);
                    continue;
                }
                pos += 1;
            }
            var text = rest;
            var prefix: []const u8 = "";
            if (std.mem.startsWith(u8, rest, "[ ] ") or std.mem.startsWith(u8, rest, "[ ]\t")) {
                prefix = "☐ ";
                text = rest[4..];
            } else if (std.mem.startsWith(u8, rest, "[x] ") or std.mem.startsWith(u8, rest, "[X] ") or std.mem.startsWith(u8, rest, "[x]\t") or std.mem.startsWith(u8, rest, "[X]\t")) {
                prefix = "☑ ";
                text = rest[4..];
            }
            const inlined = try emphasize(a, text);
            if (prefix.len > 0) {
                const full = try std.fmt.allocPrint(a, "{s}{s}", .{ prefix, inlined.text });
                try blocks.append(a, .{ .kind = .bullet, .text = full, .spans = inlined.spans, .indent = indent });
            } else {
                try blocks.append(a, .{ .kind = .bullet, .text = inlined.text, .spans = inlined.spans, .indent = indent });
            }
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

fn isTableHeader(line: []const u8) bool {
    return std.mem.indexOfScalar(u8, line, '|') != null;
}

fn isTableSeparator(line: []const u8) bool {
    if (line.len == 0) return false;
    var has_dash = false;
    for (line) |c| {
        if (c == '-') has_dash = true;
        if (c != '-' and c != ':' and c != '|' and c != ' ' and c != '\t') return false;
    }
    return has_dash;
}

fn isTableRow(line: []const u8) bool {
    return std.mem.indexOfScalar(u8, line, '|') != null;
}

fn splitTableRow(a: std.mem.Allocator, line: []const u8) ![]const []const u8 {
    var cells: std.ArrayListUnmanaged([]const u8) = .empty;
    // Strip leading and trailing pipes.
    var s = std.mem.trim(u8, line, " \t");
    if (s.len > 0 and s[0] == '|') s = s[1..];
    if (s.len > 0 and s[s.len - 1] == '|') s = s[0 .. s.len - 1];
    var start: usize = 0;
    var i: usize = 0;
    while (i < s.len) : (i += 1) {
        if (s[i] == '|') {
            const cell = std.mem.trim(u8, s[start..i], " \t");
            try cells.append(a, try a.dupe(u8, cell));
            start = i + 1;
        }
    }
    if (start < s.len) {
        const cell = std.mem.trim(u8, s[start..], " \t");
        if (cell.len > 0) try cells.append(a, try a.dupe(u8, cell));
    }
    return cells.items;
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
        // Strikethrough ~~text~~
        if (c == '~' and i + 1 < src.len and src[i + 1] == '~') {
            try b.flush();
            b.strike = !b.strike;
            i += 2;
            continue;
        }
        // Link [text](url): keep the label, drop the url.
        if (c == '[') {
            if (std.mem.indexOfScalarPos(u8, src, i + 1, ']')) |close_bracket| {
                if (close_bracket + 1 < src.len and src[close_bracket + 1] == '(') {
                    if (std.mem.indexOfScalarPos(u8, src, close_bracket + 2, ')')) |close_paren| {
                        const label = src[i + 1 .. close_bracket];
                        const inlined = try emphasize(a, label);
                        try b.out.appendSlice(a, inlined.text);
                        // record spans offset
                        for (inlined.spans) |sp| {
                            try b.spans.append(a, .{ .start = sp.start + @as(u32, @intCast(b.out.items.len - inlined.text.len)), .end = sp.end + @as(u32, @intCast(b.out.items.len - inlined.text.len)), .weight = sp.weight, .italic = sp.italic, .mono = sp.mono });
                        }
                        try b.spans.append(a, .{ .start = @intCast(b.out.items.len - inlined.text.len), .end = @intCast(b.out.items.len), .underline = true });
                        b.start = @intCast(b.out.items.len);
                        i = close_paren + 1;
                        continue;
                    }
                }
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
    strike: bool = false,

    /// Emits the run just closed. A run with no emphasis carries no span:
    /// the text style already paints it.
    fn flush(b: *Builder) !void {
        if (b.out.items.len <= b.start) return;
        if (b.bold or b.italic or b.strike) {
            try b.spans.append(b.a, .{
                .start = b.start,
                .end = @intCast(b.out.items.len),
                .weight = if (b.bold) .bold else null,
                .italic = b.italic,
                .strike = b.strike,
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
            .strike = b.strike,
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

test "nested bullets record their indent" {
    const src =
        \\- top
        \\  - nested
        \\    - deeper
    ;
    var doc = try parse(testing.allocator, src);
    defer doc.deinit();
    try testing.expectEqual(@as(usize, 3), doc.blocks.len);
    try testing.expectEqual(@as(u8, 0), doc.blocks[0].indent);
    try testing.expectEqual(@as(u8, 1), doc.blocks[1].indent);
    try testing.expectEqual(@as(u8, 2), doc.blocks[2].indent);
}

test "task lists become checkbox bullets" {
    var doc = try parse(testing.allocator, "- [ ] todo\n- [x] done");
    defer doc.deinit();
    try testing.expectEqual(Kind.bullet, doc.blocks[0].kind);
    try testing.expectEqualStrings("☐ todo", textOf(&doc, 0));
    try testing.expectEqualStrings("☑ done", textOf(&doc, 1));
}

test "tables are parsed with header and rows" {
    const src =
        \\| Name | Age |
        \\| --- | --- |
        \\| Ada | 36 |
        \\| Bob | 40 |
    ;
    var doc = try parse(testing.allocator, src);
    defer doc.deinit();
    try testing.expectEqual(@as(usize, 1), doc.blocks.len);
    try testing.expectEqual(Kind.table, doc.blocks[0].kind);
    try testing.expectEqual(@as(usize, 2), doc.blocks[0].table_header.len);
    try testing.expectEqualStrings("Name", doc.blocks[0].table_header[0]);
    try testing.expectEqualStrings("Age", doc.blocks[0].table_header[1]);
    try testing.expect(std.mem.indexOf(u8, doc.blocks[0].text, "Ada") != null);
}

test "footnotes are recognized" {
    var doc = try parse(testing.allocator, "[^1]: a footnote");
    defer doc.deinit();
    try testing.expectEqual(Kind.footnote, doc.blocks[0].kind);
    try testing.expect(std.mem.indexOf(u8, textOf(&doc, 0), "a footnote") != null);
}

test "strikethrough produces a strike span" {
    var doc = try parse(testing.allocator, "this is ~~gone~~ text");
    defer doc.deinit();
    const block = doc.blocks[0];
    try testing.expectEqualStrings("this is gone text", block.text);
    try testing.expectEqual(@as(usize, 1), block.spans.len);
    try testing.expect(block.spans[0].strike);
}

test "links keep the label and drop the url" {
    var doc = try parse(testing.allocator, "see [the docs](https://example.com) here");
    defer doc.deinit();
    const block = doc.blocks[0];
    try testing.expectEqualStrings("see the docs here", block.text);
    // A span for the link (underline) should exist.
    var found = false;
    for (block.spans) |sp| {
        if (sp.underline) found = true;
    }
    try testing.expect(found);
}
