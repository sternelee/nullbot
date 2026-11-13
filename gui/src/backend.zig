//! Everything the GUI knows about the NullClaw runtime: where its files live,
//! which commands to run, and how to read the JSON they print.
//!
//! The GUI does not link NullClaw; instead this module describes the
//! command line the GUI drives as a child process and the shapes it parses
//! back. Keeping all of that here means it is testable without a window.
const std = @import("std");
const Io = std.Io;

pub const exe = "nullclaw";

/// The environment variable that points the window at a different runtime
/// binary: a build from a checkout, or a stub in a test. Empty counts as
/// unset. Without it the window prefers the runtime bundled beside itself —
/// `gui/zig-out/bin/nullclaw` sits next to `gui/zig-out/bin/nullclaw-gui` —
/// and only then falls back to `PATH`. The returned slice is owned by the
/// caller.
pub fn executable(
    gpa: std.mem.Allocator,
    io: Io,
    environ: std.process.Environ.Map,
) ![]u8 {
    if (environ.get("NULLCLAW_BIN")) |path| {
        if (path.len > 0) return gpa.dupe(u8, path);
    }
    if (std.process.executablePathAlloc(io, gpa)) |self_path| {
        defer gpa.free(self_path);
        if (std.fs.path.dirname(self_path)) |dir| {
            if (std.fs.path.join(gpa, &.{ dir, exe })) |path| {
                // The path is absolute (it came from the GUI's own location),
                // so it must be checked with accessAbsolute: Dir.cwd().access
                // would treat it as relative to the cwd and wrongly miss the
                // bundled runtime next to the GUI binary.
                if (std.Io.Dir.accessAbsolute(io, path, .{})) |_| {
                    return path;
                } else |_| {
                    gpa.free(path);
                }
            } else |_| {}
        }
    } else |_| {}
    return gpa.dupe(u8, exe);
}

/// Where NullClaw keeps its state. Mirrors `src/config_paths.zig` in the
/// runtime: `$NULLCLAW_HOME`, else `~/.nullclaw`; the workspace from
/// `$NULLCLAW_WORKSPACE`, else `<home>/workspace`.
pub const Paths = struct {
    gpa: std.mem.Allocator,
    home: []u8,
    config: []u8,
    workspace: []u8,

    pub fn resolve(gpa: std.mem.Allocator, environ: std.process.Environ.Map) !Paths {
        const home = if (environ.get("NULLCLAW_HOME")) |h|
            try gpa.dupe(u8, h)
        else blk: {
            const user_home = environ.get("HOME") orelse environ.get("USERPROFILE") orelse
                return error.NoHomeDirectory;
            break :blk try std.fs.path.join(gpa, &.{ user_home, ".nullclaw" });
        };
        errdefer gpa.free(home);
        const config = try std.fs.path.join(gpa, &.{ home, "config.json" });
        errdefer gpa.free(config);
        const workspace = if (environ.get("NULLCLAW_WORKSPACE")) |w|
            try gpa.dupe(u8, w)
        else
            try std.fs.path.join(gpa, &.{ home, "workspace" });
        return .{ .gpa = gpa, .home = home, .config = config, .workspace = workspace };
    }

    pub fn deinit(self: *Paths) void {
        self.gpa.free(self.home);
        self.gpa.free(self.config);
        self.gpa.free(self.workspace);
        self.* = undefined;
    }
};

/// One row of the sidebar. `history list --json` names these `session_id` and
/// counts messages; `agent sessions list --json` names them `session_key` and
/// counts turns. Both are read, so either command can feed the sidebar.
pub const Session = struct {
    key: []u8,
    message_count: u64 = 0,
    turn_count: u64 = 0,
    created_at: []u8,
    last_active: []u8,

    pub fn deinit(self: *const Session, gpa: std.mem.Allocator) void {
        gpa.free(self.key);
        gpa.free(self.created_at);
        gpa.free(self.last_active);
    }

    /// Turns, from whichever count the runtime reported.
    pub fn turns(self: Session) u64 {
        if (self.turn_count > 0) return self.turn_count;
        return self.message_count / 2;
    }
};

/// One turn of a transcript, from `history show <id> --json`.
pub const Message = struct {
    role: []u8,
    content: []u8,
    created_at: []u8,

    pub fn deinit(self: *const Message, gpa: std.mem.Allocator) void {
        gpa.free(self.role);
        gpa.free(self.content);
        gpa.free(self.created_at);
    }

    pub fn isUser(self: Message) bool {
        return std.ascii.eqlIgnoreCase(self.role, "user");
    }
};

/// What `agent invoke … --json` answers.
pub const Invoke = struct {
    session: []u8,
    response: []u8,
    turn_count: u64,

    pub fn deinit(self: *const Invoke, gpa: std.mem.Allocator) void {
        gpa.free(self.session);
        gpa.free(self.response);
    }
};

pub const ParseError = error{ UnexpectedShape, OutOfMemory };

fn field(obj: std.json.ObjectMap, names: []const []const u8) ?std.json.Value {
    for (names) |name| {
        if (obj.get(name)) |v| switch (v) {
            .null => {},
            else => return v,
        };
    }
    return null;
}

fn fieldString(obj: std.json.ObjectMap, names: []const []const u8) ?[]const u8 {
    const v = field(obj, names) orelse return null;
    return switch (v) {
        .string => |s| s,
        else => null,
    };
}

fn fieldU64(obj: std.json.ObjectMap, names: []const []const u8) u64 {
    const v = field(obj, names) orelse return 0;
    return switch (v) {
        .integer => |i| if (i > 0) @intCast(i) else 0,
        .float => |f| if (f > 0) @intFromFloat(f) else 0,
        else => 0,
    };
}

/// Parses the `sessions` array of either list command.
pub fn parseSessions(gpa: std.mem.Allocator, text: []const u8) ![]Session {
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const root = std.json.parseFromSliceLeaky(std.json.Value, arena.allocator(), text, .{}) catch
        return error.UnexpectedShape;
    const obj = switch (root) {
        .object => |o| o,
        else => return error.UnexpectedShape,
    };
    const list = switch (field(obj, &.{"sessions"}) orelse return error.UnexpectedShape) {
        .array => |a| a,
        else => return error.UnexpectedShape,
    };
    var out: std.ArrayListUnmanaged(Session) = .empty;
    errdefer {
        for (out.items) |s| s.deinit(gpa);
        out.deinit(gpa);
    }
    for (list.items) |item| {
        const row = switch (item) {
            .object => |o| o,
            else => continue,
        };
        const key = fieldString(row, &.{ "session_id", "session_key", "key" }) orelse continue;
        try out.append(gpa, .{
            .key = try gpa.dupe(u8, key),
            .message_count = fieldU64(row, &.{"message_count"}),
            .turn_count = fieldU64(row, &.{"turn_count"}),
            .created_at = try gpa.dupe(u8, fieldString(row, &.{ "first_message_at", "created_at" }) orelse ""),
            .last_active = try gpa.dupe(u8, fieldString(row, &.{ "last_message_at", "last_active" }) orelse ""),
        });
    }
    return out.toOwnedSlice(gpa);
}

/// Adopts the slice `parseSessions` returned into a growable list. The
/// allocation is exactly the slice's length (`toOwnedSlice` shrank it), so the
/// list owns it and its `deinit` frees it.
pub fn sessionsToList(slice: []Session) std.ArrayListUnmanaged(Session) {
    return .{ .items = slice, .capacity = slice.len, .pointer_stability = .{} };
}

/// The same for `parseMessages`.
pub fn messagesToList(slice: []Message) std.ArrayListUnmanaged(Message) {
    return .{ .items = slice, .capacity = slice.len, .pointer_stability = .{} };
}

/// Parses the `messages` array of `history show <id> --json`.
pub fn parseMessages(gpa: std.mem.Allocator, text: []const u8) ![]Message {
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const root = std.json.parseFromSliceLeaky(std.json.Value, arena.allocator(), text, .{}) catch
        return error.UnexpectedShape;
    const obj = switch (root) {
        .object => |o| o,
        else => return error.UnexpectedShape,
    };
    const list = switch (field(obj, &.{"messages"}) orelse return error.UnexpectedShape) {
        .array => |a| a,
        else => return error.UnexpectedShape,
    };
    var out: std.ArrayListUnmanaged(Message) = .empty;
    errdefer {
        for (out.items) |m| m.deinit(gpa);
        out.deinit(gpa);
    }
    for (list.items) |item| {
        const row = switch (item) {
            .object => |o| o,
            else => continue,
        };
        try out.append(gpa, .{
            .role = try gpa.dupe(u8, fieldString(row, &.{"role"}) orelse "assistant"),
            .content = try gpa.dupe(u8, fieldString(row, &.{"content"}) orelse ""),
            .created_at = try gpa.dupe(u8, fieldString(row, &.{"created_at"}) orelse ""),
        });
    }
    return out.toOwnedSlice(gpa);
}

/// Parses `agent invoke … --json`.
pub fn parseInvoke(gpa: std.mem.Allocator, text: []const u8) !Invoke {
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const root = std.json.parseFromSliceLeaky(std.json.Value, arena.allocator(), text, .{}) catch
        return error.UnexpectedShape;
    const obj = switch (root) {
        .object => |o| o,
        else => return error.UnexpectedShape,
    };
    const response = fieldString(obj, &.{"response"}) orelse return error.UnexpectedShape;
    return .{
        .session = try gpa.dupe(u8, fieldString(obj, &.{"session"}) orelse ""),
        .response = try gpa.dupe(u8, response),
        .turn_count = fieldU64(obj, &.{"turn_count"}),
    };
}

/// The message inside an error envelope, when the runtime printed one. The
/// runtime answers failures with `{"error":{"code":…,"message":…}}`.
pub fn parseError(gpa: std.mem.Allocator, text: []const u8) ?[]u8 {
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const root = std.json.parseFromSliceLeaky(std.json.Value, arena.allocator(), text, .{}) catch
        return null;
    const obj = switch (root) {
        .object => |o| o,
        else => return null,
    };
    const err = obj.get("error") orelse return null;
    const message = switch (err) {
        // The runtime's envelope is flat, not nested: `appendJsonError` in
        // `src/main.zig` writes `{"error":"<code>","message":"<sentence>"}`.
        // The sentence beside the code is the part worth showing, so prefer it
        // and fall back to the code only when there is no sentence.
        .string => |code| fieldString(obj, &.{"message"}) orelse code,
        .object => |o| fieldString(o, &.{"message"}) orelse return null,
        else => return null,
    };
    if (message.len == 0) return null;
    return gpa.dupe(u8, message) catch null;
}

/// The most useful line to show for a failed command: its error envelope, its
/// stderr, or its stdout, in that order.
pub fn diagnose(gpa: std.mem.Allocator, stdout: []const u8, stderr: []const u8) ?[]u8 {
    if (parseError(gpa, stdout)) |m| return m;
    // The runtime writes its error envelope to stdout, but a wrapper script or
    // a stub may put the same envelope on stderr. Its message reads better than
    // the raw JSON, so take it from either stream.
    if (parseError(gpa, stderr)) |m| return m;
    const raw = if (std.mem.trim(u8, stderr, " \t\r\n").len > 0) stderr else stdout;
    const trimmed = std.mem.trim(u8, raw, " \t\r\n");
    if (trimmed.len == 0) return null;
    const line = trimmed[0 .. std.mem.indexOfScalar(u8, trimmed, '\n') orelse trimmed.len];
    return gpa.dupe(u8, std.mem.trim(u8, line, " \t\r")) catch null;
}

// ---------------------------------------------------------------- command line

/// Appends `agent invoke … --json`: one machine-readable turn.
pub fn argvInvoke(
    gpa: std.mem.Allocator,
    out: *std.ArrayListUnmanaged([]const u8),
    opts: InvokeOptions,
) !void {
    try out.append(gpa, "agent");
    try out.append(gpa, "invoke");
    try out.append(gpa, "--message");
    try out.append(gpa, opts.message);
    if (opts.session) |s| if (s.len > 0) {
        try out.append(gpa, "--session");
        try out.append(gpa, s);
    };
    if (opts.provider) |v| if (v.len > 0) {
        try out.append(gpa, "--provider");
        try out.append(gpa, v);
    };
    if (opts.model) |v| if (v.len > 0) {
        try out.append(gpa, "--model");
        try out.append(gpa, v);
    };
    if (opts.temperature) |v| if (v.len > 0) {
        try out.append(gpa, "--temperature");
        try out.append(gpa, v);
    };
    if (opts.agent_name) |v| if (v.len > 0) {
        try out.append(gpa, "--agent");
        try out.append(gpa, v);
    };
    if (opts.workspace) |v| if (v.len > 0) {
        try out.append(gpa, "--workspace");
        try out.append(gpa, v);
    };
    if (opts.skill) |v| if (v.len > 0) {
        try out.append(gpa, "--skill");
        try out.append(gpa, v);
    };
    try out.append(gpa, "--json");
}

pub const InvokeOptions = struct {
    message: []const u8,
    session: ?[]const u8 = null,
    provider: ?[]const u8 = null,
    model: ?[]const u8 = null,
    temperature: ?[]const u8 = null,
    agent_name: ?[]const u8 = null,
    workspace: ?[]const u8 = null,
    skill: ?[]const u8 = null,
};

/// Appends `agent sessions list --json`: the sidebar's rows.
pub fn argvSessionList(gpa: std.mem.Allocator, out: *std.ArrayListUnmanaged([]const u8)) !void {
    try out.appendSlice(gpa, &.{ "agent", "sessions", "list", "--json" });
}

/// Appends `history show <id> --json --limit N`: one transcript.
pub fn argvHistoryShow(
    gpa: std.mem.Allocator,
    out: *std.ArrayListUnmanaged([]const u8),
    session: []const u8,
    limit: usize,
    limit_text: []const u8,
) !void {
    try out.appendSlice(gpa, &.{ "history", "show", session, "--limit", limit_text, "--json" });
    std.mem.doNotOptimizeAway(limit);
}

/// Appends `history list --limit N --json`.
pub fn argvHistoryList(
    gpa: std.mem.Allocator,
    out: *std.ArrayListUnmanaged([]const u8),
    limit_text: []const u8,
) !void {
    try out.appendSlice(gpa, &.{ "history", "list", "--limit", limit_text, "--json" });
}

/// Appends a command, with `--json` when the runtime takes it, e.g.
/// `status --json` or `service status`.
pub fn argvCommand(
    gpa: std.mem.Allocator,
    out: *std.ArrayListUnmanaged([]const u8),
    words: []const []const u8,
    json: bool,
) !void {
    try out.appendSlice(gpa, words);
    if (json) try out.append(gpa, "--json");
}

// -------------------------------------------------------------- configuration

/// `~/.nullclaw/config.json`, parsed and editable in memory.
pub const ConfigDoc = struct {
    gpa: std.mem.Allocator,
    arena: std.heap.ArenaAllocator,
    raw: []u8,
    value: std.json.Value,

    pub fn load(gpa: std.mem.Allocator, io: Io, path: []const u8) !ConfigDoc {
        const raw = try std.Io.Dir.cwd().readFileAlloc(io, path, gpa, .limited(16 << 20));
        errdefer gpa.free(raw);
        var arena = std.heap.ArenaAllocator.init(gpa);
        errdefer arena.deinit();
        const value = try std.json.parseFromSliceLeaky(std.json.Value, arena.allocator(), raw, .{});
        return .{ .gpa = gpa, .arena = arena, .raw = raw, .value = value };
    }

    pub fn deinit(self: *ConfigDoc) void {
        self.gpa.free(self.raw);
        self.arena.deinit();
        self.* = undefined;
    }

    pub fn object(self: *const ConfigDoc) ?std.json.ObjectMap {
        return switch (self.value) {
            .object => |o| o,
            else => null,
        };
    }

    /// A dotted path's value, as text: `"default_model"`, `"memory.backend"`.
    pub fn get(self: *ConfigDoc, path: []const u8) ?[]const u8 {
        var cur: std.json.Value = self.value;
        var it = std.mem.splitScalar(u8, path, '.');
        while (it.next()) |part| {
            const obj = switch (cur) {
                .object => |o| o,
                else => return null,
            };
            cur = obj.get(part) orelse return null;
        }
        return switch (cur) {
            .string => |s| s,
            .integer => |i| std.fmt.allocPrint(self.arena.allocator(), "{d}", .{i}) catch null,
            .float => |f| std.fmt.allocPrint(self.arena.allocator(), "{d}", .{f}) catch null,
            .bool => |b| if (b) "true" else "false",
            else => null,
        };
    }

    /// A dotted path's object, for a section the form reads as a whole rather
    /// than one key at a time (`mcp_servers`). Null when the path is missing
    /// or is not an object.
    pub fn objectAt(self: *ConfigDoc, path: []const u8) ?std.json.ObjectMap {
        var cur: std.json.Value = self.value;
        var it = std.mem.splitScalar(u8, path, '.');
        while (it.next()) |part| {
            const obj = switch (cur) {
                .object => |o| o,
                else => return null,
            };
            cur = obj.get(part) orelse return null;
        }
        return switch (cur) {
            .object => |o| o,
            else => null,
        };
    }

    /// Sets a dotted path to a string, creating the objects along the way.
    /// Every step walks a *pointer* into `self.value`: an `ObjectMap` is a
    /// value type, so mutating a copy would leave `self.value` pointing at the
    /// pre-growth storage and later reads would miss the write.
    pub fn setString(self: *ConfigDoc, path: []const u8, text: []const u8) !void {
        try self.setValue(path, .{ .string = try self.arena.allocator().dupe(u8, text) });
    }

    pub fn setBool(self: *ConfigDoc, path: []const u8, value: bool) !void {
        try self.setValue(path, .{ .bool = value });
    }

    pub fn setInteger(self: *ConfigDoc, path: []const u8, value: i64) !void {
        try self.setValue(path, .{ .integer = value });
    }

    /// Sets a dotted path from user text, preserving booleans and integers when
    /// they are unambiguous so config fields keep their expected JSON types.
    pub fn setAuto(self: *ConfigDoc, path: []const u8, text: []const u8) !void {
        const trimmed = std.mem.trim(u8, text, " \t\r\n");
        if (std.ascii.eqlIgnoreCase(trimmed, "true")) return self.setBool(path, true);
        if (std.ascii.eqlIgnoreCase(trimmed, "false")) return self.setBool(path, false);
        if (trimmed.len > 0) {
            if (std.fmt.parseInt(i64, trimmed, 10)) |n| {
                return self.setInteger(path, n);
            } else |_| {}
        }
        return self.setString(path, trimmed);
    }

    fn setValue(self: *ConfigDoc, path: []const u8, value: std.json.Value) !void {
        const a = self.arena.allocator();
        var obj: *std.json.ObjectMap = switch (self.value) {
            .object => |*o| o,
            else => return error.NotAnObject,
        };
        var it = std.mem.splitScalar(u8, path, '.');
        var part = it.next() orelse return error.EmptyPath;
        while (it.next()) |next_part| {
            const entry = try obj.getOrPut(a, try a.dupe(u8, part));
            if (!entry.found_existing) entry.value_ptr.* = .{ .object = .{} };
            obj = switch (entry.value_ptr.*) {
                .object => |*o| o,
                else => return error.NotAnObject,
            };
            part = next_part;
        }
        try obj.put(a, try a.dupe(u8, part), value);
    }

    /// The document as indented JSON, ready to write back.
    pub fn render(self: *const ConfigDoc, gpa: std.mem.Allocator) ![]u8 {
        return std.json.Stringify.valueAlloc(gpa, self.value, .{ .whitespace = .indent_2 });
    }

    pub fn save(self: *const ConfigDoc, io: Io, path: []const u8) !void {
        const text = try self.render(self.gpa);
        defer self.gpa.free(text);
        var with_newline = try std.ArrayListUnmanaged(u8).initCapacity(self.gpa, text.len + 1);
        defer with_newline.deinit(self.gpa);
        with_newline.appendSliceAssumeCapacity(text);
        with_newline.appendAssumeCapacity('\n');
        try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = with_newline.items });
    }
};

// ------------------------------------------------------------- JSON as lines

/// A JSON document flattened into the indented lines a page shows, with every
/// object and array collapsed to a summary unless its path is expanded. The
/// same pass serves every command that prints JSON, so no page needs its own
/// parser for shapes the GUI does not model.
pub const JsonLine = struct {
    depth: u16,
    text: []u8,
    kind: Kind,
    /// What follows `text` on the same line: a scalar value, or the brace that
    /// opens a container. Null when the line stands alone.
    ///
    /// A JSON viewer that puts `"key":` and its value on separate rows reads
    /// as a list of fragments rather than as a document; the pair is one line
    /// here, and the view colours the two halves with spans.
    value: ?Trailing = null,
    /// The dotted path of the object or array this line summarizes, so a click
    /// can open it. Null for every other line.
    path: ?[]u8 = null,

    pub const Kind = enum { key, string, number, boolean, null_, punct, summary };

    pub const Trailing = struct {
        text: []u8,
        kind: Kind,
    };

    pub fn deinit(self: *const JsonLine, gpa: std.mem.Allocator) void {
        gpa.free(self.text);
        if (self.value) |v| gpa.free(v.text);
        if (self.path) |p| gpa.free(p);
    }

    /// The text the page draws for this line: the key and its value joined,
    /// or the key alone when nothing follows it. `text` stays the key so a
    /// summary can be looked up by the path it stands for.
    pub fn painted(self: *const JsonLine, a: std.mem.Allocator) []const u8 {
        const v = self.value orelse return self.text;
        return std.fmt.allocPrint(a, "{s} {s}", .{ self.text, v.text }) catch self.text;
    }
};

pub const JsonLines = struct {
    gpa: std.mem.Allocator,
    list: std.ArrayListUnmanaged(JsonLine) = .empty,
    expanded: *const std.StringHashMapUnmanaged(void),
    /// Owns the parsed document and the dotted paths walked while flattening.
    arena: std.heap.ArenaAllocator,
    /// Set when the text was not JSON, or when memory ran out; the page then
    /// shows the raw text instead of lines.
    problem: ?[]const u8 = null,

    pub fn deinit(self: *JsonLines) void {
        for (self.list.items) |*l| l.deinit(self.gpa);
        self.list.deinit(self.gpa);
        self.arena.deinit();
    }

    pub fn slice(self: *const JsonLines) []const JsonLine {
        return self.list.items;
    }

    /// Flattens `text`; `expanded` holds the dotted paths the user opened,
    /// e.g. `providers`. Never fails: a document that is not JSON comes back
    /// with `problem` set and no lines.
    pub fn build(
        gpa: std.mem.Allocator,
        text: []const u8,
        expanded: *const std.StringHashMapUnmanaged(void),
    ) JsonLines {
        var self = JsonLines{
            .gpa = gpa,
            .expanded = expanded,
            .arena = std.heap.ArenaAllocator.init(gpa),
        };
        const value = std.json.parseFromSliceLeaky(std.json.Value, self.arena.allocator(), text, .{}) catch {
            self.problem = "the runtime did not print JSON";
            return self;
        };
        var path: std.ArrayListUnmanaged(u8) = .empty;
        defer path.deinit(gpa);
        self.walk(value, 0, &path, true) catch {
            for (self.list.items) |*l| l.deinit(self.gpa);
            self.list.clearRetainingCapacity();
            self.problem = "out of memory while reading the reply";
        };
        return self;
    }

    fn push(self: *JsonLines, depth: u16, kind: JsonLine.Kind, comptime fmt: []const u8, args: anytype) std.mem.Allocator.Error!void {
        const text = try std.fmt.allocPrint(self.gpa, fmt, args);
        errdefer self.gpa.free(text);
        try self.list.append(self.gpa, .{ .depth = depth, .text = text, .kind = kind });
    }

    /// A summary line remembers the path it stands for, so a click opens it.
    fn pushSummary(self: *JsonLines, depth: u16, path: []const u8, comptime fmt: []const u8, args: anytype) std.mem.Allocator.Error!void {
        const text = try std.fmt.allocPrint(self.gpa, fmt, args);
        errdefer self.gpa.free(text);
        const owned = try self.gpa.dupe(u8, path);
        errdefer self.gpa.free(owned);
        try self.list.append(self.gpa, .{ .depth = depth, .text = text, .kind = .summary, .path = owned });
    }

    /// A scalar's text and kind, for the value half of a pair. Null for a
    /// container, which opens on its own line instead.
    fn scalar(self: *JsonLines, value: std.json.Value) ?JsonLine.Trailing {
        const a = self.gpa;
        return switch (value) {
            .string => |s| .{ .text = std.fmt.allocPrint(a, "\"{s}\"", .{s}) catch return null, .kind = .string },
            .integer => |i| .{ .text = std.fmt.allocPrint(a, "{d}", .{i}) catch return null, .kind = .number },
            .float => |f| .{ .text = std.fmt.allocPrint(a, "{d}", .{f}) catch return null, .kind = .number },
            .bool => |b| .{ .text = a.dupe(u8, if (b) "true" else "false") catch return null, .kind = .boolean },
            .null => .{ .text = a.dupe(u8, "null") catch return null, .kind = .null_ },
            .number_string => |s| .{ .text = a.dupe(u8, s) catch return null, .kind = .number },
            else => null,
        };
    }

    /// The root of the document. Every container below it is drawn by
    /// `pushPair` or `pushIndexed`, which put its opening brace on the label's
    /// line; only the root has no label to hang one on.
    fn walk(self: *JsonLines, value: std.json.Value, depth: u16, path: *std.ArrayListUnmanaged(u8), top: bool) std.mem.Allocator.Error!void {
        _ = top;
        switch (value) {
            .object => |o| {
                if (o.count() == 0) {
                    try self.push(depth, .punct, "{{}}", .{});
                    return;
                }
                try self.push(depth, .punct, "{{", .{});
                var it = o.iterator();
                while (it.next()) |entry| {
                    const mark = path.items.len;
                    if (path.items.len > 0) try path.append(self.gpa, '.');
                    try path.appendSlice(self.gpa, entry.key_ptr.*);
                    try self.pushPair(depth + 1, entry.key_ptr.*, entry.value_ptr.*, path);
                    path.shrinkRetainingCapacity(mark);
                }
                try self.push(depth, .punct, "}}", .{});
            },
            .array => |a| {
                if (a.items.len == 0) {
                    try self.push(depth, .punct, "[]", .{});
                    return;
                }
                try self.push(depth, .punct, "[", .{});
                for (a.items, 0..) |item, i| {
                    try self.pushIndexed(depth + 1, i, item, path);
                }
                try self.push(depth, .punct, "]", .{});
            },
            else => try self.pushValue(depth, value),
        }
    }

    /// A bare value with no label: the root of a document that is not a
    /// container.
    fn pushValue(self: *JsonLines, depth: u16, value: std.json.Value) std.mem.Allocator.Error!void {
        if (self.scalar(value)) |v| {
            try self.list.append(self.gpa, .{ .depth = depth, .text = v.text, .kind = v.kind });
        }
    }

    /// One `"key": value` line. A scalar value rides on the key's line, and so
    /// does a container's opening brace: `"providers": {` reads as one entry,
    /// while a brace on a line of its own reads as a stray fragment.
    fn pushPair(self: *JsonLines, depth: u16, key: []const u8, value: std.json.Value, path: *std.ArrayListUnmanaged(u8)) std.mem.Allocator.Error!void {
        const label = try std.fmt.allocPrint(self.gpa, "\"{s}\":", .{key});
        errdefer self.gpa.free(label);
        try self.pushLabelled(depth, label, .key, value, path);
    }

    /// One `#i value` line of an array; the index labels a scalar the way a
    /// key labels an object entry.
    fn pushIndexed(self: *JsonLines, depth: u16, i: usize, value: std.json.Value, path: *std.ArrayListUnmanaged(u8)) std.mem.Allocator.Error!void {
        const label = try std.fmt.allocPrint(self.gpa, "#{d}", .{i});
        errdefer self.gpa.free(label);
        try self.pushLabelled(depth, label, .number, value, path);
    }

    fn pushLabelled(
        self: *JsonLines,
        depth: u16,
        label: []u8,
        label_kind: JsonLine.Kind,
        value: std.json.Value,
        path: *std.ArrayListUnmanaged(u8),
    ) std.mem.Allocator.Error!void {
        if (self.scalar(value)) |v| {
            errdefer self.gpa.free(v.text);
            try self.list.append(self.gpa, .{ .depth = depth, .text = label, .kind = label_kind, .value = v });
            return;
        }
        switch (value) {
            .object => |o| {
                if (o.count() == 0) {
                    try self.list.append(self.gpa, .{ .depth = depth, .text = label, .kind = label_kind, .value = .{ .text = try self.gpa.dupe(u8, "{}"), .kind = .punct } });
                    return;
                }
                try self.list.append(self.gpa, .{ .depth = depth, .text = label, .kind = label_kind, .value = .{ .text = try self.gpa.dupe(u8, "{"), .kind = .punct } });
                if (self.expanded.contains(path.items)) {
                    var it = o.iterator();
                    while (it.next()) |entry| {
                        const mark = path.items.len;
                        if (path.items.len > 0) try path.append(self.gpa, '.');
                        try path.appendSlice(self.gpa, entry.key_ptr.*);
                        try self.pushPair(depth + 1, entry.key_ptr.*, entry.value_ptr.*, path);
                        path.shrinkRetainingCapacity(mark);
                    }
                } else {
                    try self.pushSummary(depth + 1, path.items, "… {d} keys", .{o.count()});
                }
                try self.push(depth, .punct, "}}", .{});
            },
            .array => |a| {
                if (a.items.len == 0) {
                    try self.list.append(self.gpa, .{ .depth = depth, .text = label, .kind = label_kind, .value = .{ .text = try self.gpa.dupe(u8, "[]"), .kind = .punct } });
                    return;
                }
                try self.list.append(self.gpa, .{ .depth = depth, .text = label, .kind = label_kind, .value = .{ .text = try self.gpa.dupe(u8, "["), .kind = .punct } });
                if (self.expanded.contains(path.items)) {
                    for (a.items, 0..) |item, i| {
                        try self.pushIndexed(depth + 1, i, item, path);
                    }
                } else {
                    try self.pushSummary(depth + 1, path.items, "… {d} items", .{a.items.len});
                }
                try self.push(depth, .punct, "]", .{});
            },
            else => unreachable,
        }
    }
};

// ── List rows ───────────────────────────────────────────────────────────
//
// The runtime's data pages answer with objects and arrays of records, not
// with prose. Drawing them as a JSON tree makes the reader parse the shape
// themselves; a page that knows what it asked for can draw a row per record
// with its state on the right. `Rows` is that: a flat list of titled rows,
// each with an optional state, built from a document by a small reader.

/// One line of a data page: a title, an optional detail under it, and a
/// state shown at the right edge.
pub const Row = struct {
    title: []u8,
    /// Empty for a row that has nothing to say under its title. Owned when
    /// non-empty; the empty slice is the literal, which is not freed.
    detail: []const u8 = "",
    state: State = .none,

    pub const State = enum { none, on, off, warn, bad };

    pub fn deinit(self: *const Row, gpa: std.mem.Allocator) void {
        gpa.free(self.title);
        if (self.detail.len > 0) gpa.free(self.detail);
    }
};

/// A titled group of rows: `Channels`, `Tools`, `Memory engines`.
pub const Group = struct {
    title: []u8,
    rows: std.ArrayListUnmanaged(Row) = .empty,

    pub fn deinit(self: *Group, gpa: std.mem.Allocator) void {
        gpa.free(self.title);
        for (self.rows.items) |*r| r.deinit(gpa);
        self.rows.deinit(gpa);
    }
};

pub const Rows = struct {
    gpa: std.mem.Allocator,
    groups: std.ArrayListUnmanaged(Group) = .empty,
    /// A line shown above the groups: the document's own summary, when it has
    /// one worth repeating.
    note: []u8 = &.{},
    /// Set when the text was not the shape this page expects; the page then
    /// falls back to the raw tree.
    problem: ?[]const u8 = null,
    arena: std.heap.ArenaAllocator,

    pub fn deinit(self: *Rows) void {
        for (self.groups.items) |*g| g.deinit(self.gpa);
        self.groups.deinit(self.gpa);
        if (self.note.len > 0) self.gpa.free(self.note);
        self.arena.deinit();
    }

    pub fn empty(gpa: std.mem.Allocator) Rows {
        return .{ .gpa = gpa, .arena = std.heap.ArenaAllocator.init(gpa) };
    }

    fn group(self: *Rows, title: []const u8) !*Group {
        for (self.groups.items) |*g| {
            if (std.mem.eql(u8, g.title, title)) return g;
        }
        const owned = try self.gpa.dupe(u8, title);
        errdefer self.gpa.free(owned);
        try self.groups.append(self.gpa, .{ .title = owned });
        return &self.groups.items[self.groups.items.len - 1];
    }

    fn row(self: *Rows, group_title: []const u8, title: []const u8, detail: []const u8, state: Row.State) !void {
        const g = try self.group(group_title);
        const owned_title = try self.gpa.dupe(u8, title);
        errdefer self.gpa.free(owned_title);
        const owned_detail = if (detail.len > 0) try self.gpa.dupe(u8, detail) else "";
        errdefer if (owned_detail.len > 0) self.gpa.free(owned_detail);
        try g.rows.append(self.gpa, .{ .title = owned_title, .detail = owned_detail, .state = state });
    }

    pub fn totalRows(self: *const Rows) usize {
        var n: usize = 0;
        for (self.groups.items) |g| n += g.rows.items.len;
        return n;
    }
};

/// Reads `capabilities --json` into groups: the channels, the memory engines,
/// and the tools, each with whether the build has it and whether the config
/// turns it on.
pub fn readCapabilities(gpa: std.mem.Allocator, text: []const u8) Rows {
    var out = Rows.empty(gpa);
    const root = std.json.parseFromSliceLeaky(std.json.Value, out.arena.allocator(), text, .{}) catch {
        out.problem = "the runtime did not print JSON";
        return out;
    };
    const obj = switch (root) {
        .object => |o| o,
        else => {
            out.problem = "the answer is not an object";
            return out;
        },
    };

    if (obj.get("version")) |v| {
        if (v == .string) out.note = gpa.dupe(u8, v.string) catch &.{};
    }

    // Channels: a record per channel, with the count the config sets.
    if (obj.get("channels")) |ch| {
        if (ch == .array) {
            for (ch.array.items) |item| {
                if (item != .object) continue;
                const rec = item.object;
                const key = str(rec.get("key")) orelse continue;
                const label = str(rec.get("label")) orelse key;
                const configured = bool_(rec.get("configured")) orelse false;
                const in_build = bool_(rec.get("enabled_in_build")) orelse true;
                const count = int(rec.get("configured_count")) orelse 0;
                var detail_buf: [96]u8 = undefined;
                const detail = if (!in_build)
                    "not in this build"
                else if (configured and count > 0)
                    std.fmt.bufPrint(&detail_buf, "{s} · {d} configured", .{ label, count }) catch label
                else if (configured)
                    std.fmt.bufPrint(&detail_buf, "{s} · configured", .{label}) catch label
                else
                    std.fmt.bufPrint(&detail_buf, "{s} · not configured", .{label}) catch label;
                out.row("Channels", key, detail, if (!in_build) .off else if (configured) .on else .none) catch {};
            }
        }
    }

    // Memory engines: the registry's list, with the active one marked.
    const active = str(obj.get("active_memory_backend")) orelse "";
    if (obj.get("memory_engines")) |eng| {
        if (eng == .array) {
            for (eng.array.items) |item| {
                if (item != .object) continue;
                const rec = item.object;
                const name = str(rec.get("name")) orelse continue;
                const in_build = bool_(rec.get("enabled_in_build")) orelse true;
                const is_active = std.mem.eql(u8, name, active);
                out.row("Memory engines", name, if (is_active) "active" else if (!in_build) "not in this build" else "", if (!in_build) .off else if (is_active) .on else .none) catch {};
            }
        }
    }

    // Tools: a bare list of names, plus the detail object that says which the
    // runtime loaded and which the config enables.
    if (obj.get("tools_detail")) |td| {
        if (td == .object) {
            const detail = td.object;
            if (detail.get("runtime_loaded")) |loaded| {
                if (loaded == .array) {
                    for (loaded.array.items) |item| {
                        const name = str(item) orelse continue;
                        out.row("Tools", name, "loaded", .on) catch {};
                    }
                }
            }
        }
    } else if (obj.get("tools")) |tools| {
        if (tools == .array) {
            for (tools.array.items) |item| {
                const name = str(item) orelse continue;
                out.row("Tools", name, "", .none) catch {};
            }
        }
    }

    return out;
}

/// Reads `models summary --json`: the default provider and model, then one
/// row per provider with whether it has a key.
pub fn readModels(gpa: std.mem.Allocator, text: []const u8) Rows {
    var out = Rows.empty(gpa);
    const root = std.json.parseFromSliceLeaky(std.json.Value, out.arena.allocator(), text, .{}) catch {
        out.problem = "the runtime did not print JSON";
        return out;
    };
    const obj = switch (root) {
        .object => |o| o,
        else => {
            out.problem = "the answer is not an object";
            return out;
        },
    };

    const provider = str(obj.get("default_provider")) orelse "";
    const model = str(obj.get("default_model")) orelse "";
    if (model.len > 0 or provider.len > 0) {
        var buf: [256]u8 = undefined;
        out.note = gpa.dupe(u8, std.fmt.bufPrint(&buf, "{s} · {s}", .{
            if (provider.len > 0) provider else "no provider",
            if (model.len > 0) model else "no model",
        }) catch "") catch &.{};
    }

    if (obj.get("providers")) |provs| {
        if (provs == .array) {
            for (provs.array.items) |item| {
                if (item != .object) continue;
                const rec = item.object;
                const name = str(rec.get("name")) orelse continue;
                const has_key = bool_(rec.get("has_key")) orelse false;
                const is_default = std.mem.eql(u8, name, provider);
                out.row("Providers", name, if (is_default) "default" else "", if (has_key) .on else .warn) catch {};
            }
        }
    }
    return out;
}

/// Reads a plain array of records — `skills list`, `channel list`,
/// `cron list`, `mcp list` — into one group, using whichever name field the
/// record carries.
pub fn readRecordList(gpa: std.mem.Allocator, text: []const u8, group_title: []const u8) Rows {
    var out = Rows.empty(gpa);
    const root = std.json.parseFromSliceLeaky(std.json.Value, out.arena.allocator(), text, .{}) catch {
        out.problem = "the runtime did not print JSON";
        return out;
    };
    const items = switch (root) {
        .array => |a| a.items,
        .object => |o| blk: {
            // Some commands wrap the list in an object; take the first array.
            var it = o.iterator();
            while (it.next()) |e| {
                if (e.value_ptr.* == .array) break :blk e.value_ptr.array.items;
            }
            out.problem = "the answer holds no list";
            return out;
        },
        else => {
            out.problem = "the answer is not a list";
            return out;
        },
    };

    for (items) |item| {
        switch (item) {
            .object => |rec| {
                const title = str(rec.get("name")) orelse
                    str(rec.get("key")) orelse
                    str(rec.get("id")) orelse
                    str(rec.get("session_key")) orelse
                    continue;
                const detail = str(rec.get("description")) orelse
                    str(rec.get("label")) orelse
                    str(rec.get("schedule")) orelse
                    str(rec.get("command")) orelse
                    "";
                const state: Row.State = if (bool_(rec.get("enabled")) orelse true) .on else .off;
                out.row(group_title, title, detail, state) catch {};
            },
            .string => |s| out.row(group_title, s, "", .none) catch {},
            else => {},
        }
    }
    return out;
}

/// Reads `memory stats --json`: one group of key/value rows, with the numbers
/// the page is usually opened for called out.
pub fn readMemoryStats(gpa: std.mem.Allocator, text: []const u8) Rows {
    var out = Rows.empty(gpa);
    const root = std.json.parseFromSliceLeaky(std.json.Value, out.arena.allocator(), text, .{}) catch {
        out.problem = "the runtime did not print JSON";
        return out;
    };
    const obj = switch (root) {
        .object => |o| o,
        else => {
            out.problem = "the answer is not an object";
            return out;
        },
    };

    // The two numbers the page exists for come first.
    if (int(obj.get("entries"))) |n| {
        var buf: [64]u8 = undefined;
        out.note = gpa.dupe(u8, std.fmt.bufPrint(&buf, "{d} entries", .{n}) catch "") catch &.{};
    }

    var it = obj.iterator();
    while (it.next()) |e| {
        const value = switch (e.value_ptr.*) {
            .string => |s| s,
            .integer => |i| std.fmt.allocPrint(out.arena.allocator(), "{d}", .{i}) catch continue,
            .bool => |b| if (b) "true" else "false",
            .null => "—",
            else => continue,
        };
        out.row("Memory", e.key_ptr.*, value, .none) catch {};
    }
    return out;
}

fn str(v: ?std.json.Value) ?[]const u8 {
    const val = v orelse return null;
    return switch (val) {
        .string => |s| s,
        else => null,
    };
}

fn bool_(v: ?std.json.Value) ?bool {
    const val = v orelse return null;
    return switch (val) {
        .bool => |b| b,
        else => null,
    };
}

fn int(v: ?std.json.Value) ?i64 {
    const val = v orelse return null;
    return switch (val) {
        .integer => |i| i,
        else => null,
    };
}

/// The paths a JSON document offers to open, for a page's expand-all control.
/// A document that is not an object offers none.
pub fn topLevelKeys(gpa: std.mem.Allocator, text: []const u8) [][]u8 {
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const root = std.json.parseFromSliceLeaky(std.json.Value, arena.allocator(), text, .{}) catch
        return &.{};
    const obj = switch (root) {
        .object => |o| o,
        else => return &.{},
    };
    var out: std.ArrayListUnmanaged([]u8) = .empty;
    var it = obj.iterator();
    while (it.next()) |entry| {
        const key = gpa.dupe(u8, entry.key_ptr.*) catch break;
        out.append(gpa, key) catch {
            gpa.free(key);
            break;
        };
    }
    return out.toOwnedSlice(gpa) catch &.{};
}

pub fn freeTopLevelKeys(gpa: std.mem.Allocator, keys: [][]u8) void {
    for (keys) |k| gpa.free(k);
    gpa.free(keys);
}

/// A timestamp as the sidebar shows it: `05-30 14:07`, or the text as given
/// when it is not an ISO stamp.
/// `MM-DD HH:MM` out of an ISO stamp, in memory that outlives the call: the
/// view hands the result straight to a widget, and nanoui draws the frame
/// after the view returns, so a caller's stack buffer would be gone by then.
pub fn formatStamp(a: std.mem.Allocator, stamp: []const u8) []const u8 {
    if (stamp.len >= 16 and stamp[4] == '-' and stamp[7] == '-' and
        (stamp[10] == 'T' or stamp[10] == ' '))
    {
        return std.fmt.allocPrint(a, "{s}-{s} {s}:{s}", .{
            stamp[5..7], stamp[8..10], stamp[11..13], stamp[14..16],
        }) catch stamp;
    }
    const line = stamp[0 .. std.mem.indexOfScalar(u8, stamp, '\n') orelse stamp.len];
    return if (line.len > 24) line[0..24] else line;
}

// --------------------------------------------------------------------- tests

const testing = std.testing;

fn testEnv() std.process.Environ.Map {
    var map = std.process.Environ.Map.init(testing.allocator);
    map.put("HOME", "/home/user") catch unreachable;
    return map;
}

test "paths come from the environment" {
    var map = testEnv();
    defer map.deinit();
    var paths = try Paths.resolve(testing.allocator, map);
    defer paths.deinit();
    try testing.expectEqualStrings("/home/user/.nullclaw", paths.home);
    try testing.expectEqualStrings("/home/user/.nullclaw/config.json", paths.config);
    try testing.expectEqualStrings("/home/user/.nullclaw/workspace", paths.workspace);
}

test "NULLCLAW_HOME overrides the default home" {
    var map = testEnv();
    defer map.deinit();
    try map.put("NULLCLAW_HOME", "/srv/nullclaw");
    try map.put("NULLCLAW_WORKSPACE", "/srv/work");
    var paths = try Paths.resolve(testing.allocator, map);
    defer paths.deinit();
    try testing.expectEqualStrings("/srv/nullclaw", paths.home);
    try testing.expectEqualStrings("/srv/nullclaw/config.json", paths.config);
    try testing.expectEqualStrings("/srv/work", paths.workspace);
}

test "NULLCLAW_BIN points the window at another runtime" {
    var environ = std.process.Environ.Map.init(testing.allocator);
    defer environ.deinit();

    const plain = try executable(testing.allocator, std.Io.Threaded.global_single_threaded.io(), environ);
    defer testing.allocator.free(plain);
    try testing.expectEqualStrings("nullclaw", plain);

    try environ.put("NULLCLAW_BIN", "/opt/checkout/nullclaw");
    const pointed = try executable(testing.allocator, std.Io.Threaded.global_single_threaded.io(), environ);
    defer testing.allocator.free(pointed);
    try testing.expectEqualStrings("/opt/checkout/nullclaw", pointed);

    // Empty counts as unset, so an exported-but-blank variable is not a
    // program named "".
    try environ.put("NULLCLAW_BIN", "");
    const blank = try executable(testing.allocator, std.Io.Threaded.global_single_threaded.io(), environ);
    defer testing.allocator.free(blank);
    try testing.expectEqualStrings("nullclaw", blank);
}

test "sessions parse from history list" {
    const text =
        \\{"total":1,"limit":50,"offset":0,"sessions":[{"session_id":"cli_user_a",
        \\"message_count":6,"first_message_at":"2026-05-30T14:07:01Z",
        \\"last_message_at":"2026-05-30T14:31:00Z"}]}
    ;
    const sessions = try parseSessions(testing.allocator, text);
    defer {
        for (sessions) |s| s.deinit(testing.allocator);
        testing.allocator.free(sessions);
    }
    try testing.expectEqual(@as(usize, 1), sessions.len);
    try testing.expectEqualStrings("cli_user_a", sessions[0].key);
    try testing.expectEqual(@as(u64, 6), sessions[0].message_count);
    try testing.expectEqual(@as(u64, 3), sessions[0].turns());
    try testing.expectEqualStrings("2026-05-30T14:31:00Z", sessions[0].last_active);
}

test "sessions parse from agent sessions list" {
    const text =
        \\{"sessions":[{"session_key":"s1","created_at":"2026-05-30T14:07:01Z",
        \\"last_active":"2026-05-30T14:31:00Z","turn_count":4,"turn_running":false}],"total":1}
    ;
    const sessions = try parseSessions(testing.allocator, text);
    defer {
        for (sessions) |s| s.deinit(testing.allocator);
        testing.allocator.free(sessions);
    }
    try testing.expectEqualStrings("s1", sessions[0].key);
    try testing.expectEqual(@as(u64, 4), sessions[0].turns());
    try testing.expectEqualStrings("2026-05-30T14:07:01Z", sessions[0].created_at);
}

test "an empty session list is not an error" {
    const sessions = try parseSessions(testing.allocator, "{\"sessions\":[],\"total\":0}");
    defer testing.allocator.free(sessions);
    try testing.expectEqual(@as(usize, 0), sessions.len);
}

test "a reply that is not a session list is rejected" {
    try testing.expectError(error.UnexpectedShape, parseSessions(testing.allocator, "not json"));
    try testing.expectError(error.UnexpectedShape, parseSessions(testing.allocator, "[1,2,3]"));
}

test "messages parse from history show" {
    const text =
        \\{"session_id":"s1","total":2,"limit":100,"offset":0,"messages":[
        \\{"role":"user","content":"hello","created_at":"2026-05-30T14:07:01Z"},
        \\{"role":"assistant","content":"hi there","created_at":"2026-05-30T14:07:02Z"}]}
    ;
    const messages = try parseMessages(testing.allocator, text);
    defer {
        for (messages) |m| m.deinit(testing.allocator);
        testing.allocator.free(messages);
    }
    try testing.expectEqual(@as(usize, 2), messages.len);
    try testing.expect(messages[0].isUser());
    try testing.expect(!messages[1].isUser());
    try testing.expectEqualStrings("hi there", messages[1].content);
}

test "invoke parses its response" {
    const text = "{\"session\":\"s1\",\"response\":\"pong\",\"turn_count\":2}";
    const result = try parseInvoke(testing.allocator, text);
    defer result.deinit(testing.allocator);
    try testing.expectEqualStrings("s1", result.session);
    try testing.expectEqualStrings("pong", result.response);
    try testing.expectEqual(@as(u64, 2), result.turn_count);
}

test "invoke without a response is rejected" {
    try testing.expectError(error.UnexpectedShape, parseInvoke(testing.allocator, "{\"session\":\"s1\"}"));
}

test "an error envelope is read for its message" {
    const text = "{\"error\":{\"code\":\"session_store_unavailable\",\"message\":\"Session store not available\",\"backend\":\"hybrid\"}}";
    const message = parseError(testing.allocator, text).?;
    defer testing.allocator.free(message);
    try testing.expectEqualStrings("Session store not available", message);
}

test "the runtime's flat error envelope shows its message, not its code" {
    // Regression: `appendJsonError` in `../src/main.zig` writes the envelope
    // flat — `{"error":"<code>","message":"<sentence>"}` — so `error` is a
    // string. The parser used to hand back the code, which put
    // "config_not_found" in the toast instead of the sentence telling the user
    // to run `nullclaw onboard`.
    const flat = diagnose(
        testing.allocator,
        "{\"error\":\"config_not_found\",\"message\":\"No config found -- run `nullclaw onboard` first\"}",
        "",
    ).?;
    defer testing.allocator.free(flat);
    try testing.expectEqualStrings("No config found -- run `nullclaw onboard` first", flat);

    // With no sentence beside it, the code is all there is.
    const code_only = diagnose(testing.allocator, "{\"error\":\"doctor_failed\"}", "").?;
    defer testing.allocator.free(code_only);
    try testing.expectEqualStrings("doctor_failed", code_only);
}

test "diagnose prefers the error envelope, then stderr" {
    const envelope = diagnose(testing.allocator, "{\"error\":{\"message\":\"no config\"}}", "noise").?;
    defer testing.allocator.free(envelope);
    try testing.expectEqualStrings("no config", envelope);

    const from_stderr = diagnose(testing.allocator, "", "boom\nsecond line\n").?;
    defer testing.allocator.free(from_stderr);
    try testing.expectEqualStrings("boom", from_stderr);

    // The envelope is what matters, whichever stream it arrived on: a wrapper
    // or a stub may write it to stderr, and its message reads better than the
    // raw JSON.
    const envelope_on_stderr = diagnose(
        testing.allocator,
        "",
        "{\"error\":{\"code\":\"stub\",\"message\":\"no answer for: status\"}}",
    ).?;
    defer testing.allocator.free(envelope_on_stderr);
    try testing.expectEqualStrings("no answer for: status", envelope_on_stderr);

    try testing.expectEqual(@as(?[]u8, null), diagnose(testing.allocator, "  \n", ""));
}

test "invoke argv carries the options and asks for json" {
    var argv: std.ArrayListUnmanaged([]const u8) = .empty;
    defer argv.deinit(testing.allocator);
    try argvInvoke(testing.allocator, &argv, .{
        .message = "hello",
        .session = "s1",
        .provider = "openrouter",
        .model = "openai/gpt-4o",
        .temperature = "0.7",
        .workspace = "/tmp/ws",
        .skill = "review",
    });
    const want = [_][]const u8{
        "agent",       "invoke",        "--message",     "hello",
        "--session",   "s1",            "--provider",    "openrouter",
        "--model",     "openai/gpt-4o", "--temperature", "0.7",
        "--workspace", "/tmp/ws",       "--skill",       "review",
        "--json",
    };
    try testing.expectEqualSlices([]const u8, &want, argv.items);
}

test "invoke argv leaves out the options it was not given" {
    var argv: std.ArrayListUnmanaged([]const u8) = .empty;
    defer argv.deinit(testing.allocator);
    try argvInvoke(testing.allocator, &argv, .{ .message = "hi" });
    const want = [_][]const u8{ "agent", "invoke", "--message", "hi", "--json" };
    try testing.expectEqualSlices([]const u8, &want, argv.items);
}

test "invoke argv skips empty option values" {
    var argv: std.ArrayListUnmanaged([]const u8) = .empty;
    defer argv.deinit(testing.allocator);
    try argvInvoke(testing.allocator, &argv, .{ .message = "hi", .session = "", .model = "" });
    const want = [_][]const u8{ "agent", "invoke", "--message", "hi", "--json" };
    try testing.expectEqualSlices([]const u8, &want, argv.items);
}

test "session and history argv" {
    var argv: std.ArrayListUnmanaged([]const u8) = .empty;
    defer argv.deinit(testing.allocator);
    try argvSessionList(testing.allocator, &argv);
    try testing.expectEqualSlices([]const u8, &.{ "agent", "sessions", "list", "--json" }, argv.items);

    argv.clearRetainingCapacity();
    try argvHistoryList(testing.allocator, &argv, "200");
    try testing.expectEqualSlices([]const u8, &.{ "history", "list", "--limit", "200", "--json" }, argv.items);

    argv.clearRetainingCapacity();
    try argvHistoryShow(testing.allocator, &argv, "s1", 500, "500");
    try testing.expectEqualSlices(
        []const u8,
        &.{ "history", "show", "s1", "--limit", "500", "--json" },
        argv.items,
    );
}

test "argvCommand appends the flag only where the runtime takes it" {
    var argv: std.ArrayListUnmanaged([]const u8) = .empty;
    defer argv.deinit(testing.allocator);
    try argvCommand(testing.allocator, &argv, &.{ "memory", "stats" }, true);
    try testing.expectEqualSlices([]const u8, &.{ "memory", "stats", "--json" }, argv.items);

    argv.clearRetainingCapacity();
    try argvCommand(testing.allocator, &argv, &.{ "service", "status" }, false);
    try testing.expectEqualSlices([]const u8, &.{ "service", "status" }, argv.items);
}

test "config doc reads, sets and renders dotted paths" {
    const text =
        \\{"default_provider":"openrouter","default_temperature":0.7,
        \\"memory":{"backend":"hybrid","sqlite":{"path":"/tmp/m.db"}}}
    ;
    var doc = ConfigDoc{
        .gpa = testing.allocator,
        .arena = std.heap.ArenaAllocator.init(testing.allocator),
        .raw = try testing.allocator.dupe(u8, text),
        .value = undefined,
    };
    defer doc.deinit();
    doc.value = try std.json.parseFromSliceLeaky(std.json.Value, doc.arena.allocator(), doc.raw, .{});

    try testing.expectEqualStrings("openrouter", doc.get("default_provider").?);
    try testing.expectEqualStrings("hybrid", doc.get("memory.backend").?);
    try testing.expectEqualStrings("/tmp/m.db", doc.get("memory.sqlite.path").?);
    try testing.expectEqual(@as(?[]const u8, null), doc.get("memory.nope"));

    try doc.setString("default_model", "anthropic/claude-sonnet-4");
    try testing.expectEqualStrings("anthropic/claude-sonnet-4", doc.get("default_model").?);

    try doc.setString("memory.redis.host", "127.0.0.1");
    try testing.expectEqualStrings("127.0.0.1", doc.get("memory.redis.host").?);

    const rendered = try doc.render(testing.allocator);
    defer testing.allocator.free(rendered);
    try testing.expect(std.mem.indexOf(u8, rendered, "\"default_model\": \"anthropic/claude-sonnet-4\"") != null);
    try testing.expect(std.mem.indexOf(u8, rendered, "\"host\": \"127.0.0.1\"") != null);
}

test "json lines collapse and expand by path" {
    const text = "{\"backend\":\"hybrid\",\"providers\":{\"openrouter\":{\"key\":\"k\"}}}";

    var collapsed: std.StringHashMapUnmanaged(void) = .empty;
    defer collapsed.deinit(testing.allocator);
    var lines = JsonLines.build(testing.allocator, text, &collapsed);
    defer lines.deinit();
    try testing.expectEqual(@as(?[]const u8, null), lines.problem);

    // `{`, the backend pair, `"providers": {`, the collapsed summary, that
    // object's `}`, the root's `}`. A pair is one row: the value — a scalar or
    // a container's opening brace — rides on its key's line.
    try testing.expectEqual(@as(usize, 6), lines.slice().len);
    try testing.expectEqualStrings("{", lines.slice()[0].text);
    try testing.expectEqualStrings("\"backend\":", lines.slice()[1].text);
    try testing.expectEqualStrings("\"hybrid\"", lines.slice()[1].value.?.text);
    try testing.expectEqual(JsonLine.Kind.string, lines.slice()[1].value.?.kind);
    try testing.expectEqualStrings("\"providers\":", lines.slice()[2].text);
    try testing.expectEqualStrings("{", lines.slice()[2].value.?.text);
    try testing.expectEqual(JsonLine.Kind.punct, lines.slice()[2].value.?.kind);
    try testing.expectEqualStrings("… 1 keys", lines.slice()[3].text);
    try testing.expectEqual(JsonLine.Kind.summary, lines.slice()[3].kind);
    try testing.expectEqual(@as(u16, 2), lines.slice()[3].depth);
    try testing.expectEqualStrings("providers", lines.slice()[3].path.?);
    // Only a summary carries a path: a click has nothing to open elsewhere.
    try testing.expectEqual(@as(?[]u8, null), lines.slice()[1].path);

    var expanded: std.StringHashMapUnmanaged(void) = .empty;
    defer expanded.deinit(testing.allocator);
    try expanded.put(testing.allocator, "providers", {});
    var open = JsonLines.build(testing.allocator, text, &expanded);
    defer open.deinit();
    var saw_nested = false;
    for (open.slice()) |l| {
        if (std.mem.eql(u8, l.text, "\"openrouter\":")) saw_nested = true;
    }
    try testing.expect(saw_nested);
}

test "json lines summarize arrays" {
    const text = "{\"items\":[1,2,3]}";
    var expanded: std.StringHashMapUnmanaged(void) = .empty;
    defer expanded.deinit(testing.allocator);
    var lines = JsonLines.build(testing.allocator, text, &expanded);
    defer lines.deinit();
    // `{`, `"items": [`, the summary, `]`, `}`.
    try testing.expectEqual(@as(usize, 5), lines.slice().len);
    try testing.expectEqualStrings("[", lines.slice()[1].value.?.text);
    try testing.expectEqualStrings("… 3 items", lines.slice()[2].text);
    try testing.expectEqualStrings("items", lines.slice()[2].path.?);

    try expanded.put(testing.allocator, "items", {});
    var open = JsonLines.build(testing.allocator, text, &expanded);
    defer open.deinit();
    var numbers: usize = 0;
    for (open.slice()) |l| {
        if (l.kind == .number) numbers += 1;
    }
    // Three `#i` index markers, each carrying its value on the same line.
    try testing.expectEqual(@as(usize, 3), numbers);
    // Every one of them is a pair: the value did not get a row of its own.
    for (open.slice()) |l| {
        if (l.kind == .number) try testing.expect(l.value != null);
    }
}

test "top level keys name a document's sections" {
    const keys = topLevelKeys(testing.allocator, "{\"a\":1,\"b\":2}");
    defer freeTopLevelKeys(testing.allocator, keys);
    try testing.expectEqual(@as(usize, 2), keys.len);
}

test "a document that is not json reports a problem instead of failing" {
    var expanded: std.StringHashMapUnmanaged(void) = .empty;
    defer expanded.deinit(testing.allocator);
    var lines = JsonLines.build(testing.allocator, "usage: nullclaw …", &expanded);
    defer lines.deinit();
    try testing.expect(lines.problem != null);
    try testing.expectEqual(@as(usize, 0), lines.slice().len);
    try testing.expectEqual(@as(usize, 0), topLevelKeys(testing.allocator, "nope").len);
}

test "stamps format as month-day and time" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try testing.expectEqualStrings("05-30 14:07", formatStamp(a, "2026-05-30T14:07:01Z"));
    try testing.expectEqualStrings("05-30 14:07", formatStamp(a, "2026-05-30 14:07:01Z"));
    try testing.expectEqualStrings("", formatStamp(a, ""));
    try testing.expectEqualStrings("not a stamp", formatStamp(a, "not a stamp"));
}
