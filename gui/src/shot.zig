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

    // The configuration page, loading the real file through `gotConfig`.
    w.app.openPage(.config);
    w.settle(1);
    try shoot(&w, "03-config");

    // A capability page, answered by the runtime itself.
    w.app.openPage(.models);
    w.settle(1);
    try shoot(&w, "04-models");

    // The same page with every key opened, which is what clicking a summary row
    // does.
    w.app.expandAll();
    w.tester.settle(0.5);
    try shoot(&w, "05-expanded");

    // The complaint path, with a runtime that answers nothing — the toast is the
    // one the window really shows, not one typed into the state.
    var path_buffer_2: [256]u8 = undefined;
    const failing = try harness.writeFailingStub(io, &path_buffer_2);
    var broken: harness.Window = undefined;
    try broken.initWith(.{ .runtime = failing });
    defer broken.deinit();
    broken.app.openPage(.status);
    broken.settle(1);
    try shoot(&broken, "06-complaint");
}
