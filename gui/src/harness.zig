//! A window driven headlessly, so a broken box or a missing label fails in a
//! test rather than on screen.
const std = @import("std");
const testing = std.testing;
const ui = @import("nanoui").ui;

const state = @import("state.zig");
const theme = @import("theme.zig");
const view = @import("view.zig");

/// A home of its own: the app resolves `~/.nullclaw` from here, and no test
/// should read the machine's real one. Tests that need a configuration write
/// `test_home ++ "/.nullclaw/config.json"`.
pub const test_home = "/tmp/nullclaw-gui-tests";

/// A `nullclaw` that answers the commands the window runs, so the whole chain
/// — the argv the pages build, the spawn, the JSON, the state, the drawing —
/// is exercised without the real runtime installed.
const stub_source =
    \\#!/bin/sh
    \\case "$1 $2" in
    \\"agent sessions")
    \\  printf '%s' '{"sessions":[{"session_key":"s1","created_at":"2026-05-30T09:00:00Z","last_active":"2026-05-30T12:30:00Z","turn_count":3,"turn_running":false}],"total":1}'
    \\  ;;
    \\"history show")
    \\  printf '%s' '{"session_id":"s1","total":2,"limit":200,"offset":0,"messages":[{"role":"user","content":"what is nullclaw","created_at":"2026-05-30T12:00:00Z"},{"role":"assistant","content":"**nullclaw** is a Zig runtime.","created_at":"2026-05-30T12:00:04Z"}]}'
    \\  ;;
    \\"agent invoke")
    \\  printf '%s' '{"session":"s1","response":"stub reply","turn_count":4}'
    \\  ;;
    \\"models summary")
    \\  printf '%s' '{"default_provider":"openrouter","default_model":"openrouter/stub-model","providers":[{"name":"openrouter","has_key":true},{"name":"anthropic","has_key":false}]}'
    \\  ;;
    \\"config validate")
    \\  printf '%s' '{"valid":true}'
    \\  ;;
    \\"memory stats")
    \\  printf '%s' '{"backend":"sqlite","retrieval":"hybrid","entries":16,"sources":1}'
    \\  ;;
    \\"skills list"|"channel list"|"cron list"|"mcp list")
    \\  printf '%s' '[]'
    \\  ;;
    \\*)
    \\  case "$1" in
    \\  capabilities)
    \\    printf '%s' '{"version":"stub","active_memory_backend":"sqlite","channels":[{"key":"cli","label":"CLI","enabled_in_build":true,"configured":true,"configured_count":1},{"key":"telegram","label":"Telegram","enabled_in_build":true,"configured":false,"configured_count":0}],"memory_engines":[{"name":"sqlite","enabled_in_build":true,"configured":true},{"name":"markdown","enabled_in_build":true,"configured":false}],"tools":["shell","file_read"],"tools_detail":{"runtime_loaded":["shell","file_read"]}}'
    \\    ;;
    \\  status|doctor|config|models|memory|skills|channel|cron|mcp|auth|workspace|hardware|service|update)
    \\    printf '%s' '{"page":"'"$1"'","stub":true}'
    \\    ;;
    \\  *)
    \\    printf '%s' '{"error":"stub","message":"no answer for: '"$*"'"}' >&2
    \\    exit 1
    \\    ;;
    \\  esac
    \\  ;;
    \\esac
;

/// A runtime that answers nothing, with the envelope the real one writes —
/// `appendJsonError` in `src/main.zig` writes it flat, not nested. Tests that
/// want a page's complaint rather than its rows point at this one.
pub const failing_stub_source =
    \\#!/bin/sh
    \\printf '%s' '{"error":"stub","message":"no answer for: '"$*"'"}' >&2
    \\exit 1
;

const stub_dir = ".zig-cache/gui-stub";

/// Writes the stub runtime and returns its path, which is a slice of `buffer`.
/// `io` must be a real threaded instance: the global single-threaded one has no
/// allocator, and spawning a process needs one.
pub fn writeStub(io: std.Io, buffer: []u8) ![]const u8 {
    return writeStubNamed(io, buffer, "nullclaw", stub_source);
}

/// The same, for the runtime that answers nothing.
pub fn writeFailingStub(io: std.Io, buffer: []u8) ![]const u8 {
    return writeStubNamed(io, buffer, "nullclaw-failing", failing_stub_source);
}

fn writeStubNamed(io: std.Io, buffer: []u8, name: []const u8, source: []const u8) ![]const u8 {
    std.Io.Dir.cwd().createDirPath(io, stub_dir) catch {};
    const path = try std.fmt.bufPrint(buffer, "{s}/{s}", .{ stub_dir, name });
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = source });
    // writeFile leaves the file 0644, and a file that is not executable is not
    // a program.
    const chmod = try std.process.run(testing.allocator, io, .{ .argv = &.{ "chmod", "+x", path } });
    defer testing.allocator.free(chmod.stdout);
    defer testing.allocator.free(chmod.stderr);
    try testing.expect(chmod.term.success());
    return path;
}

/// Writes `~/.nullclaw/config.json` for the window's test home, so the config
/// page has a real file to load. The caller removes it.
pub fn writeConfig(io: std.Io, text: []const u8) ![]const u8 {
    const dir = test_home ++ "/.nullclaw";
    const file = dir ++ "/config.json";
    std.Io.Dir.cwd().createDirPath(io, dir) catch {};
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = file, .data = text });
    return file;
}

pub fn removeConfig(io: std.Io) void {
    std.Io.Dir.cwd().deleteFile(io, test_home ++ "/.nullclaw/config.json") catch {};
}

pub const Window = struct {
    threaded: std.Io.Threaded,
    environ: std.process.Environ.Map,
    app: state.AppState,
    tester: ui.Tester,

    pub const Options = struct {
        /// A `nullclaw` to run instead of the one on `PATH`: the stub the
        /// integration tests answer through.
        runtime: ?[]const u8 = null,
    };

    /// Initialized in place and never moved: both `Tester` and the view hold
    /// pointers into their own storage (the view holds `&app`), so returning
    /// one of these by value would leave them dangling.
    pub fn init(self: *Window) !void {
        return self.initWith(.{});
    }

    pub fn initWith(self: *Window, options: Options) !void {
        self.threaded = std.Io.Threaded.init(testing.allocator, .{});
        errdefer self.threaded.deinit();
        self.environ = std.process.Environ.Map.init(testing.allocator);
        errdefer self.environ.deinit();
        // A home of its own: the app resolves ~/.nullclaw from here, and no
        // test should read the machine's real one.
        try self.environ.put("HOME", test_home);
        if (options.runtime) |path| try self.environ.put("NULLCLAW_BIN", path);
        self.app = try state.AppState.init(testing.allocator, self.threaded.io(), &self.environ);
        errdefer self.app.deinit();
        try self.tester.init(testing.allocator, .init(&self.app, view.root), .{
            .width = 1180,
            .height = 800,
            .theme = theme.uiTheme(self.app.palette),
        });
    }

    pub fn deinit(self: *Window) void {
        self.tester.deinit();
        self.app.deinit();
        self.environ.deinit();
        self.threaded.deinit();
    }

    /// Draws frames until the runtime has answered everything in flight, so a
    /// test can assert what the window shows once a command has come back.
    /// The view pumps the executor at the top of every frame, so framing is
    /// all it takes to fold a result in.
    ///
    /// This waits on the wall clock rather than on frames: a frame takes
    /// microseconds, so a frame budget would give up long before the spawned
    /// process got anywhere. One millisecond between frames is enough for the
    /// runtime's thread to make progress, and the loop leaves as soon as there
    /// is nothing in flight.
    pub fn settle(self: *Window, max_seconds: f32) void {
        const frames: usize = @intFromFloat(max_seconds * 1000);
        const io = self.threaded.io();
        var i: usize = 0;
        while (i < frames) : (i += 1) {
            if (!self.app.busy()) return;
            self.tester.frame();
            std.Io.sleep(io, std.Io.Duration.fromMilliseconds(1), .awake) catch {};
        }
        self.tester.frame();
    }
};
