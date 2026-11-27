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

    // The settings menu, reached from the button at the sidebar's foot: the
    // window's one entry to every page but the conversation.
    w.app.toggleSettings();
    w.tester.settle(0.5);
    try shoot(&w, "01b-settings-menu");
    w.app.openPage(.chat);
    w.tester.settle(0.3);

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
        \\# the provider this config names
        \\nullclaw config get default_provider
        \\```
        \\
        \\**Note:** the provider needs an API key before it can be used, and
        \\***every*** channel inherits it — a channel marked ~~enabled~~ in the
        \\config is not a channel that has a key.
        \\
        \\- `openrouter` — the default
        \\- `anthropic` — Claude
        \\
        \\> Keys live in the secrets store, not the config file.
        \\> > A config may name a key, but it should not hold one.
        \\
        \\- - -
        \\
        \\The runtime reads it once, at startup:
        \\
        \\```zig
        \\const key = config.providers.items[0].api_key orelse "missing";
        \\if (key.len == 0) return error.NoKey; // fail loudly
        \\const help =
        \\    \\\\Set models.providers.<name>.api_key, then restart.
        \\    \\\\An empty value is the same as no value at all.
        \\;
        \\```
    );
    w.tester.settle(0.5);
    try shoot(&w, "02-chat-markdown");

    // A quoted passage, a numbered list, and a break between sections: the
    // three shapes prose uses to hand something to someone else.
    w.app.newChat();
    w.app.pushMessage("user", "What does the security model say?");
    w.app.pushMessage("assistant",
        \\## The shape of a deployment
        \\
        \\> A gateway that is not exposed cannot be attacked. Bind it to
        \\> `127.0.0.1`, pair once, and reach it through a tunnel — the three
        \\> rules that follow are consequences of that one.
        \\
        \\---
        \\
        \\The checks, in the order a request meets them:
        \\
        \\8. the tunnel terminates the TLS session
        \\9. the gateway verifies the bearer token
        \\10. the tool layer re-checks the workspace scope
        \\11. the sandbox runs the command, and nothing above it can widen it
        \\
        \\> > A quotation inside a quotation carries two edges, and the outer
        \\> > one is the fainter of the two.
    );
    w.tester.settle(0.5);
    try shoot(&w, "02f-chat-quote-list-rule");

    // A table, a nested list and a footnote: the three things an answer can
    // carry that a paragraph cannot show. The reference in the prose is a
    // link to the note under the reply.
    w.app.newChat();
    w.app.pushMessage("user", "Which providers are configured, and what do they cost?");
    w.app.pushMessage("assistant",
        \\Each provider needs its own key[^keys]. These are set up now:
        \\
        \\| Provider | Model | Key |
        \\| :--- | :--- | ---: |
        \\| openrouter | claude-sonnet-4 | set |
        \\| anthropic | claude-opus-4 | set |
        \\| zhipu | glm-4.6 | none |
        \\
        \\What is left:
        \\
        \\- configure
        \\  - the zhipu key
        \\    - at https://open.bigmodel.cn
        \\- [x] openrouter
        \\- [ ] anthropic
        \\
        \\[^keys]: Stored in `~/.nullclaw/config.json` under `models.providers`.
    );
    w.tester.settle(0.5);
    try shoot(&w, "02b-chat-table");

    // Six ranks of heading, and a code block whose Copy button is part of the
    // shot: the hierarchy a reply is read by, and the one control it has.
    w.app.newChat();
    w.app.pushMessage("user", "How is a reply structured?");
    w.app.pushMessage("assistant",
        \\# Session startup
        \\
        \\## What the runtime reads
        \\
        \\### The workspace
        \\
        \\#### Required files
        \\
        \\##### Order
        \\
        \\###### Notes
        \\
        \\Each step is one read, and the whole list is longer than the block
        \\shows:
        \\
        \\```zig
        \\const std = @import("std");
        \\const bootstrap = @import("bootstrap/root.zig");
        \\
        \\/// What the runtime reads before the first turn.
        \\pub const Startup = struct {
        \\    workspace: std.fs.Dir,
        \\    identity: ?Identity = null,
        \\    skills: []const Skill = &.{},
        \\
        \\    pub fn load(dir: std.fs.Dir) !Startup {
        \\        var self: Startup = .{ .workspace = dir };
        \\        self.identity = try Identity.read(dir);
        \\        self.skills = try Skill.scan(dir);
        \\        return self;
        \\    }
        \\
        \\    pub fn deinit(self: *Startup) void {
        \\        if (self.identity) |*id| id.deinit();
        \\        for (self.skills) |*s| s.deinit();
        \\    }
        \\};
        \\```
    );
    w.tester.settle(0.5);
    try shoot(&w, "02e-chat-headings");

    // A table wider than the window keeps its columns and scrolls sideways,
    // a `<br>` breaks a line where it stands, and a note carries the way back
    // to the sentence that cited it.
    w.app.newChat();
    w.app.pushMessage("user", "Show the channel matrix, and the pairing rule.");
    w.app.pushMessage("assistant",
        \\Pairing comes first[^pairing].<br>Everything else waits on it.
        \\
        \\| Channel | Transport | Auth | Allowlist | Mode | Retries | Reconnect | Backoff | Pairing | Scope |
        \\| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
        \\| telegram | long poll | bot token | required | supervised | 3 | backoff | exponential | six digits | per account |
        \\| discord | websocket | bot token | required | supervised | 3 | backoff | exponential | six digits | per account |
        \\| signal | dbus | linked device | required | supervised | 3 | backoff | exponential | six digits | per account |
        \\
        \\[^pairing]: A six-digit code, shown once at startup and exchanged for a token.
    );
    w.tester.settle(0.5);
    try shoot(&w, "02c-chat-wide-table");

    // An inline formula, a checklist, and a picture: the three things an
    // answer carries that prose alone cannot.
    // A picture the answer points at: the shot of the empty window, so the
    // picture in the shot is one a reader can recognise as decoded rather
    // than a placeholder.
    w.app.newChat();
    w.app.pushMessage("user", "Explain the pairing rule, and what is left to do.");
    w.app.pushMessage("assistant",
        \\What is left:
        \\
        \\- [x] generate the key pair
        \\- [x] show the code once, at startup
        \\- [ ] exchange it for a token
        \\  - [ ] store the token in the secret store
        \\- [ ] refuse a second exchange
        \\
        \\![the window this was taken in](/tmp/nullclaw-gui-shots/01-chat-empty.png)
        \\
        \\![a screenshot that is not there](/tmp/nullclaw-gui-shots/missing.png)
        \\
        \\![a diagram on the web](https://example.com/diagram.png)
        \\
        \\The wait between attempts grows as $t_n = \min(2^n \times 250, 8000)$ ms,
        \\so the fifth try already waits $2^5 \times 250 = 8000$ ms, and every
        \\later one waits the same.
    );
    w.tester.settle(0.5);
    try shoot(&w, "02d-chat-math-task-image");

    // An answer mid-flight: the transcript, then the bubble being written,
    // with the composer offering to stop it.
    w.app.sending = true;
    w.app.onDelta("Reading the config, then the workspace.\n\nThe provider is ");
    w.tester.settle(0.3);
    try shoot(&w, "12-streaming");
    w.app.sending = false;
    w.app.clearStream();

    // The Model board, loading the real file through `gotConfig`.
    w.app.openPage(.cfg_model);
    w.settle(1);
    try shoot(&w, "03-config");

    // A board with more rows than the Model one: the rail stays put, the card
    // scrolls under the pinned bar, and the bar keeps its place.
    w.app.openPage(.cfg_agent);
    w.tester.settle(0.4);
    w.tester.resize(1180, 1500);
    w.tester.settle(0.5);
    try shoot(&w, "10-config-full");
    // The System group's first board: what contains a command, and what is
    // kept of it.
    w.app.openPage(.cfg_security);
    w.tester.settle(0.5);
    try shoot(&w, "10b-config-security");
    w.tester.resize(1180, 800);
    w.app.openPage(.cfg_model);
    w.tester.settle(0.4);
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

    // The palette menu, hung off the settings menu's foot. It is view state
    // rather than a runtime answer, so it is the one popover opened by hand —
    // and it is the last shot, because a menu that has been opened stays drawn
    // until its own frame closes it, which would leak into every shot after.
    w.app.toggleSettings();
    w.tester.settle(0.4);
    w.app.theme_menu_open = true;
    w.tester.settle(0.4);
    try shoot(&w, "01c-theme-menu");

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
