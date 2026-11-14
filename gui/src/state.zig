//! The application's state and every action that changes it. The view reads
//! this and nothing else; the runtime's answers arrive on worker threads and
//! are folded in by `pump` at the top of a frame, so the view never blocks.
const std = @import("std");
const ui = @import("nanoui").ui;
const backend = @import("backend.zig");
const yc = @import("nullclaw");
const md = @import("md.zig");
const runtime = @import("runtime.zig");
const theme = @import("theme.zig");

pub const Io = std.Io;

/// The page the main area shows. Everything but `chat` and `config` is a
/// runtime command whose JSON the generic viewer draws, which is how the GUI
/// stays aligned with the runtime without a parser per feature.
pub const Page = enum {
    chat,
    config,
    status,
    capabilities,
    models,
    memory,
    skills,
    channels,
    cron,
    mcp,
    auth,
    workspace,
    hardware,
    service,
    update,
    doctor,

    pub fn label(self: Page) []const u8 {
        return switch (self) {
            .chat => "Chat",
            .config => "Configuration",
            .status => "Status",
            .capabilities => "Capabilities",
            .models => "Models",
            .memory => "Memory",
            .skills => "Skills",
            .channels => "Channels",
            .cron => "Cron",
            .mcp => "MCP servers",
            .auth => "Auth",
            .workspace => "Workspace",
            .hardware => "Hardware",
            .service => "Service",
            .update => "Update",
            .doctor => "Doctor",
        };
    }

    pub fn icon(self: Page) []const u8 {
        return switch (self) {
            .chat => "bubble.left.and.bubble.right",
            .config => "gearshape",
            .status => "gauge.medium",
            .capabilities => "checklist",
            .models => "cpu",
            .memory => "brain",
            .skills => "sparkles",
            .channels => "antenna.radiowaves.left.and.right",
            .cron => "clock",
            .mcp => "puzzlepiece.extension",
            .auth => "key",
            .workspace => "folder",
            .hardware => "bolt.horizontal",
            .service => "power",
            .update => "arrow.down.circle",
            .doctor => "stethoscope",
        };
    }

    /// The runtime command this page runs, or null for a page with its own
    /// view. `takesJson` decides whether `--json` is appended to it.
    pub fn command(self: Page) ?[]const []const u8 {
        return switch (self) {
            .chat => null,
            .config => &.{ "config", "show" },
            .status => &.{"status"},
            .capabilities => &.{"capabilities"},
            // `models list` prints prose; `models summary` is the one that
            // takes `--json` (src/main.zig, the models usage block).
            .models => &.{ "models", "summary" },
            .memory => &.{ "memory", "stats" },
            .skills => &.{ "skills", "list" },
            .channels => &.{ "channel", "list" },
            .cron => &.{ "cron", "list" },
            .mcp => &.{ "mcp", "list" },
            // `auth status` takes a provider; openai-codex is the one the
            // runtime authenticates by OAuth (the other is weixin).
            .auth => &.{ "auth", "status", "openai-codex" },
            .workspace => &.{ "workspace", "audit" },
            .hardware => &.{ "hardware", "scan" },
            // A check, not an install: `nullclaw update [--check] [--yes]`,
            // and it takes no `--json`.
            .update => &.{ "update", "--check" },
            .service => &.{ "service", "status" },
            .doctor => &.{"doctor"},
        };
    }

    /// Whether the runtime documents `--json` for this page's command. The
    /// pages that do not get the runtime's prose shown instead — see
    /// view.jsonView's non-JSON branch. `contract.zig` checks this against the
    /// runtime's own usage text.
    pub fn takesJson(self: Page) bool {
        return switch (self) {
            .chat, .auth, .hardware, .update, .service => false,
            else => true,
        };
    }
};

/// The pages the sidebar lists, in order.
pub const nav = [_]Page{
    .chat,     .config,   .status, .capabilities, .models, .memory,
    .skills,   .channels, .cron,   .mcp,          .auth,   .workspace,
    .hardware, .service,  .update, .doctor,
};

/// Provider ids nullclaw's provider factory knows. Shown in the
/// configuration page's Provider select, in this order.
pub const prov_ids = [_][]const u8{
    "openrouter",
    "anthropic",
    "openai",
    "openai-codex",
    "ollama",
    "gemini",
    "deepseek",
    "xai",
    "together-ai",
    "fireworks",
    "moonshot",
    "zhipu",
    "minimax",
    "sglang",
};

/// Memory engines `src/memory/engines/registry.zig` registers. Shown in the
/// configuration page's Memory select, in the order the registry lists them.
pub const memory_backends = [_][]const u8{
    "hybrid",
    "sqlite",
    "markdown",
    "lucid",
    "memory",
    "redis",
    "lancedb",
    "api",
    "postgres",
    "clickhouse",
    "kg",
    "none",
};

/// What a finished command was for. One request struct is heap allocated per
/// command and freed when its result is folded in.
const Request = struct {
    state: *AppState,
    kind: Kind,

    const Kind = enum { sessions, transcript, invoke, page, config_load, config_save, config_summary };
};

/// The counts the configuration page shows for Capabilities, read from the
/// page that actually runs the command.
pub const CapsSummary = struct {
    channels_configured: usize,
    channels_total: usize,
    memory_active: usize,
    memory_total: usize,
    tools: usize,
};

pub const AppState = struct {
    gpa: std.mem.Allocator,
    io: Io,
    environ: *std.process.Environ.Map,
    paths: backend.Paths,
    /// The runtime to run: `$NULLCLAW_BIN`, or `nullclaw` off `PATH`.
    exe: []u8,
    executor: runtime.Executor,
    /// The runtime linked into this binary, built on first use. Null until
    /// then, and null again if it could not be built — a window with no
    /// config still opens, and the chat says why it cannot answer.
    linked: ?yc.runtime_builder.Runtime = null,
    /// Why `linked` is null, when it is.
    linked_error: ?[]u8 = null,
    /// Turns running against `linked`, one thread each.
    turns: runtime.Turns,

    /// The sidebar's rows.
    sessions: std.ArrayListUnmanaged(backend.Session) = .empty,
    selected: ?usize = null,
    /// The selected session's transcript, and each message's reply parsed for
    /// drawing. Parsing is cached here so a frame never re-reads markdown.
    messages: std.ArrayListUnmanaged(backend.Message) = .empty,
    docs: std.ArrayListUnmanaged(md.Doc) = .empty,
    sessions_running: bool = false,
    transcript_running: bool = false,

    /// What the user is typing.
    composer: ui.TextBuffer = .{},
    /// A turn is in flight.
    sending: bool = false,

    page: Page = .chat,

    /// The generic JSON page: the raw reply and its flattened lines.
    json_text: []u8 = &.{},
    json_lines: ?backend.JsonLines = null,
    /// The same answer read as list rows, for the pages that know what they
    /// asked for. Null when the page has no reader or the answer did not fit
    /// the shape, and the tree is drawn instead.
    rows: ?backend.Rows = null,
    json_expanded: std.StringHashMapUnmanaged(void) = .empty,
    json_running: bool = false,

    /// The configuration page.
    config: ?backend.ConfigDoc = null,
    config_running: bool = false,
    config_dirty: bool = false,
    /// The dotted path and value the quick-edit row holds.
    edit_path: ui.TextBuffer = .{},
    edit_value: ui.TextBuffer = .{},

    /// Common configuration form fields (kept in sync with the loaded document).
    /// Index into the provider options the select offers.
    cfg_default_provider: usize = 0,
    /// The provider ids the select offers: every id the runtime knows plus the
    /// one the config names when it is not in that list.
    cfg_provider_options: []const []const u8 = &.{},
    cfg_default_model: ui.TextBuffer = .{},
    cfg_api_key: ui.TextBuffer = .{},
    cfg_api_base_url: ui.TextBuffer = .{},
    cfg_gateway_host: ui.TextBuffer = .{},
    cfg_gateway_port: ui.TextBuffer = .{},
    cfg_gateway_allow_public_bind: bool = false,
    cfg_autonomy_level: ui.TextBuffer = .{},
    /// Memory: which engine stores turns, and whether it writes on its own.
    cfg_memory_backend: usize = 0,
    cfg_memory_auto_save: bool = true,
    /// Reliability: how many times a provider call is retried, and how long
    /// to wait between tries.
    cfg_retries: ui.TextBuffer = .{},
    cfg_backoff_ms: ui.TextBuffer = .{},
    /// Workspace: the directory the agent may read and write.
    cfg_workspace: ui.TextBuffer = .{},
    /// Cron: whether scheduled tasks run, and how often the scheduler ticks.
    cfg_cron_enabled: bool = false,
    cfg_cron_interval: ui.TextBuffer = .{},
    /// MCP: the servers the agent can call, one `name command` per line.
    cfg_mcp_servers: ui.TextBuffer = .{},
    show_advanced_config: bool = false,

    /// What the Skills and Capabilities pages last read, so the configuration
    /// page can summarise them without running the commands again. Null until
    /// those pages have been opened.
    skills_count: ?usize = null,
    caps_summary: ?CapsSummary = null,
    summary_running: bool = false,
    /// How many of the summary commands are still in flight.
    summary_pending: u8 = 0,

    /// Built-in runtime managed by the GUI.
    daemon: runtime.Daemon,
    daemon_auto_started: bool = false,

    /// The palette the window is drawn in, and whether the switcher is open.
    palette_index: usize = 0,
    palette: theme.Palette = theme.choices[0].palette,
    theme_menu_open: bool = false,
    /// The diagnostics panel the sidebar's footer opens.
    diagnostics_open: bool = false,

    /// The last thing that happened, shown for a few seconds.
    toast: []u8 = &.{},
    toast_shown_at: f64 = -1,

    /// The requests whose command has not come back yet. They are freed here
    /// on shutdown so a window closed mid-command leaks nothing.
    pending: std.ArrayListUnmanaged(*Request) = .empty,
    pub fn init(
        gpa: std.mem.Allocator,
        io: Io,
        environ: *std.process.Environ.Map,
    ) !AppState {
        var resolved = try backend.Paths.resolve(gpa, environ.*);
        errdefer resolved.deinit();
        const program = try backend.executable(gpa, io, environ.*);
        errdefer gpa.free(program);
        var self = AppState{
            .gpa = gpa,
            .io = io,
            .environ = environ,
            .paths = resolved,
            .exe = program,
            .executor = runtime.Executor.init(gpa, io, program),
            .turns = runtime.Turns.init(gpa),
            .daemon = runtime.Daemon.init(gpa, io, program),
        };
        self.loadTheme();
        // Auto-enable the bundled runtime on startup (best effort).
        self.ensureDaemonRunning();
        self.daemon_auto_started = true;
        return self;
    }

    pub fn deinit(self: *AppState) void {
        // Stop the managed runtime first so it doesn't outlive the GUI.
        self.daemon.stop();
        self.daemon.deinit();
        // Nothing can call a handler once the executor is down, so whatever is
        // still pending is ours to free.
        self.turns.deinit();
        if (self.linked) |*rt| rt.deinit();
        if (self.linked_error) |why| self.gpa.free(why);
        self.executor.deinit();
        for (self.pending.items) |req| self.gpa.destroy(req);
        self.pending.deinit(self.gpa);
        self.clearSessions();
        self.sessions.deinit(self.gpa);
        self.clearMessages();
        self.messages.deinit(self.gpa);
        self.docs.deinit(self.gpa);
        self.composer.deinit();
        self.edit_path.deinit();
        self.edit_value.deinit();
        self.cfg_default_model.deinit();
        self.cfg_api_key.deinit();
        self.cfg_api_base_url.deinit();
        self.cfg_gateway_host.deinit();
        self.cfg_gateway_port.deinit();
        self.cfg_autonomy_level.deinit();
        self.cfg_retries.deinit();
        self.cfg_backoff_ms.deinit();
        self.cfg_workspace.deinit();
        self.cfg_cron_interval.deinit();
        self.cfg_mcp_servers.deinit();
        self.clearJson();
        self.clearExpanded();
        self.json_expanded.deinit(self.gpa);
        if (self.config) |*c| c.deinit();
        self.gpa.free(self.toast);
        for (self.cfg_provider_options) |id| self.gpa.free(id);
        self.gpa.free(self.cfg_provider_options);
        self.gpa.free(self.exe);
        self.paths.deinit();
        self.* = undefined;
    }

    // ------------------------------------------------------------- lifecycle

    /// Folds finished commands in. Call once at the top of a frame.
    pub fn pump(self: *AppState) void {
        self.executor.pump();
        self.turns.pump(self, onTurnDone);
        // Keep the embedded runtime alive while the GUI is open.
        self.ensureDaemonRunning();
    }

    /// True while anything is in flight, so the view keeps asking for frames.
    /// True while a command is in flight. The managed gateway is not work:
    /// it runs for the whole session, so counting it made the header say
    /// "working…" forever.
    pub fn busy(self: *AppState) bool {
        return self.executor.busy() or self.turns.busy();
    }

    /// Builds the linked runtime on first use. A config that cannot carry a
    /// turn leaves `linked_error` set, and the chat reports it instead of
    /// pretending to be ready.
    fn ensureLinked(self: *AppState) ?*yc.runtime_builder.Runtime {
        if (self.linked) |*rt| return rt;
        if (self.linked_error != null) return null;
        self.linked = yc.runtime_builder.Runtime.init(self.gpa) catch |err| {
            self.linked_error = std.fmt.allocPrint(self.gpa, "{s}", .{@errorName(err)}) catch null;
            return null;
        };
        return &self.linked.?;
    }

    fn onTurnDone(self: *AppState, result: runtime.TurnResult) void {
        self.sending = false;
        if (result.failure) |err| {
            const text = std.fmt.allocPrint(self.gpa, "{s}", .{@errorName(err)}) catch return;
            defer self.gpa.free(text);
            self.pushMessage("error", text);
            self.say(text);
            return;
        }
        if (result.reply.len == 0) {
            self.say("the runtime answered with nothing");
            return;
        }
        self.pushMessage("assistant", result.reply);
    }

    fn ensureDaemonRunning(self: *AppState) void {
        if (self.daemon.running()) return;
        const host = self.configFormGatewayHost();
        const port = self.configFormGatewayPort();
        self.daemon.start(host, port) catch {};
    }

    pub fn restartDaemon(self: *AppState) void {
        self.daemon.stop();
        self.ensureDaemonRunning();
    }

    fn configFormGatewayHost(self: *AppState) []const u8 {
        const text = std.mem.trim(u8, self.cfg_gateway_host.text(), " \t\r\n");
        if (text.len > 0) return text;
        if (self.config) |*doc| {
            if (doc.get("gateway.host")) |v| if (v.len > 0) return v;
        }
        return "127.0.0.1";
    }

    fn configFormGatewayPort(self: *AppState) u16 {
        const text = std.mem.trim(u8, self.cfg_gateway_port.text(), " \t\r\n");
        if (text.len > 0) {
            if (std.fmt.parseInt(u16, text, 10)) |p| return p else |_| {}
        }
        if (self.config) |*doc| {
            if (doc.get("gateway.port")) |v| {
                if (std.fmt.parseInt(u16, v, 10)) |p| return p else |_| {}
            }
        }
        return 3000;
    }

    pub fn daemonStatusText(self: *AppState, a: std.mem.Allocator) []const u8 {
        return self.daemon.statusLabel(a);
    }

    fn submit(self: *AppState, argv: []const []const u8, label: []const u8, kind: Request.Kind) void {
        const req = self.gpa.create(Request) catch {
            self.say("out of memory");
            return;
        };
        req.* = .{ .state = self, .kind = kind };
        self.pending.append(self.gpa, req) catch {
            self.gpa.destroy(req);
            self.say("out of memory");
            return;
        };
        self.executor.submit(argv, label, runtime.Handler.of(req, onDone)) catch |err| {
            _ = self.pending.swapRemove(self.pending.items.len - 1);
            self.gpa.destroy(req);
            self.sayf("could not start {s}: {s}", .{ label, @errorName(err) });
        };
    }

    fn onDone(req: *Request, result: runtime.Result) void {
        const self = req.state;
        for (self.pending.items, 0..) |item, i| {
            if (item == req) {
                _ = self.pending.swapRemove(i);
                break;
            }
        }
        defer self.gpa.destroy(req);
        // `result` borrows the job's buffers, which are freed as soon as this
        // returns: every branch copies what it keeps.
        //
        // A runtime that could not be started still owes every kind its turn:
        // the config page reads a file, and must work when there is no runtime
        // to run at all. `blame` reports the spawn error in place of anything
        // the command would have said.
        switch (req.kind) {
            .sessions => self.gotSessions(result),
            .transcript => self.gotTranscript(result),
            .invoke => self.gotInvoke(result),
            .page => self.gotPage(result),
            .config_load => self.gotConfig(result),
            .config_save => self.gotConfigSaved(result),
            .config_summary => self.gotConfigSummary(result),
        }
    }

    // ---------------------------------------------------------------- toasts

    pub fn say(self: *AppState, text: []const u8) void {
        self.gpa.free(self.toast);
        self.toast = self.gpa.dupe(u8, text) catch &.{};
        self.toast_shown_at = -1;
    }

    pub fn sayf(self: *AppState, comptime fmt: []const u8, args: anytype) void {
        const text = std.fmt.allocPrint(self.gpa, fmt, args) catch return;
        defer self.gpa.free(text);
        self.say(text);
    }

    /// Called by the view: stamps the toast with the frame clock the first
    /// time it is drawn, so hiding it needs no wall clock.
    /// Reports a command that failed, taking the reason from the runtime's
    /// own error envelope when it printed one. `diagnose` allocates, so the
    /// text is copied into the toast before it is freed.
    /// The best explanation available for a failed command, as a string the
    /// caller owns; null only when there is no memory for one.
    fn reason(self: *AppState, result: runtime.Result) ?[]u8 {
        // A runtime that never started has nothing on stderr: the spawn error
        // is the whole story, and a far more useful one than a generic line.
        if (result.spawn_error) |err| {
            return std.fmt.allocPrint(self.gpa, "{s}: {s}", .{ result.label, @errorName(err) }) catch null;
        }
        const why = backend.diagnose(self.gpa, result.stdout, result.stderr);
        defer if (why) |text| self.gpa.free(text);
        return self.gpa.dupe(u8, why orelse "the runtime's command failed") catch null;
    }

    fn blame(self: *AppState, result: runtime.Result) void {
        const text = self.reason(result) orelse return;
        defer self.gpa.free(text);
        self.say(text);
    }
    pub fn toastVisible(self: *AppState, now: f64) bool {
        if (self.toast.len == 0) return false;
        if (self.toast_shown_at < 0) self.toast_shown_at = now;
        return now - self.toast_shown_at < 6.0;
    }

    pub fn dismissToast(self: *AppState) void {
        self.gpa.free(self.toast);
        self.toast = &.{};
        self.toast_shown_at = -1;
    }

    // -------------------------------------------------------------- sessions

    pub fn refreshSessions(self: *AppState) void {
        if (self.sessions_running) return;
        var argv: std.ArrayListUnmanaged([]const u8) = .empty;
        defer argv.deinit(self.gpa);
        backend.argvSessionList(self.gpa, &argv) catch return;
        self.sessions_running = true;
        self.submit(argv.items, "sessions", .sessions);
    }

    fn gotSessions(self: *AppState, result: runtime.Result) void {
        self.sessions_running = false;
        if (!result.ok) {
            self.blame(result);
            return;
        }
        const parsed = backend.parseSessions(self.gpa, result.stdout) catch {
            self.say("the runtime's session list could not be read");
            return;
        };
        const keep = if (self.selected) |i| self.sessions.items[i].key else null;
        var keep_owned: ?[]u8 = null;
        if (keep) |k| keep_owned = self.gpa.dupe(u8, k) catch null;
        defer if (keep_owned) |k| self.gpa.free(k);

        // The old list is freed before the new one takes its place: the array
        // comes from `toOwnedSlice`, so it owns itself and its rows own their
        // strings.
        self.clearSessions();
        self.sessions.deinit(self.gpa);
        self.sessions = backend.sessionsToList(parsed);
        self.selected = null;
        if (keep_owned) |k| {
            for (self.sessions.items, 0..) |*s, i| {
                if (std.mem.eql(u8, s.key, k)) {
                    self.selected = i;
                    break;
                }
            }
        }
        if (self.selected == null and self.sessions.items.len > 0) self.select(0);
    }

    fn clearSessions(self: *AppState) void {
        for (self.sessions.items) |*s| s.deinit(self.gpa);
        self.sessions.clearRetainingCapacity();
    }

    pub fn select(self: *AppState, index: usize) void {
        if (index >= self.sessions.items.len) return;
        self.selected = index;
        self.loadTranscript(self.sessions.items[index].key);
    }

    fn loadTranscript(self: *AppState, key: []const u8) void {
        if (self.transcript_running) return;
        var argv: std.ArrayListUnmanaged([]const u8) = .empty;
        defer argv.deinit(self.gpa);
        backend.argvHistoryShow(self.gpa, &argv, key, 200, "200") catch return;
        self.transcript_running = true;
        self.submit(argv.items, "history show", .transcript);
    }

    fn gotTranscript(self: *AppState, result: runtime.Result) void {
        self.transcript_running = false;
        if (!result.ok) {
            self.blame(result);
            return;
        }
        const parsed = backend.parseMessages(self.gpa, result.stdout) catch {
            self.say("the transcript could not be read");
            return;
        };
        self.clearMessages();
        self.messages.deinit(self.gpa);
        self.messages = backend.messagesToList(parsed);
        for (self.messages.items) |m| {
            var doc = md.parse(self.gpa, m.content) catch md.Doc{ .arena = std.heap.ArenaAllocator.init(self.gpa) };
            self.docs.append(self.gpa, doc) catch {
                doc.deinit();
            };
        }
    }

    fn clearMessages(self: *AppState) void {
        for (self.messages.items) |*m| m.deinit(self.gpa);
        self.messages.clearRetainingCapacity();
        for (self.docs.items) |*d| d.deinit();
        self.docs.clearRetainingCapacity();
    }

    /// Appends a turn and parses it for the view. Every message has exactly
    /// one doc, so `docs` and `messages` are indexed alike.
    pub fn pushMessage(self: *AppState, role: []const u8, content: []const u8) void {
        const owned_role = self.gpa.dupe(u8, role) catch return;
        errdefer self.gpa.free(owned_role);
        const owned_text = self.gpa.dupe(u8, content) catch return;
        errdefer self.gpa.free(owned_text);
        var doc = md.parse(self.gpa, owned_text) catch md.Doc{ .arena = std.heap.ArenaAllocator.init(self.gpa) };
        errdefer doc.deinit();
        self.messages.append(self.gpa, .{
            .role = owned_role,
            .content = owned_text,
            .created_at = &.{},
        }) catch return;
        self.docs.append(self.gpa, doc) catch {
            _ = self.messages.pop();
            self.gpa.free(owned_role);
            self.gpa.free(owned_text);
            return;
        };
    }

    // --------------------------------------------------------------- sending

    /// Sends what the composer holds to the runtime and appends the answer.
    /// A new session is created by the runtime when none is selected, which is
    /// what the "New chat" button relies on.
    /// Runs one turn against the linked runtime. The turn is a function call,
    /// not a subprocess: the window carries the runtime, so there is no
    /// program to find and no JSON to parse back.
    pub fn send(self: *AppState) void {
        const text = std.mem.trim(u8, self.composer.text(), " \t\r\n");
        if (text.len == 0 or self.sending) return;

        const session: ?[]const u8 = if (self.selected) |i|
            (if (i < self.sessions.items.len) self.sessions.items[i].key else null)
        else
            null;

        // What the person typed is theirs, and it is shown before anything can
        // fail: a turn that cannot start must not swallow the message.
        self.pushMessage("user", text);
        self.composer.clear();

        const rt = self.ensureLinked() orelse {
            const why = self.linked_error orelse "the runtime could not be built";
            self.pushMessage("error", why);
            self.sayf("no runtime: {s}", .{why});
            return;
        };

        self.sending = true;
        self.turns.start(rt, text, session) catch |err| {
            self.sending = false;
            const why = std.fmt.allocPrint(self.gpa, "could not start the turn: {s}", .{@errorName(err)}) catch return;
            defer self.gpa.free(why);
            self.pushMessage("error", why);
        };
    }

    pub fn newChat(self: *AppState) void {
        self.selected = null;
        self.clearMessages();
        self.composer.clear();
        self.page = .chat;
    }

    fn gotInvoke(self: *AppState, result: runtime.Result) void {
        self.sending = false;
        if (!result.ok) {
            const text = self.reason(result) orelse return;
            defer self.gpa.free(text);
            self.pushMessage("error", text);
            self.say(text);
            return;
        }
        const reply = backend.parseInvoke(self.gpa, result.stdout) catch {
            self.say("the runtime's reply could not be read");
            return;
        };
        defer reply.deinit(self.gpa);
        self.pushMessage("assistant", reply.response);
        // A turn can create the session it ran in: pick it up in the sidebar.
        self.refreshSessions();
    }

    // ----------------------------------------------------------- json pages

    pub fn openPage(self: *AppState, page: Page) void {
        self.page = page;
        // A toast belongs to the page that produced it: a configuration
        // error would otherwise linger for six seconds on every page the
        // user opens after it.
        self.dismissToast();
        switch (page) {
            .chat => {},
            .config => self.loadConfig(),
            else => self.runPage(),
        }
    }

    pub fn runPage(self: *AppState) void {
        if (self.json_running) return;

        // A page whose answer the runtime can produce as a function is asked
        // directly: no program to find, no stdout to parse. The rest still go
        // through the CLI, which is where their answers are built.
        if (self.answerInProcess()) |text| {
            defer self.gpa.free(text);
            self.setJson(text);
            return;
        }

        const words = self.page.command() orelse return;
        var argv: std.ArrayListUnmanaged([]const u8) = .empty;
        defer argv.deinit(self.gpa);
        backend.argvCommand(self.gpa, &argv, words, self.page.takesJson()) catch return;
        self.json_running = true;
        self.submit(argv.items, self.page.label(), .page);
    }

    /// Builds a page's answer from the linked runtime, for the pages whose
    /// JSON the runtime already exposes as a function. Null when this page
    /// has no such function, and the caller falls back to the CLI.
    fn answerInProcess(self: *AppState) ?[]u8 {
        // The pages that read the config load it here rather than borrowing
        // the runtime's: opening a page must not build a runtime, and a
        // window that has never run a turn still has a config on disk.
        return switch (self.page) {
            .capabilities, .models, .memory, .mcp, .skills, .channels => blk: {
                var cfg = yc.config.Config.load(self.gpa) catch break :blk null;
                defer cfg.deinit();
                break :blk switch (self.page) {
                    // Capabilities lists what the build has even without a
                    // config; with one it also says what the config turns on.
                    .capabilities => yc.capabilities.buildManifestJson(self.gpa, &cfg, null) catch null,
                    .models => yc.page_json.modelsSummary(self.gpa, &cfg) catch null,
                    .memory => (yc.page_json.memoryStats(self.gpa, &cfg) catch null) orelse null,
                    .mcp => yc.mcp_admin.buildServersJson(self.gpa, cfg.mcp_servers) catch null,
                    .skills => yc.page_json.skillsList(self.gpa, &cfg) catch null,
                    .channels => yc.page_json.channelList(self.gpa, &cfg) catch null,
                    else => unreachable,
                };
            },
            .status => yc.status.buildRuntimeStatusJson(self.gpa) catch null,
            .doctor => yc.doctor.buildDoctorJson(self.gpa) catch null,
            // Cron reads the jobs off disk, so it needs no config either.
            .cron => yc.page_json.cronList(self.gpa) catch null,
            else => null,
        };
    }

    fn gotPage(self: *AppState, result: runtime.Result) void {
        self.json_running = false;
        if (!result.ok) {
            // A command that failed printed its complaint on stderr, so there
            // are no rows to show. The complaint itself is what the page must
            // keep: a toast lasts six seconds, and "the runtime said nothing"
            // beside a real error message is the window losing the only useful
            // thing it was told.
            const why = self.reason(result) orelse "the runtime's command failed";
            defer self.gpa.free(why);
            // No toast: the page keeps the message now, and saying it twice —
            // once in a card that stays, once in a banner that expires — is
            // noise. A toast is for what the page cannot show.
            self.setJsonProblem(why);
            return;
        }
        self.setJson(result.stdout);
    }

    /// Shows `why` in the page's panel instead of a tree: the command ran and
    /// failed, and its own words are the content.
    pub fn setJsonProblem(self: *AppState, why: []const u8) void {
        self.clearJson();
        self.clearExpanded();
        self.json_text = self.gpa.dupe(u8, why) catch &.{};
        var lines = backend.JsonLines{
            .gpa = self.gpa,
            .expanded = &self.json_expanded,
            .arena = std.heap.ArenaAllocator.init(self.gpa),
        };
        lines.problem = "the runtime's command failed";
        self.json_lines = lines;
    }

    pub fn setJson(self: *AppState, text: []const u8) void {
        self.clearJson();
        self.json_text = self.gpa.dupe(u8, text) catch &.{};
        self.clearExpanded();
        self.rebuildJson();
        self.rebuildRows();
    }

    /// The counts the configuration page shows, taken from the groups the
    /// Capabilities page built.
    fn summariseCaps(rows: *const backend.Rows) CapsSummary {
        var out = CapsSummary{
            .channels_configured = 0,
            .channels_total = 0,
            .memory_active = 0,
            .memory_total = 0,
            .tools = 0,
        };
        for (rows.groups.items) |g| {
            if (std.mem.eql(u8, g.title, "Channels")) {
                out.channels_total = g.rows.items.len;
                for (g.rows.items) |r| {
                    if (r.state == .on) out.channels_configured += 1;
                }
            } else if (std.mem.eql(u8, g.title, "Memory engines")) {
                out.memory_total = g.rows.items.len;
                for (g.rows.items) |r| {
                    if (r.state == .on) out.memory_active += 1;
                }
            } else if (std.mem.eql(u8, g.title, "Tools")) {
                out.tools = g.rows.items.len;
            }
        }
        return out;
    }

    /// Reads the answer as list rows when the page has a reader for it. A
    /// reader that cannot make sense of the document leaves `problem` set and
    /// the page falls back to the tree, so nothing is lost.
    fn rebuildRows(self: *AppState) void {
        if (self.rows) |*r| r.deinit();
        self.rows = null;
        const text = self.json_text;
        if (text.len == 0) return;
        const built = switch (self.page) {
            .capabilities => backend.readCapabilities(self.gpa, text),
            .models => backend.readModels(self.gpa, text),
            .memory => backend.readMemoryStats(self.gpa, text),
            .skills => backend.readRecordList(self.gpa, text, "Skills"),
            .channels => backend.readRecordList(self.gpa, text, "Channels"),
            .cron => backend.readRecordList(self.gpa, text, "Scheduled tasks"),
            .mcp => backend.readRecordList(self.gpa, text, "MCP servers"),
            else => return,
        };
        // A reader that could not read the document falls back to the tree.
        // A reader that read it and found nothing keeps the empty list: "no
        // skills installed" is an answer, and a tree of `[` `]` is not.
        if (built.problem != null) {
            var dropped = built;
            dropped.deinit();
            return;
        }
        // The configuration page summarises these two, so what this page just
        // read is kept for it rather than run again.
        switch (self.page) {
            .skills => self.skills_count = built.totalRows(),
            .capabilities => self.caps_summary = summariseCaps(&built),
            else => {},
        }
        self.rows = built;
    }

    /// Drops every open path. The map owns its key strings — `togglePath` and
    /// `expandAll` dupe each one — so clearing the entries is not enough; each
    /// key has to be freed first, or every path ever opened leaks.
    fn clearExpanded(self: *AppState) void {
        var it = self.json_expanded.keyIterator();
        while (it.next()) |key| self.gpa.free(key.*);
        self.json_expanded.clearRetainingCapacity();
    }

    fn rebuildJson(self: *AppState) void {
        if (self.json_lines) |*l| l.deinit();
        self.json_lines = backend.JsonLines.build(self.gpa, self.json_text, &self.json_expanded);
        if (self.json_lines.?.problem) |why| self.say(why);
    }

    fn clearJson(self: *AppState) void {
        self.gpa.free(self.json_text);
        self.json_text = &.{};
        if (self.json_lines) |*l| l.deinit();
        self.json_lines = null;
        if (self.rows) |*r| r.deinit();
        self.rows = null;
    }

    /// Opens or closes a node the viewer drew as a summary line.
    pub fn togglePath(self: *AppState, path: []const u8) void {
        // `fetchRemove` hands back the stored key, which this side owns; the
        // `path` the caller passed points into the line list, not into the map.
        if (self.json_expanded.fetchRemove(path)) |entry| {
            self.gpa.free(entry.key);
        } else {
            const owned = self.gpa.dupe(u8, path) catch return;
            self.json_expanded.put(self.gpa, owned, {}) catch {
                self.gpa.free(owned);
                return;
            };
        }
        self.rebuildJson();
    }

    pub fn expandAll(self: *AppState) void {
        const keys = backend.topLevelKeys(self.gpa, self.json_text);
        defer backend.freeTopLevelKeys(self.gpa, keys);
        for (keys) |k| {
            if (self.json_expanded.contains(k)) continue;
            const owned = self.gpa.dupe(u8, k) catch return;
            self.json_expanded.put(self.gpa, owned, {}) catch self.gpa.free(owned);
        }
        self.rebuildJson();
    }

    pub fn collapseAll(self: *AppState) void {
        self.clearExpanded();
        self.rebuildJson();
    }

    // ---------------------------------------------------------------- config

    pub fn loadConfig(self: *AppState) void {
        if (self.config_running) return;
        self.config_running = true;
        self.submit(&.{ "config", "validate" }, "config", .config_load);
    }

    fn gotConfig(self: *AppState, result: runtime.Result) void {
        self.config_running = false;
        if (self.config) |*c| {
            c.deinit();
            self.config = null;
        }
        self.config = backend.ConfigDoc.load(self.gpa, self.io, self.paths.config) catch |err| {
            if (err == error.FileNotFound) {
                self.sayf("no config yet at {s} -- run `nullclaw onboard`", .{self.paths.config});
            } else {
                self.sayf("could not read {s}: {s}", .{ self.paths.config, @errorName(err) });
            }
            return;
        };
        self.config_dirty = false;
        self.syncFormFromConfig();
        // The page edits the file itself, so the tree is drawn from the
        // document just read rather than from `config validate`'s output:
        // that view is merged, and saving it would drop the defaults it added.
        self.showConfigDoc();
        if (!result.ok) self.blame(result);
        self.loadConfigSummary();
    }

    /// Reads the two things the configuration page only summarises: the
    /// installed skills and the build's capabilities. Both are runtime state
    /// rather than config keys, so the page asks rather than reading the file.
    fn loadConfigSummary(self: *AppState) void {
        if (self.summary_running) return;
        self.summary_running = true;
        self.summary_pending = 2;
        self.submit(&.{ "capabilities", "--json" }, "capabilities", .config_summary);
        self.submit(&.{ "skills", "list", "--json" }, "skills", .config_summary);
    }

    fn gotConfigSummary(self: *AppState, result: runtime.Result) void {
        // Two commands answer into this one kind; the flag clears when both
        // are in, so a third open does not queue behind a half-finished pair.
        if (self.summary_pending > 0) self.summary_pending -= 1;
        if (self.summary_pending == 0) self.summary_running = false;
        if (!result.ok) return;

        // Which command this is, by what it returned: capabilities has
        // `channels`, skills is a bare list.
        var rows = if (std.mem.indexOf(u8, result.stdout, "\"channels\"") != null)
            backend.readCapabilities(self.gpa, result.stdout)
        else
            backend.readRecordList(self.gpa, result.stdout, "Skills");
        defer rows.deinit();
        if (rows.problem != null) return;

        if (std.mem.indexOf(u8, result.stdout, "\"channels\"") != null) {
            self.caps_summary = summariseCaps(&rows);
        } else {
            self.skills_count = rows.totalRows();
        }
    }

    fn setBuf(buf: *ui.TextBuffer, text: []const u8) void {
        buf.set(text);
    }

    /// Builds the option list the provider select shows: every id the runtime
    /// knows plus the one the config names, when that one is not in the list.
    fn buildProviderOptions(self: *AppState, config_provider: []const u8) ![]const []const u8 {
        const in_known = blk: {
            for (prov_ids) |id| {
                if (std.mem.eql(u8, id, config_provider)) break :blk true;
            }
            break :blk false;
        };
        const extra = if (config_provider.len > 0 and
            !in_known) config_provider else null;
        // Every entry is copied: the known ids are static literals, so the
        // free in deinit is only valid on memory the form owns.
        const count = @as(usize, prov_ids.len) + @as(usize, @intFromBool(extra != null));
        const all = try self.gpa.alloc([]const u8, count);
        errdefer self.gpa.free(all);
        var at: usize = 0;
        for (prov_ids) |id| {
            all[at] = try self.gpa.dupe(u8, id);
            at += 1;
        }
        if (extra) |id| {
            all[at] = try self.gpa.dupe(u8, id);
            at += 1;
        }
        return all[0..at];
    }

    /// The provider id the select is holding.
    fn providerName(self: *const AppState) []const u8 {
        if (self.cfg_default_provider >= self.cfg_provider_options.len) return "";
        return self.cfg_provider_options[self.cfg_default_provider];
    }

    fn syncFormFromConfig(self: *AppState) void {
        const doc = if (self.config) |*c| c else return;
        // The runtime wants the default model as "provider/model" under
        // agents.defaults.model.primary; the form splits that into the
        // provider pick and the model text so each is edited on its own.
        //
        // Only the nested form is read. A config that still carries the
        // retired top-level `default_provider` / `default_model` pair is
        // rejected by the runtime itself (src/config.zig: "top-level
        // default_provider is not supported"), so filling the form from it
        // would hide a config that cannot load. `legacyConfigKeys` reports it
        // instead, and the page offers the migration.
        const primary = doc.get("agents.defaults.model.primary") orelse "";
        var default_provider: []const u8 = "";
        var default_model: []const u8 = primary;
        if (std.mem.indexOfScalar(u8, primary, '/')) |slash| {
            default_provider = primary[0..slash];
            default_model = primary[slash + 1 ..];
        }
        setBuf(&self.cfg_default_model, default_model);

        // The provider field is a select, so it holds an index. An id the
        // known list lacks is kept in the options, so the index can still
        // point at it.
        const options = self.buildProviderOptions(default_provider) catch {
            // Without room for the list, the select simply shows the known
            // ids; the config keeps its own value.
            for (self.cfg_provider_options) |id| self.gpa.free(id);
            self.gpa.free(self.cfg_provider_options);
            self.cfg_provider_options = &.{};
            self.cfg_default_provider = 0;
            return;
        };
        for (self.cfg_provider_options) |id| self.gpa.free(id);
        self.gpa.free(self.cfg_provider_options);
        self.cfg_provider_options = options;
        self.cfg_default_provider = if (default_provider.len == 0) 0 else blk: {
            var found: usize = 0;
            var at = false;
            for (options, 0..) |opt, i| {
                if (std.mem.eql(u8, opt, default_provider)) {
                    found = i;
                    at = true;
                    break;
                }
            }
            break :blk if (at) found else 0;
        };

        const provider_key = if (default_provider.len > 0) default_provider else "openrouter";
        var key_path_buf: [256]u8 = undefined;
        var base_path_buf: [256]u8 = undefined;
        const key_path = std.fmt.bufPrint(&key_path_buf, "models.providers.{s}.api_key", .{provider_key}) catch "models.providers.openrouter.api_key";
        const base_path = std.fmt.bufPrint(&base_path_buf, "models.providers.{s}.base_url", .{provider_key}) catch "models.providers.openrouter.base_url";
        setBuf(&self.cfg_api_key, doc.get(key_path) orelse "");
        setBuf(&self.cfg_api_base_url, doc.get(base_path) orelse "");

        setBuf(&self.cfg_gateway_host, doc.get("gateway.host") orelse "127.0.0.1");
        setBuf(&self.cfg_gateway_port, doc.get("gateway.port") orelse "3000");
        self.cfg_gateway_allow_public_bind = blk: {
            const v = doc.get("gateway.allow_public_bind") orelse "false";
            break :blk std.ascii.eqlIgnoreCase(v, "true");
        };
        setBuf(&self.cfg_autonomy_level, doc.get("autonomy.level") orelse doc.get("autonomy") orelse "supervised");

        // Memory: an engine the registry does not know leaves the select on
        // its first entry rather than inventing an index.
        const engine = doc.get("memory.backend") orelse "hybrid";
        self.cfg_memory_backend = blk: {
            for (memory_backends, 0..) |name, i| {
                if (std.mem.eql(u8, name, engine)) break :blk i;
            }
            break :blk 0;
        };
        self.cfg_memory_auto_save = std.ascii.eqlIgnoreCase(doc.get("memory.auto_save") orelse "true", "true");

        setBuf(&self.cfg_retries, doc.get("reliability.provider_retries") orelse "2");
        setBuf(&self.cfg_backoff_ms, doc.get("reliability.provider_backoff_ms") orelse "500");

        setBuf(&self.cfg_workspace, doc.get("workspace") orelse self.paths.workspace);
        self.cfg_cron_enabled = std.ascii.eqlIgnoreCase(doc.get("cron.enabled") orelse "false", "true");
        setBuf(&self.cfg_cron_interval, doc.get("cron.interval_minutes") orelse "30");
        self.syncMcpFromConfig(doc);
    }

    /// MCP servers are objects, not a string, so the form shows them one per
    /// line as `name command` and reads them back the same way.
    fn syncMcpFromConfig(self: *AppState, doc: *backend.ConfigDoc) void {
        const servers = doc.objectAt("mcp_servers") orelse {
            self.cfg_mcp_servers.clear();
            return;
        };
        var buf: std.ArrayListUnmanaged(u8) = .empty;
        defer buf.deinit(self.gpa);
        var it = servers.iterator();
        while (it.next()) |entry| {
            const rec = switch (entry.value_ptr.*) {
                .object => |o| o,
                else => continue,
            };
            const command = switch (rec.get("command") orelse continue) {
                .string => |v| v,
                else => continue,
            };
            if (buf.items.len > 0) buf.append(self.gpa, '\n') catch return;
            buf.appendSlice(self.gpa, entry.key_ptr.*) catch return;
            buf.append(self.gpa, ' ') catch return;
            buf.appendSlice(self.gpa, command) catch return;
        }
        self.cfg_mcp_servers.set(buf.items);
    }

    /// Applies the common config form fields into the loaded document.
    pub fn applyConfigForm(self: *AppState) void {
        const doc = if (self.config) |*c| c else {
            self.say("load configuration first");
            return;
        };
        const provider = self.providerName();
        const model = std.mem.trim(u8, self.cfg_default_model.text(), " \t\r\n");
        const api_key = std.mem.trim(u8, self.cfg_api_key.text(), " \t\r\n");
        const base_url = std.mem.trim(u8, self.cfg_api_base_url.text(), " \t\r\n");
        const gw_host = std.mem.trim(u8, self.cfg_gateway_host.text(), " \t\r\n");
        const gw_port = std.mem.trim(u8, self.cfg_gateway_port.text(), " \t\r\n");
        const autonomy = std.mem.trim(u8, self.cfg_autonomy_level.text(), " \t\r\n");

        var changed = false;
        // Combine the provider pick and the model text into the "provider/model"
        // form the runtime reads from agents.defaults.model.primary.
        if (model.len > 0) {
            const combined = if (provider.len > 0)
                std.fmt.allocPrint(self.gpa, "{s}/{s}", .{ provider, model }) catch null
            else
                self.gpa.dupe(u8, model) catch null;
            if (combined) |text| {
                defer self.gpa.free(text);
                doc.setString("agents.defaults.model.primary", text) catch {};
                changed = true;
            }
        }
        const provider_key = if (provider.len > 0) provider else "openrouter";
        if (provider_key.len > 0) {
            var key_path_buf: [256]u8 = undefined;
            const key_path = std.fmt.bufPrint(&key_path_buf, "models.providers.{s}.api_key", .{provider_key}) catch null;
            if (key_path) |p| {
                if (api_key.len > 0) {
                    doc.setString(p, api_key) catch {};
                } else {
                    // empty means remove? keep as-is by not overwriting; user can clear via JSON
                }
            }
            var base_path_buf: [256]u8 = undefined;
            const base_path = std.fmt.bufPrint(&base_path_buf, "models.providers.{s}.base_url", .{provider_key}) catch null;
            if (base_path) |p| {
                if (base_url.len > 0) {
                    doc.setString(p, base_url) catch {};
                }
            }
        }
        if (gw_host.len > 0) {
            doc.setString("gateway.host", gw_host) catch {};
            changed = true;
        }
        if (gw_port.len > 0) {
            doc.setAuto("gateway.port", gw_port) catch {};
            changed = true;
        }
        const public_bind_now = std.ascii.eqlIgnoreCase(doc.get("gateway.allow_public_bind") orelse "false", "true");
        if (public_bind_now != self.cfg_gateway_allow_public_bind) {
            doc.setBool("gateway.allow_public_bind", self.cfg_gateway_allow_public_bind) catch {};
            changed = true;
        }
        if (autonomy.len > 0) {
            doc.setString("autonomy.level", autonomy) catch {};
            changed = true;
        }
        changed = self.applyMemoryAndReliability(doc) or changed;
        if (changed) self.config_dirty = true;
        self.showConfigDoc();
        self.say("form changes applied in memory -- Save writes them");
        // No restart here: the edits live only in the in-memory document, so
        // a restarted gateway would just re-read the unchanged file on disk.
        // saveConfig() restarts once the file has actually been written.
    }

    /// Renders the loaded document into the JSON tree. Without this the config
    /// page draws its toolbar over an empty pane: nothing else ever fills
    /// `json_lines` for that page.
    fn showConfigDoc(self: *AppState) void {
        const doc = if (self.config) |*c| c else return;
        const text = doc.render(self.gpa) catch |err| {
            self.sayf("could not render {s}: {s}", .{ self.paths.config, @errorName(err) });
            return;
        };
        defer self.gpa.free(text);
        self.setJson(text);
    }

    /// Writes the loaded document back, so the config page's edits survive.
    pub fn saveConfig(self: *AppState) void {
        const doc = if (self.config) |*c| c else return;
        if (self.config_running) return;
        // Persist any pending form edits before saving.
        self.applyConfigFormQuiet(doc);
        doc.save(self.io, self.paths.config) catch |err| {
            self.sayf("could not write {s}: {s}", .{ self.paths.config, @errorName(err) });
            return;
        };
        self.config_dirty = false;
        self.say("configuration saved");
        // The runtime validates the file it will actually read.
        self.config_running = true;
        self.submit(&.{ "config", "validate" }, "config validate", .config_save);
        // Restart managed runtime to pick up saved config/gateway settings.
        self.restartDaemon();
    }

    fn applyConfigFormQuiet(self: *AppState, doc: *backend.ConfigDoc) void {
        const provider = self.providerName();
        const model = std.mem.trim(u8, self.cfg_default_model.text(), " \t\r\n");
        const api_key = std.mem.trim(u8, self.cfg_api_key.text(), " \t\r\n");
        const base_url = std.mem.trim(u8, self.cfg_api_base_url.text(), " \t\r\n");
        const gw_host = std.mem.trim(u8, self.cfg_gateway_host.text(), " \t\r\n");
        const gw_port = std.mem.trim(u8, self.cfg_gateway_port.text(), " \t\r\n");
        const autonomy = std.mem.trim(u8, self.cfg_autonomy_level.text(), " \t\r\n");

        if (model.len > 0) {
            const combined = if (provider.len > 0)
                std.fmt.allocPrint(self.gpa, "{s}/{s}", .{ provider, model }) catch null
            else
                self.gpa.dupe(u8, model) catch null;
            if (combined) |text| {
                defer self.gpa.free(text);
                doc.setString("agents.defaults.model.primary", text) catch {};
            }
        }
        const provider_key = if (provider.len > 0) provider else "openrouter";
        var key_path_buf: [256]u8 = undefined;
        if (std.fmt.bufPrint(&key_path_buf, "models.providers.{s}.api_key", .{provider_key})) |p| {
            if (api_key.len > 0) doc.setString(p, api_key) catch {};
        } else |_| {}
        var base_path_buf: [256]u8 = undefined;
        if (std.fmt.bufPrint(&base_path_buf, "models.providers.{s}.base_url", .{provider_key})) |p| {
            if (base_url.len > 0) doc.setString(p, base_url) catch {};
        } else |_| {}
        if (gw_host.len > 0) doc.setString("gateway.host", gw_host) catch {};
        if (gw_port.len > 0) doc.setAuto("gateway.port", gw_port) catch {};
        doc.setBool("gateway.allow_public_bind", self.cfg_gateway_allow_public_bind) catch {};
        if (autonomy.len > 0) doc.setString("autonomy.level", autonomy) catch {};
        _ = self.applyMemoryAndReliability(doc);
        self.showConfigDoc();
    }

    /// Writes the Memory and Reliability fields, reporting whether anything
    /// actually changed so a no-op Apply does not mark the file dirty.
    fn applyMemoryAndReliability(self: *AppState, doc: *backend.ConfigDoc) bool {
        var changed = false;

        const backend_name = if (self.cfg_memory_backend < memory_backends.len)
            memory_backends[self.cfg_memory_backend]
        else
            "hybrid";
        const backend_now = doc.get("memory.backend") orelse "hybrid";
        if (!std.mem.eql(u8, backend_now, backend_name)) {
            doc.setString("memory.backend", backend_name) catch {};
            changed = true;
        }
        const auto_save_now = std.ascii.eqlIgnoreCase(doc.get("memory.auto_save") orelse "true", "true");
        if (auto_save_now != self.cfg_memory_auto_save) {
            doc.setBool("memory.auto_save", self.cfg_memory_auto_save) catch {};
            changed = true;
        }

        // Numbers, so `setAuto` types them; an empty field keeps the file's.
        const retries = std.mem.trim(u8, self.cfg_retries.text(), " \t\r\n");
        if (retries.len > 0) {
            const now = doc.get("reliability.provider_retries") orelse "";
            if (!std.mem.eql(u8, now, retries)) {
                doc.setAuto("reliability.provider_retries", retries) catch {};
                changed = true;
            }
        }
        const backoff = std.mem.trim(u8, self.cfg_backoff_ms.text(), " \t\r\n");
        if (backoff.len > 0) {
            const now = doc.get("reliability.provider_backoff_ms") orelse "";
            if (!std.mem.eql(u8, now, backoff)) {
                doc.setAuto("reliability.provider_backoff_ms", backoff) catch {};
                changed = true;
            }
        }

        // Workspace: a path the agent may read and write.
        const workspace = std.mem.trim(u8, self.cfg_workspace.text(), " \t\r\n");
        if (workspace.len > 0) {
            const now = doc.get("workspace") orelse "";
            if (!std.mem.eql(u8, now, workspace)) {
                doc.setString("workspace", workspace) catch {};
                changed = true;
            }
        }

        // Cron: on or off, and how often the scheduler wakes.
        const cron_now = std.ascii.eqlIgnoreCase(doc.get("cron.enabled") orelse "false", "true");
        if (cron_now != self.cfg_cron_enabled) {
            doc.setBool("cron.enabled", self.cfg_cron_enabled) catch {};
            changed = true;
        }
        const interval = std.mem.trim(u8, self.cfg_cron_interval.text(), " \t\r\n");
        if (interval.len > 0) {
            const now = doc.get("cron.interval_minutes") orelse "";
            if (!std.mem.eql(u8, now, interval)) {
                doc.setAuto("cron.interval_minutes", interval) catch {};
                changed = true;
            }
        }

        changed = self.applyMcpServers(doc) or changed;
        return changed;
    }

    /// Writes the MCP list back as `mcp_servers` objects. A line is
    /// `name command`; a server already in the file keeps its other keys
    /// (transport, args, env), so editing the list does not drop them.
    fn applyMcpServers(self: *AppState, doc: *backend.ConfigDoc) bool {
        const text = std.mem.trim(u8, self.cfg_mcp_servers.text(), " \t\r\n");
        const existing = doc.objectAt("mcp_servers");
        const before = if (existing) |o| o.count() else 0;

        var parsed: usize = 0;
        var it = std.mem.splitScalar(u8, text, '\n');
        while (it.next()) |raw| {
            const line = std.mem.trim(u8, raw, " \t\r");
            if (line.len == 0) continue;
            const space = std.mem.indexOfScalar(u8, line, ' ') orelse continue;
            const name = std.mem.trim(u8, line[0..space], " \t");
            const command = std.mem.trim(u8, line[space + 1 ..], " \t");
            if (name.len == 0 or command.len == 0) continue;
            parsed += 1;

            var path_buf: [256]u8 = undefined;
            const cmd_path = std.fmt.bufPrint(&path_buf, "mcp_servers.{s}.command", .{name}) catch continue;
            const now = doc.get(cmd_path);
            if (now) |v| {
                if (std.mem.eql(u8, v, command)) continue;
            }
            doc.setString(cmd_path, command) catch continue;
            // A new server needs a transport; the runtime defaults to stdio.
            var t_buf: [256]u8 = undefined;
            const transport_path = std.fmt.bufPrint(&t_buf, "mcp_servers.{s}.transport", .{name}) catch continue;
            if (doc.get(transport_path) == null) {
                doc.setString(transport_path, "stdio") catch {};
            }
        }
        // A list that shrank is a change even when no line was rewritten.
        return parsed != before;
    }

    fn gotConfigSaved(self: *AppState, result: runtime.Result) void {
        self.config_running = false;
        if (result.ok) {
            self.say("configuration saved and valid");
        } else {
            const why = backend.diagnose(self.gpa, result.stdout, result.stderr);
            defer if (why) |text| self.gpa.free(text);
            self.sayf("saved, but the runtime objects: {s}", .{why orelse "no reason given"});
        }
    }

    /// Sets one dotted path in the loaded document from the quick-edit row.
    pub fn applyEdit(self: *AppState) void {
        const doc = if (self.config) |*c| c else return;
        const path = std.mem.trim(u8, self.edit_path.text(), " \t");
        const value = std.mem.trim(u8, self.edit_value.text(), " \t");
        if (path.len == 0) {
            self.say("name a dotted path, e.g. default_model");
            return;
        }
        doc.setAuto(path, value) catch |err| {
            self.sayf("could not set {s}: {s}", .{ path, @errorName(err) });
            return;
        };
        self.config_dirty = true;
        self.syncFormFromConfig();
        // The tree shows the document, not the file, so it has to be redrawn
        // for the edit to appear.
        self.showConfigDoc();
        self.sayf("{s} set in memory -- Save writes it", .{path});
    }

    pub fn setPalette(self: *AppState, index: usize) void {
        if (index >= theme.choices.len) return;
        self.palette_index = index;
        self.palette = theme.choices[index].palette;
        self.saveTheme();
    }

    /// Where the chosen palette is remembered: a line in the runtime's home
    /// directory, beside its own files. Not `config.json`, which belongs to
    /// the runtime and would be sent back through `config validate`.
    fn themePath(self: *AppState, buf: []u8) ?[]const u8 {
        return std.fmt.bufPrint(buf, "{s}/gui-theme", .{self.paths.home}) catch null;
    }

    fn loadTheme(self: *AppState) void {
        var path_buf: [512]u8 = undefined;
        const path = self.themePath(&path_buf) orelse return;
        const text = std.Io.Dir.cwd().readFileAlloc(self.io, path, self.gpa, .limited(64)) catch return;
        defer self.gpa.free(text);
        const name = std.mem.trim(u8, text, " \t\r\n");
        for (theme.choices, 0..) |choice, i| {
            if (std.ascii.eqlIgnoreCase(choice.name, name)) {
                self.palette_index = i;
                self.palette = choice.palette;
                return;
            }
        }
    }

    fn saveTheme(self: *AppState) void {
        var path_buf: [512]u8 = undefined;
        const path = self.themePath(&path_buf) orelse return;
        std.Io.Dir.cwd().writeFile(self.io, .{
            .sub_path = path,
            .data = theme.choices[self.palette_index].name,
        }) catch {};
    }

    pub fn uiTheme(self: *const AppState) ui.Theme {
        return theme.uiTheme(self.palette);
    }
};

// --------------------------------------------------------------------- tests

const testing = std.testing;

test "every page has a label, an icon and a command" {
    for (nav) |p| {
        try testing.expect(p.label().len > 0);
        try testing.expect(p.icon().len > 0);
        if (p.command()) |words| {
            try testing.expect(words.len > 0);
        } else {
            // Chat is the only page that runs nothing: its conversation is the
            // agent itself, not a command.
            try testing.expect(p == .chat);
        }
    }
}

test "the nav lists every page exactly once" {
    try testing.expectEqual(@as(usize, @typeInfo(Page).@"enum".field_names.len), nav.len);
    for (nav, 0..) |a, i| {
        for (nav[i + 1 ..]) |b| try testing.expect(a != b);
    }
}

test "nav starts on chat and names the runtime pages" {
    try testing.expectEqual(Page.chat, nav[0]);
    try testing.expectEqualSlices([]const u8, &.{ "models", "summary" }, Page.models.command().?);
    try testing.expectEqualSlices([]const u8, &.{ "memory", "stats" }, Page.memory.command().?);
    try testing.expectEqualSlices([]const u8, &.{"doctor"}, Page.doctor.command().?);
    try testing.expectEqualSlices([]const u8, &.{ "config", "show" }, Page.config.command().?);
    try testing.expectEqualSlices([]const u8, &.{ "update", "--check" }, Page.update.command().?);
    try testing.expect(Page.models.takesJson());
    try testing.expect(!Page.update.takesJson());
}

test "a pushed message keeps a doc beside it" {
    var s = AppState{
        .gpa = testing.allocator,
        .io = undefined,
        .environ = undefined,
        .paths = undefined,
        .exe = &.{},
        .executor = runtime.Executor.init(testing.allocator, undefined, ""),
        .turns = runtime.Turns.init(testing.allocator),
        .daemon = runtime.Daemon.init(testing.allocator, undefined, ""),
    };
    defer {
        s.daemon.deinit();
        s.clearMessages();
        s.messages.deinit(testing.allocator);
        s.docs.deinit(testing.allocator);
    }
    s.pushMessage("assistant", "# Hi\n\nSome **bold** text.");
    try testing.expectEqual(@as(usize, 1), s.messages.items.len);
    try testing.expectEqual(@as(usize, 1), s.docs.items.len);
    try testing.expectEqual(md.Kind.heading, s.docs.items[0].blocks[0].kind);
    try testing.expectEqualStrings("Hi", s.docs.items[0].firstLine());
}

// Regression: the map of open paths owns its key strings — `togglePath` and
// `expandAll` dupe each one — but nothing freed them, so every path ever opened
// leaked. `zig build shots` is what surfaced it, because `expandAll` is the only
// caller that opens more than one. The testing allocator is the assertion here.
test "opening and closing json paths does not leak the paths" {
    var s = AppState{
        .gpa = testing.allocator,
        .io = undefined,
        .environ = undefined,
        .paths = undefined,
        .exe = &.{},
        .executor = runtime.Executor.init(testing.allocator, undefined, ""),
        .turns = runtime.Turns.init(testing.allocator),
        .daemon = runtime.Daemon.init(testing.allocator, undefined, ""),
    };
    defer {
        s.daemon.deinit();
        s.clearJson();
        s.clearExpanded();
        s.json_expanded.deinit(testing.allocator);
        s.composer.deinit();
        s.edit_path.deinit();
        s.edit_value.deinit();
    }

    s.setJson("{\"providers\":{\"openrouter\":{\"model\":\"m\"}},\"agents\":{\"a\":1}}");

    s.expandAll();
    try testing.expect(s.json_expanded.count() >= 2);
    s.collapseAll();
    try testing.expectEqual(@as(usize, 0), s.json_expanded.count());

    s.togglePath("providers");
    try testing.expectEqual(@as(usize, 1), s.json_expanded.count());
    s.togglePath("providers");
    try testing.expectEqual(@as(usize, 0), s.json_expanded.count());

    // And again, so the key freed on the way out is not freed twice.
    s.expandAll();
    s.togglePath("agents");
    s.collapseAll();

    // Replacing the text drops the paths that pointed into the old tree.
    s.expandAll();
    s.setJson("{}");
}

// ----
