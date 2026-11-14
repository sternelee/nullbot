//! The JSON a data page shows, built as a function rather than printed.
//!
//! `nullclaw models summary --json` and its neighbours write their answer to
//! stdout and exit; a program that wants the answer has to spawn them and read
//! it back. These are the same answers, built with `std.json` from the same
//! sources, so a caller can have them without a subprocess.
//!
//! Only the pages the desktop window shows are here. The rest still live in
//! `main.zig`, where the command line needs them.
const std = @import("std");
const Config = @import("config.zig").Config;
const memory_mod = @import("memory/root.zig");

/// `models summary --json`: the default provider and model, then one record
/// per configured provider with whether it has a key.
pub fn modelsSummary(allocator: std.mem.Allocator, cfg: *const Config) ![]u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(allocator);
    var aw: std.Io.Writer.Allocating = .fromArrayList(allocator, &out);

    const default_model: ?[]const u8 = if (cfg.default_model) |model|
        (if (cfg.default_provider.len > 0)
            try std.fmt.allocPrint(allocator, "{s}/{s}", .{ cfg.default_provider, model })
        else
            try allocator.dupe(u8, model))
    else
        null;
    defer if (default_model) |m| allocator.free(m);

    try aw.writer.writeAll("{\"default_provider\":");
    try writeOptionalString(&aw.writer, if (cfg.default_provider.len > 0) cfg.default_provider else null);
    try aw.writer.writeAll(",\"default_model\":");
    try writeOptionalString(&aw.writer, default_model);
    try aw.writer.writeAll(",\"providers\":[");

    // Sorted by name, so two runs over the same config read the same way.
    const names = try allocator.alloc([]const u8, cfg.providers.len);
    defer allocator.free(names);
    for (cfg.providers, 0..) |p, i| names[i] = p.name;
    std.mem.sort([]const u8, names, {}, struct {
        fn lt(_: void, a: []const u8, b: []const u8) bool {
            return std.mem.order(u8, a, b) == .lt;
        }
    }.lt);

    for (names, 0..) |name, i| {
        if (i > 0) try aw.writer.writeByte(',');
        // The key itself is never written: the page shows whether one is set.
        var has_key = false;
        for (cfg.providers) |p| {
            if (!std.mem.eql(u8, p.name, name)) continue;
            if (p.api_key) |k| has_key = std.mem.trim(u8, k, " \t\r\n").len > 0;
            break;
        }
        try aw.writer.writeAll("{\"name\":");
        try writeString(&aw.writer, name);
        try aw.writer.print(",\"has_key\":{s}}}", .{if (has_key) "true" else "false"});
    }
    try aw.writer.writeAll("]}");

    out = aw.toArrayList();
    return out.toOwnedSlice(allocator);
}

/// `memory stats --json`: what the memory plan resolved to, and how much is
/// in it. Null when the config has no memory backend to report on.
pub fn memoryStats(allocator: std.mem.Allocator, cfg: *const Config) !?[]u8 {
    var rt = memory_mod.initRuntime(allocator, &cfg.memory, cfg.workspace_dir) orelse return null;
    defer rt.deinit();

    const r = rt.resolved;
    const report = rt.diagnose();

    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(allocator);
    var aw: std.Io.Writer.Allocating = .fromArrayList(allocator, &out);
    const w = &aw.writer;

    try w.writeAll("{\"backend\":");
    try writeString(w, r.primary_backend);
    try w.writeAll(",\"retrieval\":");
    try writeString(w, r.retrieval_mode);
    try w.writeAll(",\"vector\":");
    try writeString(w, r.vector_mode);
    try w.writeAll(",\"embedding\":");
    try writeString(w, r.embedding_provider);
    try w.writeAll(",\"rollout\":");
    try writeString(w, r.rollout_mode);
    try w.writeAll(",\"sync\":");
    try writeString(w, r.vector_sync_mode);
    try w.print(",\"sources\":{d}", .{r.source_count});
    try w.writeAll(",\"fallback\":");
    try writeString(w, r.fallback_policy);
    try w.print(",\"entries\":{d}", .{report.entry_count});
    try w.writeAll(",\"vector_entries\":");
    if (report.vector_entry_count) |n| try w.print("{d}", .{n}) else try w.writeAll("null");
    try w.writeAll(",\"outbox_pending\":");
    if (report.outbox_pending) |n| try w.print("{d}", .{n}) else try w.writeAll("null");
    try w.writeAll("}");

    out = aw.toArrayList();
    return try out.toOwnedSlice(allocator);
}

/// `skills list --json`: the skills installed in the workspace and beside the
/// config, with what each needs and whether it has it.
pub fn skillsList(allocator: std.mem.Allocator, cfg: *const Config) ![]u8 {
    const skills_mod = @import("skills.zig");
    const config_paths = @import("config_paths.zig");

    const builtin_dir = config_paths.defaultConfigDir(allocator) catch null;
    defer if (builtin_dir) |d| allocator.free(d);

    const skills = try skills_mod.listSkillsMerged(
        allocator,
        builtin_dir orelse cfg.workspace_dir,
        cfg.workspace_dir,
        null,
    );
    defer skills_mod.freeSkills(allocator, skills);

    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(allocator);
    var aw: std.Io.Writer.Allocating = .fromArrayList(allocator, &out);
    const w = &aw.writer;

    try w.writeByte('[');
    for (skills, 0..) |skill, i| {
        if (i > 0) try w.writeByte(',');
        try w.writeAll("{\"name\":");
        try writeString(w, skill.name);
        try w.writeAll(",\"version\":");
        try writeString(w, skill.version);
        try w.writeAll(",\"description\":");
        try writeString(w, skill.description);
        try w.print(",\"enabled\":{s}", .{if (skill.enabled) "true" else "false"});
        try w.print(",\"available\":{s}", .{if (skill.available) "true" else "false"});
        if (skill.missing_deps.len > 0) {
            try w.writeAll(",\"missing\":");
            try writeString(w, skill.missing_deps);
        }
        try w.writeByte('}');
    }
    try w.writeByte(']');

    out = aw.toArrayList();
    return try out.toOwnedSlice(allocator);
}

/// `channel list --json`: the channels this build has, with whether each is
/// configured and how many accounts it holds.
pub fn channelList(allocator: std.mem.Allocator, cfg: *const Config) ![]u8 {
    const channel_admin = @import("channel_admin.zig");
    const health = @import("health.zig");

    var snapshot = try health.snapshot(allocator);
    defer snapshot.deinit(allocator);

    const items = try channel_admin.collectConfiguredChannels(allocator, &cfg.channels, snapshot);
    defer allocator.free(items);

    return std.json.Stringify.valueAlloc(allocator, items, .{ .emit_null_optional_fields = false });
}

/// `cron list --json`: the scheduled tasks on disk.
///
/// The CLI asks a running gateway first and falls back to the files; this
/// reads the files, which is what a window that is not the gateway should do.
pub fn cronList(allocator: std.mem.Allocator) ![]u8 {
    const cron = @import("cron.zig");

    var scheduler = cron.CronScheduler.init(allocator, 1024, true);
    defer scheduler.deinit();
    try cron.loadJobs(&scheduler);

    return cron.buildJobsJson(allocator, scheduler.listJobs());
}

fn writeString(w: *std.Io.Writer, s: []const u8) !void {
    try w.writeByte('"');
    for (s) |ch| switch (ch) {
        '"' => try w.writeAll("\\\""),
        '\\' => try w.writeAll("\\\\"),
        '\n' => try w.writeAll("\\n"),
        '\r' => try w.writeAll("\\r"),
        '\t' => try w.writeAll("\\t"),
        else => if (ch < 0x20) try w.print("\\u{x:0>4}", .{ch}) else try w.writeByte(ch),
    };
    try w.writeByte('"');
}

fn writeOptionalString(w: *std.Io.Writer, s: ?[]const u8) !void {
    if (s) |v| try writeString(w, v) else try w.writeAll("null");
}
