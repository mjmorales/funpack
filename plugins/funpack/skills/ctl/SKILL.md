---
name: ctl
description: Operate the funpack binary on a machine — install, update, roll back, pin, scan, and report status of the funpack toolchain on disk. Use when the user wants to install funpack, update/upgrade to the latest release, check which funpack version is installed or on PATH, pin or switch to a specific version, roll back a bad upgrade, or audit every funpack binary on the machine. Triggers on "install funpack", "update funpack", "upgrade funpack", "what funpack version", "funpack binary status", "scan funpack installs", "pin funpack to <version>", "roll back funpack", "funpack on PATH", "manage the funpack binary". Not for authoring funpack programs, engine/runtime code, or project scaffolding — those are funpack-project / funpack-engine-api / funpack-language.
---

# funpack:ctl — funpack binary systems operations

Install, update, roll back, pin, and audit the **funpack binary** on a machine. You decide
which operation and whether to gate it; the bundled script `scripts/funpackctl` does the
download/extract/symlink/version-compare mechanics.

Invoke the script with:

```
${CLAUDE_PLUGIN_ROOT}/skills/ctl/scripts/funpackctl <command> [args]
```

(In this repo's working tree that resolves to
`plugins/funpack/skills/ctl/scripts/funpackctl`.) Always run `scan` or `status` first
to learn the machine's current state before any mutating command.

## The install model (read this before acting)

funpack ships as a single binary. Three channels can coexist on one machine, and
`scan` reports all of them:

- **managed** — this skill's prefix `$FUNPACK_HOME` (default `~/.funpack`). Holds one
  dir per version under `versions/<semver>/` and an active-version symlink at
  `bin/funpack`. Switching versions and rolling back are O(1) symlink swaps with no
  re-download. **Only this channel supports `rollback` and instant version-pinning** —
  it is the home for everything the user asks about updates/rollbacks/version-setting.
- **brew** — `brew install mjmorales/tap/funpack`. Simple, but keeps no old versions,
  so it cannot roll back or pin.
- **dev-build** — a binary compiled from a checkout. `scan` detects it at `./funpack.bin`
  or `./cmd/funpack/funpack` relative to the cwd (e.g. `task binary` output), never
  machine-wide.

Source of truth for releases: GitHub releases on `mjmorales/funpack`, binary line tagged
`v*`, one asset per platform (`macos-arm64`, `linux-arm64`, `linux-x64`). Intel macOS has
no prebuilt asset — build from source there.

**Runtime prerequisite — SDL2.** The `run`/`live`/`attach` verbs link SDL2 dynamically at a
build-time-baked absolute path; the pure verbs (`build`/`check`/`test`/`warden`) do not. The
prebuilt macOS binary resolves SDL2 through Homebrew's `sdl2-compat` (the maintained
SDL2-ABI-over-SDL3 provider — Homebrew migrated the `sdl2` formula to it), so a machine
missing it dies in dyld before `main` with `Library not loaded: …/libSDL2-2.0.0.dylib`.
Install the provider once — macOS `brew install sdl2-compat`, Linux `apt install
libsdl2-dev`. funpack cannot self-diagnose this; the loader fails before any funpack code
runs.

**Critical PATH fact:** what `funpack` actually runs is whatever PATH resolves first.
A managed `install`/`update` only re-points `~/.funpack/bin/funpack`; it does **not**
change PATH or override a brew shim. If the user is on brew and you install into the
managed prefix, `funpack` on PATH is unchanged until `~/.funpack/bin` precedes brew on
PATH (or you run `funpackctl link`). Always check `status` after a mutation and surface
this if the on-PATH version did not move.

## Intent → command

| User wants | Command |
|---|---|
| "what version / is it current?" | `status` |
| "show me every funpack on this box" | `scan` |
| "what releases exist?" | `releases [N]` |
| "install funpack" / "install v0.10.1" | `install [<ver>]` |
| "update / upgrade to latest" | `update` |
| "switch to / pin v0.9.0" (already installed) | `use <ver>` |
| "undo that upgrade" | `rollback` |
| "list what I have installed" | `list` |
| "remove the old v0.9.0" | `uninstall <ver>` |
| "put funpack on my PATH" | `link [<dir>]` |
| "why isn't funpack working?" | `doctor` |

## Confirmation gates

Reads (`status`, `scan`, `releases`, `list`, `which`, `doctor`) run freely — never gate
them. Gate the mutations that change which binary runs or destroy a cached version,
using `AskUserQuestion` (binary confirm), and only when the consequence is real:

- **`install` / `update` / `use` / `rollback`** — confirm once before running, stating
  the from → to versions. These are reversible (the prior version stays cached), so a
  single confirm is enough; do not re-gate each step of a multi-version sequence.
- **`uninstall`** — confirm; it deletes a cached version (re-downloadable, but gone from
  disk). The script already refuses to remove the *active* version.
- **brew/managed conflict** — if `status` shows the on-PATH funpack is brew-managed and
  the user asked to update, do not silently install into the managed prefix and declare
  victory. Present the choice via `AskUserQuestion`: (1) `brew upgrade` the brew install
  (recommended if they want to keep brew as the source of truth), or (2) install into the
  managed prefix and `link`/PATH-order it ahead of brew. Pick option 1 first unless they
  want pinning/rollback, which brew can't give.

## Standard procedures

**Status check / "is my funpack current?"** → run `status`. Read back the active version,
the on-PATH version, the latest release, and the drift verdict (`up to date` / `behind` /
`ahead`). The verdict compares latest against the active version, or the on-PATH version
when nothing is managed — so a "behind" verdict on an unmanaged box is about the brew/dev
binary, not a managed install. If behind, offer `update`.

**First install on a fresh machine** → `scan` to confirm none present → confirm → `install`
(latest) → tell the user to add `$FUNPACK_HOME/bin` to PATH or run `link`, then `doctor`
to confirm `funpack version` runs from PATH.

**Update** → `status` (capture from-version) → confirm from → to → `update` → `status`
again. If on-PATH did not move (brew/order), apply the brew/managed conflict gate above.

**Roll back a bad upgrade** → `list` to show active + rollback target → confirm →
`rollback`. Rollback toggles between the two most-recent active versions; running it
again returns to where you were.

**Pin to a specific version** → if already installed (`list`), `use <ver>`; otherwise
`install <ver>` (which downloads then activates it).

**Diagnose "funpack not found / wrong version"** → `doctor` → it checks the prefix, the
active symlink, PATH resolution, that `funpack version` runs, platform asset
availability, and `gh` presence. Then `scan` to see competing installs.

For the platform/asset matrix, the managed layout, and brew↔managed reconciliation
details, see `references/operations.md`.
