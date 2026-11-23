//! Sidebar module — the conversation list, styled after zeron's rail: a search
//! field with a compact/detailed toggle, then sessions grouped under the
//! channel they came from, each group folding shut.
//!
//! The module owns only its view state (search buffer, row mode, grouping);
//! the sessions themselves stay in `AppState`. Rendering is a plain function of
//! `(sessions, selected, palette)`, so a frame never allocates.

const std = @import("std");
const ui = @import("nanoui").ui;
const design = @import("../design.zig");
const backend = @import("../backend.zig");
const session_row = @import("session_row.zig");

pub const RowMode = session_row.RowMode;

/// What a list frame decided: the row the pointer picked, the row whose hover
/// slot asked to archive/unarchive, and any group whose header was pressed.
pub const ListResult = struct {
    clicked: ?usize = null,
    archive: ?usize = null,
    fold: ?[]const u8 = null,
};

/// The group a session belongs to: the part of its key before the colon.
/// `api:default` is the API's, `telegram:42` is Telegram's. A key with no
/// colon is its own group, which is what a one-off session looks like.
pub fn groupOf(key: []const u8) []const u8 {
    if (std.mem.indexOfScalar(u8, key, ':')) |i| {
        if (i > 0) return key[0..i];
    }
    return key;
}

/// A group's display name: the channel, capitalised the way a heading is.
/// `api` reads as "API" because that is what it is; everything else gets its
/// first letter up.
pub fn groupTitle(name: []const u8) []const u8 {
    if (std.mem.eql(u8, name, "api")) return "API";
    return name;
}

/// The sidebar's own, small view state. Lives in `AppState`.
pub const Sidebar = struct {
    search: ui.TextBuffer = .{},
    mode: RowMode = .compact,
    grouped: bool = true,

    pub fn isSearching(self: *const Sidebar) bool {
        return self.search.text().len > 0;
    }

    /// Draw the search field plus the compact/grouped toggles. Returns true
    /// when the view toggles changed (so the caller can redraw immediately).
    pub fn renderHeader(self: *Sidebar, ctx: *ui.Context, pal: *const design.SemanticColor) bool {
        const wrap = ui.div(ctx).column().wFull().gap(design.Spacing.sm).px(design.Spacing.md).pb(design.Spacing.sm);
        defer wrap.end();

        // Search field.
        {
            const field = ui.div(ctx).row().wFull().h(32).itemsCenter().gap(design.Spacing.sm)
                .px(design.Spacing.sm).rounded(design.Radius.md).bg(pal.bg_tertiary).borderW(1).border(pal.border_subtle);
            defer field.end();

            ui.icon(ctx, "magnifyingglass", .{ .size = 12, .color = pal.text_faint });
            _ = ui.textField(ctx, &self.search, .{
                .placeholder = "Search chats",
                .width = .fill,
                .size = design.FontSize.base,
                .bare = true,
                .color = pal.text_primary,
                .placeholder_color = pal.text_faint,
                .caret_color = pal.accent,
            });
        }

        // Toggles row.
        var changed = false;
        {
            const row = ui.div(ctx).row().wFull().itemsCenter().gap(design.Spacing.xs);
            defer row.end();

            const compact_label = if (self.mode == .compact) "Compact" else "Detailed";
            if (ui.button(ctx, compact_label, .{
                .variant = .ghost,
                .size = design.FontSize.xs,
            }).clicked) {
                self.mode = if (self.mode == .compact) .detailed else .compact;
                changed = true;
            }

            if (ui.button(ctx, if (self.grouped) "Grouped" else "Flat", .{
                .variant = .ghost,
                .size = design.FontSize.xs,
            }).clicked) {
                self.grouped = !self.grouped;
                changed = true;
            }
        }
        return changed;
    }

    /// Draw the session list into a scrolling column. Returns what the frame
    /// picked.
    ///
    /// Sessions are grouped under the channel they came from, the way zeron
    /// groups them under their project: a heading with the group's name and how
    /// many it holds, and its rows under it. Pressing a heading folds the group
    /// shut, which is what `folded` records.
    pub fn renderList(
        self: *Sidebar,
        ctx: *ui.Context,
        sessions: []const backend.Session,
        selected: ?usize,
        dark: bool,
        pal: *const design.SemanticColor,
        folded: *std.StringHashMapUnmanaged(void),
    ) ListResult {
        var result: ListResult = .{};

        ui.key(ctx, "sidebar-sessions");
        // `grow` + `min_height = 0`: the box takes the room the foot leaves and
        // reports no minimum of its own, so a long list scrolls instead of
        // pushing the foot off the window. No `hFull` here — that asked for the
        // whole column and left the foot with nothing.
        const list = ui.div(ctx).column().grow().wFull().minW(0).scrollY().gap(1)
            .px(design.Spacing.sm).pb(design.Spacing.sm);
        ctx.node(list.index).style.min_height = 0;
        defer list.end();

        if (sessions.len == 0) {
            session_row.renderEmpty(ctx, "No sessions yet", "Send a message to start one.", pal);
            return result;
        }

        const query = self.search.text();
        var shown: usize = 0;

        // One pass per group: the sessions are already in the runtime's order,
        // so a group's rows stay in that order too. A group is drawn the first
        // time its name is met, and its members are gathered then.
        var seen: std.ArrayListUnmanaged([]const u8) = .empty;
        defer seen.deinit(ctx.alloc());

        for (sessions) |session| {
            if (!matches(query, session.key)) continue;
            const name = groupOf(session.key);
            if (containsStr(seen.items, name)) continue;
            seen.append(ctx.alloc(), name) catch continue;

            // How many of the group survive the query, for the heading's count.
            var count: usize = 0;
            for (sessions) |other| {
                if (matches(query, other.key) and std.mem.eql(u8, groupOf(other.key), name)) count += 1;
            }

            const is_folded = folded.contains(name);
            if (session_row.renderSectionHeader(ctx, groupTitle(name), count, is_folded, false, pal)) {
                result.fold = name;
            }
            shown += 1;
            if (is_folded) continue;

            for (sessions, 0..) |member, j| {
                if (!matches(query, member.key)) continue;
                if (!std.mem.eql(u8, groupOf(member.key), name)) continue;

                const sel = selected != null and selected.? == j;
                const row_data = session_row.RowData{
                    .title = member.key,
                    .preview = null,
                    .last_active = backend.formatStamp(ctx.alloc(), member.last_active),
                    .project_path = null,
                    .is_pinned = false,
                    .is_archived = false,
                    .unseen = false,
                    .indicator = .idle,
                };

                ui.keyInt(ctx, @intCast(j));
                const row_result = session_row.render(ctx, row_data, self.mode, sel, dark, pal);

                if (row_result.clicked) result.clicked = j;
                if (row_result.action != .none) result.archive = j;
                shown += 1;
            }
        }

        if (shown == 0) {
            session_row.renderEmpty(ctx, "No matching chats", "Try a different search.", pal);
        }

        return result;
    }
};

fn containsStr(haystack: []const []const u8, needle: []const u8) bool {
    for (haystack) |h| {
        if (std.mem.eql(u8, h, needle)) return true;
    }
    return false;
}

/// Case-insensitive substring test. An empty query matches everything.
fn matches(query: []const u8, haystack: []const u8) bool {
    if (query.len == 0) return true;
    if (query.len > haystack.len) return false;
    var i: usize = 0;
    while (i + query.len <= haystack.len) : (i += 1) {
        var same = true;
        for (query, 0..) |ch, j| {
            if (std.ascii.toLower(ch) != std.ascii.toLower(haystack[i + j])) {
                same = false;
                break;
            }
        }
        if (same) return true;
    }
    return false;
}

test "matches is case-insensitive substring" {
    try std.testing.expect(matches("", "anything"));
    try std.testing.expect(matches("tele", "telegram:42"));
    try std.testing.expect(matches("TELE", "telegram:42"));
    try std.testing.expect(!matches("zzz", "telegram:42"));
    try std.testing.expect(!matches("longer-than", "x"));
}

test "a session's group is the channel before its colon" {
    try std.testing.expectEqualStrings("api", groupOf("api:default"));
    try std.testing.expectEqualStrings("telegram", groupOf("telegram:42"));
    try std.testing.expectEqualStrings("discord", groupOf("discord:guild:7"));
    // No colon: the key is its own group, which is what a one-off looks like.
    try std.testing.expectEqualStrings("scratch", groupOf("scratch"));
    // A leading colon has no channel to name, so the key stands for itself.
    try std.testing.expectEqualStrings(":odd", groupOf(":odd"));
}

test "a group's title capitalises the API and nothing else" {
    try std.testing.expectEqualStrings("API", groupTitle("api"));
    try std.testing.expectEqualStrings("telegram", groupTitle("telegram"));
}
