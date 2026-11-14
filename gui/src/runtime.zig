//! Running `nullclaw` without freezing the window.
//!
//! A turn can take many seconds, so every command runs on its own thread and
//! the view collects the finished ones at the top of a frame (`pump`). The
//! executor owns the command line, the output, and the thread; a handler sees
//! them for the length of one call and must copy what it wants to keep.
const std = @import("std");
const yc = @import("nullclaw");
const Io = std.Io;
const builtin = @import("builtin");

/// How much of a command's output is kept. A runtime that prints more than
/// this has gone wrong, and the tail is not worth the memory.
const output_limit: usize = 16 << 20;

/// What a finished command produced. Every slice is borrowed from the job and
/// is freed as soon as the handler returns.
pub const Result = struct {
    argv: []const []const u8,
    label: []const u8,
    /// The child ran and exited with status 0.
    ok: bool,
    code: u8,
    stdout: []const u8,
    stderr: []const u8,
    /// Set when the child could not be started at all, e.g. the runtime is
    /// not installed. `code` is 0 and both streams are empty.
    spawn_error: ?anyerror = null,

    /// The command as a single line, for the log.
    pub fn command(self: Result, gpa: std.mem.Allocator) []const u8 {
        return std.mem.join(gpa, " ", self.argv) catch self.label;
    }
};

/// Where a finished command goes. `Handler.of(&state, State.onResult)` builds
/// one without a cast at the call site.
pub const Handler = struct {
    ctx: *anyopaque,
    call: *const fn (ctx: *anyopaque, result: Result) void,

    pub fn of(ptr: anytype, comptime f: fn (@TypeOf(ptr), Result) void) Handler {
        const P = @TypeOf(ptr);
        return .{
            .ctx = @ptrCast(ptr),
            .call = struct {
                fn invoke(p: *anyopaque, result: Result) void {
                    f(@as(P, @ptrCast(@alignCast(p))), result);
                }
            }.invoke,
        };
    }
};

const Job = struct {
    gpa: std.mem.Allocator,
    io: Io,
    argv: [][]u8,
    label: []u8,
    handler: Handler,
    thread: std.Thread,
    /// Set once the thread has been joined; a thread is joined exactly once.
    joined: bool = false,
    done: std.atomic.Value(bool) = .init(false),
    stdout: []u8 = &.{},
    stderr: []u8 = &.{},
    ok: bool = false,
    code: u8 = 0,
    spawn_error: ?anyerror = null,

    /// Joins the worker thread. A `std.Thread` handle may be joined exactly
    /// once, and `pump` plus `deinit` both want to; this makes that safe.
    fn joinOnce(self: *Job) void {
        if (self.joined) return;
        self.thread.join();
        self.joined = true;
    }

    fn free(self: *Job) void {
        for (self.argv) |arg| self.gpa.free(arg);
        self.gpa.free(self.argv);
        self.gpa.free(self.label);
        self.gpa.free(self.stdout);
        self.gpa.free(self.stderr);
        self.gpa.destroy(self);
    }
};

fn work(job: *Job) void {
    const view = job.gpa.alloc([]const u8, job.argv.len) catch {
        job.spawn_error = error.OutOfMemory;
        job.done.store(true, .release);
        return;
    };
    defer job.gpa.free(view);
    for (job.argv, 0..) |arg, i| view[i] = arg;

    const outcome = std.process.run(job.gpa, job.io, .{
        .argv = view,
        .stdout_limit = .limited(output_limit),
        .stderr_limit = .limited(output_limit),
    }) catch |err| {
        job.spawn_error = err;
        job.done.store(true, .release);
        return;
    };
    job.stdout = outcome.stdout;
    job.stderr = outcome.stderr;
    job.ok = outcome.term.success();
    job.code = switch (outcome.term) {
        .exited => |code| code,
        else => 1,
    };
    job.done.store(true, .release);
}

pub const Executor = struct {
    gpa: std.mem.Allocator,
    io: Io,
    /// The program to run. It becomes `argv[0]`, which is what
    /// `std.process.run`'s default `exe = .detect` executes: a bare name is
    /// looked up on `PATH`, and a path containing a `/` is used as it stands.
    /// Borrowed, so it must outlive the executor.
    exe: []const u8,
    jobs: std.ArrayListUnmanaged(*Job) = .empty,
    running: usize = 0,

    pub fn init(gpa: std.mem.Allocator, io: Io, exe: []const u8) Executor {
        return .{ .gpa = gpa, .io = io, .exe = exe };
    }

    /// Stops every thread and frees every job. A command still running is
    /// waited for: the runtime is not a background service, and killing a turn
    /// halfway would leave its session half written.
    pub fn deinit(self: *Executor) void {
        for (self.jobs.items) |job| {
            job.joinOnce();
            job.free();
        }
        self.jobs.deinit(self.gpa);
        self.* = undefined;
    }

    /// Starts `exe` followed by `argv` on its own thread. The command line and
    /// the label are copied, so the caller's buffers may go out of scope at
    /// once. `argv` is the arguments only; the program is prepended here, as
    /// `std.process.run` reads the program out of `argv[0]`.
    pub fn submit(
        self: *Executor,
        argv: []const []const u8,
        label: []const u8,
        handler: Handler,
    ) !void {
        const job = try self.gpa.create(Job);
        errdefer self.gpa.destroy(job);

        const owned = try self.gpa.alloc([]u8, argv.len + 1);
        var copied: usize = 0;
        errdefer {
            for (owned[0..copied]) |arg| self.gpa.free(arg);
            self.gpa.free(owned);
        }
        owned[0] = try self.gpa.dupe(u8, self.exe);
        copied = 1;
        for (argv, 0..) |arg, i| {
            owned[i + 1] = try self.gpa.dupe(u8, arg);
            copied = i + 2;
        }
        const owned_label = try self.gpa.dupe(u8, label);
        errdefer self.gpa.free(owned_label);

        job.* = .{
            .gpa = self.gpa,
            .io = self.io,
            .argv = owned,
            .label = owned_label,
            .handler = handler,
            .thread = undefined,
        };
        errdefer job.free();
        job.thread = try std.Thread.spawn(.{}, work, .{job});
        try self.jobs.append(self.gpa, job);
        self.running += 1;
    }

    /// Hands every finished command to its handler. Call once at the top of a
    /// frame; handlers may submit further commands.
    pub fn pump(self: *Executor) void {
        var i: usize = 0;
        while (i < self.jobs.items.len) {
            const job = self.jobs.items[i];
            if (!job.done.load(.acquire)) {
                i += 1;
                continue;
            }
            job.joinOnce();
            self.running -= 1;
            job.handler.call(job.handler.ctx, .{
                .argv = job.argv,
                .label = job.label,
                .ok = job.ok,
                .code = job.code,
                .stdout = job.stdout,
                .stderr = job.stderr,
                .spawn_error = job.spawn_error,
            });
            _ = self.jobs.swapRemove(i);
            job.free();
        }
    }

    pub fn busy(self: *const Executor) bool {
        return self.running > 0;
    }

    /// Waits for everything still running and dispatches it. For tests and
    /// for a clean shutdown; the window never calls it.
    pub fn waitAll(self: *Executor) void {
        while (self.jobs.items.len > 0) {
            for (self.jobs.items) |job| job.joinOnce();
            self.pump();
        }
    }
};

// --------------------------------------------------------------------- tests

const testing = std.testing;

const Collector = struct {
    count: usize = 0,
    last_ok: bool = false,
    stdout: []u8 = &.{},
    spawn_error: ?anyerror = null,

    fn onResult(self: *Collector, result: Result) void {
        self.count += 1;
        self.last_ok = result.ok;
        self.spawn_error = result.spawn_error;
        testing.allocator.free(self.stdout);
        self.stdout = testing.allocator.dupe(u8, result.stdout) catch &.{};
    }

    fn deinit(self: *Collector) void {
        testing.allocator.free(self.stdout);
    }
};

fn skipOnWindows() !void {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
}

test "a command's output reaches its handler" {
    try skipOnWindows();
    var io_instance: Io.Threaded = .init(testing.allocator, .{});
    var executor = Executor.init(testing.allocator, io_instance.io(), "/bin/echo");
    defer executor.deinit();

    var collector: Collector = .{};
    defer collector.deinit();

    try executor.submit(&.{ "hello", "nullclaw" }, "echo", Handler.of(&collector, Collector.onResult));
    try testing.expect(executor.busy());
    executor.waitAll();

    try testing.expectEqual(@as(usize, 1), collector.count);
    try testing.expect(collector.last_ok);
    try testing.expectEqualStrings("hello nullclaw\n", collector.stdout);
    try testing.expectEqual(@as(?anyerror, null), collector.spawn_error);
    try testing.expect(!executor.busy());
}

// Regression: `std.process.run` reads the program out of `argv[0]`, and the
// argv the pages build starts at the subcommand (`agent`, `status`). Without
// the executor prepending the program every command spawned "agent" and
// failed with FileNotFound, which looked exactly like a missing runtime.
test "the executor's program is argv[0], bare names included" {
    try skipOnWindows();
    var io_instance: Io.Threaded = .init(testing.allocator, .{});
    // A bare name, so this only works if argv[0] is really the program and
    // `exe = .detect` looks it up on PATH.
    var executor = Executor.init(testing.allocator, io_instance.io(), "echo");
    defer executor.deinit();

    var collector: Collector = .{};
    defer collector.deinit();

    try executor.submit(&.{"through-path"}, "echo", Handler.of(&collector, Collector.onResult));
    executor.waitAll();

    try testing.expectEqual(@as(?anyerror, null), collector.spawn_error);
    try testing.expectEqualStrings("through-path\n", collector.stdout);
}

test "a failing command reports its exit code and stderr" {
    try skipOnWindows();
    var io_instance: Io.Threaded = .init(testing.allocator, .{});
    var executor = Executor.init(testing.allocator, io_instance.io(), "/bin/sh");
    defer executor.deinit();

    const Probe = struct {
        code: u8 = 0,
        ok: bool = true,
        stderr: []u8 = &.{},
        fn onResult(self: *@This(), result: Result) void {
            self.code = result.code;
            self.ok = result.ok;
            testing.allocator.free(self.stderr);
            self.stderr = testing.allocator.dupe(u8, result.stderr) catch &.{};
        }
    };
    var probe: Probe = .{};
    defer testing.allocator.free(probe.stderr);

    try executor.submit(
        &.{ "-c", "echo nope >&2; exit 3" },
        "failing",
        Handler.of(&probe, Probe.onResult),
    );
    executor.waitAll();

    try testing.expect(!probe.ok);
    try testing.expectEqual(@as(u8, 3), probe.code);
    try testing.expectEqualStrings("nope\n", probe.stderr);
}

test "a missing program is a spawn error, not a crash" {
    try skipOnWindows();
    var io_instance: Io.Threaded = .init(testing.allocator, .{});
    var executor = Executor.init(testing.allocator, io_instance.io(), "/nonexistent/nullclaw-does-not-exist");
    defer executor.deinit();

    var collector: Collector = .{};
    defer collector.deinit();

    try executor.submit(
        &.{"--json"},
        "missing",
        Handler.of(&collector, Collector.onResult),
    );
    executor.waitAll();

    try testing.expectEqual(@as(usize, 1), collector.count);
    try testing.expect(collector.spawn_error != null);
    try testing.expect(!collector.last_ok);
}

test "several commands run and report in turn" {
    try skipOnWindows();
    var io_instance: Io.Threaded = .init(testing.allocator, .{});
    var executor = Executor.init(testing.allocator, io_instance.io(), "/bin/echo");
    defer executor.deinit();

    var collector: Collector = .{};
    defer collector.deinit();

    for (0..5) |i| {
        var buf: [8]u8 = undefined;
        const text = try std.fmt.bufPrint(&buf, "{d}", .{i});
        try executor.submit(&.{text}, "echo", Handler.of(&collector, Collector.onResult));
    }
    try testing.expectEqual(@as(usize, 5), executor.running);
    executor.waitAll();
    try testing.expectEqual(@as(usize, 5), collector.count);
}

test "a handler may submit the next command" {
    try skipOnWindows();
    var io_instance: Io.Threaded = .init(testing.allocator, .{});
    var executor = Executor.init(testing.allocator, io_instance.io(), "/bin/echo");
    defer executor.deinit();

    const Chain = struct {
        executor: *Executor,
        seen: usize = 0,
        fn onResult(self: *@This(), result: Result) void {
            _ = result;
            self.seen += 1;
            if (self.seen < 3) {
                self.executor.submit(&.{"again"}, "chain", Handler.of(self, @This().onResult)) catch {};
            }
        }
    };
    var chain: Chain = .{ .executor = &executor };
    try executor.submit(&.{"start"}, "chain", Handler.of(&chain, Chain.onResult));
    executor.waitAll();
    try testing.expectEqual(@as(usize, 3), chain.seen);
}

/// A long-lived `nullclaw gateway` process managed by the GUI.
///
/// The gateway owns its own stdout/stderr (inherited by default through the
/// child pipes we drain in a watcher thread) and runs until stopped. `poll`
/// reports whether it is still alive; `stop` asks it to exit and waits for it.
pub const Daemon = struct {
    gpa: std.mem.Allocator,
    io: Io,
    exe: []const u8,
    child: ?std.process.Child = null,
    /// The outcome of the last `wait`, set once the child has been reaped.
    term: ?std.process.Child.Term = null,
    /// Why `start` failed, when the child could not be spawned at all.
    last_error: ?[]u8 = null,
    /// Host/port the gateway was asked to bind; remembered for the status UI.
    host: []u8 = &.{},
    port: u16 = 0,

    pub fn init(gpa: std.mem.Allocator, io: Io, exe: []const u8) Daemon {
        return .{ .gpa = gpa, .io = io, .exe = exe };
    }

    pub fn deinit(self: *Daemon) void {
        self.stop();
        self.clearError();
        if (self.host.len > 0) self.gpa.free(self.host);
        self.host = &.{};
        self.* = undefined;
    }

    fn clearError(self: *Daemon) void {
        if (self.last_error) |msg| self.gpa.free(msg);
        self.last_error = null;
    }

    fn setError(self: *Daemon, comptime fmt: []const u8, args: anytype) void {
        self.clearError();
        self.last_error = std.fmt.allocPrint(self.gpa, fmt, args) catch null;
    }

    /// True while the child process is running.
    pub fn running(self: *Daemon) bool {
        if (self.child == null) return false;
        if (self.term != null) return false;
        // Reap without blocking: on Unix a signalled/stopped child is only
        // reported after `wait`; a still-running child returns `unknown`.
        self.poll();
        return self.child != null and self.term == null;
    }

    /// Non-blocking reap. Safe to call often.
    pub fn poll(self: *Daemon) void {
        const child = if (self.child) |*c| c else return;
        if (self.term != null) return;
        // std.process.Child.wait is blocking in 0.17; avoid hanging the UI.
        // Instead, try waitpid via posix when available.
        if (builtin.os.tag == .windows) return;
        if (child.id) |pid| {
            var status: c_int = 0;
            const rc = std.c.waitpid(@intCast(pid), &status, std.c.W.NOHANG);
            if (rc == 0) return; // still running
            if (rc < 0) return;
            // Mark reaped so deinit/stop won't wait again.
            child.id = null;
            // Decode wait status portably enough for common Unix.
            const u: u32 = @bitCast(status);
            if (std.c.W.IFEXITED(u)) {
                self.term = .{ .exited = @intCast(std.c.W.EXITSTATUS(u)) };
            } else {
                self.term = .{ .unknown = u };
            }
        }
    }

    /// Starts `exe gateway [--host host] [--port port]` if not already running.
    pub fn start(self: *Daemon, host: []const u8, port: u16) !void {
        if (self.running()) return;
        // If a previous child exited, clear it so we can start fresh.
        if (self.child != null and self.term != null) {
            self.child = null;
            self.term = null;
        }
        self.clearError();

        var argv_buf: [6][]const u8 = undefined;
        var n: usize = 0;
        argv_buf[n] = self.exe;
        n += 1;
        argv_buf[n] = "gateway";
        n += 1;
        var port_buf: [16]u8 = undefined;
        if (host.len > 0) {
            argv_buf[n] = "--host";
            n += 1;
            argv_buf[n] = host;
            n += 1;
        }
        if (port != 0) {
            argv_buf[n] = "--port";
            n += 1;
            argv_buf[n] = std.fmt.bufPrint(&port_buf, "{d}", .{port}) catch "0";
            n += 1;
        }

        const child = std.process.spawn(self.io, .{
            .argv = argv_buf[0..n],
            .stdin = .ignore,
            .stdout = .ignore,
            .stderr = .ignore,
        }) catch |err| {
            self.setError("could not start gateway: {s}", .{@errorName(err)});
            return err;
        };
        self.child = child;

        if (self.host.len > 0) self.gpa.free(self.host);
        self.host = self.gpa.dupe(u8, host) catch &.{};
        self.port = port;
    }

    /// Stops the managed gateway, if any, and waits for it to exit.
    pub fn stop(self: *Daemon) void {
        const child = if (self.child) |*c| c else return;
        self.poll();
        if (self.term == null) {
            child.kill(self.io);
            // Block until reaped.
            self.term = child.wait(self.io) catch .{ .unknown = 0 };
            // wait consumes id on some impls; be defensive.
            child.id = null;
        }
        // Close any pipes we might have (we used ignore, so nothing to close).
        self.child = null;
    }

    /// A short human-readable status string for the UI, in memory that
    /// outlives the call: nanoui draws the frame after the view returns, so a
    /// caller's stack buffer would be gone by then.
    pub fn statusLabel(self: *Daemon, a: std.mem.Allocator) []const u8 {
        if (self.running()) {
            if (self.port != 0 and self.host.len > 0) {
                return std.fmt.allocPrint(a, "running on {s}:{d}", .{ self.host, self.port }) catch "running";
            }
            if (self.port != 0) {
                return std.fmt.allocPrint(a, "running on :{d}", .{self.port}) catch "running";
            }
            return "running";
        }
        if (self.last_error) |msg| return msg;
        if (self.term) |t| {
            return switch (t) {
                .exited => |code| std.fmt.allocPrint(a, "stopped (exit {d})", .{code}) catch "stopped",
                .signal => |sig| std.fmt.allocPrint(a, "stopped (signal {d})", .{@backingInt(sig)}) catch "stopped",
                .stopped => |sig| std.fmt.allocPrint(a, "stopped ({d})", .{@backingInt(sig)}) catch "stopped",
                .unknown => "stopped",
            };
        }
        return "not running";
    }
};

// ── In-process turns ────────────────────────────────────────────────────
//
// The window links the runtime, so a turn is a function call rather than a
// subprocess. It still runs on its own thread: `Agent.turn` can take a minute
// and the view is rebuilt every frame.

/// One turn running on its own thread, with the reply it produced.
pub const Turn = struct {
    gpa: std.mem.Allocator,
    /// The runtime the turn runs against. Owned by the state, not by this.
    runtime: *yc.runtime_builder.Runtime,
    message: []u8,
    session: ?[]u8,
    thread: std.Thread,
    joined: bool = false,
    done: std.atomic.Value(bool) = .init(false),
    reply: []u8 = &.{},
    failure: ?anyerror = null,

    fn joinOnce(self: *Turn) void {
        if (self.joined) return;
        self.thread.join();
        self.joined = true;
    }

    fn free(self: *Turn) void {
        self.gpa.free(self.message);
        if (self.session) |s| self.gpa.free(s);
        self.gpa.free(self.reply);
        self.gpa.destroy(self);
    }
};

fn turnWork(t: *Turn) void {
    defer t.done.store(true, .release);
    if (t.session) |key| t.runtime.useSession(key);
    const reply = t.runtime.turn(t.message) catch |err| {
        t.failure = err;
        return;
    };
    defer t.runtime.allocator.free(reply);
    t.reply = t.gpa.dupe(u8, reply) catch &.{};
}

/// Runs turns against the linked runtime, one thread each.
pub const Turns = struct {
    gpa: std.mem.Allocator,
    jobs: std.ArrayListUnmanaged(*Turn) = .empty,

    pub fn init(gpa: std.mem.Allocator) Turns {
        return .{ .gpa = gpa };
    }

    pub fn deinit(self: *Turns) void {
        for (self.jobs.items) |job| {
            job.joinOnce();
            job.free();
        }
        self.jobs.deinit(self.gpa);
        self.* = undefined;
    }

    pub fn busy(self: *const Turns) bool {
        for (self.jobs.items) |job| {
            if (!job.done.load(.acquire)) return true;
        }
        return false;
    }

    /// Starts a turn. The message and session are copied.
    pub fn start(
        self: *Turns,
        runtime: *yc.runtime_builder.Runtime,
        message: []const u8,
        session: ?[]const u8,
    ) !void {
        const job = try self.gpa.create(Turn);
        errdefer self.gpa.destroy(job);
        job.* = .{
            .gpa = self.gpa,
            .runtime = runtime,
            .message = try self.gpa.dupe(u8, message),
            .session = if (session) |s| try self.gpa.dupe(u8, s) else null,
            .thread = undefined,
        };
        errdefer self.gpa.free(job.message);
        job.thread = try std.Thread.spawn(.{}, turnWork, .{job});
        try self.jobs.append(self.gpa, job);
    }

    /// Hands every finished turn to `handler`, oldest first, and frees it.
    pub fn pump(self: *Turns, ctx: anytype, comptime handler: fn (@TypeOf(ctx), TurnResult) void) void {
        var i: usize = 0;
        while (i < self.jobs.items.len) {
            const job = self.jobs.items[i];
            if (!job.done.load(.acquire)) {
                i += 1;
                continue;
            }
            job.joinOnce();
            handler(ctx, .{
                .reply = job.reply,
                .failure = job.failure,
            });
            _ = self.jobs.swapRemove(i);
            job.free();
        }
    }
};

/// What a finished turn produced: the reply, or why it failed.
pub const TurnResult = struct {
    reply: []const u8,
    failure: ?anyerror,
};
