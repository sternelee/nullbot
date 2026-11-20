//! Renders the window's screens to PNGs, so what the tests assert about can
//! also be looked at. Run with `zig build shots`.
//!
//! The pages are driven the way the app drives them — a runtime on the other
//! end of a process, and a real config file on disk — rather than by injecting
//! JSON into the state. A shot that comes out empty is therefore a page that
//! really is empty, which is exactly how the config page's missing content was
//! caught.
const std = @import("std");
const testing = std.testing;

const harness = @import("harness.zig");

const dir = "/tmp/nullclaw-gui-shots";

fn shoot(w: *harness.Window, name: []const u8) !void {
    const io = std.Io.Threaded.global_single_threaded.io();
    try std.Io.Dir.cwd().createDirPath(io, dir);
    var buf: [256]u8 = undefined;
    const path = try std.fmt.bufPrint(&buf, "{s}/{s}.png", .{ dir, name });
    try w.tester.screenshot(path);
}

test "screenshots" {
    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var path_buffer: [256]u8 = undefined;
    const stub = try harness.writeStub(io, &path_buffer);
    _ = try harness.writeConfig(io,
        \\{
        \\  "agents": { "defaults": { "model": { "primary": "openrouter/glm-4.6" } } },
        \\  "gateway": { "port": 18789 },
        \\  "memory": { "engine": "sqlite" }
        \\}
    );
    defer harness.removeConfig(io);

    var w: harness.Window = undefined;
    try w.initWith(.{ .runtime = stub });
    defer w.deinit();

    // An empty conversation, as it looks the first time the app is opened.
    w.tester.settle(0.5);
    try shoot(&w, "01-chat-empty");

    // The "nullclaw ∨" menu open: every non-chat page, including the
    // configuration editor, is reached from this one collapsible entry.
    try w.tester.clickText("nullclaw ⌄");
    w.tester.settle(0.6);
    try shoot(&w, "01b-brand-menu");
    w.app.menu_open = false;
    w.tester.settle(0.3);

    // The palette menu, hung off the footer's palette button. It is view state
    // rather than a runtime answer, so it is the one popover opened by hand.
    w.app.theme_menu_open = true;
    w.tester.settle(0.4);
    try shoot(&w, "01c-theme-menu");
    w.app.theme_menu_open = false;
    w.tester.settle(0.2);

    // The settings menu is no longer a shot of its own: `openPage` swaps the
    // sidebar to it for every page but chat, so it is in every settings-page
    // shot below (see `03-config`). A dedicated one would be a byte-identical
    // copy.

    // A conversation: the transcript comes back from the runtime, and the
    // markdown the model writes is drawn as text rather than asterisks.
    w.app.refreshSessions();
    w.settle(1);
    w.app.select(0);
    w.settle(1);
    w.app.pushMessage("user", "How do I see which providers are configured?");
    w.app.pushMessage("assistant",
        \\Run `nullclaw models list`, or read `~/.nullclaw/config.json`:
        \\
        \\```sh
        \\nullclaw config get default_provider
        \\```
        \\
        \\**Note:** the provider needs an API key before it can be used.
        \\
        \\- `openrouter` — the default
        \\- `anthropic` — Claude
        \\
        \\> Keys live in the secrets store, not the config file.
    );
    w.tester.settle(0.5);
    try shoot(&w, "02-chat-markdown");

    // An answer mid-flight: the transcript, then the bubble being written,
    // with the composer offering to stop it.
    w.app.sending = true;
    w.app.onDelta("Reading the config, then the workspace.\n\nThe provider is ");
    w.tester.settle(0.3);
    try shoot(&w, "12-streaming");
    w.app.sending = false;
    w.app.clearStream();

    // The configuration page, loading the real file through `gotConfig`.
    w.app.openPage(.config);
    w.settle(1);
    try shoot(&w, "03-config");

    // The same page in a window tall enough for every section, so the lower
    // half of the form can be looked at without scrolling.
    w.tester.resize(1180, 1500);
    w.tester.settle(0.5);
    try shoot(&w, "10-config-full");
    w.tester.resize(1180, 800);
    w.tester.settle(0.5);

    // A capability page, answered by the runtime itself.
    w.app.openPage(.models);
    w.settle(1);
    try shoot(&w, "04-models");

    // A page that draws its answer as a list rather than a tree.
    w.app.openPage(.capabilities);
    w.settle(1);
    try shoot(&w, "08-capabilities");

    // The audit page: findings from the workspace, with their severities.
    w.app.openPage(.workspace);
    w.settle(1);
    try shoot(&w, "11-workspace");

    // A page whose command answered with nothing, which is an answer.
    w.app.openPage(.skills);
    w.settle(1);
    try shoot(&w, "09-empty");

    // A page whose answer the runtime builds in-process, drawn as a foldable
    // tree. Status is the one page that still shows the raw JSON tree rather
    // than rows; every key is opened, which is what clicking a summary row
    // does.
    w.app.openPage(.status);
    w.settle(1);
    w.app.expandAll();
    w.tester.settle(0.5);
    try shoot(&w, "05-expanded");

    // The diagnostics panel, over the chat.
    w.app.diagnostics_open = true;
    w.tester.settle(0.5);
    try shoot(&w, "07-diagnostics");
    w.app.diagnostics_open = false;

    // The complaint path. Every JSON page is answered in-process now, so a
    // failing runtime no longer produces a complaint on its own; the page is
    // shown the message the runtime would have printed, which is what
    // `setJsonProblem` draws.
    var broken: harness.Window = undefined;
    try broken.initWith(.{ .runtime = stub });
    defer broken.deinit();
    broken.app.openPage(.status);
    broken.settle(1);
    broken.app.setJsonProblem("no answer for: status");
    broken.tester.frame();
    try shoot(&broken, "06-complaint");
}
