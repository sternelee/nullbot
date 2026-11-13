# nullclaw-gui

A desktop window for [NullClaw](../../README.md): the session list, the
conversation, the composer, and a page for each thing the runtime can tell you
about itself.

It is a separate binary from `nullclaw`: the window links
[nanoui](https://github.com/justrach/nanoui) and drives `nullclaw` as a child
process, rather than linking the runtime into the GUI. Keeping them separate
lets the two evolve independently; the GUI reads `~/.nullclaw/config.json`
directly and otherwise talks to the runtime through its CLI. Both now build
with **Zig 0.17.0**.

## Build and run

```sh
cd gui
zig build            # builds zig-out/bin/nullclaw-gui
zig build run        # builds and opens the window
zig build test       # 67 tests, headless
zig build shots      # renders the window's screens to /tmp/nullclaw-gui-shots
```

`nullclaw` must be on `PATH` for anything but the empty state to work; without
it each page says so and the conversation shows what the runtime said when it
could not be started. `NULLCLAW_BIN` points the window at a different binary —
a build from a checkout, say. An empty value counts as unset.

The tests do not need a runtime installed: `src/tests.zig` writes a stub
`nullclaw` that answers the commands the window runs, and drives the real view
against it, so the argv, the spawn, the JSON, the state and the drawing are all
exercised end to end.

## What it looks like

`zig build shots` writes PNGs of the real window, drawn by the same view code
the app runs:

| File | Screen |
| --- | --- |
| `01-chat-empty.png` | A new conversation, with the opening suggestions |
| `02-chat-markdown.png` | A reply, with headings, code, lists and quotes |
| `03-config.png` | The configuration page: runtime card, then Provider, Workspace, MCP servers, Cron, Skills and Capabilities |
| `04-models.png` | The models summary, one row per key |
| `05-expanded.png` | The same page with every key opened |
| `06-complaint.png` | The same page when the runtime answers nothing: its complaint is on the page |
| `07-diagnostics.png` | The diagnostics panel over the chat: runtime, paths, session, theme |
| `08-capabilities.png` | Capabilities as a list: channels, memory engines and tools, each with its state |
| `09-empty.png` | A page whose command answered with nothing: what is missing, and the command that adds it |
| `10-config-full.png` | The configuration page in a tall window, so every section is visible at once |

The shots are taken through the same path the app uses — a runtime answering
from a process, and a config file on disk — rather than by handing the pages
JSON to draw. A shot that comes out empty is therefore a page that really is
empty.

## The pages, and what they run

Every page is one of the runtime's own commands, with `--json` where the
runtime takes it. `src/contract.zig` reads `../src/main.zig` and fails if any of
this drifts: the command names are checked against the runtime's usage block,
the subcommands against its `*_SUBCOMMANDS` constants, and the `--json` column
against its own usage text. It also pins the shapes, not just the names: for
each emitter the window parses (`appendHistoryListJson`, `appendHistoryShowJson`,
`appendAgentSessionListJson`, `appendAgentInvokeResponseJson`, `appendJsonError`)
it asserts the key names the parser looks for are still written there. The two
binaries are built from one repository, so the test can read the runtime's source
even though it cannot build it here.

| Page | Command |
| --- | --- |
| Chat | `agent invoke --message … [--session …] --json` |
| Configuration | `config validate --json`, plus `~/.nullclaw/config.json` read and written directly |
| Status | `status --json` |
| Capabilities | `capabilities --json` |
| Models | `models summary --json` |
| Memory | `memory stats --json` |
| Skills | `skills list --json` |
| Channels | `channel list --json` |
| Cron | `cron list --json` |
| MCP servers | `mcp list --json` |
| Workspace | `workspace audit --json` |
| Doctor | `doctor --json` |
| Auth | `auth status openai-codex` |
| Hardware | `hardware scan` |
| Service | `service status` |
| Update | `update --check` |

A page that knows the shape of its answer draws it as a list — one group per
kind of thing, one row per record, with its state at the right edge — and
falls back to the JSON tree when the answer does not fit. Capabilities,
Models, Memory, Skills, Channels, Cron and MCP servers have readers; the rest
draw the tree.

The four without `--json` print prose; those pages show the prose rather than
rows. Session history comes from `agent sessions list --json` and
`history show <key> --json` — the runtime has no HTTP API for conversations, so
the window talks to the CLI.

## The files

| File | What it holds |
| --- | --- |
| `src/main.zig` | `App` and the window, and nothing else |
| `src/state.zig` | `AppState`: sessions, transcript, pages, config editing, and every action |
| `src/view.zig` | The drawing: sidebar, transcript, composer, JSON rows, toasts |
| `src/backend.zig` | The runtime's side: argv builders, the JSON it returns, its readers, `config.json` |
| `src/runtime.zig` | Running `nullclaw` off the UI thread and folding results back in |
| `src/md.zig` | The little markdown reader the transcript draws with |
| `src/theme.zig` | Six palettes, mapped onto nanoui's theme |
| `src/harness.zig` | A window driven headlessly, for the tests |
| `src/tests.zig` | What the window must draw, and where |
| `src/contract.zig` | The check that keeps the pages aligned with the runtime |
| `src/shot.zig` | The screenshots `zig build shots` writes |

### How a command runs

`nullclaw agent -m …` can take a while, so nothing blocks the UI thread. A page
action builds an argv and hands it to `runtime.Executor`, which spawns a thread
per command (`std.process.run`); the view calls `AppState.pump()` at the top of
every frame, and that is where finished commands are folded back into the state.
A page action can start another command from inside its own handler, which is
how sending a message refreshes the session list.

## What is deliberately not a page

Four of the runtime's commands have no page, on purpose:

| Command | Why not |
| --- | --- |
| `onboard` | An interactive terminal wizard. The window cannot answer its prompts, so when there is no config the Configuration page says so and names the command to run. |
| `gateway`, `acp` | Long-running servers. A window that talks to the runtime should not start one behind your back. |
| `migrate` | Imports another runtime's memory into this one. It rewrites stored data, so it stays a command you run on purpose. |

`version` and `help` are not pages either: Doctor reports which runtime is on
the other end, and the runtime's own `--help` is a terminal's job.

## Known limits

- `nullclaw` is not bundled and not built here; the window needs one on `PATH`.
  The one on this machine's `PATH` is **2026.4.9**, which predates the release
  this checkout is (`2026.5.29`) and has drifted: `config validate` and
  `models summary` do not exist in it, `agent sessions list --json` drops into
  the interactive agent, and `status --json` prints prose. Against that binary
  most pages show a complaint toast rather than rows, which is drift, not a
  window defect — but it does mean no page has been watched rendering a real
  runtime's output.
- Alignment is therefore checked against the runtime's **source**, not against a
  running binary: `src/contract.zig` reads `../src/main.zig` for the command
  surface, the `--json` support and the JSON shapes, and `zig build shots` drives
  a stub that replays those shapes. Both binaries now build with Zig 0.17.0,
  but the GUI deliberately stays a separate process so it does not link the
  runtime.
- The sidebar and transcript need a session store, and the store is only present
  with the sqlite memory backend — `HistoryStoreContext.init` returns
  `error.SessionStoreUnavailable` otherwise (`src/memory/root.zig:2074`). With
  the markdown backend the sidebar degrades to a toast.
- The Auth page checks the `openai-codex` provider — the runtime's `auth status`
  takes a provider, and `weixin` is the other one it knows.
- Workspace audit and hardware scan are shown as prose because they have no
  `--json`.
- The window is macOS-shaped: nanoui links AppKit/WebKit/Metal, and the tests
  run on macOS and Linux.
