---
name: mcp
argument-hint: "<install|update|uninstall|status>"
description: Install, update, uninstall, or check the funpack-mcp server binary that the funpack plugin's MCP wrapper runs. Use when the MCP tools are unavailable, after installing/updating the plugin, or to fetch/refresh the binary. Triggers on "install the funpack mcp", "update funpack-mcp", "uninstall the mcp", "funpack mcp not found", "fetch the mcp binary", "the funpack MCP isn't working".
---

# funpack-mcp binary install / update / uninstall

You manage the **funpack-mcp server binary** the plugin's MCP wrapper execs. The plugin
ships a committed wrapper (`bin/funpack-mcp`) but the actual server binary is fetched
into a persistent data dir so it **survives plugin updates** (the plugin install dir is
wiped on every update). The mechanics live in a script; your job is to dispatch to it and
**interpret the result for the user**.

## Why a separate fetch is needed (state this if asked)

`${CLAUDE_PLUGIN_ROOT}` (where the wrapper lives) is replaced on every plugin update, so a
binary placed there is lost. `${CLAUDE_PLUGIN_DATA}` (`~/.claude/plugins/data/<plugin-id>/`)
persists and is exported to both the MCP child process and the Bash you run here, so the
binary's home is `$CLAUDE_PLUGIN_DATA/bin/funpack-mcp`. The wrapper checks that path first.

## Dispatch

Take the **first token** of `$ARGUMENTS`. Map it to the subcommand; **no argument defaults
to `status`**. Run the script via its plugin-relative path:

```bash
bash "$CLAUDE_PLUGIN_ROOT/scripts/funpack-mcp-bin.sh" <subcommand>
```

| `$ARGUMENTS` first token | Subcommand | What it does |
|---|---|---|
| `install` | `install` | Fetch the latest release for this platform → `$CLAUDE_PLUGIN_DATA/bin/funpack-mcp` |
| `update` | `update` | Reinstall only if a newer release exists |
| `uninstall` | `uninstall` | Remove the installed binary + version stamp |
| `status` (or empty) | `status` | Report target path, installed/latest version, update availability |

If `$CLAUDE_PLUGIN_ROOT` is not set (running outside a plugin session), resolve the script
from this skill's own directory: it sits at `../../scripts/funpack-mcp-bin.sh` relative to
this `SKILL.md`. Run it the same way.

The script owns all mechanics and **all network access** — you never download or curl
anything yourself, and there are no secrets to handle.

## Interpret the result

The script emits greppable `key: value` lines on **stderr** and meaningful exit codes (0 ok).
Read these keys, do not recompute them:

- `target` / `target-kind` — resolved binary path and which slot it landed in (`plugin-data`
  is the normal update-surviving home).
- `version` — the tag installed (install/update success only).
- `source` — `release-asset (...)` or `build-from-source (...)` (install/update only).
- `present` / `executable` / `installed` / `latest` / `update-available` — status fields.

After it runs, give the user a short, plain-language readout:

- **install / update success** — confirm the **version** (the `version:` line) and the
  **location** (the `target:` line), then tell them how to load it: *the funpack MCP server
  is a stdio process Claude Code launched at session start; it keeps running the old binary
  until that process is relaunched. To pick up the new one, **start a new session** or run
  **`/reload-plugins`** (which reconnects the plugin's MCP servers). A running session will
  not switch binaries on its own.*
- **`status`** — relay installed vs latest and whether an update is available; if `present:
  no` or `executable: no`, recommend `install`. If `update-available: yes`, recommend `update`.
- **`update` with nothing to do** (`update-available: no`) — say it's already current, reporting
  the `installed:` version.
- **uninstall** — confirm removal; note that a `funpack-mcp` installed via **brew** or
  **`go install`** on `PATH` is **not** managed here, so if the MCP still resolves a binary
  after uninstall, that PATH copy is why.

## The macos-amd64 (Intel Mac) gap — handle, don't guess

The release publishes tarballs for **linux-arm64, linux-x64, macos-arm64** only — there is
**no macos-x64 (Intel Mac) asset**. On an Intel Mac the script automatically falls back to
**build-from-source**: it locates the `mcp/` Go module (relative to the repo, or via
`$FUNPACK_MCP_SRC`) and runs `go build`. If that path is taken you'll see a
`source: build-from-source (...)` line — tell the user it was built locally and that **Go is
required** for this platform. If neither an asset nor a buildable source tree is available,
the script exits non-zero with a message naming the gap (install Go + run from the repo, or
use a brew tap if one exists) — relay that message verbatim rather than inventing a fix.

## Failure handling

On a non-zero exit, surface the script's stderr message directly — it already names the
cause (no network, unsupported platform, missing source for build-from-source, etc.). Do not
retry blindly or fabricate a workaround; if the cause is environmental (offline, unsupported
arch), say so and stop.
