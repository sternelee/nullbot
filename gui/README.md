# nullclaw-gui

A desktop window for [NullClaw](../../README.md): the session list, the
conversation, the composer, and a page for each thing the runtime can tell you
about itself.

The window links the runtime. `nullclaw` is a module here, not a program the
window goes looking for: `src/runtime_builder.zig` assembles a config, a
provider, a tool set and a memory backend into a `Runtime`, and a chat turn is
`Runtime.turn(message)` on its own thread. There is no subprocess and no JSON to
parse back for chat, the gateway or most data pages — `zig build` produces one
binary that is the whole window.

A turn streams. `Agent` already had the hook — `stream_callback` plus
`stream_ctx`, and `turn()` switches to `streamChat` when they are set — so the
window sets them and reads the deltas at the top of each frame. The answer is
drawn as it is written, with a caret, and the composer's button becomes stop
while a turn runs. Stopping abandons the turn rather than cancelling the
provider request: a request in flight cannot be interrupted from here, so what
it still writes is dropped and the reply is not shown.

A new chat gets its own session key. Without one every turn landed in the
same session, which is why "New chat" used to reopen the transcript it was
supposed to leave behind.

The session list and the transcript come from the linked runtime's own session
store, and the configuration page reads and writes `~/.nullclaw/config.json`
directly and validates it in process. The data pages are answered the same way:
`src/page_json.zig` builds the JSON those pages show — models, memory, skills,
channels, cron — from the same sources the CLI reads; `capabilities`, `status`,
`doctor`, `mcp` and `workspace_audit` already exposed theirs. Those pages
therefore answer with no runtime on disk at all. Only three pages still spawn a
process — `hardware`, `service` and `update` — and they fall back to `PATH` when
no runtime is beside the window.

Both build with **Zig 0.17.0**.

## Build and run

```sh
cd gui
zig build            # builds zig-out/bin/nullclaw-gui
zig build run        # builds and opens the window
zig build test       # 177 tests, headless
zig build shots      # renders the window's screens to /tmp/nullclaw-gui-shots
```

Chat, the gateway and most data pages need nothing installed: the runtime is
linked in and answers them from the same binary. The three pages that still
shell out (`hardware`, `service`, `update`) look for a `nullclaw` in this order:
`$NULLCLAW_BIN` (a stub or a checkout build; an empty value counts as unset), a
`nullclaw` beside the window binary, then `PATH`.

## Package for macOS

```sh
cd gui
sh macos/package.sh                                  # version from `git describe`
VERSION=0.2.0 sh macos/package.sh                     # or say it
```

That builds `NullClaw.app` and `NullClaw-macos-arm64.dmg` in `zig-out/package`,
with the sha256 of the image beside it. The bundle holds one binary — the window
links the runtime, so there is nothing to install next to it — plus its icon and
the plist that names them.

- The build targets `aarch64-macos.13.0` with `apple_m1`, and the script checks
  the result with `vtool`: a cached artifact for another system would otherwise
  ship under a plist that claims otherwise.
- `macos/make-icon.sh` draws `macos/AppIcon.icns` from the repo's own
  `nullclaw.png` with `sips` and `iconutil`; the script runs it when the picture
  is newer than the icon. `pngquant`, when installed, takes the icon from about
  1.5 MB to about 60 KB.
- Signing is ad hoc by default. Set `CODESIGN_IDENTITY` to a Developer ID
  Application identity to sign properly, and `NOTARY_PROFILE` (a profile saved
  with `xcrun notarytool store-credentials`) or `NOTARY_KEY_PATH` /
  `NOTARY_KEY_ID` / `NOTARY_ISSUER_ID` to notarize and staple both the app and
  the image.

The tests do not need a runtime installed either: `src/harness.zig` writes a stub
`nullclaw` that answers the commands those pages run, and drives the real view
against it, so the argv, the spawn, the JSON, the state and the drawing are all
exercised end to end. The in-process pages are covered by driving the linked
runtime itself.

## What it looks like

`zig build shots` writes PNGs of the real window, drawn by the same view code
the app runs:

| File | Screen |
| --- | --- |
| `01-chat-empty.png` | A new conversation, with the opening suggestions |
| `01b-brand-menu.png` | The "nullclaw ⌄" menu: every non-chat page, including Configuration |
| `01c-theme-menu.png` | The palette menu hung off the footer's palette button |
| `02-chat-markdown.png` | A reply, with headings, code, lists and quotes |
| `02b-chat-table.png` | A table with per-column alignment, a nested checklist and a footnote |
| `02c-chat-wide-table.png` | A table too wide for the column: it scrolls sideways, and a note carries the way back |
| `02d-chat-math-task-image.png` | An inline formula, a checklist with its boxes, and a picture from a path |
| `02e-chat-headings.png` | Six heading ranks, and a long code block folded behind its count |
| `02f-chat-quote-list-rule.png` | A quoted passage as one tinted block, a break, and a numbered list whose numbers share a gutter |
| `03-config.png` | The Model board: the settings menu is the list of boards, and the action bar is pinned |
| `04-models.png` | The models summary, one row per key |
| `05-expanded.png` | The Status page's JSON tree with every key opened |
| `06-complaint.png` | A page when the runtime answers nothing: its complaint is on the page |
| `07-diagnostics.png` | The diagnostics panel over the chat: runtime, paths, session, theme |
| `08-capabilities.png` | Capabilities as a list: channels, memory engines and tools, each with its state |
| `09-empty.png` | A page whose command answered with nothing: what is missing, and the command that adds it |
| `10-config-full.png` | The Agent board in a tall window, so its whole card fits under the pinned bar |
| `11-workspace.png` | The workspace audit: findings grouped by severity, each with its rule and `path:line` |
| `12-streaming.png` | An answer mid-flight: the bubble being written, the caret, and the composer offering to stop |

The shots are taken through the same path the app uses — a runtime answering
from a process, and a config file on disk — rather than by handing the pages
JSON to draw. A shot that comes out empty is therefore a page that really is
empty.

## The layout

- **Rail** (the 52pt strip at the far left): a new chat, then the three page
  destinations — Chat, Workspace and Settings. The page you are on keeps its
  button lit.
- **Sidebar**: the conversation list by default — the "nullclaw ⌄" brand menu
  (every non-chat page, including the configuration editor), a search field with
  **Compact / Detailed** and **Grouped / Flat** toggles, the session list grouped
  by recency (Today / Yesterday / Previous 7 days / Older), and the footer with
  the account row and the palette switcher. Rows carry a status dot, an optional
  project monogram, the session key, a stamp and a hover slot to archive, drawn
  in the design system's spacing and colours (`src/design.zig`). Pressing the
  rail's Settings button swaps this for the **settings menu**: a header with a
  back button, a **Search settings** field that filters the pages by label and
  keyword, then every settings page grouped Workspace / Runtime / System (a
  query flattens the menu and shows each match with its group). Opening a
  settings page shows the menu; opening the conversation shows the list.
- **Body**: a header with the page title and the chat / work mode tabs, the
  page itself, and a banner for the current toast.

The composer completes as you type: `@` offers workspace files and `/` offers
the runtime's slash commands, filtered by what follows. Up and Down move
through the list, Return or Tab takes a candidate, Escape closes it, and
taking one does not also send the message.

The configuration is not one page. Each board is a row of the settings menu —
Model, Workspace, Agent, Autonomy, Memory, Runtime server, Runtime, Gateway, MCP
servers, Schedules, Reliability, Diagnostics and Advanced — so the menu is the
only list of them: a page with a second list of decisions inside it, folded or
otherwise, was two menus for one choice. A board's page is that board: its
sentence, its card, and the pinned action bar (Save & restart, Apply and
Reload). There is no raw JSON tree anywhere, because the boards read the file
and set it. Advanced keeps the one control the boards cannot offer: a dotted
path typed by hand.

The markdown an agent writes is drawn, not echoed: headings at six ranks (each a
size, a weight and its own leading), lists (nested, numbered, and `- [x]`
checkboxes), tables with their columns aligned by the
separator's colons, sized to their content, striped on alternate rows so one
can be followed across, and scrolling sideways when they outgrow the column, `<br>` hard breaks, quotations that are one tinted block
with an edge down their left side — one edge per level of nesting, the
outermost faintest — thematic breaks that keep air only where there is
something to separate, ordered lists whose numbers are right-aligned in a
gutter so `9.` and `10.` do not step the text out of line, code highlighted
by the language its fence names (comments, strings, numbers, keywords, types,
constants and calls, in colours mixed from the palette so every theme
highlights in its own terms) and folded after fourteen lines behind a
control that counts what is hidden, so one file's worth of code does not
bury the message under it, footnotes (`[^label]`, numbered by where they
are first cited, drawn as an accent badge at the reference, with the note
under the reply and a way back to the sentence itself), inline code on a tinted pill, emphasis that nests
(`***both***` is bold and italic at once, `**bold with *italic* inside**`
keeps its weight), strikethrough, inline mathematics (`$x^2$`, set in
italics with the few TeX shapes a chat uses folded into Unicode: `x^2`
becomes `x²`, `\alpha` becomes `α`), checklists that draw a real box per item
and fill it when the item is done, striking the finished ones through, pictures (`![alt](path)` on a line of its
own, decoded from disk and drawn under its caption — and a picture that
cannot be drawn keeps its place as a dashed frame naming the alt text and the
reason, which is how a remote one reads, since a frame may not wait on the
network), and links — `[label](url)`, `<url>`, and the bare URLs, `www.`
hosts and email addresses GFM links on its own, drawn underlined in the
theme's link colour. A link opens in the browser; a footnote reference jumps
to the note under the reply.

## The pages, and what they run

Most pages are answered from the linked runtime in process, so they need no
runtime on disk. `src/contract.zig` reads `../src/main.zig` and fails if the
command surface drifts: the command names are checked against the runtime's
usage block, the subcommands against its `*_SUBCOMMANDS` constants, and the
`--json` column against its own usage text. It also pins the shapes, not just
the names: for each emitter the window parses (`appendHistoryListJson`,
`appendHistoryShowJson`, `appendAgentSessionListJson`,
`appendAgentInvokeResponseJson`, `appendJsonError`) it asserts the key names the
parser looks for are still written there.

| Page | How it answers |
| --- | --- |
| Chat | `Runtime.turn(message)` on its own thread, streamed |
| Configuration | `~/.nullclaw/config.json` read and written directly, validated with the runtime's own `Config` |
| Status | runtime's `buildRuntimeStatusJson`, in process |
| Capabilities | runtime's `buildManifestJson`, in process |
| Models | `page_json.modelsSummary`, in process |
| Memory | `page_json.memoryStats`, in process |
| Skills | `page_json.skillsList`, in process |
| Channels | `page_json.channelList`, in process |
| Cron | `page_json.cronList`, in process |
| MCP servers | `mcp_admin.buildServersJson`, in process |
| Workspace | `workspace_audit.renderJsonReport`, in process |
| Doctor | runtime's `buildDoctorJson`, in process |
| Auth | `page_json.authStatusText`, in process (prose) |
| Hardware | `hardware scan`, spawned |
| Service | `service status`, spawned |
| Update | `update --check`, spawned |

A page that knows the shape of its answer draws it as a list — one group per
kind of thing, one row per record, with its state at the right edge — and
falls back to the JSON tree when the answer does not fit. Capabilities, Models,
Memory, Skills, Channels, Cron, MCP servers and Workspace have readers; the rest
draw the tree.

The four without `--json` print prose; those pages show the prose rather than
rows. Session history comes from the linked runtime's session store — the
runtime has no HTTP API for conversations, so the window queries the store
directly.

## The files

| File | What it holds |
| --- | --- |
| `src/main.zig` | The entry point: builds `AppState`, creates the window, runs it |
| `src/state.zig` | `AppState`: sessions, transcript, pages, config editing, and every action |
| `src/view.zig` | The drawing: rail, sidebar, transcript, composer, JSON rows, toasts |
| `src/backend.zig` | The runtime's on-disk layout, the argv builders for the spawned pages, the JSON readers, `config.json` |
| `src/runtime.zig` | Running a turn or a command off the UI thread and folding results back in |
| `src/md.zig` | The little markdown reader the transcript draws with |
| `src/theme.zig` | Seven palettes, mapped onto nanoui's theme |
| `src/harness.zig` | A window driven headlessly, for the tests |
| `src/tests.zig` | What the window must draw, and where |
| `src/contract.zig` | The check that keeps the pages aligned with the runtime |
| `src/wiring.zig` | The linked-runtime wiring: the memory runtime lives in the struct, not a frame |
| `src/shot.zig` | The screenshots `zig build shots` writes |
| `src/design.zig` | The design system: spacing, radius, typography, animation and shadow tokens, an eight-colour project palette (picked by path hash), and the semantic-colour mapping every widget draws from |
| `src/sidebar/mod.zig` | The conversation sidebar's view state (search buffer, compact/detailed mode, grouping) and its search field, view toggles and recency-grouped list |
| `src/sidebar/session_row.zig` | One session row: status dot, project monogram, title/preview, stamp and hover slot; plus section headers and the empty state |
| `src/virtual_list.zig` | A viewport-based list utility (overscan, scroll-to-index, hit testing) for long lists |
| `src/chat/mod.zig` | The conversation body: a scrolling, centred, selectable transcript of message rows plus the streaming row |
| `src/chat/message.zig` | One message row: role avatar, name, a copy affordance, the markdown body, and the streaming caret |
| `src/chat/code_block.zig` | A fenced code block with a header carrying the language and a copy button |
| `src/composer/mod.zig` | The composer: multi-line input (Return sends, Shift-Return breaks the line), a focus-tinted frame, the model chip, the keyboard hint and the send / stop control |
| `src/composer/model_chip.zig` | The model chip at the composer's left; click opens Configuration |

### How a turn and a command run

A turn can take a minute, so nothing blocks the UI thread. A chat turn runs on
its own thread (`runtime.Turns`) against the linked runtime and reports back
through `stream_callback` and a completion handler. The pages answered in
process fill the page inside `openPage`, on the frame itself. The three spawned
pages build an argv and hand it to `runtime.Executor`, which spawns a thread per
command (`std.process.run`). Either way the view calls `AppState.pump()` at the
top of every frame, and that is where finished work is folded back into the
state. A page action can start another command from inside its own handler,
which is how sending a message refreshes the session list.

## What is deliberately not a page

Four of the runtime's commands have no page, on purpose:

| Command | Why not |
| --- | --- |
| `onboard` | An interactive terminal wizard. The window cannot answer its prompts, so when there is no config the Configuration page says so and names the command to run. |
| `gateway`, `acp` | Long-running servers. The gateway is served from the linked runtime on its own thread (the window shows its state in diagnostics), but it is not a page. |
| `migrate` | Imports another runtime's memory into this one. It rewrites stored data, so it stays a command you run on purpose. |

`version` and `help` are not pages either: Doctor reports which runtime is on
the other end, and the runtime's own `--help` is a terminal's job.

## Known limits

- The sidebar and transcript need a session store, and the store is only present
  with the sqlite memory backend — `HistoryStoreContext.init` returns
  `error.SessionStoreUnavailable` otherwise (`src/memory/root.zig`). With the
  markdown backend the sidebar degrades to a toast.
- The Auth page checks the `openai-codex` provider — the runtime's `auth status`
  takes a provider, and `weixin` is the other one it knows.
- Hardware scan is shown as prose; it has no `--json`. The `hardware`, `service`
  and `update` pages spawn a `nullclaw`, so on a machine without one on disk they
  show a complaint rather than rows.
- Alignment is checked against the runtime's **source**, not against a running
  binary: `src/contract.zig` reads `../src/main.zig` for the command surface, the
  `--json` support and the JSON shapes, and `zig build shots` drives a stub that
  replays those shapes. The two binaries are built from one repository, so the
  test can read the runtime's source even though it cannot build it here.
- The window is macOS-shaped: nanoui links AppKit/WebKit/Metal, and the tests
  run on macOS and Linux.
