//! Syntax highlighting for a fenced code block, from the language its fence
//! named. It is a tokenizer, not a parser: it knows comments, strings,
//! numbers, keywords and a few shapes that read as one (`fn name`, `Type`,
//! `CONSTANT`), which is enough to make code scannable without pretending to
//! understand it.
//!
//! The colours are mixed from the window's own palette rather than fixed, so
//! every theme — and both of the light ones — highlights in a way that belongs
//! to it.
const std = @import("std");
const ui = @import("nanoui").ui;
const theme = @import("theme.zig");

/// What a run of the source is, which decides its colour and weight.
pub const Kind = enum {
    /// `if`, `const`, `fn`, `def`, `select` — the language's own words.
    keyword,
    /// A name that reads as a type: `String`, `Vec`, `ui.Context`.
    type_name,
    /// A name that reads as a constant: `MAX_BODY_SIZE`, `Null`.
    constant,
    /// A function's name where the language marks it: after `fn`, before `(`.
    function,
    /// A quoted string, including its quotes.
    string,
    /// A number, with its suffix and exponent.
    number,
    /// A comment, to the end of its line or to its closing marker.
    comment,
    /// `#include`, `@decorator`, `#[derive]` — a line's directive.
    meta,
    /// An operator or bracket: quieter than the names around it.
    punctuation,
};

/// A highlighted run of the block's text, as `ui.Span` ranges.
pub fn spans(
    a: std.mem.Allocator,
    lang: []const u8,
    src: []const u8,
    palette: theme.Palette,
) ![]ui.Span {
    const dialect = Dialect.of(lang);
    const colours = Colours.of(palette);
    var tokens: Tokens = .empty;
    defer tokens.deinit(a);
    try scan(a, dialect, src, &tokens);

    const out = try a.alloc(ui.Span, tokens.items.len);
    for (tokens.items, 0..) |t, i| {
        out[i] = .{
            .start = t.start,
            .end = t.end,
            .color = colours.colour(t.kind),
            .weight = switch (t.kind) {
                .keyword => .semibold,
                .comment => null,
                else => null,
            },
            .italic = t.kind == .comment,
        };
    }
    return out;
}

/// How a language spells its comments, strings and keywords.
const Dialect = struct {
    line_comment: []const u8 = "//",
    /// Extra line-comment markers beyond the first (`#`, `--`, `%`).
    alt_comment: []const u8 = "",
    block_open: []const u8 = "",
    block_close: []const u8 = "",
    /// A string opened by `"` closes at `"` and honours `\` escapes.
    quotes: []const u8 = "\"'",
    /// A string opened by a backtick runs to the next backtick, newlines and
    /// all (JavaScript, Go, SQL).
    backtick: bool = false,
    /// A raw string's quotes that ignore `\` (Python's `r"..."` is rarer than
    /// its ordinary form, so this is off unless a dialect says otherwise).
    raw_prefixed: bool = false,
    /// `#` starts a directive (C's `#include`, Rust's `#[derive]`).
    hash_directive: bool = false,
    /// `@` starts one (Python's, Java's decorators).
    at_directive: bool = false,
    /// `\\` at the start of a line opens a string that runs to the end of it:
    /// Zig's multiline string literal. It is the language's most common way to
    /// write a block of text, and without it those lines read as code.
    backslash_string: bool = false,
    keywords: []const []const u8 = &.{},

    fn of(lang_in: []const u8) Dialect {
        // The fence's info string may carry more than the language
        // ("```zig title=main.zig"); only the first word names it.
        const lang = blk: {
            const end = std.mem.indexOfAny(u8, lang_in, " \t{,") orelse lang_in.len;
            break :blk lang_in[0..end];
        };
        for (table) |entry| {
            for (entry.names) |name| {
                if (std.ascii.eqlIgnoreCase(lang, name)) return entry.dialect;
            }
        }
        return generic;
    }

    const Entry = struct { names: []const []const u8, dialect: Dialect };

    const c_like = Dialect{
        .line_comment = "//",
        .block_open = "/*",
        .block_close = "*/",
        .keywords = &.{
            "if",        "else",     "for",      "while",     "do",     "switch",  "case",
            "break",     "continue", "return",   "struct",    "union",  "enum",    "typedef",
            "static",    "const",    "volatile", "extern",    "sizeof", "goto",    "inline",
            "void",      "int",      "char",     "float",     "double", "long",    "short",
            "unsigned",  "signed",   "auto",     "register",  "class",  "public",  "private",
            "protected", "virtual",  "template", "namespace", "using",  "new",     "delete",
            "try",       "catch",    "throw",    "operator",  "this",   "nullptr", "true",
            "false",
        },
    };

    const zig = Dialect{
        .line_comment = "//",
        .quotes = "\"'",
        .backslash_string = true,
        .keywords = &.{
            "const",    "var",      "fn",             "pub",       "return",      "if",          "else",
            "for",      "while",    "switch",         "struct",    "enum",        "union",       "error",
            "try",      "catch",    "defer",          "errdefer",  "comptime",    "inline",      "export",
            "extern",   "test",     "usingnamespace", "asm",       "unreachable", "orelse",      "and",
            "or",       "break",    "continue",       "null",      "undefined",   "true",        "false",
            "async",    "await",    "resume",         "suspend",   "nosuspend",   "threadlocal", "anytype",
            "anyframe", "align",    "allowzero",      "callconv",  "linksection", "noalias",     "noinline",
            "packed",   "volatile", "opaque",         "addrspace",
        },
    };

    const rust = Dialect{
        .line_comment = "//",
        .block_open = "/*",
        .block_close = "*/",
        .hash_directive = true,
        .keywords = &.{
            "fn",   "let",   "mut",    "const",  "static", "struct", "enum",
            "impl", "trait", "pub",    "use",    "mod",    "return", "if",
            "else", "match", "for",    "while",  "loop",   "break",  "continue",
            "self", "Self",  "super",  "crate",  "async",  "await",  "move",
            "dyn",  "where", "unsafe", "extern", "as",     "in",     "ref",
            "true", "false", "type",   "union",
        },
    };

    const python = Dialect{
        .line_comment = "#",
        .quotes = "\"'",
        .at_directive = true,
        .keywords = &.{
            "def",    "class",    "return",   "if",     "elif",  "else",   "for",
            "while",  "break",    "continue", "import", "from",  "as",     "with",
            "try",    "except",   "finally",  "raise",  "pass",  "lambda", "yield",
            "global", "nonlocal", "assert",   "del",    "and",   "or",     "not",
            "in",     "is",       "None",     "True",   "False", "async",  "await",
            "self",
        },
    };

    const js = Dialect{
        .line_comment = "//",
        .block_open = "/*",
        .block_close = "*/",
        .backtick = true,
        .keywords = &.{
            "function",  "const",   "let",    "var",        "return",   "if",         "else",
            "for",       "while",   "do",     "switch",     "case",     "break",      "continue",
            "class",     "extends", "new",    "this",       "typeof",   "instanceof", "in",
            "of",        "try",     "catch",  "finally",    "throw",    "async",      "await",
            "yield",     "import",  "export", "default",    "from",     "null",       "undefined",
            "true",      "false",   "delete", "void",       "static",   "get",        "set",
            "interface", "type",    "enum",   "implements", "readonly",
        },
    };

    const shell = Dialect{
        .line_comment = "#",
        .quotes = "\"'",
        .keywords = &.{
            "if",     "then",     "else",  "elif",  "fi",       "for",    "while",
            "do",     "done",     "case",  "esac",  "function", "return", "local",
            "export", "readonly", "unset", "shift", "trap",     "set",    "source",
            "echo",   "printf",   "cd",    "exit",  "test",
        },
    };

    const json = Dialect{
        .line_comment = "",
        .keywords = &.{ "true", "false", "null" },
    };

    const go = Dialect{
        .line_comment = "//",
        .block_open = "/*",
        .block_close = "*/",
        .backtick = true,
        .keywords = &.{
            "func", "var",     "const",  "type",   "struct", "interface", "map",
            "chan", "go",      "defer",  "select", "case",   "default",   "switch",
            "if",   "else",    "for",    "range",  "return", "break",     "continue",
            "goto", "package", "import", "nil",    "true",   "false",     "fallthrough",
        },
    };

    const sql = Dialect{
        .line_comment = "--",
        .block_open = "/*",
        .block_close = "*/",
        .backtick = true,
        .keywords = &.{
            "select", "from",   "where",  "insert", "into",   "values",   "update",
            "set",    "delete", "create", "table",  "index",  "alter",    "drop",
            "join",   "left",   "right",  "inner",  "outer",  "on",       "group",
            "by",     "order",  "having", "limit",  "offset", "as",       "and",
            "or",     "not",    "null",   "is",     "in",     "distinct", "union",
        },
    };

    const ini = Dialect{
        .line_comment = ";",
        .alt_comment = "#",
        .quotes = "\"'",
        .keywords = &.{ "true", "false" },
    };

    const generic = Dialect{
        .line_comment = "//",
        .alt_comment = "#",
        .block_open = "/*",
        .block_close = "*/",
        .backtick = true,
        .hash_directive = true,
        .at_directive = true,
        .keywords = &.{ "true", "false", "null", "nil", "none", "True", "False", "None" },
    };

    const table = [_]Entry{
        .{ .names = &.{ "zig", "zon" }, .dialect = zig },
        .{ .names = &.{ "c", "h", "cc", "cpp", "cxx", "hpp", "objc", "java", "cs", "csharp", "kotlin", "swift", "scala" }, .dialect = c_like },
        .{ .names = &.{ "rust", "rs" }, .dialect = rust },
        .{ .names = &.{ "python", "py", "pyi" }, .dialect = python },
        .{ .names = &.{ "js", "javascript", "jsx", "ts", "typescript", "tsx", "mjs", "cjs", "json5" }, .dialect = js },
        .{ .names = &.{ "sh", "bash", "zsh", "shell", "console", "fish", "dotenv", "env", "toml", "yaml", "yml", "dockerfile", "make", "makefile" }, .dialect = shell },
        .{ .names = &.{"json"}, .dialect = json },
        .{ .names = &.{ "go", "golang" }, .dialect = go },
        .{ .names = &.{ "sql", "postgres", "sqlite", "mysql" }, .dialect = sql },
        .{ .names = &.{ "ini", "conf", "cfg", "properties" }, .dialect = ini },
    };
};

/// One colour per kind, mixed from the palette so every theme highlights in
/// its own terms instead of importing another editor's.
const Colours = struct {
    keyword: ui.Color,
    type_name: ui.Color,
    constant: ui.Color,
    function: ui.Color,
    string: ui.Color,
    number: ui.Color,
    comment: ui.Color,
    meta: ui.Color,
    punctuation: ui.Color,

    fn of(p: theme.Palette) Colours {
        const accent = p.accent;
        return .{
            // Control words take the accent the rest of the window uses, a
            // shade deeper so a page of code does not read as links.
            .keyword = accent.mix(p.text, 0.35),
            .type_name = accent.mix(p.text, 0.15),
            .constant = p.warning,
            // A call's name is the accent, lightened: several palettes set
            // `success` to the same green as `accent`, so a function painted
            // with the accent alone would be the same colour as a string.
            .function = accent.mix(p.text, 0.55),
            .string = p.success,
            // A lighter warning than a constant's, so a literal number and a
            // named constant read as the same family but not the same thing.
            .number = p.warning.mix(p.text, 0.3),
            // A comment is meant to be skipped, so it is the quietest thing
            // on the surface.
            .comment = p.muted.alpha(0.85),
            .meta = p.danger.mix(p.text, 0.25),
            .punctuation = p.muted,
        };
    }

    fn colour(self: Colours, kind: Kind) ui.Color {
        return switch (kind) {
            .keyword => self.keyword,
            .type_name => self.type_name,
            .constant => self.constant,
            .function => self.function,
            .string => self.string,
            .number => self.number,
            .comment => self.comment,
            .meta => self.meta,
            .punctuation => self.punctuation,
        };
    }
};

const Tok = struct { start: u32, end: u32, kind: Kind };
const Tokens = std.ArrayListUnmanaged(Tok);

fn push(tokens: *Tokens, a: std.mem.Allocator, start: usize, end: usize, kind: Kind) !void {
    if (end <= start) return;
    try tokens.append(a, .{ .start = @intCast(start), .end = @intCast(end), .kind = kind });
}

fn isWordChar(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '_';
}

/// The characters that read as punctuation: brackets, separators, operators.
/// Quotes and backticks are left out on purpose — they open strings, and a
/// run that took them in would start the string too late to colour it.
fn isPunct(c: u8) bool {
    return switch (c) {
        '(',
        ')',
        '[',
        ']',
        '{',
        '}',
        '<',
        '>',
        ',',
        ';',
        ':',
        '.',
        '?',
        '!',
        '+',
        '-',
        '*',
        '/',
        '%',
        '&',
        '|',
        '^',
        '~',
        '=',
        '@',
        '#',
        '$',
        '\\',
        => true,
        else => false,
    };
}

fn scan(a: std.mem.Allocator, d: Dialect, src: []const u8, tokens: *Tokens) !void {
    var i: usize = 0;
    // A quote's opening, so a string that never closes stops at its line
    // rather than colouring the rest of the block.
    var line_end = std.mem.indexOfScalar(u8, src, '\n') orelse src.len;

    while (i < src.len) {
        const c = src[i];
        if (i > line_end) line_end = std.mem.indexOfScalarPos(u8, src, i, '\n') orelse src.len;

        // Comments, which swallow whatever follows them.
        if (d.line_comment.len > 0 and std.mem.startsWith(u8, src[i..], d.line_comment)) {
            try push(tokens, a, i, line_end, .comment);
            i = line_end;
            continue;
        }
        if (d.alt_comment.len > 0 and std.mem.startsWith(u8, src[i..], d.alt_comment)) {
            try push(tokens, a, i, line_end, .comment);
            i = line_end;
            continue;
        }
        if (d.block_open.len > 0 and std.mem.startsWith(u8, src[i..], d.block_open)) {
            // Nested block comments exist in Rust and Zig; counting the
            // markers is what keeps the highlight from ending early.
            var depth: usize = 1;
            var j = i + d.block_open.len;
            while (j < src.len and depth > 0) {
                if (std.mem.startsWith(u8, src[j..], d.block_open)) {
                    depth += 1;
                    j += d.block_open.len;
                } else if (std.mem.startsWith(u8, src[j..], d.block_close)) {
                    depth -= 1;
                    j += d.block_close.len;
                } else j += 1;
            }
            try push(tokens, a, i, j, .comment);
            i = j;
            continue;
        }
        if (d.hash_directive and c == '#') {
            try push(tokens, a, i, line_end, .meta);
            i = line_end;
            continue;
        }
        if (d.at_directive and c == '@') {
            var j = i + 1;
            while (j < src.len and (isWordChar(src[j]) or src[j] == '.')) j += 1;
            try push(tokens, a, i, j, .meta);
            i = j;
            continue;
        }

        // Zig's multiline string: `\\text`, to the end of the line.
        if (d.backslash_string and c == '\\' and i + 1 < src.len and src[i + 1] == '\\' and
            (i == 0 or src[i - 1] == '\n' or src[i - 1] == ' ' or src[i - 1] == '\t'))
        {
            try push(tokens, a, i, line_end, .string);
            i = line_end;
            continue;
        }

        // Strings.
        if (std.mem.indexOfScalar(u8, d.quotes, c) != null) {
            var j = i + 1;
            while (j < src.len) {
                if (src[j] == '\\' and j + 1 < src.len) {
                    j += 2;
                    continue;
                }
                if (src[j] == c) {
                    j += 1;
                    break;
                }
                // A plain quote's string does not run past its line.
                if (src[j] == '\n') break;
                j += 1;
            }
            try push(tokens, a, i, j, .string);
            i = j;
            continue;
        }
        if (d.backtick and c == '`') {
            const close = std.mem.indexOfScalarPos(u8, src, i + 1, '`') orelse src.len;
            const end = @min(close + 1, src.len);
            try push(tokens, a, i, end, .string);
            i = end;
            continue;
        }

        // Numbers: digits, then whatever else a literal may carry.
        if (std.ascii.isDigit(c) and !(i > 0 and isWordChar(src[i - 1]))) {
            var j = i;
            while (j < src.len and (std.ascii.isAlphanumeric(src[j]) or src[j] == '.' or src[j] == '_')) {
                // A `.` only belongs to the number when a digit follows it,
                // so `1..5` stays a range and `1.5` stays one number.
                if (src[j] == '.' and !(j + 1 < src.len and std.ascii.isDigit(src[j + 1]))) break;
                j += 1;
            }
            try push(tokens, a, i, j, .number);
            i = j;
            continue;
        }

        // Words: keywords, then whatever their shape suggests.
        if (isWordChar(c) and !(i > 0 and isWordChar(src[i - 1]))) {
            var j = i;
            while (j < src.len and isWordChar(src[j])) j += 1;
            // Each segment of a dotted path is its own word: `ui.Context`
            // colours the type and leaves `ui` alone, which is what an
            // editor shows and what keeps a field name from reading as one.
            const after = j;
            const word = src[i..j];
            const kind: ?Kind = blk: {
                for (d.keywords) |kw| {
                    if (std.mem.eql(u8, kw, word)) break :blk .keyword;
                }
                // `fn name`, `def name`, `func name`, `function name`.
                if (isDefinitionHead(src, i)) break :blk .function;
                if (followedByCall(src, after)) break :blk .function;
                if (isNamedConstant(word)) break :blk .constant;
                if (std.ascii.isUpper(word[0])) break :blk .type_name;
                break :blk null;
            };
            if (kind) |k| try push(tokens, a, i, after, k);
            i = after;
            continue;
        }

        // Punctuation, gathered so a run of it is one span. The set is
        // explicit rather than ASCII's: a `"` or a backtick opens a string,
        // and letting it into a punctuation run swallowed the quote and
        // painted the rest of the line as one.
        if (isPunct(c) or c == ' ' or c == '\t') {
            var j = i;
            while (j < src.len and (isPunct(src[j]) or src[j] == ' ' or src[j] == '\t')) {
                // A `\\` that opens a Zig string belongs to the string, not to
                // the run of indentation and operators in front of it. Stop
                // here so the next pass sees it.
                if (d.backslash_string and src[j] == '\\' and j + 1 < src.len and src[j + 1] == '\\') break;
                j += 1;
            }
            if (j > i) {
                try push(tokens, a, i, j, .punctuation);
                i = j;
                continue;
            }
        }
        i += 1;
    }
}

/// Whether the word at `at` is a name being defined: `fn f`, `def f`,
/// `func f`, `function f`, `class T`.
fn isDefinitionHead(src: []const u8, at: usize) bool {
    const heads = [_][]const u8{ "fn", "def", "func", "function", "class", "struct", "enum", "trait", "impl", "interface", "type" };
    var k = at;
    while (k > 0 and (src[k - 1] == ' ' or src[k - 1] == '\t')) k -= 1;
    if (k == 0 or k == at) return false;
    const word_end = k;
    var word_start = k;
    while (word_start > 0 and isWordChar(src[word_start - 1])) word_start -= 1;
    const word = src[word_start..word_end];
    for (heads) |h| if (std.mem.eql(u8, h, word)) return true;
    return false;
}

/// Whether a name is called rather than used: the next non-space character
/// opens an argument list.
fn followedByCall(src: []const u8, at: usize) bool {
    var k = at;
    while (k < src.len and (src[k] == ' ' or src[k] == '\t')) k += 1;
    return k < src.len and src[k] == '(';
}

/// `MAX_BODY_SIZE`, `KEY_LEN`: a name of capitals and digits that is not a
/// single letter.
fn isNamedConstant(word: []const u8) bool {
    if (word.len < 2) return false;
    var letters: usize = 0;
    for (word) |c| {
        if (std.ascii.isLower(c)) return false;
        if (std.ascii.isAlphabetic(c)) letters += 1;
    }
    return letters >= 2;
}

// --------------------------------------------------------------------- tests

const testing = std.testing;
const neutral = @import("theme.zig").neutral;

const Found = struct { kind: Kind, text: []const u8 };

/// The kinds the tokenizer found, in order, with their text.
fn kinds(gpa: std.mem.Allocator, lang: []const u8, src: []const u8) ![]Found {
    const spans_ = try spans(gpa, lang, src, neutral);
    defer gpa.free(spans_);
    const out = try gpa.alloc(Found, spans_.len);
    for (spans_, 0..) |sp, i| {
        out[i] = .{ .kind = kindOf(sp, neutral), .text = src[sp.start..sp.end] };
    }
    return out;
}

fn kindOf(sp: ui.Span, p: theme.Palette) Kind {
    const cs = Colours.of(p);
    for ([_]Kind{ .keyword, .type_name, .constant, .function, .string, .number, .comment, .meta, .punctuation }) |k| {
        if (std.meta.eql(cs.colour(k), sp.color.?)) return k;
    }
    return .punctuation;
}

test "zig keywords, strings, numbers and comments are told apart" {
    const src =
        \\const x = 42;
        \\// a note
        \\pub fn main() void {
        \\    const name = "hello";
        \\}
    ;
    const toks = try kinds(testing.allocator, "zig", src);
    defer testing.allocator.free(toks);

    var saw_const = false;
    var saw_pub = false;
    var saw_number = false;
    var saw_string = false;
    var saw_comment = false;
    var saw_function = false;
    for (toks) |t| {
        if (t.kind == .keyword and std.mem.eql(u8, t.text, "const")) saw_const = true;
        if (t.kind == .keyword and std.mem.eql(u8, t.text, "pub")) saw_pub = true;
        if (t.kind == .number and std.mem.eql(u8, t.text, "42")) saw_number = true;
        if (t.kind == .string and std.mem.eql(u8, t.text, "\"hello\"")) saw_string = true;
        if (t.kind == .comment and std.mem.eql(u8, t.text, "// a note")) saw_comment = true;
        if (t.kind == .function and std.mem.eql(u8, t.text, "main")) saw_function = true;
    }
    try testing.expect(saw_const);
    try testing.expect(saw_pub);
    try testing.expect(saw_number);
    try testing.expect(saw_string);
    try testing.expect(saw_comment);
    try testing.expect(saw_function);
}

test "zig's multiline string is a string, not code" {
    // `\\const x = 1;` is text, not a declaration: without this the words
    // inside it would be coloured as keywords and the reader would be lied to.
    const src = "const doc =\n    \\\\const x = 1;\n    \\\\return x;\n;";
    const toks = try kinds(testing.allocator, "zig", src);
    defer testing.allocator.free(toks);

    var saw_keyword_string = false;
    var saw_real_keyword = false;
    for (toks) |t| {
        if (t.kind == .keyword and std.mem.eql(u8, t.text, "const") and std.mem.indexOf(u8, t.text, "\\") != null) saw_keyword_string = true;
        if (t.kind == .keyword and std.mem.eql(u8, t.text, "const")) saw_real_keyword = true;
    }
    // The `const` inside the string is part of a string span, not a keyword.
    try testing.expect(saw_real_keyword);
    try testing.expect(!saw_keyword_string);
    var saw_string = false;
    var saw_wrong_keyword = false;
    for (toks) |t| {
        if (t.kind == .string and std.mem.indexOf(u8, t.text, "return x;") != null) saw_string = true;
        if (t.kind == .keyword and std.mem.eql(u8, t.text, "return")) saw_wrong_keyword = true;
    }
    try testing.expect(saw_string);
    try testing.expect(!saw_wrong_keyword);
}

test "a shell comment runs to the end of its line" {
    const toks = try kinds(testing.allocator, "sh", "# install it\nnullclaw onboard");
    defer testing.allocator.free(toks);
    try testing.expectEqual(Kind.comment, toks[0].kind);
    try testing.expectEqualStrings("# install it", toks[0].text);
}

test "a block comment does not end at its first close marker" {
    // Rust nests block comments; the highlight has to follow the depth or the
    // rest of the block would be painted as a comment.
    const src = "/* outer /* inner */ still */ code";
    const toks = try kinds(testing.allocator, "rust", src);
    defer testing.allocator.free(toks);
    try testing.expectEqual(Kind.comment, toks[0].kind);
    try testing.expectEqualStrings("/* outer /* inner */ still */", toks[0].text);
}

test "a type name and a constant are not keywords" {
    const toks = try kinds(testing.allocator, "zig", "const MAX_BODY_SIZE: usize = Buffer.len;");
    defer testing.allocator.free(toks);
    var saw_constant = false;
    var saw_type = false;
    for (toks) |t| {
        if (t.kind == .constant and std.mem.eql(u8, t.text, "MAX_BODY_SIZE")) saw_constant = true;
        if (t.kind == .type_name and std.mem.eql(u8, t.text, "Buffer")) saw_type = true;
    }
    try testing.expect(saw_constant);
    try testing.expect(saw_type);
}

test "an unknown language still breaks strings and numbers out" {
    const toks = try kinds(testing.allocator, "brainfuck", "x = \"text\" + 12");
    defer testing.allocator.free(toks);
    var saw_string = false;
    var saw_number = false;
    for (toks) |t| {
        if (t.kind == .string) saw_string = true;
        if (t.kind == .number) saw_number = true;
    }
    try testing.expect(saw_string);
    try testing.expect(saw_number);
}

test "spans stay inside the text they were found in" {
    const src = "fn a(x: u8) []const u8 { return \"}\"; }";
    const spans_ = try spans(testing.allocator, "zig", src, neutral);
    defer testing.allocator.free(spans_);
    var last: u32 = 0;
    for (spans_) |sp| {
        try testing.expect(sp.start >= last);
        try testing.expect(sp.end <= src.len);
        try testing.expect(sp.end > sp.start);
        last = sp.end;
    }
}
