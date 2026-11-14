//! nullclaw-gui: a desktop front end for NullClaw, built on nanoui.
//!
//! This app owns the window and drives the `nullclaw` runtime as a
//! child process (`nullclaw history …`, `nullclaw agent invoke …`,
//! `nullclaw config …`) and reads `~/.nullclaw/config.json` directly. See
//! src/runtime.zig for the executor and src/backend.zig for the command line.
const std = @import("std");
const nanoui = @import("nanoui");
const ui = nanoui.ui;

const yc = @import("nullclaw");
const state = @import("state.zig");
const theme = @import("theme.zig");
const view = @import("view.zig");

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;

    // Before anything reaches for the runtime: providers and tools spawn
    // processes through the shared compat layer, and without this it hands
    // them a single-threaded io. Every request then fails as
    // `CompatibleApiError`, which surfaces as "all providers failed" on the
    // first message.
    yc.runtime_builder.Runtime.initProcessIo(init);

    var app_state = try state.AppState.init(gpa, init.io, init.environ_map);
    defer app_state.deinit();

    const app = try nanoui.App.create(init, .{ .name = "nullclaw" });
    defer app.destroy();

    _ = try app.newWindow(.{
        .title = "nullclaw",
        .width = 1180,
        .height = 800,
        .min_width = 760,
        .min_height = 520,
        .title_bar = .hidden,
        .theme = theme.uiTheme(app_state.palette),
        .content = .{ .view = .init(&app_state, view.root) },
    });
    try app.run();
}
