//! The application's state and every action that changes it. The view reads
//! this and nothing else; the runtime's answers arrive on worker threads and
//! are folded in by `pump` at the top of a frame, so the view never blocks.
const std = @import("std");
const builtin = @import("builtin");
const nanoui = @import("nanoui");
const ui = nanoui.ui;
const backend = @import("backend.zig");
const yc = @import("nullclaw");
const md = @import("md.zig");
const runtime = @import("runtime.zig");
const theme = @import("theme.zig");
const sidebar = @import("sidebar/mod.zig");
pub const Io = std.Io;

/// The page the main area shows. Everything but `chat` and `config` is a
/// runtime command whose JSON the generic viewer draws, which is how the GUI
/// stays aligned with the runtime without a parser per feature.
pub const Page = enum {
    chat,
    // The configuration boards. Each is a page in the settings menu, so the
    // menu is the only list of them: the page used to be one entry with a
    // second rail of boards inside it, which is two menus for one decision.
    cfg_model,
    cfg_agent,
    cfg_autonomy,
    cfg_workspace,
    cfg_memory,
    cfg_server,
    cfg_execution,
    cfg_gateway,
    cfg_mcp,
    cfg_schedules,
    cfg_reliability,
    cfg_diagnostics,
    cfg_security,
    cfg_tools,
    cfg_session,
    cfg_logs,
    cfg_advanced,
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
            .cfg_model => ConfigBoard.model.label(),
            .cfg_agent => ConfigBoard.agent.label(),
            .cfg_autonomy => ConfigBoard.autonomy.label(),
            .cfg_workspace => ConfigBoard.workspace.label(),
            .cfg_memory => ConfigBoard.memory.label(),
            .cfg_server => ConfigBoard.server.label(),
            .cfg_execution => ConfigBoard.execution.label(),
            .cfg_gateway => ConfigBoard.gateway.label(),
            .cfg_mcp => ConfigBoard.mcp.label(),
            .cfg_schedules => ConfigBoard.schedules.label(),
            .cfg_reliability => ConfigBoard.reliability.label(),
            .cfg_diagnostics => ConfigBoard.diagnostics.label(),
            .cfg_security => ConfigBoard.security.label(),
            .cfg_tools => ConfigBoard.tools.label(),
            .cfg_session => ConfigBoard.session.label(),
            .cfg_logs => ConfigBoard.logs.label(),
            .cfg_advanced => ConfigBoard.advanced.label(),
            .status => "Status",
            .capabilities => "Capabilities",
            .models => "Model catalog",
            .memory => "Memory stats",
            .skills => "Skills",
            .channels => "Channels",
            .cron => "Cron jobs",
            .mcp => "MCP status",
            .auth => "Auth",
            .workspace => "Workspace audit",
            .hardware => "Hardware",
            .service => "Service",
            .update => "Update",
            .doctor => "Doctor",
        };
    }

    pub fn icon(self: Page) []const u8 {
        // Every name here is one nanoui's own table can draw; a name it does
        // not know is a missing-glyph box in the menu and the header. `every
        // page wears an icon the toolkit can draw` holds the list to that.
        return switch (self) {
            .chat => "text.cursor",
            .cfg_model => ConfigBoard.model.icon(),
            .cfg_agent => ConfigBoard.agent.icon(),
            .cfg_autonomy => ConfigBoard.autonomy.icon(),
            .cfg_workspace => ConfigBoard.workspace.icon(),
            .cfg_memory => ConfigBoard.memory.icon(),
            .cfg_server => ConfigBoard.server.icon(),
            .cfg_execution => ConfigBoard.execution.icon(),
            .cfg_gateway => ConfigBoard.gateway.icon(),
            .cfg_mcp => ConfigBoard.mcp.icon(),
            .cfg_schedules => ConfigBoard.schedules.icon(),
            .cfg_reliability => ConfigBoard.reliability.icon(),
            .cfg_diagnostics => ConfigBoard.diagnostics.icon(),
            .cfg_security => ConfigBoard.security.icon(),
            .cfg_tools => ConfigBoard.tools.icon(),
            .cfg_session => ConfigBoard.session.icon(),
            .cfg_logs => ConfigBoard.logs.icon(),
            .cfg_advanced => ConfigBoard.advanced.icon(),
            .status => "gauge.with.dots.needle.33percent",
            .capabilities => "checklist",
            .models => "cpu",
            .memory => "brain",
            .skills => "sparkles",
            .channels => "network",
            .cron => "arrow.clockwise",
            .mcp => "wrench.and.screwdriver",
            .auth => "lock",
            .workspace => "folder",
            .hardware => "memorychip",
            .service => "globe",
            .update => "arrow.up",
            .doctor => "waveform.path.ecg",
        };
    }

    /// The runtime command this page runs, or null for a page with its own
    /// view. `takesJson` decides whether `--json` is appended to it.
    pub fn command(self: Page) ?[]const []const u8 {
        return switch (self) {
            .chat => null,
            // The boards are answered from the config file in process, so they
            // spawn nothing.
            .cfg_model,
            .cfg_agent,
            .cfg_autonomy,
            .cfg_workspace,
            .cfg_memory,
            .cfg_server,
            .cfg_execution,
            .cfg_gateway,
            .cfg_mcp,
            .cfg_schedules,
            .cfg_reliability,
            .cfg_diagnostics,
            .cfg_security,
            .cfg_tools,
            .cfg_session,
            .cfg_logs,
            .hardware,
            .cfg_advanced,
            => null,
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
            // A check, not an install: `nullclaw update [--check] [--yes]`,
            // and it takes no `--json`.
            .update => &.{ "update", "--check" },
            .service => &.{ "service", "status" },
            .doctor => &.{"doctor"},
        };
    }

    /// The board this page edits, when it edits one. The config file is read
    /// for exactly these pages, and drawn by exactly these pages.
    pub fn configBoard(self: Page) ?ConfigBoard {
        return switch (self) {
            .cfg_model => .model,
            .cfg_agent => .agent,
            .cfg_autonomy => .autonomy,
            .cfg_workspace => .workspace,
            .cfg_memory => .memory,
            .cfg_server => .server,
            .cfg_execution => .execution,
            .cfg_gateway => .gateway,
            .cfg_mcp => .mcp,
            .cfg_schedules => .schedules,
            .cfg_reliability => .reliability,
            .cfg_diagnostics => .diagnostics,
            .cfg_security => .security,
            .cfg_tools => .tools,
            .cfg_session => .session,
            .cfg_logs => .logs,
            // The hardware page is the board: it was a scan, and a scan of
            // devices the config never turns on is not a setting.
            .hardware => .hardware,
            .cfg_advanced => .advanced,
            else => null,
        };
    }

    /// The board that edits this page's concern, when one exists. A read-only
    /// page is where the state is read; this is how it hands over to the
    /// settings that produced it, instead of leaving the reader to find the
    /// same word in the menu.
    pub fn settingsPage(self: Page) ?Page {
        return switch (self) {
            .models => .cfg_model,
            .memory => .cfg_memory,
            .workspace => .cfg_workspace,
            .mcp => .cfg_mcp,
            .cron => .cfg_schedules,
            .channels => null,
            else => null,
        };
    }

    /// Whether the runtime documents `--json` for this page's command. The
    /// pages that do not get the runtime's prose shown instead — see
    /// view.jsonView's non-JSON branch. `contract.zig` checks this against the
    /// runtime's own usage text.
    pub fn takesJson(self: Page) bool {
        return switch (self) {
            .chat, .auth, .update, .service => false,
            .cfg_model,
            .cfg_agent,
            .cfg_autonomy,
            .cfg_workspace,
            .cfg_memory,
            .cfg_server,
            .cfg_execution,
            .cfg_gateway,
            .cfg_mcp,
            .cfg_schedules,
            .cfg_reliability,
            .cfg_diagnostics,
            .cfg_security,
            .cfg_tools,
            .cfg_session,
            .cfg_logs,
            .cfg_advanced,
            => false,
            else => true,
        };
    }

    /// Extra words the settings search accepts for this page, beyond its
    /// label: the concepts people type for it.
    pub fn keywords(self: Page) []const u8 {
        return switch (self) {
            .chat => "conversation message",
            .cfg_model => ConfigBoard.model.keywords(),
            .cfg_agent => ConfigBoard.agent.keywords(),
            .cfg_autonomy => ConfigBoard.autonomy.keywords(),
            .cfg_workspace => ConfigBoard.workspace.keywords(),
            .cfg_memory => ConfigBoard.memory.keywords(),
            .cfg_server => ConfigBoard.server.keywords(),
            .cfg_execution => ConfigBoard.execution.keywords(),
            .cfg_gateway => ConfigBoard.gateway.keywords(),
            .cfg_mcp => ConfigBoard.mcp.keywords(),
            .cfg_schedules => ConfigBoard.schedules.keywords(),
            .cfg_reliability => ConfigBoard.reliability.keywords(),
            .cfg_diagnostics => ConfigBoard.diagnostics.keywords(),
            .cfg_security => ConfigBoard.security.keywords(),
            .cfg_tools => ConfigBoard.tools.keywords(),
            .cfg_session => ConfigBoard.session.keywords(),
            .cfg_logs => ConfigBoard.logs.keywords(),
            .cfg_advanced => ConfigBoard.advanced.keywords(),
            .status => "status health uptime",
            .capabilities => "capabilities channels tools memory engines",
            .models => "models provider model summary",
            .memory => "memory engine store backend",
            .skills => "skills plugins",
            .channels => "channels telegram discord signal slack whatsapp email",
            .cron => "cron schedule jobs tasks",
            .mcp => "mcp servers tools protocol",
            .auth => "auth login oauth codex credentials token",
            .workspace => "workspace files audit directory",
            .hardware => "hardware peripherals devices scan",
            .service => "service daemon launchd systemd",
            .update => "update upgrade version release",
            .doctor => "doctor diagnostics check health",
        };
    }
};

/// Every page, in order. The brand menu lists all but chat; the rail and the
/// mode tabs open the two that matter most.
pub const nav = [_]Page{
    .chat,            .cfg_model,    .cfg_workspace, .cfg_agent,
    .cfg_autonomy,    .cfg_memory,   .cfg_server,    .cfg_execution,
    .cfg_gateway,     .cfg_mcp,      .cfg_schedules, .cfg_reliability,
    .cfg_diagnostics, .cfg_security, .cfg_tools,     .cfg_session,
    .cfg_logs,        .hardware,     .cfg_advanced,  .status,
    .capabilities,    .models,       .memory,        .workspace,
    .skills,          .channels,     .cron,          .mcp,
    .auth,            .service,      .update,        .doctor,
};

/// The boards the configuration page is divided into.
///
/// The page used to stack every section in one scroll — thirteen cards, with a
/// JSON tree under them — so finding "the temperature" meant scrolling past
/// everything else and knowing it lived under Model. A board is one concern,
/// and the page shows one at a time.
pub const ConfigBoard = enum {
    model,
    agent,
    autonomy,
    workspace,
    memory,
    server,
    execution,
    gateway,
    mcp,
    schedules,
    reliability,
    diagnostics,
    security,
    tools,
    session,
    logs,
    hardware,
    advanced,

    pub fn label(self: ConfigBoard) []const u8 {
        return switch (self) {
            .model => "Model",
            .agent => "Agent",
            .autonomy => "Autonomy",
            .workspace => "Workspace",
            .memory => "Memory",
            .server => "Runtime server",
            .execution => "Runtime",
            .gateway => "Gateway",
            .mcp => "MCP servers",
            .schedules => "Schedules",
            .reliability => "Reliability",
            .diagnostics => "Diagnostics",
            .security => "Security",
            .tools => "Tools",
            .session => "Sessions",
            .logs => "Logs",
            .hardware => "Hardware",
            .advanced => "Advanced",
        };
    }

    /// What the board is for, in the sentence the page opens with.
    pub fn note(self: ConfigBoard) []const u8 {
        return switch (self) {
            .model => "Which model answers, and how it is asked.",
            .agent => "How one turn runs: how far it may go, and how much it remembers.",
            .autonomy => "What the agent may do without asking.",
            .workspace => "The directory the agent may read and write.",
            .memory => "Which engine stores turns, and whether it searches by meaning.",
            .server => "The HTTP gateway this window serves in-process, for other clients. Chat and the pages are answered directly, not through it.",
            .execution => "Where the agent's commands run.",
            .gateway => "The HTTP server this window serves for other clients.",
            .mcp => "One per line: `name command`. The agent can call these.",
            .schedules => "Whether tasks run on a timer, and how many at once.",
            .reliability => "How hard a failing provider call is retried.",
            .diagnostics => "What the runtime records while it works.",
            .security => "How a command is contained, what it may use, and what is kept of it.",
            .tools => "The limits one tool call is held to.",
            .session => "How conversations are keyed, how long they live, and how work is claimed.",
            .logs => "What is written down while the runtime works, and how much of it is kept.",
            .hardware => "The board or serial device the agent may talk to, and nothing else.",
            .advanced => "Set any dotted path in the file directly.",
        };
    }

    /// The rail's icon. Every name here is one the toolkit can draw; the test
    /// that holds every icon in the view to the toolkit's table covers them.
    pub fn icon(self: ConfigBoard) []const u8 {
        return switch (self) {
            .model => "cpu",
            .agent => "sparkles",
            .autonomy => "lock",
            .workspace => "folder",
            .memory => "brain",
            .server => "globe",
            .execution => "memorychip",
            .gateway => "network",
            .mcp => "wrench.and.screwdriver",
            .schedules => "arrow.clockwise",
            .reliability => "waveform.path.ecg",
            .diagnostics => "gauge.with.dots.needle.33percent",
            // A lock for what contains a command, a wrench for what runs it,
            // and a person for the conversations it runs in. (The toolkit's
            // table has no shield and no second person; the test that holds
            // every icon to it caught both.)
            .security => "lock",
            .tools => "wrench.and.screwdriver",
            .session => "person.fill",
            .logs => "doc.text",
            .hardware => "memorychip",
            .advanced => "equal.square",
        };
    }

    /// The page that opens this board, so a header and a row of the settings
    /// menu reach it the same way.
    pub fn page(self: ConfigBoard) ?Page {
        return switch (self) {
            .model => .cfg_model,
            .agent => .cfg_agent,
            .autonomy => .cfg_autonomy,
            .workspace => .cfg_workspace,
            .memory => .cfg_memory,
            .server => .cfg_server,
            .execution => .cfg_execution,
            .gateway => .cfg_gateway,
            .mcp => .cfg_mcp,
            .schedules => .cfg_schedules,
            .reliability => .cfg_reliability,
            .diagnostics => .cfg_diagnostics,
            .security => .cfg_security,
            .tools => .cfg_tools,
            .session => .cfg_session,
            .logs => .cfg_logs,
            .hardware => .hardware,
            .advanced => .cfg_advanced,
        };
    }

    /// The words the settings search accepts for this board, beyond its label.
    pub fn keywords(self: ConfigBoard) []const u8 {
        return switch (self) {
            .model => "model provider api key base url temperature reasoning effort",
            .agent => "agent iterations history compact timezone timeout",
            .autonomy => "autonomy approval workspace rate limit risk",
            .workspace => "workspace directory path",
            .memory => "memory engine backend search embedding",
            .server => "server runtime gateway port bind pairing",
            .execution => "runtime docker container image native",
            .gateway => "gateway host port pairing public bind",
            .mcp => "mcp servers protocol command",
            .schedules => "cron scheduler tasks timer interval",
            .reliability => "retries backoff reliability",
            .diagnostics => "diagnostics log tool calls llm io",
            .security => "security sandbox landlock firejail bubblewrap docker resources audit memory cpu",
            .tools => "tools shell timeout output file size web fetch limits",
            .session => "session dm scope idle concurrent claim timeout typing conversations",
            .logs => "logs logging receipts payloads llm io ledger token usage",
            .hardware => "hardware serial port baud rate probe target datasheet arduino stm32",
            .advanced => "advanced dotted path raw value",
        };
    }
};

/// A heading and the pages under it in the settings menu. When the settings
/// button is pressed the sidebar swaps its conversation list for this menu, so
/// the settings read as a section of the window rather than as a popover hung
/// off a single button.
pub const SettingsGroup = struct {
    title: []const u8,
    pages: []const Page,
};

/// The settings menu, grouped the way the runtime itself thinks about them.
/// Every page but chat appears here exactly once; a test holds it to that, so a
/// new page cannot be added to `nav` and quietly left out of the menu.
pub const settings_groups = [_]SettingsGroup{
    // Every board is a row here: what the window may read and write, and how
    // it answers.
    .{ .title = "Workspace", .pages = &.{ .cfg_model, .cfg_workspace, .cfg_agent, .cfg_autonomy, .cfg_memory, .skills } },
    .{ .title = "Runtime", .pages = &.{ .cfg_server, .cfg_execution, .cfg_gateway, .cfg_mcp, .cfg_schedules, .cfg_reliability, .cfg_diagnostics, .channels, .cron, .mcp, .status } },
    .{ .title = "System", .pages = &.{ .cfg_security, .cfg_tools, .cfg_session, .cfg_logs, .hardware, .models, .memory, .workspace, .capabilities, .cfg_advanced, .auth, .service, .update, .doctor } },
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
/// `reasoning_effort` values the runtime accepts, in the order the select
/// offers them. The empty first entry is "not set", which is what a config
/// without the key means.
pub const reasoning_efforts = [_][]const u8{ "low", "medium", "high" };

/// `runtime.kind` values: the agent runs in this process, or in a container.
pub const runtime_kinds = [_][]const u8{ "native", "docker" };

/// `security.sandbox.backend`: what may contain a command, in the order the
/// runtime's own detection prefers them.
pub const sandbox_backends = [_][]const u8{ "auto", "landlock", "firejail", "bubblewrap", "docker", "none" };

/// `session.dm_scope`: how a direct message is keyed to a conversation.
/// `diagnostics.backend`: what records what the runtime does. The names are
/// the runtime's own (`none`/`noop`, `log`, `verbose`, `file`, `otel`).
pub const diagnostics_backends = [_][]const u8{ "none", "log", "verbose", "file", "otel" };

/// `hardware.transport`: how a board is reached.
pub const hardware_transports = [_][]const u8{ "none", "serial", "probe" };

pub const dm_scopes = [_][]const u8{ "main", "per_peer", "per_channel_peer", "per_account_channel_peer" };

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

    const Kind = enum { page };
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

/// A picture from an answer, read from disk once. `bytes` is empty when the
/// file could not be read, so the view draws why rather than trying again on
/// every frame.
/// The number of lines a code block shows before it is folded away. Long
/// enough to read the start of a function, short enough that a reply with a
/// file's worth of code still lets the next message be reached.
pub const code_fold_lines: usize = 14;

pub const ImageEntry = struct {
    bytes: []u8 = &.{},
    /// Why it could not be read, owned by the map's key allocator.
    failure: ?[]const u8 = null,
};

pub const CompletionItem = struct {
    /// What is inserted into the composer.
    label: []const u8,
    /// A short description drawn beside it.
    detail: []const u8 = "",
    /// Owned copies of the strings above.
    owned_label: []u8,
    owned_detail: []u8,
};

pub const AppState = struct {
    gpa: std.mem.Allocator,
    io: Io,
    environ: *std.process.Environ.Map,
    paths: backend.Paths,
    /// The runtime to run: `$NULLCLAW_BIN`, or `nullclaw` off `PATH`.
    exe: []u8,
    executor: runtime.Executor,
    /// The runtime linked into this binary, built on first use and heap
    /// allocated. Null until then, and null again if it could not be built —
    /// a window with no config still opens, and the chat says why it cannot
    /// answer. It is a pointer, not an inline value, because `AppState.init`
    /// returns the struct by value: an inline runtime would leave the agent's
    /// `mem_rt`/`policy` pointers aimed at the discarded `init` frame after
    /// the copy. A heap runtime keeps one stable address for the life of the
    /// window.
    linked: ?*yc.runtime_builder.Runtime = null,
    /// Why `linked` is null, when it is.
    linked_error: ?[]u8 = null,
    /// Turns running against `linked`, one thread each.
    turns: runtime.Turns,

    /// The sidebar's rows.
    sessions: std.ArrayListUnmanaged(backend.Session) = .empty,
    selected: ?usize = null,
    /// The conversation sidebar's own view state: its search buffer, row
    /// mode, and grouping. The sessions themselves live in `sessions`.
    sidebar: sidebar.Sidebar = .{},
    /// The selected session's transcript, and each message's reply parsed for
    /// drawing. Parsing is cached here so a frame never re-reads markdown.
    messages: std.ArrayListUnmanaged(backend.Message) = .empty,
    /// The answer as it is being written, before the turn ends. Empty when
    /// nothing is streaming. The view draws it after the last message, with
    /// the caret, so a long turn shows progress instead of a spinner.
    stream_text: std.ArrayListUnmanaged(u8) = .empty,
    /// The key a new conversation will be filed under. Without one every turn
    /// lands in the same session, which is why "New chat" used to reopen the
    /// old transcript: the runtime had nowhere else to put the messages.
    draft_session: std.ArrayListUnmanaged(u8) = .empty,
    /// Bumped for every new conversation, so two drafts in one run differ.
    draft_seq: u64 = 0,
    /// The streaming text parsed for the view, kept in step with `stream_text`.
    stream_doc: ?md.Doc = null,
    docs: std.ArrayListUnmanaged(md.Doc) = .empty,

    /// What the user is typing.
    composer: ui.TextBuffer = .{},
    /// Whether the composer had the keyboard last frame: the frame tints its
    /// border from this, so a focused input reads as live.
    composer_focused: bool = false,
    /// A turn is in flight.
    sending: bool = false,

    // ── Composer autocomplete ─────────────────────────────────────────────
    /// Which completion the composer is offering, if any.
    completion_mode: enum { none, mention, slash } = .none,
    /// The byte range of `composer` the completion will replace: the trigger
    /// and the prefix typed after it, up to the caret.
    completion_start: usize = 0,
    completion_end: usize = 0,
    /// The filtered candidates for the current completion.
    completion_items: std.ArrayListUnmanaged(CompletionItem) = .empty,
    /// Which candidate is highlighted.
    completion_selected: usize = 0,

    // ── Transcript navigation ─────────────────────────────────────────────
    /// A footnote the reader asked to jump to, from a reference in the
    /// answer: the transcript scrolls to its definition on the next frame.
    reveal_footnote: ?u32 = null,
    /// A reference the reader asked to come back to, from the note they
    /// jumped to: the transcript scrolls to where it is cited.
    reveal_reference: ?u32 = null,
    /// Where the reference being returned to was drawn, in window points. The
    /// message that holds it records this as it draws; the transcript turns
    /// it into a scroll offset, because only the transcript knows its own
    /// box and how far down it already is.
    reveal_reference_y: ?f32 = null,

    /// A picture an answer pointed at, loaded once and kept: decoding is the
    /// expensive part, and a transcript redraws every frame.
    images: std.StringHashMapUnmanaged(ImageEntry) = .empty,

    /// Which long code blocks the reader has opened. Keyed by the block's own
    /// text and language, so the state survives every frame the transcript is
    /// rebuilt for — and toggling one block does not fold another.
    code_expanded: std.AutoHashMapUnmanaged(u64, bool) = .empty,

    /// The settings menu's search field. A query filters the pages by label
    /// and keyword; an empty query draws the grouped menu.
    settings_search: ui.TextBuffer = .{},

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

    // ── The rest of the settings the page edits ──────────────────────────
    // Each is a field of `config.json` the runtime actually reads, chosen
    // because it changes what the agent does rather than how it is tuned.
    // The long tail (memory search internals, qmd, per-channel keys) stays in
    // the advanced fold: a form that mirrors every key is a worse editor than
    // the file itself.

    /// `default_temperature`: how much variation the model is allowed.
    cfg_temperature: ui.TextBuffer = .{},
    /// `reasoning_effort`: how hard a reasoning model thinks, when it takes one.
    /// Null when the config does not set it, which is what the empty select
    /// shows.
    cfg_reasoning_effort: ?usize = null,
    /// `agent.max_tool_iterations`: how many tool calls one turn may make.
    cfg_max_tool_iterations: ui.TextBuffer = .{},
    /// `agent.max_history_messages`: how much of the conversation is sent.
    cfg_max_history: ui.TextBuffer = .{},
    /// `agent.compact_context`: whether long turns are summarised.
    cfg_compact_context: bool = false,
    /// `agent.timezone`: the zone the agent reasons about times in.
    cfg_timezone: ui.TextBuffer = .{},
    /// `agent.message_timeout_secs`: how long one turn may take.
    cfg_message_timeout: ui.TextBuffer = .{},
    /// `autonomy.workspace_only`: whether the agent is held to the workspace.
    cfg_workspace_only: bool = true,
    /// `autonomy.max_actions_per_hour`: the rate the agent is held to.
    cfg_max_actions: ui.TextBuffer = .{},
    /// `autonomy.block_high_risk_commands`: whether the dangerous ones are refused.
    cfg_block_high_risk: bool = true,
    /// `autonomy.require_approval_for_medium_risk`: whether the middle ones ask.
    cfg_approve_medium: bool = true,
    /// `runtime.kind`: native, or a container.
    cfg_runtime_kind: usize = 0,
    /// `runtime.docker.image`: the container the agent runs in.
    cfg_docker_image: ui.TextBuffer = .{},
    /// `gateway.require_pairing`: whether a client must pair before it is served.
    cfg_gateway_require_pairing: bool = true,
    /// `memory.search.enabled`: whether memory is searched by meaning.
    cfg_memory_search: bool = true,
    /// `scheduler.enabled` / `scheduler.max_tasks`: the task runner.
    cfg_scheduler_enabled: bool = true,
    cfg_scheduler_max_tasks: ui.TextBuffer = .{},
    /// `diagnostics.log_tool_calls` / `log_llm_io`: what the runtime records.
    cfg_log_tool_calls: bool = false,
    cfg_log_llm_io: bool = false,

    // ── Security: what contains a command, and what is kept of it ──────────
    /// `security.sandbox.backend`: index into `sandbox_backends`.
    cfg_sandbox_backend: usize = 0,
    /// `security.sandbox.enabled`: null follows the backend's own answer, as
    /// the runtime does when the key is absent.
    cfg_sandbox_enabled: ?bool = null,
    cfg_max_memory_mb: ui.TextBuffer = .{},
    cfg_max_cpu_seconds: ui.TextBuffer = .{},
    cfg_max_subprocesses: ui.TextBuffer = .{},
    cfg_memory_monitoring: bool = true,
    cfg_audit_enabled: bool = true,
    cfg_audit_log_path: ui.TextBuffer = .{},
    cfg_audit_max_size_mb: ui.TextBuffer = .{},
    cfg_audit_sign_events: bool = false,

    // ── Tools: the limits one call is held to ──────────────────────────────
    cfg_shell_timeout_secs: ui.TextBuffer = .{},
    cfg_shell_max_output_bytes: ui.TextBuffer = .{},
    cfg_max_file_size_bytes: ui.TextBuffer = .{},
    cfg_web_fetch_max_chars: ui.TextBuffer = .{},

    // ── Sessions: how conversations are keyed and claimed ─────────────────
    /// `session.dm_scope`: index into `dm_scopes`.
    cfg_dm_scope: usize = 2,
    cfg_session_idle_minutes: ui.TextBuffer = .{},
    cfg_session_max_concurrent: ui.TextBuffer = .{},
    cfg_claim_max_attempts: ui.TextBuffer = .{},
    cfg_claim_lockout_secs: ui.TextBuffer = .{},
    cfg_typing_interval_secs: ui.TextBuffer = .{},

    /// `diagnostics.backend`: index into `diagnostics_backends`.
    cfg_diagnostics_backend: usize = 0,
    cfg_otel_endpoint: ui.TextBuffer = .{},
    cfg_otel_service: ui.TextBuffer = .{},
    cfg_api_error_max_chars: ui.TextBuffer = .{},

    // ── Logs: what is written down, and how much of it is kept ─────────────
    cfg_log_receipts: bool = false,
    cfg_log_payloads: bool = false,
    cfg_ledger_enabled: bool = true,
    cfg_ledger_window_hours: ui.TextBuffer = .{},
    cfg_ledger_max_bytes: ui.TextBuffer = .{},
    cfg_ledger_max_lines: ui.TextBuffer = .{},

    // ── Hardware: the one device the agent may talk to ─────────────────────
    cfg_hardware_enabled: bool = false,
    /// `hardware.transport`: index into `hardware_transports`.
    cfg_hardware_transport: usize = 0,
    cfg_hardware_serial_port: ui.TextBuffer = .{},
    cfg_hardware_baud_rate: ui.TextBuffer = .{},
    cfg_hardware_probe_target: ui.TextBuffer = .{},
    cfg_hardware_datasheets: bool = false,

    /// What the Skills and Capabilities pages last read, so the configuration
    /// page can summarise them without running the commands again. Null until
    /// those pages have been opened.
    skills_count: ?usize = null,
    caps_summary: ?CapsSummary = null,

    /// The gateway the GUI serves from the linked runtime. It is not a field
    /// of its own: the gateway runs on the linked runtime's thread (see
    /// `Runtime.serveGateway`), so its life is the linked runtime's life.
    daemon_auto_started: bool = false,

    /// The model the config names as its default, read once so the composer's
    /// chip can name it without a frame ever parsing the file. Empty when
    /// there is no config or it names no model, which hides the chip rather
    /// than showing a guess.
    default_model: []u8 = &.{},

    /// The palette the window is drawn in, and whether the switcher is open.
    palette_index: usize = 0,
    palette: theme.Palette = theme.choices[0].palette,
    theme_menu_open: bool = false,
    /// The "nullclaw ∨" menu beside the brand. Every non-chat page lives in
    /// it, so the sidebar stays a list of conversations, like the web client.
    menu_open: bool = false,
    /// Which project groups in the sidebar are folded shut, by group name.
    /// Zeron's sidebar groups sessions under their project and lets each group
    /// fold; this is that fold, kept per group so one closing leaves the rest
    /// as they were.
    folded_groups: std.StringHashMapUnmanaged(void) = .empty,
    /// The top-of-page mode switch. Chat is the conversation; Work is the
    /// runtime's tools. Work opens the first tool page when chosen.
    active_tab: enum { chat, work } = .chat,
    /// True while the sidebar shows the settings menu instead of the
    /// conversation list. The settings button on the rail turns it on, and
    /// starting a chat turns it off.
    settings_open: bool = false,
    /// The diagnostics panel the sidebar's footer opens.
    diagnostics_open: bool = false,

    /// The last thing that happened, shown for a few seconds.
    toast: []u8 = &.{},
    toast_shown_at: f64 = -1,
    /// Strings a frame has already drawn and a click handler has since
    /// replaced. nanoui measures a frame after the view returns, so a string
    /// freed mid-frame is read back — as garbage, or as a segfault once the
    /// allocator hands the page back to the kernel. They are kept until the
    /// next frame opens, when no node can still point at them.
    retired: std.ArrayListUnmanaged([]u8) = .empty,
    /// The same, for a list of strings retired as a whole: a config reload
    /// replaces the provider options, and the frame that asked for it is still
    /// holding the old ids. The ids go into `retired`; the array holding them
    /// needs its own type to be freed correctly.
    retired_lists: std.ArrayListUnmanaged([]const []const u8) = .empty,

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
        };
        self.loadTheme();
        self.loadDefaultModel();
        // The gateway the window serves takes its port from the file, so the
        // file is read before the runtime is built rather than when the first
        // configuration board is opened. Without this the window bound 3000 at
        // startup whatever `gateway.port` said, and only moved to the
        // configured port when someone pressed Save.
        self.seedDaemonForm();
        // Auto-enable the bundled runtime on startup (best effort). Building
        // the linked runtime also brings the gateway up (see `ensureLinked`),
        // so the window serves HTTP from the first frame. Tests drive the
        // window against a stub and build the runtime lazily on the first
        // turn, so they skip this: building it here would turn every window
        // test into a runtime test.
        if (!builtin.is_test) _ = self.ensureLinked();
        self.daemon_auto_started = true;
        return self;
    }

    pub fn deinit(self: *AppState) void {
        // The linked runtime owns the gateway thread; stopping it first is
        // what releases the port before the rest of the state goes away.
        if (self.linked) |rt| rt.stopGateway();
        // Nothing can call a handler once the executor is down, so whatever is
        // still pending is ours to free.
        self.turns.deinit();
        if (self.linked) |rt| {
            rt.deinit();
            self.gpa.destroy(rt);
            self.linked = null;
        }
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
        var image_it = self.images.iterator();
        while (image_it.next()) |e| {
            self.gpa.free(e.key_ptr.*);
            self.gpa.free(e.value_ptr.bytes);
            if (e.value_ptr.failure) |why| self.gpa.free(why);
        }
        self.images.deinit(self.gpa);
        self.code_expanded.deinit(self.gpa);
        // Whatever the menu was offering is ours to free, strings and all.
        self.clearCompletion();
        self.completion_items.deinit(self.gpa);
        self.sidebar.search.deinit();
        self.settings_search.deinit();
        self.stream_text.deinit(self.gpa);
        self.draft_session.deinit(self.gpa);
        if (self.stream_doc) |*d| d.deinit();
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
        self.cfg_max_memory_mb.deinit();
        self.cfg_max_cpu_seconds.deinit();
        self.cfg_max_subprocesses.deinit();
        self.cfg_audit_log_path.deinit();
        self.cfg_audit_max_size_mb.deinit();
        self.cfg_shell_timeout_secs.deinit();
        self.cfg_shell_max_output_bytes.deinit();
        self.cfg_max_file_size_bytes.deinit();
        self.cfg_web_fetch_max_chars.deinit();
        self.cfg_session_idle_minutes.deinit();
        self.cfg_session_max_concurrent.deinit();
        self.cfg_claim_max_attempts.deinit();
        self.cfg_claim_lockout_secs.deinit();
        self.cfg_typing_interval_secs.deinit();
        self.cfg_otel_endpoint.deinit();
        self.cfg_otel_service.deinit();
        self.cfg_api_error_max_chars.deinit();
        self.cfg_ledger_window_hours.deinit();
        self.cfg_ledger_max_bytes.deinit();
        self.cfg_ledger_max_lines.deinit();
        self.cfg_hardware_serial_port.deinit();
        self.cfg_hardware_baud_rate.deinit();
        self.cfg_hardware_probe_target.deinit();
        self.clearJson();
        self.clearExpanded();
        self.json_expanded.deinit(self.gpa);
        if (self.config) |*c| c.deinit();
        self.releaseRetired();
        self.retired.deinit(self.gpa);
        self.retired_lists.deinit(self.gpa);
        self.gpa.free(self.toast);
        self.gpa.free(self.default_model);
        for (self.cfg_provider_options) |id| self.gpa.free(id);
        self.gpa.free(self.cfg_provider_options);
        self.gpa.free(self.exe);
        self.paths.deinit();
        self.* = undefined;
    }

    // ------------------------------------------------------------- lifecycle

    /// Folds finished commands in. Call once at the top of a frame.
    pub fn pump(self: *AppState) void {
        // A frame that has been measured is finished with the strings it drew,
        // so this is the first moment they can be freed.
        self.releaseRetired();
        self.executor.pump();
        self.turns.pumpStreaming(self, onDelta, onTurnDone);
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

    /// True while an answer is arriving, so the view draws the caret and
    /// keeps asking for frames.
    pub fn streaming(self: *AppState) bool {
        return self.stream_text.items.len > 0;
    }

    /// Builds the linked runtime on first use. A config that cannot carry a
    /// turn leaves `linked_error` set, and the chat reports it instead of
    /// pretending to be ready.
    fn ensureLinked(self: *AppState) ?*yc.runtime_builder.Runtime {
        if (self.linked) |rt| return rt;
        if (self.linked_error != null) return null;
        const built = self.gpa.create(yc.runtime_builder.Runtime) catch return null;
        built.* = yc.runtime_builder.Runtime.init(self.gpa) catch |err| {
            self.gpa.destroy(built);
            self.linked_error = std.fmt.allocPrint(self.gpa, "{s}", .{@errorName(err)}) catch null;
            return null;
        };
        self.linked = built;
        // Now that the runtime sits at its heap address, point the agent and
        // the memory tools at it. Doing this inside `Runtime.init` would aim
        // them at a frame that no longer exists, which is what made the first
        // turn read a freed stack slot as the outbox handle.
        const rt = built;
        rt.wireMemory();
        // The gateway serves from this runtime too; bring it up now that the
        // runtime has a stable address.
        self.ensureDaemonRunning();
        return rt;
    }

    fn onTurnDone(self: *AppState, result: runtime.TurnResult) void {
        self.sending = false;
        // Whatever streamed is now part of the transcript, so the live copy
        // goes away before the finished message takes its place.
        self.clearStream();
        if (result.abandoned) {
            // The person stopped it: the partial text was theirs to throw
            // away, and an error line would blame the runtime for it.
            self.say("stopped");
            return;
        }
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
        if (self.gatewayRunning()) return;
        // The gateway is served by the linked runtime, so it can only start
        // once that runtime exists. This does not build the runtime itself:
        // `ensureLinked` does that on the first turn (and calls back here), so
        // a window that has not run a turn yet — every headless test — does
        // not grow a runtime just from being pumped.
        const rt = self.linked orelse return;
        const host = self.configFormGatewayHost();
        const port = self.configFormGatewayPort();
        // Silent on the frame path: `pump` calls this every frame, and a
        // failure would stack a toast per frame. `restartDaemon` reports the
        // outcome instead, once, for the person who asked for it.
        rt.serveGateway(host, port) catch {};
    }

    pub fn restartDaemon(self: *AppState) void {
        if (self.linked) |rt| rt.stopGateway();
        self.ensureDaemonRunning();
        // A restart that did not come back is the one thing the person who
        // pressed "Save & restart" has to be told: the file was written either
        // way, and a gateway that stayed down is otherwise invisible until
        // something else fails to reach it.
        if (self.linked != null and !self.gatewayRunning()) {
            self.say("saved, but the gateway did not come back");
        }
    }

    /// Stops the linked runtime's gateway without restarting it.
    pub fn stopGateway(self: *AppState) void {
        if (self.linked) |rt| rt.stopGateway();
    }

    /// True while the linked runtime is serving the gateway.
    pub fn gatewayRunning(self: *const AppState) bool {
        const rt = self.linked orelse return false;
        return rt.gatewayRunning();
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
        if (self.gatewayRunning()) {
            return std.fmt.allocPrint(a, "running on {s}:{d}", .{
                self.configFormGatewayHost(),
                self.configFormGatewayPort(),
            }) catch "running";
        }
        if (self.linked_error) |why| {
            return std.fmt.allocPrint(a, "runtime unavailable: {s}", .{why}) catch "runtime unavailable";
        }
        if (self.linked) |rt| {
            if (rt.gateway_failure) |err| {
                return std.fmt.allocPrint(a, "gateway stopped: {s}", .{@errorName(err)}) catch "gateway stopped";
            }
        }
        return "stopped";
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
            .page => self.gotPage(result),
        }
    }

    // ---------------------------------------------------------------- toasts

    // ── Transcript navigation ─────────────────────────────────────────────

    /// Jumps to a footnote's definition. The transcript lays the notes out
    /// when it draws them, so the scroll is resolved then: this only records
    /// which one to reach.
    pub fn jumpToFootnote(self: *AppState, number: u32) void {
        self.reveal_footnote = number;
        self.reveal_reference = null;
        self.reveal_reference_y = null;
    }

    /// Comes back to where a note was cited: the message that holds the
    /// reference records its place as it draws, and the transcript scrolls
    /// there. The note the reader was on stays where it is.
    pub fn returnToReference(self: *AppState, number: u32) void {
        self.reveal_reference = number;
        self.reveal_reference_y = null;
        self.reveal_footnote = null;
    }

    /// A code block's identity: its language and its text. Two identical
    /// blocks share a key, which is what a reader would expect — folding one
    /// copy of a snippet folds the other.
    pub fn codeKey(text: []const u8, lang: []const u8) u64 {
        var h = std.hash.Wyhash.init(0);
        h.update(lang);
        h.update("\x00");
        h.update(text);
        return h.final();
    }

    /// Whether a long block is open. A block the reader has never touched is
    /// closed when it is longer than `code_fold_lines`.
    pub fn codeOpen(self: *AppState, key: u64, lines: usize) bool {
        if (self.code_expanded.get(key)) |open| return open;
        return lines <= code_fold_lines;
    }

    pub fn toggleCode(self: *AppState, key: u64, lines: usize) void {
        const open = self.codeOpen(key, lines);
        self.code_expanded.put(self.gpa, key, !open) catch {};
    }

    /// A picture an answer pointed at, loaded on first use and then kept.
    ///
    /// Only what is on this machine is drawn: a path, absolute or relative to
    /// the workspace. A remote picture would have to be fetched, and a frame
    /// may not wait on the network, so a URL is answered as a link instead.
    pub fn image(self: *AppState, url: []const u8) ImageEntry {
        if (self.images.get(url)) |entry| return entry;
        var entry: ImageEntry = .{};
        if (self.readImage(url)) |bytes| {
            entry.bytes = bytes;
        } else |err| {
            entry.failure = self.gpa.dupe(u8, @errorName(err)) catch "unreadable";
        }
        // The key is the caller's text, so it is copied; the entry outlives
        // the frame that asked for it.
        const key = self.gpa.dupe(u8, url) catch return entry;
        self.images.put(self.gpa, key, entry) catch {
            self.gpa.free(key);
            self.gpa.free(entry.bytes);
            if (entry.failure) |why| self.gpa.free(why);
        };
        return entry;
    }

    fn readImage(self: *AppState, url: []const u8) ![]u8 {
        // A `file://` URL is a path with a scheme on it.
        const path = if (std.mem.startsWith(u8, url, "file://")) url["file://".len..] else url;
        if (std.mem.indexOf(u8, path, "://") != null) return error.RemoteImageNotFetched;
        if (path.len == 0) return error.EmptyPath;
        const resolved = if (std.fs.path.isAbsolute(path))
            path
        else blk: {
            // Relative paths are the workspace's: that is where an agent's
            // files and screenshots live.
            const ws = self.workspaceDir();
            break :blk std.fs.path.join(self.gpa, &.{ ws, path }) catch return error.OutOfMemory;
        };
        defer if (!std.fs.path.isAbsolute(path)) self.gpa.free(resolved);
        return std.Io.Dir.cwd().readFileAlloc(self.io, resolved, self.gpa, .limited(16 << 20));
    }

    /// The workspace the runtime reads and writes: the one the config page
    /// holds, the loaded runtime's, or the one `~/.nullclaw` scaffolds.
    fn workspaceDir(self: *AppState) []const u8 {
        const typed = std.mem.trim(u8, self.cfg_workspace.text(), " \t\r\n");
        if (typed.len > 0) return typed;
        if (self.linked) |rt| {
            const ws = rt.config.workspace_dir;
            if (ws.len > 0) return ws;
        }
        return self.paths.workspace;
    }

    /// Opens a link from the answer in the system's browser.
    pub fn openLink(self: *AppState, url: []const u8) void {
        if (!std.mem.startsWith(u8, url, "https://") and
            !std.mem.startsWith(u8, url, "http://") and
            !std.mem.startsWith(u8, url, "mailto:"))
        {
            self.sayf("not a link: {s}", .{url});
            return;
        }
        // A headless test clicking a link must not open a page in the
        // machine's browser: that is a side effect on the person running the
        // suite, and `zig build test` has to stay hermetic.
        if (builtin.is_test) {
            self.sayf("opened {s}", .{url});
            return;
        }
        if (!nanoui.shell.openUrl(url)) {
            self.sayf("could not open {s}", .{url});
            return;
        }
        self.sayf("opened {s}", .{url});
    }

    pub fn say(self: *AppState, text: []const u8) void {
        self.retire(self.toast);
        self.toast = self.gpa.dupe(u8, text) catch &.{};
        self.toast_shown_at = -1;
    }

    pub fn sayf(self: *AppState, comptime fmt: []const u8, args: anytype) void {
        const text = std.fmt.allocPrint(self.gpa, fmt, args) catch return;
        defer self.gpa.free(text);
        self.say(text);
    }

    /// Keeps `bytes` alive until the next frame opens. Use this rather than
    /// freeing anything a node drawn earlier in this frame may still point at.
    fn retire(self: *AppState, bytes: []u8) void {
        if (bytes.len == 0) return;
        // A list that cannot grow leaves the string allocated, which is the
        // safe failure: freeing it now is the thing being avoided.
        self.retired.append(self.gpa, bytes) catch {};
    }

    /// Frees what earlier frames retired. Called once per frame, before
    /// anything is drawn.
    fn releaseRetired(self: *AppState) void {
        for (self.retired.items) |bytes| self.gpa.free(bytes);
        self.retired.clearRetainingCapacity();
        for (self.retired_lists.items) |list| self.gpa.free(list);
        self.retired_lists.clearRetainingCapacity();
    }

    /// Retires the provider options a reload is about to replace: the strings
    /// and the array that holds them, both freed at the next frame.
    fn retireProviderOptions(self: *AppState) void {
        for (self.cfg_provider_options) |id| self.retire(@constCast(id));
        if (self.cfg_provider_options.len > 0) {
            self.retired_lists.append(self.gpa, self.cfg_provider_options) catch {};
        }
        self.cfg_provider_options = &.{};
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
        self.retire(self.toast);
        self.toast = &.{};
        self.toast_shown_at = -1;
    }

    // -------------------------------------------------------------- sessions

    pub fn refreshSessions(self: *AppState) void {
        // The session list is a query on the linked runtime's own session
        // store, not on a CLI process. A runtime with no session store (a
        // markdown memory) has no sidebar to draw either.
        const rt = self.ensureLinked() orelse {
            self.clearSessions();
            return;
        };
        const store = rt.session_store orelse {
            self.clearSessions();
            return;
        };
        const infos = store.listSessions(self.gpa, 200, 0) catch return;
        defer yc.memory.freeSessionInfos(self.gpa, infos);

        const keep = if (self.selected) |i| self.sessions.items[i].key else null;
        var keep_owned: ?[]u8 = null;
        if (keep) |key| keep_owned = self.gpa.dupe(u8, key) catch null;
        defer if (keep_owned) |key| self.gpa.free(key);

        self.clearSessions();
        self.sessions.deinit(self.gpa);
        self.sessions = .empty;
        for (infos) |info| {
            const converted = backend.Session{
                .key = self.gpa.dupe(u8, info.session_id) catch continue,
                .message_count = info.message_count,
                .created_at = self.gpa.dupe(u8, info.first_message_at) catch "",
                .last_active = self.gpa.dupe(u8, info.last_message_at) catch "",
            };
            self.sessions.append(self.gpa, converted) catch {
                var mutable = converted;
                mutable.deinit(self.gpa);
            };
        }
        self.selected = null;
        sortSessions(self.sessions.items);
        if (keep_owned) |key| {
            for (self.sessions.items, 0..) |*session, i| {
                if (std.mem.eql(u8, session.key, key)) {
                    self.selected = i;
                    break;
                }
            }
        }
    }

    /// Newest conversation first, the way a chat client lists them: the one
    /// just had belongs at the top. ISO-8601 stamps compare as text, so the
    /// string order is the chronological order. A session the runtime could
    /// not date (an empty stamp) sorts last rather than jumping the queue.
    fn sortSessions(sessions: []backend.Session) void {
        std.mem.sort(backend.Session, sessions, {}, struct {
            fn newer(_: void, a: backend.Session, b: backend.Session) bool {
                if (a.last_active.len == 0) return false;
                if (b.last_active.len == 0) return true;
                return std.mem.order(u8, a.last_active, b.last_active) == .gt;
            }
        }.newer);
    }

    fn clearSessions(self: *AppState) void {
        // Retired, not freed: the sidebar drew its rows from these strings
        // earlier in this frame, and the frame is measured after the view.
        for (self.sessions.items) |*s| {
            self.retire(s.key);
            self.retire(s.created_at);
            self.retire(s.last_active);
        }
        self.sessions.clearRetainingCapacity();
    }

    pub fn select(self: *AppState, index: usize) void {
        if (index >= self.sessions.items.len) return;
        self.selected = index;
        // Choosing a conversation leaves the settings menu, the way picking a
        // chat in the web client closes Settings.
        self.settings_open = false;
        self.loadTranscript(self.sessions.items[index].key);
    }

    fn loadTranscript(self: *AppState, key: []const u8) void {
        // The transcript is read from the linked runtime's session store. No
        // store means no history to draw, which is what a markdown-only
        // runtime has always answered.
        const rt = self.ensureLinked() orelse {
            self.clearMessages();
            return;
        };
        const store = rt.session_store orelse {
            self.clearMessages();
            return;
        };
        const entries = store.loadMessagesDetailed(self.gpa, key, 200, 0) catch return;
        defer yc.memory.freeDetailedMessages(self.gpa, entries);

        self.clearMessages();
        self.messages.deinit(self.gpa);
        self.messages = .empty;
        for (entries) |entry| {
            const converted = backend.Message{
                .role = self.gpa.dupe(u8, entry.role) catch continue,
                .content = self.gpa.dupe(u8, entry.content) catch continue,
                .created_at = self.gpa.dupe(u8, entry.created_at) catch "",
            };
            self.messages.append(self.gpa, converted) catch {
                var mutable = converted;
                mutable.deinit(self.gpa);
                continue;
            };
            var doc = md.parse(self.gpa, converted.content) catch md.Doc{ .arena = std.heap.ArenaAllocator.init(self.gpa) };
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
        self.clearStream();
    }

    pub fn clearStream(self: *AppState) void {
        self.stream_text.clearRetainingCapacity();
        if (self.stream_doc) |*d| d.deinit();
        self.stream_doc = null;
    }

    /// Appends what the provider just wrote to the answer being streamed.
    pub fn onDelta(self: *AppState, delta: []const u8) void {
        self.stream_text.appendSlice(self.gpa, delta) catch return;
        // Re-parsed every frame: markdown is cheap at this size, and a
        // half-written fence or list should look right as it arrives.
        if (self.stream_doc) |*d| d.deinit();
        self.stream_doc = md.parse(self.gpa, self.stream_text.items) catch null;
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

        const session = self.turnSession();

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

    /// Stops the turn that is running. The provider request cannot be
    /// cancelled, so the turn is abandoned: its output stops arriving here.
    pub fn stop(self: *AppState) void {
        if (!self.sending) return;
        self.turns.stop();
        self.sending = false;
        self.clearStream();
        self.say("stopped");
    }

    // ── Composer autocomplete ─────────────────────────────────────────────

    pub fn clearCompletion(self: *AppState) void {
        for (self.completion_items.items) |item| {
            self.gpa.free(item.owned_label);
            self.gpa.free(item.owned_detail);
        }
        self.completion_items.clearRetainingCapacity();
        self.completion_mode = .none;
        self.completion_start = 0;
        self.completion_end = 0;
        self.completion_selected = 0;
    }

    /// Called whenever the composer text changes; updates the completion
    /// state. `caret` is the byte offset the textarea reports.
    pub fn updateCompletion(self: *AppState, caret: usize) void {
        self.clearCompletion();
        const text = self.composer.text();
        if (caret > text.len) return;
        // Walk backwards from the caret to find a trigger at a word boundary.
        var i = caret;
        while (i > 0) {
            const c = text[i - 1];
            if (c == '@' or c == '/') {
                // Must be at start or preceded by whitespace.
                if (i == 1 or text[i - 2] == ' ' or text[i - 2] == '\t' or text[i - 2] == '\n') {
                    const prefix = text[i..caret];
                    self.completion_start = i - 1;
                    self.completion_end = caret;
                    if (c == '@') {
                        self.completion_mode = .mention;
                        self.populateMentions(prefix);
                    } else {
                        self.completion_mode = .slash;
                        self.populateSlash(prefix);
                    }
                    return;
                }
            }
            if (c == ' ' or c == '\t' or c == '\n') break;
            i -= 1;
        }
    }

    fn populateMentions(self: *AppState, prefix: []const u8) void {
        // Offer a small set of workspace-relative paths. In a real app this
        // would walk the workspace; here we seed common ones plus any prefix.
        const candidates = [_][]const u8{
            "README.md", "AGENTS.md", "config.json", "src/main.zig", "src/agent.zig", "gui/src/state.zig", "docs/en/README.md",
        };
        for (candidates) |c| {
            if (prefix.len == 0 or std.mem.startsWith(u8, c, prefix)) {
                self.addCompletionItem(c, "file");
            }
        }
    }

    fn populateSlash(self: *AppState, prefix: []const u8) void {
        // The command names nullclaw understands, from control_plane.
        const commands = [_][]const u8{
            "new", "reset", "restart", "help", "status", "whoami", "model", "models", "think", "verbose", "reasoning", "exec", "queue", "usage", "tts", "voice", "stop", "abort", "compact", "allowlist", "approve", "context", "export-session", "session", "subagents", "tasks", "agents", "focus", "unfocus", "kill", "steer", "tell", "config", "capabilities", "debug", "skill", "skills", "doctor", "memory", "cost", "menu", "commands",
        };
        for (commands) |cmd| {
            if (prefix.len == 0 or std.mem.startsWith(u8, cmd, prefix)) {
                self.addCompletionItem(cmd, "command");
            }
        }
    }

    fn addCompletionItem(self: *AppState, label: []const u8, detail: []const u8) void {
        const owned_label = self.gpa.dupe(u8, label) catch return;
        errdefer self.gpa.free(owned_label);
        const owned_detail = self.gpa.dupe(u8, detail) catch return;
        errdefer self.gpa.free(owned_detail);
        self.completion_items.append(self.gpa, .{
            .label = owned_label,
            .detail = owned_detail,
            .owned_label = owned_label,
            .owned_detail = owned_detail,
        }) catch {};
    }

    /// Puts the highlighted candidate in place of the trigger and its prefix,
    /// leaving whatever was written after the caret where it was; the caret
    /// lands at the end of what went in.
    pub fn acceptCompletion(self: *AppState) void {
        if (self.completion_mode == .none or self.completion_items.items.len == 0) return;
        const item = self.completion_items.items[self.completion_selected];
        // A command is inserted as a command, not as the bare name.
        const inserted = if (self.completion_mode == .slash)
            std.fmt.allocPrint(self.gpa, "/{s} ", .{item.label}) catch return
        else
            std.fmt.allocPrint(self.gpa, "@{s} ", .{item.label}) catch return;
        defer self.gpa.free(inserted);
        const n = self.composer.replace(self.completion_start, self.completion_end, inserted);
        if (n > 0) self.composer.want_caret = self.completion_start + n;
        self.clearCompletion();
    }

    pub fn completionActive(self: *const AppState) bool {
        return self.completion_mode != .none and self.completion_items.items.len > 0;
    }

    pub fn completionMove(self: *AppState, delta: i32) void {
        const n = self.completion_items.items.len;
        if (n == 0) return;
        const cur: i32 = @intCast(self.completion_selected);
        const next = @mod(cur + delta, @as(i32, @intCast(n)));
        self.completion_selected = @intCast(next);
    }

    pub fn newChat(self: *AppState) void {
        self.selected = null;
        self.clearMessages();
        self.composer.clear();
        self.page = .chat;
        // Starting a conversation leaves the settings menu: it belongs to the
        // conversation list, which is what the sidebar shows again.
        self.settings_open = false;
        self.makeDraftSession();
    }

    /// Puts the cursor in the sidebar's search field. The field is drawn every
    /// frame, so asking it to take focus is a flag the next frame reads rather
    /// than a call that can happen here.
    pub fn focusSearch(self: *AppState) void {
        self.sidebar.search.want_focus = true;
    }

    /// Swaps the sidebar to the settings menu, or back. The settings button on
    /// the rail calls this; opening a page keeps `settings_open` in step through
    /// `openPage`, so the two never disagree.
    pub fn toggleSettings(self: *AppState) void {
        if (self.settings_open) {
            self.openPage(.chat);
        } else {
            // The first board, which is the one most settings start with.
            self.openPage(.cfg_model);
        }
    }

    /// Names the conversation that has not been sent yet. The key is a
    /// timestamp: it sorts by when the chat started, and it cannot collide
    /// with a session the runtime already has.
    fn makeDraftSession(self: *AppState) void {
        self.draft_session.clearRetainingCapacity();
        var buf: [40]u8 = undefined;
        // A counter rather than a clock: the window has no wall clock, and a
        // session key only has to be unique within this run.
        const stamp = std.fmt.bufPrint(&buf, "gui:{d}", .{self.draft_seq}) catch return;
        self.draft_seq += 1;
        self.draft_session.appendSlice(self.gpa, stamp) catch {};
    }

    /// The session the next turn belongs to: the one that is open, or the
    /// draft a new chat made.
    pub fn turnSession(self: *AppState) ?[]const u8 {
        if (self.selected) |i| {
            if (i < self.sessions.items.len) return self.sessions.items[i].key;
        }
        if (self.draft_session.items.len > 0) return self.draft_session.items;
        return null;
    }
    pub fn openPage(self: *AppState, page: Page) void {
        self.page = page;
        // The settings menu is what the sidebar shows for every page but the
        // conversation, so opening a settings page swaps the sidebar to the
        // menu and opening chat swaps it back. One rule keeps the rail, the
        // brand menu and the mode tabs from disagreeing about where you are.
        self.settings_open = page != .chat;
        // A toast belongs to the page that produced it: a configuration
        // error would otherwise linger for six seconds on every page the
        // user opens after it.
        self.dismissToast();
        switch (page) {
            .chat => {},
            else => if (page.configBoard() != null) self.loadConfig() else self.runPage(),
        }
    }

    pub fn runPage(self: *AppState) void {
        if (self.json_running) return;

        // The prose pages whose answers the runtime already builds as
        // functions. They are quick file queries, safe to answer on this
        // frame; the slow ones (network, hardware) still go through the CLI.
        if (self.page == .auth) {
            const text = yc.page_json.authStatusText(self.gpa) catch null;
            if (text) |answer| {
                defer self.gpa.free(answer);
                self.setJsonProse(answer);
                return;
            }
        }

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

    fn answerInProcess(self: *AppState) ?[]u8 {
        // The pages that read the config load it here rather than borrowing
        // the runtime's: opening a page must not build a runtime, and a
        // window that has never run a turn still has a config on disk.
        return switch (self.page) {
            .capabilities, .models, .memory, .mcp, .skills, .channels, .workspace => blk: {
                var cfg = yc.config.Config.loadFromPath(self.gpa, self.paths.config) catch break :blk null;
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
                    // The audit walks the workspace, so it needs the path the
                    // config resolved rather than the one the window guessed.
                    .workspace => yc.workspace_audit.renderJsonReport(self.gpa, cfg.workspace_dir, .{
                        .workspace_dir = cfg.workspace_dir,
                    }) catch null,
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

    /// Shows a page's prose answer where the tree would go, without the red
    /// styling a failure gets: `auth status` and its neighbours answer in
    /// sentences, not JSON.
    pub fn setJsonProse(self: *AppState, text: []const u8) void {
        self.clearJson();
        self.clearExpanded();
        self.json_text = self.gpa.dupe(u8, text) catch &.{};
        var lines = backend.JsonLines{
            .gpa = self.gpa,
            .expanded = &self.json_expanded,
            .arena = std.heap.ArenaAllocator.init(self.gpa),
        };
        lines.problem = "prose";
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
            .workspace => backend.readWorkspaceAudit(self.gpa, text),
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

    /// Reads the two fields the gateway needs from the file, so the window
    /// serves the port the config names from its first frame. The whole
    /// document is loaded later, by the board that edits it.
    fn seedDaemonForm(self: *AppState) void {
        var doc = backend.ConfigDoc.load(self.gpa, self.io, self.paths.config) catch return;
        defer doc.deinit();
        if (doc.get("gateway.host")) |host| {
            if (host.len > 0) setBuf(&self.cfg_gateway_host, host);
        }
        if (doc.get("gateway.port")) |port| {
            if (port.len > 0) setBuf(&self.cfg_gateway_port, port);
        }
        if (doc.get("workspace")) |workspace| {
            if (workspace.len > 0) setBuf(&self.cfg_workspace, workspace);
        }
    }

    pub fn loadConfig(self: *AppState) void {
        if (self.config_running) return;
        self.config_running = true;
        // Cleared however this returns. The early return below — no file yet,
        // or unreadable — used to leave the flag set, and every control on the
        // page is disabled while it is: Save & restart and Apply greyed out,
        // the status line reading "reading the file on disk…", and Reload
        // stopped at this function's own guard. The page could not recover
        // without restarting the window.
        defer self.config_running = false;
        // The document is read from disk here; whether the runtime accepts it
        // is checked against the loaded config directly, not by spawning
        // `config validate`.
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
        self.showConfigDoc();
        // The chip names what the config now says, not what it said when the
        // window opened.
        self.loadDefaultModel();
        // Validation is a pure check on the loaded config; a rejection is
        // shown as the page's complaint rather than a spawned command's
        // stderr.
        var cfg = yc.config.Config.loadFromPath(self.gpa, self.paths.config) catch {
            self.loadConfigSummary();
            return;
        };
        defer cfg.deinit();
        cfg.validate() catch {
            self.loadConfigSummary();
            return;
        };
        self.loadConfigSummary();
    }

    /// Reads the two things the configuration page only summarises: the
    /// installed skills and the build's capabilities. Both are runtime state
    /// rather than config keys, so the page asks rather than reading the file.
    fn loadConfigSummary(self: *AppState) void {
        // Both are runtime state the runtime already exposes as functions, so
        // the page asks them in-process rather than spawning two commands.
        var cfg = yc.config.Config.loadFromPath(self.gpa, self.paths.config) catch return;
        defer cfg.deinit();
        if (yc.capabilities.buildManifestJson(self.gpa, &cfg, null) catch null) |caps_json| {
            defer self.gpa.free(caps_json);
            self.applyConfigSummary(caps_json);
        }
        if (yc.page_json.skillsList(self.gpa, &cfg) catch null) |skills_json| {
            defer self.gpa.free(skills_json);
            self.applyConfigSummary(skills_json);
        }
    }

    /// Folds one capabilities-or-skills document into the counts the config
    /// page shows. Shared by the in-process path and the spawned fallback.
    fn applyConfigSummary(self: *AppState, text: []const u8) void {
        // Which command this is, by what it returned: capabilities has
        // `channels`, skills is a bare list.
        var rows = if (std.mem.indexOf(u8, text, "\"channels\"") != null)
            backend.readCapabilities(self.gpa, text)
        else
            backend.readRecordList(self.gpa, text, "Skills");
        defer rows.deinit();
        if (rows.problem != null) return;

        if (std.mem.indexOf(u8, text, "\"channels\"") != null) {
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
    pub fn providerName(self: *const AppState) []const u8 {
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
            self.retireProviderOptions();
            self.cfg_default_provider = 0;
            return;
        };
        self.retireProviderOptions();
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

        // The model's own settings.
        setBuf(&self.cfg_temperature, doc.get("default_temperature") orelse "0.7");
        self.cfg_reasoning_effort = blk: {
            const v = doc.get("reasoning_effort") orelse "";
            for (reasoning_efforts, 0..) |name, i| {
                if (std.mem.eql(u8, name, v)) break :blk @as(?usize, i);
            }
            break :blk null;
        };

        // The agent loop.
        setBuf(&self.cfg_max_tool_iterations, doc.get("agent.max_tool_iterations") orelse "1000");
        setBuf(&self.cfg_max_history, doc.get("agent.max_history_messages") orelse "100");
        self.cfg_compact_context = std.ascii.eqlIgnoreCase(doc.get("agent.compact_context") orelse "false", "true");
        setBuf(&self.cfg_timezone, doc.get("agent.timezone") orelse "UTC");
        setBuf(&self.cfg_message_timeout, doc.get("agent.message_timeout_secs") orelse "600");

        // What the agent is allowed to do.
        self.cfg_workspace_only = std.ascii.eqlIgnoreCase(doc.get("autonomy.workspace_only") orelse "true", "true");
        setBuf(&self.cfg_max_actions, doc.get("autonomy.max_actions_per_hour") orelse "20");
        self.cfg_block_high_risk = std.ascii.eqlIgnoreCase(doc.get("autonomy.block_high_risk_commands") orelse "true", "true");
        self.cfg_approve_medium = std.ascii.eqlIgnoreCase(doc.get("autonomy.require_approval_for_medium_risk") orelse "true", "true");

        // Where it runs.
        self.cfg_runtime_kind = blk: {
            const v = doc.get("runtime.kind") orelse "native";
            for (runtime_kinds, 0..) |name, i| {
                if (std.mem.eql(u8, name, v)) break :blk i;
            }
            break :blk 0;
        };
        setBuf(&self.cfg_docker_image, doc.get("runtime.docker.image") orelse "alpine:3.24");

        // The gateway, memory search, the scheduler and what gets recorded.
        self.cfg_gateway_require_pairing = std.ascii.eqlIgnoreCase(doc.get("gateway.require_pairing") orelse "true", "true");
        self.cfg_memory_search = std.ascii.eqlIgnoreCase(doc.get("memory.search.enabled") orelse "true", "true");
        self.cfg_scheduler_enabled = std.ascii.eqlIgnoreCase(doc.get("scheduler.enabled") orelse "true", "true");
        setBuf(&self.cfg_scheduler_max_tasks, doc.get("scheduler.max_tasks") orelse "64");
        self.cfg_log_tool_calls = std.ascii.eqlIgnoreCase(doc.get("diagnostics.log_tool_calls") orelse "false", "true");
        self.cfg_log_llm_io = std.ascii.eqlIgnoreCase(doc.get("diagnostics.log_llm_io") orelse "false", "true");

        // Security: the backend is a name, so it becomes an index; a name the
        // list does not know leaves the select on `auto`, which is what the
        // runtime does with a backend it cannot build.
        {
            const name = doc.get("security.sandbox.backend") orelse "auto";
            self.cfg_sandbox_backend = 0;
            for (sandbox_backends, 0..) |known, i| {
                if (std.ascii.eqlIgnoreCase(known, name)) self.cfg_sandbox_backend = i;
            }
            self.cfg_sandbox_enabled = if (doc.get("security.sandbox.enabled")) |v|
                std.ascii.eqlIgnoreCase(v, "true")
            else
                null;
        }
        setBuf(&self.cfg_max_memory_mb, doc.get("security.resources.max_memory_mb") orelse "");
        setBuf(&self.cfg_max_cpu_seconds, doc.get("security.resources.max_cpu_time_seconds") orelse "");
        setBuf(&self.cfg_max_subprocesses, doc.get("security.resources.max_subprocesses") orelse "");
        self.cfg_memory_monitoring = std.ascii.eqlIgnoreCase(doc.get("security.resources.memory_monitoring") orelse "true", "true");
        self.cfg_audit_enabled = std.ascii.eqlIgnoreCase(doc.get("security.audit.enabled") orelse "true", "true");
        setBuf(&self.cfg_audit_log_path, doc.get("security.audit.log_path") orelse "audit.log");
        setBuf(&self.cfg_audit_max_size_mb, doc.get("security.audit.max_size_mb") orelse "100");
        self.cfg_audit_sign_events = std.ascii.eqlIgnoreCase(doc.get("security.audit.sign_events") orelse "false", "true");

        // Tools.
        setBuf(&self.cfg_shell_timeout_secs, doc.get("tools.shell_timeout_secs") orelse "60");
        setBuf(&self.cfg_shell_max_output_bytes, doc.get("tools.shell_max_output_bytes") orelse "");
        setBuf(&self.cfg_max_file_size_bytes, doc.get("tools.max_file_size_bytes") orelse "");
        setBuf(&self.cfg_web_fetch_max_chars, doc.get("tools.web_fetch_max_chars") orelse "");

        // Sessions.
        {
            const scope = doc.get("session.dm_scope") orelse "per_channel_peer";
            self.cfg_dm_scope = 2;
            for (dm_scopes, 0..) |known, i| {
                if (std.ascii.eqlIgnoreCase(known, scope)) self.cfg_dm_scope = i;
            }
        }
        setBuf(&self.cfg_session_idle_minutes, doc.get("session.idle_minutes") orelse "60");
        setBuf(&self.cfg_session_max_concurrent, doc.get("session.max_concurrent_tasks") orelse "4");
        setBuf(&self.cfg_claim_max_attempts, doc.get("session.claim_max_attempts") orelse "5");
        setBuf(&self.cfg_claim_lockout_secs, doc.get("session.claim_lockout_secs") orelse "300");
        setBuf(&self.cfg_typing_interval_secs, doc.get("session.typing_interval_secs") orelse "5");

        // Diagnostics: the backend that decides whether anything is recorded,
        // and the OpenTelemetry endpoint it records to.
        {
            const name = doc.get("diagnostics.backend") orelse "none";
            self.cfg_diagnostics_backend = 0;
            for (diagnostics_backends, 0..) |known, i| {
                if (std.ascii.eqlIgnoreCase(known, name)) self.cfg_diagnostics_backend = i;
            }
        }
        setBuf(&self.cfg_otel_endpoint, doc.get("diagnostics.otel_endpoint") orelse "");
        setBuf(&self.cfg_otel_service, doc.get("diagnostics.otel_service_name") orelse "nullclaw");
        setBuf(&self.cfg_api_error_max_chars, doc.get("diagnostics.api_error_max_chars") orelse "");

        // Logs.
        self.cfg_log_receipts = std.ascii.eqlIgnoreCase(doc.get("diagnostics.log_message_receipts") orelse "false", "true");
        self.cfg_log_payloads = std.ascii.eqlIgnoreCase(doc.get("diagnostics.log_message_payloads") orelse "false", "true");
        self.cfg_ledger_enabled = std.ascii.eqlIgnoreCase(doc.get("diagnostics.token_usage_ledger_enabled") orelse "true", "true");
        setBuf(&self.cfg_ledger_window_hours, doc.get("diagnostics.token_usage_ledger_window_hours") orelse "24");
        setBuf(&self.cfg_ledger_max_bytes, doc.get("diagnostics.token_usage_ledger_max_bytes") orelse "0");
        setBuf(&self.cfg_ledger_max_lines, doc.get("diagnostics.token_usage_ledger_max_lines") orelse "0");

        // Hardware.
        self.cfg_hardware_enabled = std.ascii.eqlIgnoreCase(doc.get("hardware.enabled") orelse "false", "true");
        {
            const name = doc.get("hardware.transport") orelse "none";
            self.cfg_hardware_transport = 0;
            for (hardware_transports, 0..) |known, i| {
                if (std.ascii.eqlIgnoreCase(known, name)) self.cfg_hardware_transport = i;
            }
        }
        setBuf(&self.cfg_hardware_serial_port, doc.get("hardware.serial_port") orelse "");
        setBuf(&self.cfg_hardware_baud_rate, doc.get("hardware.baud_rate") orelse "115200");
        setBuf(&self.cfg_hardware_probe_target, doc.get("hardware.probe_target") orelse "");
        self.cfg_hardware_datasheets = std.ascii.eqlIgnoreCase(doc.get("hardware.workspace_datasheets") orelse "false", "true");
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
        self.loadDefaultModel();
        // The file is validated in-process: the same Config the runtime
        // builds from disk is checked here, so a save is confirmed against
        // what the gateway will read when it restarts, without spawning a
        // `config validate` process that a linked window does not ship.
        var cfg = yc.config.Config.loadFromPath(self.gpa, self.paths.config) catch {
            self.restartDaemon();
            return;
        };
        defer cfg.deinit();
        cfg.validate() catch |err| {
            self.sayf("saved, but the runtime objects: {s}", .{@errorName(err)});
            self.restartDaemon();
            return;
        };
        self.say("configuration saved and valid");
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
        changed = self.applyAgentAndSafety(doc) or changed;
        return changed;
    }

    /// Writes the model, agent-loop, autonomy, runtime, gateway, memory-search,
    /// scheduler and diagnostics fields. Each is compared before it is written,
    /// so an Apply that changed nothing leaves the file alone.
    fn applyAgentAndSafety(self: *AppState, doc: *backend.ConfigDoc) bool {
        var changed = false;

        // A helper for the fields that are text in the form and may be a
        // number, a boolean or a string in the file: `setAuto` types them.
        const Fields = struct {
            fn text(d: *backend.ConfigDoc, path: []const u8, buf: *ui.TextBuffer, ch: *bool) void {
                const v = std.mem.trim(u8, buf.text(), " \t\r\n");
                if (v.len == 0) return;
                const now = d.get(path) orelse "";
                if (std.mem.eql(u8, now, v)) return;
                d.setAuto(path, v) catch return;
                ch.* = true;
            }
            /// `fallback` is what the runtime means when the key is absent —
            /// most flags default to false, but `workspace_only` and the
            /// approval flags default to true. Reading a missing key as false
            /// made those three look unchanged when they were turned off, so
            /// the file kept the old value.
            fn flag(d: *backend.ConfigDoc, path: []const u8, value: bool, fallback: bool, ch: *bool) void {
                const now = std.ascii.eqlIgnoreCase(d.get(path) orelse (if (fallback) "true" else "false"), "true");
                if (now == value) return;
                d.setBool(path, value) catch return;
                ch.* = true;
            }
        };

        // The model.
        Fields.text(doc, "default_temperature", &self.cfg_temperature, &changed);
        {
            const want: []const u8 = if (self.cfg_reasoning_effort) |i|
                reasoning_efforts[i % reasoning_efforts.len]
            else
                "";
            const now = doc.get("reasoning_effort") orelse "";
            if (!std.mem.eql(u8, now, want)) {
                doc.setString("reasoning_effort", want) catch {};
                changed = true;
            }
        }

        // The agent loop.
        Fields.text(doc, "agent.max_tool_iterations", &self.cfg_max_tool_iterations, &changed);
        Fields.text(doc, "agent.max_history_messages", &self.cfg_max_history, &changed);
        Fields.flag(doc, "agent.compact_context", self.cfg_compact_context, false, &changed);
        Fields.text(doc, "agent.timezone", &self.cfg_timezone, &changed);
        Fields.text(doc, "agent.message_timeout_secs", &self.cfg_message_timeout, &changed);

        // What the agent may do.
        Fields.flag(doc, "autonomy.workspace_only", self.cfg_workspace_only, true, &changed);
        Fields.text(doc, "autonomy.max_actions_per_hour", &self.cfg_max_actions, &changed);
        Fields.flag(doc, "autonomy.block_high_risk_commands", self.cfg_block_high_risk, true, &changed);
        Fields.flag(doc, "autonomy.require_approval_for_medium_risk", self.cfg_approve_medium, true, &changed);

        // Where it runs.
        {
            const want = runtime_kinds[self.cfg_runtime_kind % runtime_kinds.len];
            const now = doc.get("runtime.kind") orelse "native";
            if (!std.mem.eql(u8, now, want)) {
                doc.setString("runtime.kind", want) catch {};
                changed = true;
            }
        }
        Fields.text(doc, "runtime.docker.image", &self.cfg_docker_image, &changed);

        // The gateway, memory search, the scheduler, and what is recorded.
        Fields.flag(doc, "gateway.require_pairing", self.cfg_gateway_require_pairing, true, &changed);
        Fields.flag(doc, "memory.search.enabled", self.cfg_memory_search, true, &changed);
        Fields.flag(doc, "scheduler.enabled", self.cfg_scheduler_enabled, true, &changed);
        Fields.text(doc, "scheduler.max_tasks", &self.cfg_scheduler_max_tasks, &changed);
        Fields.flag(doc, "diagnostics.log_tool_calls", self.cfg_log_tool_calls, false, &changed);
        Fields.flag(doc, "diagnostics.log_llm_io", self.cfg_log_llm_io, false, &changed);

        // Security. `sandbox.enabled` is written only when it was asked for:
        // the key being absent is the runtime's own "let the backend decide".
        {
            const want = if (self.cfg_sandbox_backend < sandbox_backends.len) sandbox_backends[self.cfg_sandbox_backend] else "auto";
            const now = doc.get("security.sandbox.backend") orelse "";
            if (!std.mem.eql(u8, now, want)) {
                doc.setString("security.sandbox.backend", want) catch {};
                changed = true;
            }
            if (self.cfg_sandbox_enabled) |on| {
                Fields.flag(doc, "security.sandbox.enabled", on, false, &changed);
            }
        }
        Fields.text(doc, "security.resources.max_memory_mb", &self.cfg_max_memory_mb, &changed);
        Fields.text(doc, "security.resources.max_cpu_time_seconds", &self.cfg_max_cpu_seconds, &changed);
        Fields.text(doc, "security.resources.max_subprocesses", &self.cfg_max_subprocesses, &changed);
        Fields.flag(doc, "security.resources.memory_monitoring", self.cfg_memory_monitoring, true, &changed);
        Fields.flag(doc, "security.audit.enabled", self.cfg_audit_enabled, true, &changed);
        Fields.text(doc, "security.audit.log_path", &self.cfg_audit_log_path, &changed);
        Fields.text(doc, "security.audit.max_size_mb", &self.cfg_audit_max_size_mb, &changed);
        Fields.flag(doc, "security.audit.sign_events", self.cfg_audit_sign_events, false, &changed);

        // Tools.
        Fields.text(doc, "tools.shell_timeout_secs", &self.cfg_shell_timeout_secs, &changed);
        Fields.text(doc, "tools.shell_max_output_bytes", &self.cfg_shell_max_output_bytes, &changed);
        Fields.text(doc, "tools.max_file_size_bytes", &self.cfg_max_file_size_bytes, &changed);
        Fields.text(doc, "tools.web_fetch_max_chars", &self.cfg_web_fetch_max_chars, &changed);

        // Sessions.
        {
            const want = if (self.cfg_dm_scope < dm_scopes.len) dm_scopes[self.cfg_dm_scope] else "per_channel_peer";
            const now = doc.get("session.dm_scope") orelse "";
            if (!std.mem.eql(u8, now, want)) {
                doc.setString("session.dm_scope", want) catch {};
                changed = true;
            }
        }
        Fields.text(doc, "session.idle_minutes", &self.cfg_session_idle_minutes, &changed);
        Fields.text(doc, "session.max_concurrent_tasks", &self.cfg_session_max_concurrent, &changed);
        Fields.text(doc, "session.claim_max_attempts", &self.cfg_claim_max_attempts, &changed);
        Fields.text(doc, "session.claim_lockout_secs", &self.cfg_claim_lockout_secs, &changed);
        Fields.text(doc, "session.typing_interval_secs", &self.cfg_typing_interval_secs, &changed);

        // Diagnostics.
        {
            const want = if (self.cfg_diagnostics_backend < diagnostics_backends.len)
                diagnostics_backends[self.cfg_diagnostics_backend]
            else
                "none";
            const now = doc.get("diagnostics.backend") orelse "";
            if (!std.mem.eql(u8, now, want)) {
                doc.setString("diagnostics.backend", want) catch {};
                changed = true;
            }
        }
        Fields.text(doc, "diagnostics.otel_endpoint", &self.cfg_otel_endpoint, &changed);
        Fields.text(doc, "diagnostics.otel_service_name", &self.cfg_otel_service, &changed);
        Fields.text(doc, "diagnostics.api_error_max_chars", &self.cfg_api_error_max_chars, &changed);

        // Logs.
        Fields.flag(doc, "diagnostics.log_message_receipts", self.cfg_log_receipts, false, &changed);
        Fields.flag(doc, "diagnostics.log_message_payloads", self.cfg_log_payloads, false, &changed);
        Fields.flag(doc, "diagnostics.token_usage_ledger_enabled", self.cfg_ledger_enabled, true, &changed);
        Fields.text(doc, "diagnostics.token_usage_ledger_window_hours", &self.cfg_ledger_window_hours, &changed);
        Fields.text(doc, "diagnostics.token_usage_ledger_max_bytes", &self.cfg_ledger_max_bytes, &changed);
        Fields.text(doc, "diagnostics.token_usage_ledger_max_lines", &self.cfg_ledger_max_lines, &changed);

        // Hardware.
        Fields.flag(doc, "hardware.enabled", self.cfg_hardware_enabled, false, &changed);
        {
            const want = if (self.cfg_hardware_transport < hardware_transports.len) hardware_transports[self.cfg_hardware_transport] else "none";
            const now = doc.get("hardware.transport") orelse "";
            if (!std.mem.eql(u8, now, want)) {
                doc.setString("hardware.transport", want) catch {};
                changed = true;
            }
        }
        Fields.text(doc, "hardware.serial_port", &self.cfg_hardware_serial_port, &changed);
        Fields.text(doc, "hardware.baud_rate", &self.cfg_hardware_baud_rate, &changed);
        Fields.text(doc, "hardware.probe_target", &self.cfg_hardware_probe_target, &changed);
        Fields.flag(doc, "hardware.workspace_datasheets", self.cfg_hardware_datasheets, false, &changed);

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

    /// Reads the default model out of the config file, so the composer can
    /// name it. One read at startup and one per save, not one per frame: the
    /// chip is drawn on every frame the chat is open.
    fn loadDefaultModel(self: *AppState) void {
        self.retire(self.default_model);
        self.default_model = &.{};
        var doc = backend.ConfigDoc.load(self.gpa, self.io, self.paths.config) catch return;
        defer doc.deinit();
        const primary = doc.get("agents.defaults.model.primary") orelse return;
        const model = std.mem.trim(u8, primary, " \t\r\n");
        if (model.len == 0) return;
        self.default_model = self.gpa.dupe(u8, model) catch &.{};
    }

    /// The model the composer's chip names. Empty when the config names none,
    /// which is the chip's cue to stay out of the way.
    pub fn modelLabel(self: *const AppState) []const u8 {
        return self.default_model;
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
            // Chat is the agent itself rather than a command, and a board is
            // read from the config file in process.
            try testing.expect(p == .chat or p.configBoard() != null);
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
    };
    defer {
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
    };
    defer {
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
