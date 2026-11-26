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
    /// For bullets and quotes: nesting depth (0 = top level).
    indent: u8 = 0,
    /// For bullets: what to draw before the text — `·`, `☐`, `☑` or `3.`.
    marker: []const u8 = "",
    /// For tables: the header row's cells; rows follow in `text` as lines.
    table_header: []const []const u8 = &.{},
    /// For tables: per-column alignment, parallel to `table_header`.
    table_align: []const Align = &.{},
    /// For tables: the parsed body rows, parallel cells to `table_header`.
    table_rows: []const []const []const u8 = &.{},
    /// Footnote references in this block (`[^label]`), with the byte range
    /// of the reference's rendered marker in `text`.
    refs: []const FootnoteRef = &.{},
    /// Clickable ranges of `text`: footnote references and links.
    anchors: []const Anchor = &.{},
};

/// A table column's alignment, from the separator row's colons.
pub const Align = enum { left, center, right };

/// One `[^label]` reference inside a block's text.
pub const FootnoteRef = struct {
    label: []const u8,
    /// Where the reference's marker starts in `Block.text`.
    start: u32,
    end: u32,
};

/// A footnote definition, `[^label]: text`, in document order.
pub const Footnote = struct {
    label: []const u8,
    text: []const u8,
    /// Styles over `text` (`**bold**`, `\`code\``), as a block's.
    spans: []ui.Span = &.{},
    /// 1-based number, by order of first reference (or definition).
    number: u32,
};

pub const Doc = struct {
    arena: std.heap.ArenaAllocator,
    blocks: []Block = &.{},
    /// Every footnote definition, numbered by order of first reference.
    footnotes: []const Footnote = &.{},
    /// Maps a footnote label to its index in `footnotes`.
    footnote_index: std.StringHashMapUnmanaged(u32) = .empty,

    pub fn deinit(self: *Doc) void {
        // Everything the parser made, the footnote table included, came from
        // this arena, so freeing it frees the document.
        self.arena.deinit();
        self.* = undefined;
    }

    /// The footnote a reference points at, or null when it has no definition.
    pub fn footnote(self: *const Doc, label: []const u8) ?*const Footnote {
        const i = self.footnote_index.get(label) orelse return null;
        return &self.footnotes[i];
    }

    /// The footnote definition at `number` (1-based), or null.
    pub fn footnoteAt(self: *const Doc, number: u32) ?*const Footnote {
        if (number == 0 or number > self.footnotes.len) return null;
        return &self.footnotes[number - 1];
    }

    /// The first plain line, for a session row's subtitle.
    pub fn firstLine(self: *const Doc) []const u8 {
        for (self.blocks) |b| {
            if (b.kind == .paragraph or b.kind == .heading) return b.text;
        }
        return "";
    }
};

/// Collects footnote references and definitions in one pass, so each
/// footnote is numbered by where it is first referred to, as a reader meets
/// it, rather than by where its definition happens to sit.
const Footnotes = struct {
    a: std.mem.Allocator,
    defs: std.ArrayListUnmanaged(Footnote) = .empty,
    /// Label -> index in `defs`, whether or not the text is known yet.
    index: std.StringHashMapUnmanaged(u32) = .empty,
    /// The text of each definition, by index, filled in when it is seen.
    texts: std.ArrayListUnmanaged([]const u8) = .empty,

    /// Everything here is allocated from the document's arena, so nothing is
    /// freed by hand: the `Doc` takes ownership and its arena goes with it.
    fn slot(self: *Footnotes, label: []const u8) !u32 {
        if (self.index.get(label)) |i| return i;
        const i: u32 = @intCast(self.defs.items.len);
        const key = try self.a.dupe(u8, label);
        try self.defs.append(self.a, .{ .label = key, .text = "", .number = i + 1 });
        try self.texts.append(self.a, "");
        try self.index.put(self.a, key, i);
        return i;
    }

    fn finish(self: *Footnotes) ![]const Footnote {
        for (self.defs.items, 0..) |*d, i| d.text = self.texts.items[i];
        return self.defs.items;
    }
};

/// Everything the block loop shares, so each branch can add to one document.
const Parser = struct {
    a: std.mem.Allocator,
    blocks: std.ArrayListUnmanaged(Block) = .empty,
    lines: std.mem.SplitIterator(u8, .scalar),
    notes: Footnotes,
    refs: std.ArrayListUnmanaged(FootnoteRef) = .empty,
    anchors: std.ArrayListUnmanaged(Anchor) = .empty,

    fn addBlock(p: *Parser, block: Block) !void {
        // The refs and anchors are per block: what was collected since the
        // last block belongs to this one, and the next block starts clean.
        var b = block;
        b.refs = p.refs.items;
        b.anchors = p.anchors.items;
        p.refs = .empty;
        p.anchors = .empty;
        try p.blocks.append(p.a, b);
    }

    /// One block's inline text: emphasis, links and footnote references.
    fn inl(p: *Parser, src: []const u8) !Inline {
        var b = Builder{ .a = p.a, .notes = &p.notes, .refs = &p.refs, .anchors = &p.anchors };
        try b.run(src);
        try b.flush();
        return .{ .text = b.out.items, .spans = b.spans.items };
    }
};

pub fn parse(gpa: std.mem.Allocator, source: []const u8) !Doc {
    var arena = std.heap.ArenaAllocator.init(gpa);
    errdefer arena.deinit();
    const a = arena.allocator();

    var p = Parser{
        .a = a,
        .lines = std.mem.splitScalar(u8, source, '\n'),
        .notes = .{ .a = a },
    };

    while (p.lines.next()) |raw| {
        const line = std.mem.trimEnd(u8, raw, " \t\r");
        const trimmed = std.mem.trimStart(u8, line, " \t");
        if (trimmed.len == 0) continue;

        if (std.mem.startsWith(u8, trimmed, "```")) {
            // The info string after the fence names the language (`zig`).
            const info = std.mem.trimStart(u8, trimmed[3..], " \t");
            const lang = if (info.len > 0) try a.dupe(u8, info) else "";
            // Everything up to the closing fence is literal, and unlike every
            // other block its lines keep their indentation.
            var body: std.ArrayListUnmanaged(u8) = .empty;
            while (p.lines.next()) |body_raw| {
                const body_line = std.mem.trimEnd(u8, body_raw, "\r");
                if (std.mem.startsWith(u8, std.mem.trimStart(u8, body_line, " \t"), "```")) break;
                if (body.items.len > 0) try body.append(a, '\n');
                try body.appendSlice(a, body_line);
            }
            try p.addBlock(.{ .kind = .code, .text = body.items, .lang = lang });
            continue;
        }

        // A footnote definition: `[^label]: text`. It is filed under its
        // label, and numbered if no reference got there first.
        if (footnoteDef(trimmed)) |def| {
            const i = try p.notes.slot(def.label);
            if (p.notes.texts.items[i].len == 0) {
                const inlined = try p.inl(def.text);
                p.notes.texts.items[i] = inlined.text;
                p.notes.defs.items[i].spans = inlined.spans;
                // A note's own references are not anchors on the page.
                p.refs.clearRetainingCapacity();
                p.anchors.clearRetainingCapacity();
            }
            continue;
        }

        if (isRule(trimmed)) {
            try p.addBlock(.{ .kind = .rule, .text = "" });
            continue;
        }

        if (headingLevel(trimmed)) |level| {
            const rest = std.mem.trimStart(u8, trimmed[level..], " \t");
            const inlined = try p.inl(rest);
            try p.addBlock(.{ .kind = .heading, .text = inlined.text, .spans = inlined.spans, .level = level });
            continue;
        }

        // A table: a piped line, then a separator of dashes and colons. A
        // piped line with no separator after it is an ordinary paragraph.
        if (isTableRow(trimmed)) {
            const sep_line = std.mem.trimStart(u8, std.mem.trimEnd(u8, p.lines.peek() orelse "", " \t\r"), " \t");
            if (isTableSeparator(sep_line)) {
                _ = p.lines.next();
                const header = try splitTableRow(a, trimmed);
                const alignment = try separatorAlign(a, sep_line, header.len);
                var rows: std.ArrayListUnmanaged([]const []const u8) = .empty;
                while (p.lines.peek()) |row_raw| {
                    const row = std.mem.trim(u8, row_raw, " \t\r");
                    if (row.len == 0 or !isTableRow(row)) break;
                    _ = p.lines.next();
                    try rows.append(a, try splitTableRow(a, row));
                }
                try p.addBlock(.{ .kind = .table, .text = "", .table_header = header, .table_align = alignment, .table_rows = rows.items });
                continue;
            }
        }

        if (bulletRest(trimmed)) |rest| {
            // The marker is the view's to draw: a middle dot for a bullet, a
            // checkbox for a task, or the number an ordered list keeps.
            var text = rest;
            var marker: []const u8 = "·";
            if (std.mem.startsWith(u8, rest, "[ ] ") or std.mem.startsWith(u8, rest, "[ ]\t")) {
                marker = "☐";
                text = rest[4..];
            } else if (std.mem.startsWith(u8, rest, "[x] ") or std.mem.startsWith(u8, rest, "[X] ") or
                std.mem.startsWith(u8, rest, "[x]\t") or std.mem.startsWith(u8, rest, "[X]\t"))
            {
                marker = "☑";
                text = rest[4..];
            } else {
                const head = std.mem.trimEnd(u8, trimmed[0 .. trimmed.len - rest.len], " \t");
                if (std.mem.endsWith(u8, head, ".") or std.mem.endsWith(u8, head, ")")) marker = try a.dupe(u8, head);
            }
            const inlined = try p.inl(text);
            try p.addBlock(.{ .kind = .bullet, .text = inlined.text, .spans = inlined.spans, .indent = nestingDepth(line), .marker = marker });
            continue;
        }

        if (quoteDepth(trimmed)) |q| {
            const inlined = try p.inl(q.rest);
            try p.addBlock(.{ .kind = .quote, .text = inlined.text, .spans = inlined.spans, .indent = q.depth });
            continue;
        }

        const inlined = try p.inl(trimmed);
        try p.addBlock(.{ .kind = .paragraph, .text = inlined.text, .spans = inlined.spans });
    }

    return .{
        .arena = arena,
        .blocks = p.blocks.items,
        .footnotes = try p.notes.finish(),
        .footnote_index = p.notes.index,
    };
}

/// How deep a line is nested: every two spaces or one tab is one level.
fn nestingDepth(line: []const u8) u8 {
    var depth: u8 = 0;
    var spaces: usize = 0;
    for (line) |c| {
        switch (c) {
            '\t' => {
                depth += 1;
                spaces = 0;
            },
            ' ' => {
                spaces += 1;
                if (spaces == 2) {
                    depth += 1;
                    spaces = 0;
                }
            },
            else => break,
        }
    }
    return depth;
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

/// The cells of a piped line, trimmed, without its edge pipes. An escaped
/// pipe (`\|`) is part of its cell rather than a divider.
fn splitTableRow(a: std.mem.Allocator, line: []const u8) ![]const []const u8 {
    var cells: std.ArrayListUnmanaged([]const u8) = .empty;
    var cell: std.ArrayListUnmanaged(u8) = .empty;
    var i: usize = 0;
    // A leading pipe opens the first cell; a trailing one closes the last.
    const s = std.mem.trim(u8, line, " \t");
    const body = if (std.mem.startsWith(u8, s, "|")) s[1..] else s;
    const end = if (std.mem.endsWith(u8, body, "|") and !std.mem.endsWith(u8, body, "\\|")) body.len - 1 else body.len;
    while (i < end) : (i += 1) {
        if (body[i] == '\\' and i + 1 < end and body[i + 1] == '|') {
            try cell.append(a, '|');
            i += 1;
            continue;
        }
        if (body[i] == '|') {
            try cells.append(a, try a.dupe(u8, std.mem.trim(u8, cell.items, " \t")));
            cell.clearRetainingCapacity();
            continue;
        }
        try cell.append(a, body[i]);
    }
    try cells.append(a, try a.dupe(u8, std.mem.trim(u8, cell.items, " \t")));
    return cells.items;
}

/// Each column's alignment from the separator row's colons (`:--`, `--:`,
/// `:--:`); a column with none is left-aligned. The result is padded or cut
/// to `n`, since a separator may name fewer columns than its header.
fn separatorAlign(a: std.mem.Allocator, sep: []const u8, n: usize) ![]const Align {
    const cells = try splitTableRow(a, sep);
    const out = try a.alloc(Align, n);
    for (out, 0..) |*al, i| {
        al.* = .left;
        if (i >= cells.len) continue;
        const c = cells[i];
        const left = std.mem.startsWith(u8, c, ":");
        const right = std.mem.endsWith(u8, c, ":");
        al.* = if (left and right) .center else if (right) .right else if (left) .left else .left;
    }
    return out;
}

/// A footnote definition, `[^label]: text`, or null.
fn footnoteDef(line: []const u8) ?struct { label: []const u8, text: []const u8 } {
    if (!std.mem.startsWith(u8, line, "[^")) return null;
    const close = std.mem.indexOf(u8, line, "]:") orelse return null;
    const label = line[2..close];
    if (label.len == 0 or std.mem.indexOfScalar(u8, label, '[') != null) return null;
    return .{ .label = label, .text = std.mem.trimStart(u8, line[close + 2 ..], " \t") };
}

const Quote = struct { depth: u8, rest: []const u8 };

/// A blockquote's depth and text: `> once`, `> > twice`, or null.
fn quoteDepth(line: []const u8) ?Quote {
    if (!std.mem.startsWith(u8, line, ">")) return null;
    var i: usize = 0;
    var depth: u8 = 0;
    while (i < line.len) {
        var j = i;
        while (j < line.len and (line[j] == '>' or line[j] == ' ' or line[j] == '\t')) {
            if (line[j] == '>') {
                depth += 1;
                i = j + 1;
            }
            j += 1;
        }
        break;
    }
    return .{ .depth = depth - 1, .rest = std.mem.trimStart(u8, line[i..], " \t") };
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

/// What parsing can fail on: only memory.
pub const Error = error{OutOfMemory};

/// What a span marks, so the view can tell a link from emphasis.
pub const Mark = enum {
    /// A reference's marker, `[1]`, which jumps to its footnote when clicked.
    footnote,
    /// A link's label, which opens its URL.
    link,
};

/// A clickable range of a block's text: where it starts and ends, and what
/// clicking it does.
pub const Anchor = struct {
    mark: Mark,
    start: u32,
    end: u32,
    /// A footnote's number, or a link's URL.
    target: []const u8 = "",
    /// A footnote's label, to find it in `Doc.footnotes`.
    label: []const u8 = "",
    /// A footnote reference's number, the one its marker shows.
    number: u32 = 0,
};

/// Strips `**`, `*`/`_`, `~~` and backticks, recording the byte ranges they
/// covered; turns links into their labels and references into numbers; and
/// links bare URLs, `www.` hosts and email addresses as GFM does. An unclosed
/// marker is left as written.
const Builder = struct {
    a: std.mem.Allocator,
    out: std.ArrayListUnmanaged(u8) = .empty,
    spans: std.ArrayListUnmanaged(ui.Span) = .empty,
    start: u32 = 0,
    bold: bool = false,
    italic: bool = false,
    strike: bool = false,
    /// The document's footnotes, numbered as references are first met.
    notes: *Footnotes,
    /// The references in this run, as the parser hands them to the block.
    refs: *std.ArrayListUnmanaged(FootnoteRef),
    anchors: *std.ArrayListUnmanaged(Anchor),
    /// Inside a link's label, where no further link is recognised.
    in_link: bool = false,

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

    fn put(b: *Builder, s: []const u8) !void {
        try b.out.appendSlice(b.a, s);
    }

    /// A code span is one span of its own: no emphasis inside it applies.
    fn code(b: *Builder, s: []const u8) !void {
        try b.flush();
        const from: u32 = @intCast(b.out.items.len);
        try b.put(s);
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

    /// A link's label, underlined and clickable from `url`.
    fn link(b: *Builder, label: []const u8, url: []const u8) Error!void {
        const label_start: u32 = @intCast(b.out.items.len);
        // A link's label is text with emphasis, not a place for more links:
        // `me@example.com` as a label must not link itself again.
        b.in_link = true;
        try b.run(label);
        b.in_link = false;
        try b.flush();
        const from = label_start;
        const to: u32 = @intCast(b.out.items.len);
        if (to == from) return;
        try b.spans.append(b.a, .{ .start = from, .end = to, .underline = true, .color = .{ .r = 0.25, .g = 0.45, .b = 0.95, .a = 1 } });
        try b.anchors.append(b.a, .{ .mark = .link, .start = from, .end = to, .target = try b.a.dupe(u8, url) });
        b.start = to;
    }

    /// `[^label]`: its footnote's number, raised, and a click target.
    fn reference(b: *Builder, label: []const u8) Error!void {
        const i = try b.notes.slot(label);
        const number = b.notes.defs.items[i].number;
        try b.flush();
        const marker = try std.fmt.allocPrint(b.a, "[{d}]", .{number});
        const from: u32 = @intCast(b.out.items.len);
        try b.put(marker);
        const to: u32 = @intCast(b.out.items.len);
        try b.spans.append(b.a, .{ .start = from, .end = to, .color = .{ .r = 0.45, .g = 0.5, .b = 0.6, .a = 1 } });
        try b.anchors.append(b.a, .{ .mark = .footnote, .start = from, .end = to, .label = b.notes.defs.items[i].label, .target = marker, .number = number });
        try b.refs.append(b.a, .{ .label = b.notes.defs.items[i].label, .start = from, .end = to });
        b.start = to;
    }

    /// Where a bare URL, `www.` host or email address ends: at whitespace, or
    /// before a closing bracket or trailing punctuation GFM leaves out.
    fn autolinkEnd(src: []const u8, from: usize) usize {
        var i = from;
        var depth: usize = 0;
        while (i < src.len) : (i += 1) {
            const c = src[i];
            if (std.ascii.isWhitespace(c)) break;
            switch (c) {
                '(' => depth += 1,
                ')' => {
                    if (depth == 0) break;
                    depth -= 1;
                },
                ']', '}', ',', ';', '"', '\'', '<', '>' => break,
                else => {},
            }
        }
        // A sentence's own punctuation is not the link's.
        var end = i;
        while (end > from and (src[end - 1] == '.' or src[end - 1] == '!' or src[end - 1] == '?' or src[end - 1] == ':')) end -= 1;
        return end;
    }

    /// A GFM autolink at `i`, if one starts there: its URL and its length.
    fn autolink(src: []const u8, i: usize) ?struct { url: []const u8, len: usize, scheme: bool } {
        const schemes = [_][]const u8{ "https://", "http://", "ftp://" };
        for (schemes) |scheme| {
            if (src.len >= i + scheme.len + 1 and std.ascii.startsWithIgnoreCase(src[i..], scheme) and src[i + scheme.len] != ' ' and src[i + scheme.len] != '\t') {
                const end = autolinkEnd(src, i + scheme.len);
                if (end > i + scheme.len) return .{ .url = src[i..end], .len = end - i, .scheme = true };
            }
        }
        if (src.len >= i + 5 and std.ascii.startsWithIgnoreCase(src[i..], "www.") and std.ascii.isAlphanumeric(src[i + 4])) {
            const end = autolinkEnd(src, i + 4);
            if (std.mem.indexOfScalar(u8, src[i + 4 .. end], '.') != null) return .{ .url = src[i..end], .len = end - i, .scheme = false };
        }
        return null;
    }

    /// An email address starting at `i`: `user@host.tld`, where the user is
    /// letters, digits, `.`, `_`, `+` and `-`, and the host has a dot and
    /// ends in a letter. Returns where the address ends, or null.
    fn email(src: []const u8, i: usize) ?usize {
        if (i >= src.len or !std.ascii.isAlphanumeric(src[i])) return null;
        var j = i;
        while (j < src.len and (std.ascii.isAlphanumeric(src[j]) or src[j] == '.' or src[j] == '_' or src[j] == '+' or src[j] == '-')) j += 1;
        if (j >= src.len or src[j] != '@') return null;
        const at = j;
        j += 1;
        if (j >= src.len) return null;
        var dots: usize = 0;
        var last: usize = j;
        while (j < src.len and (std.ascii.isAlphanumeric(src[j]) or src[j] == '.' or src[j] == '-')) : (j += 1) {
            if (src[j] == '.') dots += 1 else last = j + 1;
        }
        // The host must have a dot and end in a letter: `a@b.c.` stops at `c`.
        if (dots == 0 or last <= at + 1 or !std.ascii.isAlphabetic(src[last - 1])) return null;
        return last;
    }

    fn run(b: *Builder, src: []const u8) Error!void {
        var i: usize = 0;
        while (i < src.len) {
            const c = src[i];
            // An email address, when its user begins here: at the start of
            // the run or after anything but a word character, so `x` in
            // `x@y` is never read as a second address.
            if (!b.in_link and email(src, i) != null) {
                const end = email(src, i).?;
                const boundary = i == 0 or !(std.ascii.isAlphanumeric(src[i - 1]) or src[i - 1] == '.' or src[i - 1] == '_' or
                    src[i - 1] == '+' or src[i - 1] == '-' or src[i - 1] == '/' or src[i - 1] == '@');
                if (boundary) {
                    const address = src[i..end];
                    try b.link(address, try std.fmt.allocPrint(b.a, "mailto:{s}", .{address}));
                    i = end;
                    continue;
                }
            }
            if (c == '\\') {
                // An escaped character is itself, unless it is a newline.
                if (i + 1 < src.len and std.ascii.isPunctuation(src[i + 1])) {
                    try b.put(src[i + 1 .. i + 2]);
                    i += 2;
                    continue;
                }
            }
            if (c == '`') {
                // A run of backticks opens a span closed by as many again.
                var ticks: usize = 0;
                while (i + ticks < src.len and src[i + ticks] == '`') ticks += 1;
                if (std.mem.indexOfPos(u8, src, i + ticks, src[i .. i + ticks])) |close| {
                    // One leading and trailing space is padding, unless the
                    // content is all spaces.
                    var inner = src[i + ticks .. close];
                    if (inner.len >= 2 and inner[0] == ' ' and inner[inner.len - 1] == ' ' and std.mem.trim(u8, inner, " ").len > 0) inner = inner[1 .. inner.len - 1];
                    try b.code(inner);
                    i = close + ticks;
                    continue;
                }
            }
            if (c == '~' and i + 1 < src.len and src[i + 1] == '~') {
                // Strikethrough closes at the next `~~` with a word before it.
                if (findClose(src, i + 2, "~~")) |close| {
                    try b.flush();
                    b.strike = true;
                    try b.run(src[i + 2 .. close]);
                    try b.flush();
                    b.strike = false;
                    i = close + 2;
                    continue;
                }
            }
            if (c == '[' and i + 1 < src.len and src[i + 1] == '^') {
                // A footnote reference: `[^label]`.
                if (std.mem.indexOfScalarPos(u8, src, i + 2, ']')) |close| {
                    const label = src[i + 2 .. close];
                    if (label.len > 0 and std.mem.indexOfScalar(u8, label, '[') == null) {
                        try b.reference(label);
                        i = close + 1;
                        continue;
                    }
                }
            }
            if (c == '!') {
                // An image is its alt text, in brackets, so the reply still
                // says what was there.
                if (i + 1 < src.len and src[i + 1] == '[') {
                    if (inlineLink(src, i + 1)) |l| {
                        try b.put("[image: ");
                        try b.put(std.mem.trim(u8, l.label, " "));
                        try b.put("]");
                        i = l.end;
                        continue;
                    }
                }
            }
            if (c == '[') {
                if (inlineLink(src, i)) |l| {
                    try b.link(l.label, l.url);
                    i = l.end;
                    continue;
                }
            }
            if (c == '<') {
                // `<br>` and `<br/>`: a hard line break, as GFM's HTML does.
                // The newline in the text is what the layout breaks on, so it
                // is written into the run rather than drawn as a box.
                if (std.ascii.startsWithIgnoreCase(src[i..], "<br>")) {
                    try b.put("\n");
                    i += 4;
                    continue;
                }
                if (std.ascii.startsWithIgnoreCase(src[i..], "<br/>")) {
                    try b.put("\n");
                    i += 5;
                    continue;
                }
                if (std.ascii.startsWithIgnoreCase(src[i..], "<br />")) {
                    try b.put("\n");
                    i += 6;
                    continue;
                }
                // `<url>` and `<user@host>`: the angle brackets are syntax.
                if (std.mem.indexOfScalarPos(u8, src, i + 1, '>')) |close| {
                    const inner = src[i + 1 .. close];
                    if (inner.len > 0 and std.mem.indexOfScalar(u8, inner, ' ') == null) {
                        const is_url = std.mem.indexOf(u8, inner, "://") != null;
                        const at = std.mem.indexOfScalar(u8, inner, '@');
                        if (is_url or at != null) {
                            const url = if (is_url) inner else try std.fmt.allocPrint(b.a, "mailto:{s}", .{inner});
                            try b.link(inner, url);
                            i = close + 1;
                            continue;
                        }
                    }
                }
            }
            if (!b.in_link) {
                if (autolink(src, i)) |auto| {
                    // Not inside a word (`xwww.example.com` is not a link).
                    const boundary = i == 0 or !(std.ascii.isAlphanumeric(src[i - 1]) or src[i - 1] == '/' or src[i - 1] == '.' or src[i - 1] == '@');
                    if (boundary) {
                        const url = if (auto.scheme) auto.url else try std.fmt.allocPrint(b.a, "https://{s}", .{auto.url});
                        try b.link(auto.url, url);
                        i += auto.len;
                        continue;
                    }
                }
            }
            if (c == '*' and i + 1 < src.len and src[i + 1] == '*') {
                // Bold closes at a `**` that has a word before it.
                if (findClose(src, i + 2, "**")) |close| {
                    try b.flush();
                    b.bold = true;
                    try b.run(src[i + 2 .. close]);
                    try b.flush();
                    b.bold = false;
                    i = close + 2;
                    continue;
                }
            }
            // A single `*` or `_` is emphasis when it hugs a word: `*this*`
            // does, `2 * 3` and `default_provider` do not.
            if (c == '*') {
                const prev_space = i == 0 or src[i - 1] == ' ' or src[i - 1] == '\t';
                const next_space = i + 1 >= src.len or src[i + 1] == ' ' or src[i + 1] == '\t';
                if (!prev_space or !next_space) {
                    if (findClose(src, i + 1, "*")) |close| {
                        try b.flush();
                        b.italic = true;
                        try b.run(src[i + 1 .. close]);
                        try b.flush();
                        b.italic = false;
                        i = close + 1;
                        continue;
                    }
                }
            }
            if (c == '_') {
                const prev_word = i > 0 and std.ascii.isAlphanumeric(src[i - 1]);
                const next_word = i + 1 < src.len and std.ascii.isAlphanumeric(src[i + 1]);
                if (!(prev_word and next_word) and !prev_word and next_word) {
                    if (findClose(src, i + 1, "_")) |close| {
                        if (close + 1 >= src.len or !std.ascii.isAlphanumeric(src[close + 1])) {
                            try b.flush();
                            b.italic = true;
                            try b.run(src[i + 1 .. close]);
                            try b.flush();
                            b.italic = false;
                            i = close + 1;
                            continue;
                        }
                    }
                }
            }
            try b.put(src[i .. i + 1]);
            i += 1;
        }
    }
};

/// The next `marker` at or after `from` that has a non-space before it, is
/// not itself escaped, and for a single character is not part of a run of
/// itself: the `*` in `**both**` does not close a `*italic *`.
fn findClose(src: []const u8, from: usize, marker: []const u8) ?usize {
    var i = from;
    while (i + marker.len <= src.len) : (i += 1) {
        if (!std.mem.startsWith(u8, src[i..], marker)) continue;
        if (i == 0 or src[i - 1] == ' ' or src[i - 1] == '\t' or src[i - 1] == '\n' or src[i - 1] == '\\') continue;
        if (marker.len == 1) {
            const before_run = i >= 2 and src[i - 1] == marker[0];
            const after_run = i + 2 <= src.len and i + 1 < src.len and src[i + 1] == marker[0];
            if (before_run or after_run) continue;
        }
        return i;
    }
    return null;
}

/// An inline link or image target at `[`: its label, URL and where it ends.
fn inlineLink(src: []const u8, open: usize) ?struct { label: []const u8, url: []const u8, end: usize } {
    var i = open + 1;
    var depth: usize = 0;
    while (i < src.len) : (i += 1) {
        switch (src[i]) {
            '\\' => i += 1,
            '[' => depth += 1,
            ']' => {
                if (depth == 0) break;
                depth -= 1;
            },
            else => {},
        }
    }
    if (i >= src.len) return null;
    const label = src[open + 1 .. i];
    i += 1;
    if (i >= src.len or src[i] != '(') return null;
    i += 1;
    const close = std.mem.indexOfScalarPos(u8, src, i, ')') orelse return null;
    const url = std.mem.trim(u8, src[i..close], " \t");
    if (url.len == 0) return null;
    return .{ .label = label, .url = url, .end = close + 1 };
}

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

test "task lists carry a checkbox marker" {
    var doc = try parse(testing.allocator, "- [ ] todo\n- [x] done");
    defer doc.deinit();
    try testing.expectEqual(Kind.bullet, doc.blocks[0].kind);
    try testing.expectEqualStrings("☐", doc.blocks[0].marker);
    try testing.expectEqualStrings("todo", textOf(&doc, 0));
    try testing.expectEqualStrings("☑", doc.blocks[1].marker);
    try testing.expectEqualStrings("done", textOf(&doc, 1));
}

test "an ordered list keeps its number, and a bullet its dot" {
    var doc = try parse(testing.allocator, "3. third\n- dot");
    defer doc.deinit();
    try testing.expectEqualStrings("3.", doc.blocks[0].marker);
    try testing.expectEqualStrings("third", textOf(&doc, 0));
    try testing.expectEqualStrings("·", doc.blocks[1].marker);
    try testing.expectEqualStrings("dot", textOf(&doc, 1));
}

test "a blockquote records how deep it is nested" {
    var doc = try parse(testing.allocator, "> once\n> > twice");
    defer doc.deinit();
    try testing.expectEqual(Kind.quote, doc.blocks[0].kind);
    try testing.expectEqualStrings("once", textOf(&doc, 0));
    try testing.expectEqual(@as(u8, 0), doc.blocks[0].indent);
    try testing.expectEqualStrings("twice", textOf(&doc, 1));
    try testing.expectEqual(@as(u8, 1), doc.blocks[1].indent);
}

test "a fenced block keeps its indentation" {
    var doc = try parse(testing.allocator, "```\n    indented\n```");
    defer doc.deinit();
    try testing.expectEqualStrings("    indented", textOf(&doc, 0));
}

test "tables are parsed into cells, with each column's alignment" {
    const src =
        \\| Name | Age | Note |
        \\| :--- | ---: | :---: |
        \\| Ada | 36 | first |
        \\| Bob | 40 | second |
        \\
        \\after
    ;
    var doc = try parse(testing.allocator, src);
    defer doc.deinit();
    try testing.expectEqual(@as(usize, 2), doc.blocks.len);
    const table = doc.blocks[0];
    try testing.expectEqual(Kind.table, table.kind);
    try testing.expectEqual(@as(usize, 3), table.table_header.len);
    try testing.expectEqualStrings("Name", table.table_header[0]);
    try testing.expectEqualStrings("Note", table.table_header[2]);
    try testing.expectEqual(@as(usize, 3), table.table_align.len);
    try testing.expectEqual(Align.left, table.table_align[0]);
    try testing.expectEqual(Align.right, table.table_align[1]);
    try testing.expectEqual(Align.center, table.table_align[2]);
    try testing.expectEqual(@as(usize, 2), table.table_rows.len);
    try testing.expectEqualStrings("Ada", table.table_rows[0][0]);
    try testing.expectEqualStrings("second", table.table_rows[1][2]);
    // The paragraph after the table is still read, and the blank line between is not a block.
    try testing.expectEqual(Kind.paragraph, doc.blocks[1].kind);
    try testing.expectEqualStrings("after", textOf(&doc, 1));
}

test "a table cell may contain an escaped pipe, and a short row is padded" {
    var doc = try parse(testing.allocator, "| a | b |\n| --- | --- |\n| x \\| y |");
    defer doc.deinit();
    const table = doc.blocks[0];
    try testing.expectEqual(@as(usize, 1), table.table_rows.len);
    try testing.expectEqualStrings("x | y", table.table_rows[0][0]);
}

test "a piped line with no separator is a paragraph" {
    var doc = try parse(testing.allocator, "a | b\nnot a table");
    defer doc.deinit();
    try testing.expectEqual(@as(usize, 2), doc.blocks.len);
    try testing.expectEqual(Kind.paragraph, doc.blocks[0].kind);
    try testing.expectEqualStrings("a | b", textOf(&doc, 0));
    try testing.expectEqualStrings("not a table", textOf(&doc, 1));
}

test "a separator names fewer columns than its header leaves the rest left" {
    var doc = try parse(testing.allocator, "| a | b | c |\n| ---: | --- |\n| 1 | 2 | 3 |");
    defer doc.deinit();
    const table = doc.blocks[0];
    try testing.expectEqual(@as(usize, 3), table.table_align.len);
    try testing.expectEqual(Align.right, table.table_align[0]);
    try testing.expectEqual(Align.left, table.table_align[1]);
    try testing.expectEqual(Align.left, table.table_align[2]);
}

test "footnotes are numbered by first reference, wherever they are defined" {
    const src =
        \\See [^zeta] and then [^alpha], again [^zeta].
        \\
        \\[^alpha]: the first one
        \\[^zeta]: the other one
    ;
    var doc = try parse(testing.allocator, src);
    defer doc.deinit();
    // The definitions are not blocks of their own.
    try testing.expectEqual(@as(usize, 1), doc.blocks.len);
    try testing.expectEqualStrings("See [1] and then [2], again [1].", textOf(&doc, 0));
    try testing.expectEqual(@as(usize, 2), doc.footnotes.len);
    // `zeta` was referred to first, so it is 1.
    try testing.expectEqualStrings("zeta", doc.footnotes[0].label);
    try testing.expectEqualStrings("the other one", doc.footnotes[0].text);
    try testing.expectEqual(@as(u32, 1), doc.footnotes[0].number);
    try testing.expectEqualStrings("alpha", doc.footnotes[1].label);
    try testing.expectEqual(@as(u32, 2), doc.footnotes[1].number);
    try testing.expectEqualStrings("the first one", doc.footnote("alpha").?.text);
    try testing.expectEqualStrings("zeta", doc.footnoteAt(1).?.label);
    // Each reference is an anchor that knows its footnote.
    const block = doc.blocks[0];
    try testing.expectEqual(@as(usize, 3), block.anchors.len);
    try testing.expectEqual(Mark.footnote, block.anchors[0].mark);
    try testing.expectEqualStrings("zeta", block.anchors[0].label);
    try testing.expectEqualStrings("[1]", textOf(&doc, 0)[block.anchors[0].start..block.anchors[0].end]);
    try testing.expectEqualStrings("[2]", textOf(&doc, 0)[block.anchors[1].start..block.anchors[1].end]);
    try testing.expectEqualStrings("[1]", textOf(&doc, 0)[block.anchors[2].start..block.anchors[2].end]);
}

test "a reference with no definition still gets a number" {
    var doc = try parse(testing.allocator, "a [^missing] reference");
    defer doc.deinit();
    try testing.expectEqualStrings("a [1] reference", textOf(&doc, 0));
    try testing.expectEqual(@as(usize, 1), doc.footnotes.len);
    try testing.expectEqualStrings("", doc.footnotes[0].text);
}

test "strikethrough produces a strike span, and only over its text" {
    var doc = try parse(testing.allocator, "this is ~~gone~~ text");
    defer doc.deinit();
    const block = doc.blocks[0];
    try testing.expectEqualStrings("this is gone text", block.text);
    try testing.expectEqual(@as(usize, 1), block.spans.len);
    try testing.expect(block.spans[0].strike);
    try testing.expectEqualStrings("gone", block.text[block.spans[0].start..block.spans[0].end]);
}

test "links keep the label and open their url" {
    var doc = try parse(testing.allocator, "see [the docs](https://example.com/a) here");
    defer doc.deinit();
    const block = doc.blocks[0];
    try testing.expectEqualStrings("see the docs here", block.text);
    try testing.expectEqual(@as(usize, 1), block.anchors.len);
    try testing.expectEqual(Mark.link, block.anchors[0].mark);
    try testing.expectEqualStrings("the docs", block.text[block.anchors[0].start..block.anchors[0].end]);
    try testing.expectEqualStrings("https://example.com/a", block.anchors[0].target);
    var underlined = false;
    for (block.spans) |sp| {
        if (sp.underline) underlined = true;
    }
    try testing.expect(underlined);
}

test "an image is its alt text" {
    var doc = try parse(testing.allocator, "![a chart](chart.png)");
    defer doc.deinit();
    try testing.expectEqualStrings("[image: a chart]", textOf(&doc, 0));
}

test "bare urls, www hosts and email addresses become links" {
    const src = "Read https://example.com/docs?a=1&b=2, then www.example.org or mail me@example.com.";
    var doc = try parse(testing.allocator, src);
    defer doc.deinit();
    const block = doc.blocks[0];
    try testing.expectEqualStrings("Read https://example.com/docs?a=1&b=2, then www.example.org or mail me@example.com.", block.text);
    try testing.expectEqual(@as(usize, 3), block.anchors.len);
    try testing.expectEqualStrings("https://example.com/docs?a=1&b=2", block.anchors[0].target);
    try testing.expectEqualStrings("https://www.example.org", block.anchors[1].target);
    try testing.expectEqualStrings("mailto:me@example.com", block.anchors[2].target);
    // The sentence's own punctuation stays outside each link.
    try testing.expectEqualStrings("www.example.org", block.text[block.anchors[1].start..block.anchors[1].end]);
    try testing.expectEqualStrings("me@example.com", block.text[block.anchors[2].start..block.anchors[2].end]);
}

test "an autolink inside a word is not a link, and parentheses balance" {
    var doc = try parse(testing.allocator, "xwww.example.com and https://en.example.org/wiki/A_(b) end");
    defer doc.deinit();
    const block = doc.blocks[0];
    try testing.expectEqual(@as(usize, 1), block.anchors.len);
    try testing.expectEqualStrings("https://en.example.org/wiki/A_(b)", block.anchors[0].target);
}

test "an angle-bracketed url or address is a link without its brackets" {
    var doc = try parse(testing.allocator, "<https://example.com> and <a@b.co>");
    defer doc.deinit();
    const block = doc.blocks[0];
    try testing.expectEqualStrings("https://example.com and a@b.co", block.text);
    try testing.expectEqual(@as(usize, 2), block.anchors.len);
    try testing.expectEqualStrings("mailto:a@b.co", block.anchors[1].target);
}

test "an anchor's range survives a bullet's shift" {
    var doc = try parse(testing.allocator, "- see [docs](https://example.com)");
    defer doc.deinit();
    const block = doc.blocks[0];
    try testing.expectEqualStrings("see docs", block.text);
    try testing.expectEqualStrings("docs", block.text[block.anchors[0].start..block.anchors[0].end]);
}

test "a backslash shows the character it escapes" {
    var doc = try parse(testing.allocator, "1\\. not a list, and \\*not italic\\*");
    defer doc.deinit();
    try testing.expectEqual(@as(usize, 1), doc.blocks.len);
    try testing.expectEqualStrings("1. not a list, and *not italic*", textOf(&doc, 0));
}

test "a code span with several backticks, and one with padded spaces" {
    var doc = try parse(testing.allocator, "a `` ` `` b and ` x ` c");
    defer doc.deinit();
    const block = doc.blocks[0];
    try testing.expectEqualStrings("a ` b and x c", block.text);
    try testing.expectEqual(@as(usize, 2), block.spans.len);
    try testing.expectEqualStrings("`", block.text[block.spans[0].start..block.spans[0].end]);
    try testing.expectEqualStrings("x", block.text[block.spans[1].start..block.spans[1].end]);
}

test "bold and italic nest, and each closes at its own marker" {
    var doc = try parse(testing.allocator, "**bold *both* bold** and *italic **both** italic*");
    defer doc.deinit();
    const block = doc.blocks[0];
    try testing.expectEqualStrings("bold both bold and italic both italic", block.text);
    var bold_both = false;
    for (block.spans) |sp| {
        if (sp.weight != null and sp.italic) bold_both = true;
    }
    try testing.expect(bold_both);
}
