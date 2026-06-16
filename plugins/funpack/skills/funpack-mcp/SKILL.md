---
name: funpack-mcp
argument-hint: "<install|update|uninstall|status>"
description: Install, update, uninstall, or check the funpack-mcp server binary that the funpack plugin's MCP wrapper runs. Use when the MCP tools are unavailable, after installing/updating the plugin, or to fetch/refresh the binary. Triggers on "install the funpack mcp", "update funpack-mcp", "uninstall the mcp", "funpack mcp not found", "fetch the mcp binary", "the funpack MCP isn't working".
---

# funpack-mcp binary: install / update / uninstall / status

You manage the **funpack-mcp server binary** the plugin's MCP wrapper execs. A script owns all mechanics; your job is to dispatch to it and interpret its result for the user.

<!-- Primacy: dispatch rule + script invocation first — the two most load-bearing directives lead the prompt. -->
## 1. Dispatch

Take the **first token** of `$ARGUMENTS`; map it to a subcommand. **Empty → `status`.** Run:

```bash
bash "$CLAUDE_PLUGIN_ROOT/scripts/funpack-mcp-bin.sh" <subcommand>
```

| First token | Subcommand | Effect |
|---|---|---|
| `install` | `install` | Fetch latest release for this platform → persistent data dir |
| `update` | `update` | Reinstall only if a newer release exists |
| `uninstall` | `uninstall` | Remove the installed binary + version stamp |
| `status` / empty | `status` | Report target path, installed/latest version, update availability |

If `$CLAUDE_PLUGIN_ROOT` is unset (run outside a plugin session), resolve the script at `../../scripts/funpack-mcp-bin.sh` relative to this `SKILL.md` and run it the same way.

The script owns all mechanics and **all network access** — never download or curl anything yourself; there are no secrets to handle.

## 2. Read the script's keys — do not recompute

The script emits greppable `key: value` lines on **stderr** with meaningful exit codes (0 = ok). Branch on these keys; never re-derive them from prose or other fields:

- `target` / `target-kind` — resolved path and slot (`plugin-data` = the normal update-surviving home).
- `version` — installed tag (install/update success).
- `source` — `release-asset (...)` or `build-from-source (...)` (install/update).
- `prior-binary` — `absent` | `present` (install/update). The from-zero signal; it alone decides the load instruction below.
- `present` / `executable` / `installed` / `latest` / `update-available` — status fields.

## 3. Readout per subcommand

Give a short, plain readout.

**install / update success** — confirm `version:` and `target:`, then give exactly ONE load instruction, keyed strictly on `prior-binary`. <!-- HARD CONSTRAINT (FRICTION F9): the two remedies are mutually exclusive; never flatten to "new session or /reload-plugins". -->

| `prior-binary` | Meaning | Tell the user |
|---|---|---|
| `absent` | From-zero: no server binary existed at session start, so this session launched zero funpack tools. A mid-session `/reload-plugins` relaunches the process but does NOT inject the new server's tools into the running tool index. | **You must start a new session.** Do NOT offer `/reload-plugins` — it will not surface the tools this session. |
| `present` | In-place version bump: a server was already running, so reconnect swaps the binary in place. | **Run `/reload-plugins` to pick up the new binary, or start a new session.** A running session won't switch binaries on its own. |

**status** — relay installed vs latest and `update-available`. If `present: no` or `executable: no`, recommend `install`. If `update-available: yes`, recommend `update`.

**update, nothing to do** (`update-available: no`) — say it's already current; report the `installed:` version.

**uninstall** — confirm removal. Note: a `funpack-mcp` on `PATH` via **brew** or **`go install`** is not managed here, so if the MCP still resolves a binary after uninstall, that PATH copy is why.

## 4. macos-amd64 (Intel Mac) gap — handle, don't guess

Releases ship **linux-arm64, linux-x64, macos-arm64** only — there is **no macos-x64 asset**. On Intel Mac the script auto-falls-back to **build-from-source**: it locates the `mcp/` Go module (via the repo or `$FUNPACK_MCP_SRC`) and runs `go build`. A `source: build-from-source (...)` line means it built locally — tell the user it was built from source and **Go is required** on this platform. If neither an asset nor a buildable source tree exists, the script exits non-zero naming the gap — relay that message verbatim instead of inventing a fix.

## 5. Failure handling

On non-zero exit, surface the script's stderr verbatim — it already names the cause (offline, unsupported platform, missing source, etc.). Instead of retrying blindly or fabricating a workaround: if the cause is environmental (offline, unsupported arch), say so and stop.

## Why a separate fetch is needed (state only if asked)

`$CLAUDE_PLUGIN_ROOT` (where the committed wrapper `bin/funpack-mcp` lives) is wiped on every plugin update, so a binary placed there is lost. `$CLAUDE_PLUGIN_DATA` (`~/.claude/plugins/data/<plugin-id>/`) persists, so the binary's home is `$CLAUDE_PLUGIN_DATA/bin/funpack-mcp`, which the wrapper checks first.

The persistent home is **env-independent**: `$CLAUDE_PLUGIN_DATA` is exported only inside a plugin session, so an `install`/`update` run from ordinary Bash lacks it. Rather than fall back to a wiped-on-update cache path, the script derives the same dir deterministically — it reads the plugin name from `.claude-plugin/plugin.json`, matches the `<name>@<marketplace>` key in `~/.claude/plugins/installed_plugins.json` (falling back to the owned marketplace `funpack`), and lands the binary in `~/.claude/plugins/data/<name>-<marketplace>/bin`. Install is therefore persistent regardless of invocation — `target-kind: plugin-data` in every case. `$CLAUDE_PLUGIN_DATA` (when set) and `$FUNPACK_MCP_DATA` (dev) are honored as explicit overrides ahead of the derivation.
