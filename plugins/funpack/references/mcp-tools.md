# funpack MCP tools — intent → tool map

The funpack plugin exposes the **funpack MCP server** — the `funpack mcp` verb of the funpack binary,
wired via `plugins/funpack/.mcp.json` (the plugin runs `funpack mcp` off `PATH`; funpack ships on
`PATH` via Homebrew). Every ops verb that used to be a CLI invocation is now an MCP tool. **Do not
shell out to `funpack build|check|fmt|test|run|live|warden`** and do not parse human CLI wording —
call the tool and read its structured result. The replacement mapping is explicit at the bottom of
this file.

Tools split into two classes:

- **One-shot** — stateless verbs over a project *directory* on disk. Each runs a one-shot child
  process and returns a structured result (exit code passed through; a non-zero exit is a normal
  result, not a tool error).
- **Session-scoped** — tools that operate over a **live supervised `funpack attach` session**. Open a
  session with `session_start`, drive it with the `time_*` / `inspect_*` / `control_*` / self-heal
  tools (all take the session id), and close it with `session_end`.

## One-shot tools (stateless, over a project directory)

| Tool | Use when… |
|---|---|
| `health` | You want to confirm the funpack MCP server is live and read its build version. |
| `build` | You want the **dev** artifact + `.funpack/index.ndjson` — the fast inner-loop compile (holes allowed; pass release only when you specifically need the optimized output without shipping). |
| `export` | You want to **ship** — the optimized, hole-banned release artifact. Prefer this over `build` release; it is the shippable build, no flag to remember. |
| `check` | You want the build's verdict with **no product written** — type-check + static analysis only. |
| `fmt` | You want to format the project (or, in check mode, ask whether it is already formatted). |
| `test` | You want to run every `test "…" { assert … }` block and get a structured pass/fail summary (counts + each failing test's name and detail). |
| `docs_search` | You need to look up an engine API, a spec section, or any funpack concept — search the docs corpus for ranked hits; each hit's anchor feeds `docs_get`. **Use this instead of relying on memorized prose.** |
| `docs_get` | You have an anchor from `docs_search` and want the full text of that one documentation section. |
| `warden_find` | You're about to write a helper and want a pre-hoc reuse check — does a declaration with this name-substring already exist in the committed index? |
| `warden_holes` | You want every open typed hole (`@stub`) in the committed index. |
| `warden_probes` | You want every outstanding debug probe (`@break`/`@log`/`@watch`/`@trace`) in the committed index. |
| `warden_debt` | You want every `@todo` debt declaration (message + window) in the committed index. |
| `warden_tags` | You want the registered `@gtag` governance tags, or to list declarations by tag. |
| `warden_pipeline` | You want the flattened pipeline projection from the committed index. |
| `warden_graph` | You want the dependency/call graph from the committed index (optionally filtered to one node's edges). |

> `warden_*` tools are **pure projections** over the `.funpack/index.ndjson` that `build` emits. They
> never write source — the agent edits source; a recompile re-derives the projection.

## Session-scoped tools (over a live `funpack attach` session)

### Lifecycle

| Tool | Use when… |
|---|---|
| `session_start` | You want to open a supervised `funpack attach` session over a built artifact. Returns an opaque session id (every other session tool takes it) and the negotiated protocol version. |
| `session_end` | You're done with a session and want to close + deregister it by id. |
| `session_list` | You want to see every live session (id, version, artifact, created-at). |

### Time travel (navigate the recorded timeline)

| Tool | Use when… |
|---|---|
| `time_load` | You want to arm the time cursor at the post-startup base (tick -1), readying the recording for navigation. |
| `time_run` | You want to fold the timeline forward to a target tick (default: the last recorded tick). |
| `time_step` | You want to advance the cursor exactly one recorded tick. |
| `time_pause` | You want to acknowledge / read the cursor's current position. |
| `time_rewind` | You want to jump back to an earlier tick (restores the nearest snapshot and re-folds to the exact target). |
| `time_reset` | You want to return the cursor to the post-startup base (tick -1), keeping the snapshot ring. |
| `time_status` | You want the time session's shape: load state, cursor, recording extent, seededness, snapshot ring, branch lineage. |

### Inspect (observe-class — read a committed tick, perturb nothing)

| Tool | Use when… |
|---|---|
| `inspect_signals` | You want every signal routed during one recorded tick, in fold order. |
| `inspect_pipeline` | You want the flattened pipeline in total order (every step's ordinal, stage, behavior). |
| `inspect_trace` | You want to trace one behavior's per-instance (in → out) at a tick — the bounded re-fold. |
| `inspect_diff` | You want the committed-state diff between two retained ticks (per-table row adds/removes/changed fields). |
| `inspect_replay_behavior` | You want to confirm one behavior re-runs purely from its captured inputs — the purity theorem, checkable (`refold_matches=false` is a bug to file). |
| `inspect_draw_list` | You want one committed tick's deterministic draw-list (screenshot's sim-pure twin; **always serves headless** — it IS the determinism-path render output, so it is the headless substitute for `inspect_screenshot`). |
| `inspect_screenshot` | You want to **SEE** one committed tick as a presented PNG frame. It **writes the PNG to disk and returns a file path** (the metadata block's `path` field), not inline pixels — Read that path to view the frame. Captures land in `./.funpack-mcp` by default, or `$FUNPACK_SCREENSHOT_DIR` when the host sets it; filenames are `funpack-screenshot-<timestamp>-tick<N>.png`. Crosses the render/present boundary — only a funpack built with `FUNPACK_LIVE` can serve it (a property of the funpack **binary**, not the built artifact). The shipped funpack binary IS the `FUNPACK_LIVE` build, so this serves even headless (SDL dummy video driver — no display needed); a binary built without it refuses with a precise error pointing at `inspect_draw_list`. |

### Control (perturbing — forks a non-warranted branch off the canonical recording)

| Tool | Use when… |
|---|---|
| `control_inject_input` | You want to inject one input snapshot on a branch and fold forward (forks a branch). |
| `control_set` | You want to force one blackboard field on a branch. |
| `control_spawn` | You want to spawn one new instance of a thing on a branch (returns the minted instance id). |
| `control_despawn` | You want to despawn one instance on a branch. |
| `control_emit` | You want to emit one signal on a branch and fold a full pipeline tick over it. |
| `control_reload` | You want to hot-reload a branch onto a recompiled artifact through the gated atomic swap. |
| `control_branch` | You want to explicitly fork the canonical recording into a fresh branch at a tick — the git-like "what if?" fork. |
| `control_checkout` | You want to switch the active lineage (read source) between `branch` and `canonical` — navigates lineages, forks nothing. |

### Self-heal (turn a session's recording into a permanent regression / warranty audit)

| Tool | Use when… |
|---|---|
| `capture_test` | You want to capture one behavior instance's step at a recorded tick into a complete, idiomatic funpack `test` block, ready to fold into the project as a permanent regression. |
| `audit` | You want the determinism-warranty audit — re-fold the recording from its snapshot+seed and confirm it reproduces every recorded frame digest bit-identically (returns the first diverging tick + digest diff on failure). |

## Replacement mapping (old CLI → MCP)

The old `/funpack:build|run|test|warden` slash commands are **gone**. Use the MCP tools instead:

| Old surface | Now |
|---|---|
| `/funpack:build` · `funpack build` / `check` / `fmt` | `build`, `export`, `check`, `fmt` (one-shot) |
| `/funpack:test` · `funpack test` | `test` (one-shot) |
| `/funpack:run` · `funpack run` / `funpack live` | `session_start` → the `time_*` / `inspect_*` / `control_*` / self-heal tools → `session_end` |
| `/funpack:warden <cmd>` · `funpack warden <cmd>` | `warden_find` / `warden_holes` / `warden_probes` / `warden_debt` / `warden_tags` / `warden_pipeline` / `warden_graph` |
| Looking up an engine API, a spec `§`, or any funpack concept | `docs_search` (then `docs_get` on a hit's anchor) — **not** memorized prose |

`/funpack:new` (scaffolding the project tree) **stays** — it has no MCP equivalent.

> Tool names here are the exact identities the `funpack mcp` server registers (the generated
> `funpack.TOOL_SPECS` projected from `contract/funpack-api.json`, dispatched in `cmd/funpack/mcp_tools_*.odin`).
> If a tool isn't listed, it isn't wired — call `health` to confirm the server, and don't assume an
> unlisted verb exists.
