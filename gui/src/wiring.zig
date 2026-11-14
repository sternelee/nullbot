//! The linked runtime has to point at itself, not at a frame that is gone.

const std = @import("std");
const testing = std.testing;
const yc = @import("nullclaw");

// Regression: `Runtime.init` used to hand `agent.mem_rt` and the memory tools
// the address of a local `MemoryRuntime`. The first turn then read a freed
// stack slot as the outbox handle and segfaulted inside `sqlite3_prepare_v2`.
test "the memory runtime lives in the struct, not in a frame" {
    const gpa = testing.allocator;
    var rt = yc.runtime_builder.Runtime.init(gpa) catch |err| switch (err) {
        // A machine with no config has no runtime to point at; the wiring
        // question does not arise.
        error.NoDefaultModel => return error.SkipZigTest,
        else => return err,
    };
    defer rt.deinit();
    rt.wireMemory();

    if (rt.mem_rt_storage == null) {
        try testing.expect(rt.mem_rt == null);
        try testing.expect(rt.agent.mem_rt == null);
        return;
    }

    // The pointer must be this struct's own field. Comparing against the
    // address of the field is the whole point: any other address is a frame
    // that no longer exists.
    const field = &rt.mem_rt_storage.?;
    try testing.expect(rt.mem_rt == field);
    try testing.expect(rt.agent.mem_rt == field);

    // And what it points at must be readable, with a vector plane that is
    // either absent or real. A garbage pointer shows up here as a crash or
    // as a store without an outbox.
    const mem = field.*;
    if (mem._vector_store == null) {
        try testing.expect(mem._outbox == null);
    }
}

// Regression: the window never handed its io to the shared compat layer, so
// providers and tools spawned through a single-threaded fallback. Every
// request came back as `CompatibleApiError` and the first message ended in
// "all providers failed". `main` now calls `initProcessIo` before anything
// else; this guards that the entry point still exists and is reachable.
test "the runtime exposes the process io hook the window needs" {
    const hook = yc.runtime_builder.Runtime.initProcessIo;
    try testing.expect(@TypeOf(hook) == fn (std.process.Init) void);
}
