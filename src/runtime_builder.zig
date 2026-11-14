//! A runtime assembled in-process, for callers that are not the CLI.
//!
//! `nullclaw agent` builds an agent out of a config, a provider, a tool set, a
//! memory backend and an observer, then runs one turn. That assembly lived in
//! `agent/cli.zig`, tangled with argument parsing and stdout, so a program that
//! wanted to run a turn had to spawn the CLI and read its output.
//!
//! This is the same assembly with no terminal in it: `init` builds the pieces,
//! `turn` runs one message, `deinit` frees them. The CLI keeps its own path for
//! now; the desktop window uses this one, so a turn is a function call rather
//! than a subprocess.
const std = @import("std");
const Config = @import("config.zig").Config;
const providers = @import("providers/root.zig");
const Provider = providers.Provider;
const tools_mod = @import("tools/root.zig");
const Tool = tools_mod.Tool;
const memory_mod = @import("memory/root.zig");
const Memory = memory_mod.Memory;
const bootstrap_mod = @import("bootstrap/root.zig");
const observability = @import("observability.zig");
const Observer = observability.Observer;
const subagent_mod = @import("subagent.zig");
const subagent_runner = @import("subagent_runner.zig");
const security = @import("security/policy.zig");
const onboard = @import("onboard.zig");
const Agent = @import("agent/root.zig").Agent;

pub const Error = error{
    /// The config names no model, so there is nothing to ask.
    NoDefaultModel,
    /// The config's provider could not be built: a missing key, an unknown id.
    ProviderUnavailable,
};

/// Everything a turn needs, owned by this struct.
pub const Runtime = struct {
    allocator: std.mem.Allocator,
    config: Config,
    /// The provider bundle, kept alive for as long as the agent holds a
    /// provider interface into it.
    provider_bundle: ?providers.runtime_bundle.RuntimeProviderBundle = null,
    observer: *observability.RuntimeObserver,
    policy: security.SecurityPolicy,
    tracker: security.RateTracker,
    subagent_manager: subagent_mod.SubagentManager,
    /// The memory runtime, held by value so its address stays valid for as
    /// long as the runtime lives. `agent.mem_rt` and the memory tools point
    /// at this field, not at a local in `init`: a pointer to a local dangles
    /// the moment `init` returns, and the first turn then reads a freed
    /// stack slot as if it were the outbox handle.
    mem_rt_storage: ?memory_mod.MemoryRuntime = null,
    mem_rt: ?*memory_mod.MemoryRuntime = null,
    /// The bootstrap provider the tools were built with, freed with them.
    bootstrap_provider: ?bootstrap_mod.BootstrapProvider = null,
    tools: []const Tool = &.{},
    agent: Agent,
    /// Where turns are remembered. Owned by `mem_rt` when there is one.
    session_store: ?memory_mod.SessionStore = null,
    response_cache: ?*memory_mod.cache.ResponseCache = null,

    /// Builds a runtime from the config on disk. The caller owns it and must
    /// call `deinit`.
    pub fn init(allocator: std.mem.Allocator) !Runtime {
        var cfg = try Config.load(allocator);
        errdefer cfg.deinit();

        if (cfg.default_model == null) return Error.NoDefaultModel;

        var observer = try observability.RuntimeObserver.create(
            allocator,
            .{
                .workspace_dir = cfg.workspace_dir,
                .backend = cfg.diagnostics.backend,
                .otel_endpoint = cfg.diagnostics.otel_endpoint,
                .otel_service_name = cfg.diagnostics.otel_service_name,
            },
            cfg.diagnostics.otel_headers,
            &.{},
        );
        errdefer observer.destroy();

        var tracker = security.RateTracker.init(allocator, cfg.autonomy.max_actions_per_hour);
        errdefer tracker.deinit();

        var policy = security.SecurityPolicy{
            .autonomy = cfg.autonomy.level,
            .workspace_dir = cfg.workspace_dir,
            .workspace_only = cfg.autonomy.workspace_only,
            .allowed_commands = security.resolveAllowedCommands(cfg.autonomy.level, cfg.autonomy.allowed_commands),
            .max_actions_per_hour = cfg.autonomy.max_actions_per_hour,
            .require_approval_for_medium_risk = cfg.autonomy.require_approval_for_medium_risk,
            .block_high_risk_commands = cfg.autonomy.block_high_risk_commands,
            .block_medium_risk_commands = cfg.autonomy.block_medium_risk_commands,
            .allow_raw_url_chars = cfg.autonomy.allow_raw_url_chars,
            .tracker = &tracker,
        };

        var provider_bundle = providers.runtime_bundle.RuntimeProviderBundle.init(allocator, &cfg) catch
            return Error.ProviderUnavailable;
        errdefer provider_bundle.deinit();
        const provider_i = provider_bundle.provider();
        const resolved_api_key = provider_bundle.primaryApiKey();

        var subagent_manager = subagent_mod.SubagentManager.init(allocator, &cfg, null, .{});
        subagent_manager.observer = observer.backendObserver();
        subagent_manager.task_runner = subagent_runner.runTaskWithTools;
        errdefer subagent_manager.deinit();

        // Memory is optional: a config with no backend still runs turns, it
        // just cannot remember them.
        var mem_rt = memory_mod.initRuntime(allocator, &cfg.memory, cfg.workspace_dir);
        errdefer if (mem_rt) |*rt| rt.deinit();
        const mem_opt: ?Memory = if (mem_rt) |rt| rt.memory else null;

        const bootstrap_provider: ?bootstrap_mod.BootstrapProvider = bootstrap_mod.createProvider(
            allocator,
            cfg.memory.backend,
            mem_opt,
            cfg.workspace_dir,
        ) catch null;
        errdefer if (bootstrap_provider) |bp| bp.deinit();

        // The workspace files the prompt expects. A no-op once they exist.
        onboard.scaffoldWorkspace(
            allocator,
            cfg.workspace_dir,
            &onboard.ProjectContext{},
            bootstrap_provider,
        ) catch {};

        const tools = try tools_mod.allTools(allocator, cfg.workspace_dir, .{
            .http_enabled = cfg.http_request.enabled,
            .http_allowed_domains = cfg.http_request.allowed_domains,
            .http_max_response_size = cfg.http_request.max_response_size,
            .http_timeout_secs = cfg.http_request.timeout_secs,
            .web_search_base_url = cfg.http_request.search_base_url,
            .web_search_provider = cfg.http_request.search_provider,
            .web_search_fallback_providers = cfg.http_request.search_fallback_providers,
            .browser_enabled = cfg.browser.enabled,
            .screenshot_enabled = true,
            .mcp_server_configs = cfg.mcp_servers,
            .agents = cfg.agents,
            .configured_providers = cfg.providers,
            .fallback_api_key = resolved_api_key,
            .tools_config = cfg.tools,
            .allowed_paths = cfg.autonomy.allowed_paths,
            .policy = &policy,
            .subagent_manager = &subagent_manager,
            .bootstrap_provider = bootstrap_provider,
            .backend_name = cfg.memory.backend,
            .sandbox_backend = cfg.security.sandbox.backend,
            .sandbox_enabled = cfg.sandboxEnabled(),
        });
        errdefer tools_mod.deinitTools(allocator, tools);

        tools_mod.bindMemoryTools(tools, mem_opt);
        if (mem_rt) |*rt| tools_mod.bindMemoryRuntime(tools, rt);

        var agent = try Agent.fromConfig(allocator, &cfg, provider_i, tools, mem_opt, observer.observer());
        errdefer agent.deinit();
        agent.policy = &policy;

        // The runtime is assembled here and moved into the struct below, so
        // the pointers into it are set after the move, from the caller's own
        // copy. Setting them here would point at this frame.
        const built = Runtime{
            .allocator = allocator,
            .config = cfg,
            .provider_bundle = provider_bundle,
            .observer = observer,
            .policy = policy,
            .tracker = tracker,
            .subagent_manager = subagent_manager,
            .mem_rt_storage = mem_rt,
            .bootstrap_provider = bootstrap_provider,
            .tools = tools,
            .agent = agent,
            .session_store = if (mem_rt) |rt| rt.session_store else null,
            .response_cache = if (mem_rt) |*rt| rt.response_cache else null,
        };
        return built;
    }

    /// Points the agent and the memory tools at this struct's own field.
    ///
    /// The caller must call this once the runtime sits at the address it will
    /// keep: `init` returns by value, so a pointer taken inside it aims at a
    /// frame that is gone by the time a turn runs. `init` deliberately does
    /// not call it for that reason.
    pub fn wireMemory(self: *Runtime) void {
        if (self.mem_rt_storage) |*rt| {
            self.mem_rt = rt;
            self.agent.mem_rt = rt;
            tools_mod.bindMemoryRuntime(self.tools, rt);
        } else {
            self.mem_rt = null;
            self.agent.mem_rt = null;
        }
    }

    /// Runs one message and returns the reply. The caller owns the slice.
    pub fn turn(self: *Runtime, message: []const u8) ![]const u8 {
        return self.agent.turn(message);
    }

    /// Points the next turns at a session, so they share history.
    pub fn useSession(self: *Runtime, key: []const u8) void {
        self.agent.memory_session_id = key;
    }

    pub fn deinit(self: *Runtime) void {
        self.agent.deinit();
        tools_mod.deinitTools(self.allocator, self.tools);
        if (self.bootstrap_provider) |bp| bp.deinit();
        if (self.mem_rt) |rt| rt.deinit();
        self.subagent_manager.deinit();
        if (self.provider_bundle) |*b| b.deinit();
        self.tracker.deinit();
        self.observer.destroy();
        self.config.deinit();
    }
};
