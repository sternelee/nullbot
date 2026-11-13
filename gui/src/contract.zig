//! Checks the GUI's pages against the runtime's own CLI surface.
//!
//! The GUI and the runtime are separate binaries — the GUI drives `nullclaw`
//! as a child process — so nothing but this test keeps their command names
//! aligned. If the runtime
//! renames or drops a command, this fails here instead of in a toast.
const std = @import("std");
const testing = std.testing;

const state = @import("state.zig");

const io = std.Io.Threaded.global_single_threaded.io();

/// A page and the `*_SUBCOMMANDS` constant its subcommand belongs to (null for
/// a page that is a top-level command). The `--json` column is not repeated
/// here: it is derived from the runtime's usage text and compared with what
/// `Page.takesJson` claims, so the two cannot drift apart silently.
const Expect = struct {
    page: state.Page,
    set: ?[]const u8 = null,
};

const expects = [_]Expect{
    .{ .page = .status },
    .{ .page = .capabilities },
    .{ .page = .doctor },
    .{ .page = .config, .set = "CONFIG_SUBCOMMANDS" },
    .{ .page = .models, .set = "MODELS_SUBCOMMANDS" },
    .{ .page = .memory, .set = "MEMORY_SUBCOMMANDS" },
    .{ .page = .skills, .set = "SKILLS_SUBCOMMANDS" },
    .{ .page = .channels, .set = "CHANNEL_SUBCOMMANDS" },
    .{ .page = .cron, .set = "CRON_SUBCOMMANDS" },
    .{ .page = .mcp, .set = "MCP_SUBCOMMANDS" },
    .{ .page = .auth, .set = "AUTH_SUBCOMMANDS" },
    .{ .page = .workspace, .set = "WORKSPACE_SUBCOMMANDS" },
    .{ .page = .hardware, .set = "HARDWARE_SUBCOMMANDS" },
    .{ .page = .service, .set = "SERVICE_SUBCOMMANDS" },
    .{ .page = .update },
};

/// The runtime's source, read from the repository the GUI lives in.
fn runtimeSource(gpa: std.mem.Allocator) ?[]u8 {
    return std.Io.Dir.cwd().readFileAlloc(io, "../src/main.zig", gpa, .limited(4 << 20)) catch null;
}

/// The source with the `\\` of its multiline strings stripped, so the usage
/// text reads as it prints.
fn unescaped(gpa: std.mem.Allocator, src: []const u8) ![]u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(gpa);
    var lines = std.mem.splitScalar(u8, src, '\n');
    while (lines.next()) |line| {
        const body = std.mem.trimStart(u8, line, " \t");
        const text = if (std.mem.startsWith(u8, body, "\\\\")) body[2..] else body;
        try out.appendSlice(gpa, text);
        try out.append(gpa, '\n');
    }
    return out.toOwnedSlice(gpa);
}

/// The usage text the runtime prints for `constant`, taken from the block that
/// closes with `.{CONSTANT})`.
fn usageFor(src: []const u8, constant: []const u8) ?[]const u8 {
    var marker_buf: [128]u8 = undefined;
    const marker = std.fmt.bufPrint(&marker_buf, ".{{{s}}})", .{constant}) catch return null;
    const at = std.mem.indexOf(u8, src, marker) orelse return null;
    return src[@max(0, at -| 3000)..at];
}

/// The words of a `const NAME = "a|b|c";` line.
fn subcommands(src: []const u8, constant: []const u8) ?[]const u8 {
    var marker_buf: [128]u8 = undefined;
    const marker = std.fmt.bufPrint(&marker_buf, "const {s} = \"", .{constant}) catch return null;
    const at = std.mem.indexOf(u8, src, marker) orelse return null;
    const rest = src[at + marker.len ..];
    const end = std.mem.indexOfScalar(u8, rest, '"') orelse return null;
    return rest[0..end];
}

/// The command names the runtime's usage block lists under COMMANDS.
fn topLevel(src: []const u8, gpa: std.mem.Allocator) ![][]const u8 {
    var names: std.ArrayListUnmanaged([]const u8) = .empty;
    const start = (std.mem.indexOf(u8, src, "COMMANDS:") orelse return names.toOwnedSlice(gpa)) + "COMMANDS:".len;
    const end = std.mem.indexOfPos(u8, src, start, "OPTIONS:") orelse src.len;
    var lines = std.mem.splitScalar(u8, src[start..end], '\n');
    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (trimmed.len == 0) continue;
        const name = trimmed[0..(std.mem.indexOfAny(u8, trimmed, " \t") orelse trimmed.len)];
        try names.append(gpa, name);
    }
    return names.toOwnedSlice(gpa);
}

/// The word the runtime's usage text would name this command by: its
/// subcommand if it has one, otherwise the command itself. `--check` and
/// `openai-codex` are arguments, not subcommands.
fn needleWord(words: []const []const u8) []const u8 {
    if (words.len > 1 and !std.mem.startsWith(u8, words[1], "-")) return words[1];
    return words[0];
}

/// The body of a top-level function, up to the next one.
fn functionBody(src: []const u8, name: []const u8) ?[]const u8 {
    var buf: [128]u8 = undefined;
    const marker = std.fmt.bufPrint(&buf, "fn {s}(", .{name}) catch return null;
    const at = std.mem.indexOf(u8, src, marker) orelse return null;
    const rest = src[at..];
    const end = std.mem.indexOf(u8, rest[1..], "\nfn ") orelse rest.len;
    return rest[0..end];
}

/// A function of the runtime's that writes JSON, and the keys the GUI reads out
/// of it. The GUI parses these by name, so a rename on the runtime's side has to
/// fail here rather than turn into an empty panel.
const Emitter = struct {
    name: []const u8,
    keys: []const []const u8,
};

const emitters = [_]Emitter{
    // `history list --json` and `history show <key> --json`.
    .{ .name = "appendHistoryListJson", .keys = &.{
        "total",      "limit",         "offset",           "sessions",
        "session_id", "message_count", "first_message_at", "last_message_at",
    } },
    .{ .name = "appendHistoryShowJson", .keys = &.{
        "session_id", "total",   "limit",      "offset", "messages",
        "role",       "content", "created_at",
    } },
    // `agent sessions list --json` and `agent invoke --json`.
    .{ .name = "appendAgentSessionListJson", .keys = &.{
        "sessions", "session_key", "created_at", "last_active", "turn_count", "total",
    } },
    .{ .name = "appendAgentInvokeResponseJson", .keys = &.{ "session", "response", "turn_count" } },
    // Every failed command's envelope.
    .{ .name = "appendJsonError", .keys = &.{ "error", "message" } },
};

test "the json the pages parse is the json the runtime writes" {
    const gpa = testing.allocator;
    // The raw source, not `unescaped`: the key names are matched in the escaped
    // form they take inside a Zig string literal, which is how they are written.
    const src = runtimeSource(gpa) orelse return error.SkipZigTest;
    defer gpa.free(src);

    for (emitters) |emitter| {
        const body = functionBody(src, emitter.name) orelse {
            std.debug.print("the runtime no longer has {s}\n", .{emitter.name});
            return error.MissingEmitter;
        };
        for (emitter.keys) |key| {
            var buf: [64]u8 = undefined;
            const literal = try std.fmt.bufPrint(&buf, "\\\"{s}\\\"", .{key});
            if (std.mem.indexOf(u8, body, literal) == null) {
                std.debug.print("{s} no longer writes `{s}`\n", .{ emitter.name, key });
            }
            try testing.expect(std.mem.indexOf(u8, body, literal) != null);
        }
    }
}

test "every page's command exists in the runtime's CLI" {
    const gpa = testing.allocator;
    const raw = runtimeSource(gpa) orelse return error.SkipZigTest;
    defer gpa.free(raw);
    const src = try unescaped(gpa, raw);
    defer gpa.free(src);

    const names = try topLevel(src, gpa);
    defer gpa.free(names);
    try testing.expect(names.len > 15);

    for (expects) |expect| {
        const words = expect.page.command() orelse continue;
        try testing.expect(words.len >= 1);

        var found = false;
        for (names) |name| {
            if (std.mem.eql(u8, name, words[0])) found = true;
        }
        if (!found) std.debug.print("page {s}: no `{s}` command\n", .{ @tagName(expect.page), words[0] });
        try testing.expect(found);

        if (expect.set) |constant| {
            const set = subcommands(src, constant) orelse {
                std.debug.print("page {s}: no {s}\n", .{ @tagName(expect.page), constant });
                return error.MissingSubcommandSet;
            };
            try testing.expect(words.len >= 2);
            var it = std.mem.splitScalar(u8, set, '|');
            var known = false;
            while (it.next()) |word| {
                if (std.mem.eql(u8, word, words[1])) known = true;
            }
            if (!known) std.debug.print("page {s}: `{s}` is not in {s} ({s})\n", .{ @tagName(expect.page), words[1], constant, set });
            try testing.expect(known);
        }
    }
}

test "the pages that ask for json are the ones the runtime prints json for" {
    const gpa = testing.allocator;
    const raw = runtimeSource(gpa) orelse return error.SkipZigTest;
    defer gpa.free(raw);
    const src = try unescaped(gpa, raw);
    defer gpa.free(src);

    for (expects) |expect| {
        const words = expect.page.command() orelse continue;
        // A page's command is documented in its own command's usage block; a
        // top-level one anywhere in the usage text.
        const scope = if (expect.set) |constant| usageFor(src, constant) orelse src else src;

        var needle_buf: [64]u8 = undefined;
        const needle = try std.fmt.bufPrint(&needle_buf, "{s} [--json]", .{needleWord(words)});
        const documented = std.mem.indexOf(u8, scope, needle) != null;
        if (documented != expect.page.takesJson()) {
            std.debug.print("page {s}: Page.takesJson says {} but `{s}` is {s}\n", .{
                @tagName(expect.page),                              expect.page.takesJson(), needle,
                if (documented) "documented" else "not documented",
            });
        }
        try testing.expectEqual(documented, expect.page.takesJson());
    }
}

test "the pages cover every command the runtime offers as a page" {
    // The nav is the feature list: every page the sidebar shows must be one
    // this file has checked, so a new page cannot slip in unverified.
    try testing.expectEqual(state.nav.len, expects.len + 1); // + chat, which runs no command
    for (state.nav) |page| {
        if (page == .chat) continue;
        var seen = false;
        for (expects) |expect| {
            if (expect.page == page) seen = true;
        }
        try testing.expect(seen);
    }
}
