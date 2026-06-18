# Changelog

All notable changes to funpack are documented here.

This file is maintained automatically by the release workflow: every push to
`main` derives the next semver from the conventional-commit history and prepends
a version block here in the `chore(release)` commit. Edit older entries by hand
only — the newest block is generated.

## [0.10.0] - 2026-06-18

### Features
- feat(plugin): rewire MCP bundling to the native funpack mcp verb (4cc1b2a)
- feat(mcp): re-home the contract generator to Odin (funpack mcp gen-contract) (91929a2)
- feat(mcp): wire the one-shot compute-tool dispatch family (74acd40)
- feat(mcp): wire session_start/list/end dispatch arm onto the registry (2180032)
- feat(mcp): wire docs_get/docs_search/health in-process over the embedded corpus (a95b386)
- feat(mcp): declare server-native tools in contract, project into unified TOOL_SPECS (5ab81e9)
- feat(mcp): fill inspect_screenshot arm with native QOI->PNG transcode (e684669)
- feat(mcp): control + self-heal tool dispatch (control_*, capture_test, audit) (911bc2f)
- feat(mcp): wire the observe + time-travel tool dispatch family (c8e74fe)
- feat(mcp): server-scoped session registry + per-family dispatch chain (mcp-odin-fold) (3934dec)
- feat(mcp): port docs-search BM25 + symbol-table + blend ranker to Odin (mcp-odin-fold) (b4e6dfe)
- feat(mcp): MCP JSON-RPC 2.0 protocol layer for `funpack mcp` (mcp-odin-fold) (c41eeec)
- feat(mcp): re-home docs corpus generation + embed to Odin (mcp-odin-fold) (3bc07d6)
- feat(mcp): enrich §28 contract with per-command arg shapes + project Tool_Spec table (f0176e0)
- feat(mcp): re-home surface-parity gate to Odin funpack package (ecbe827)
- feat(mcp): stdio JSON-RPC transport scaffold + minimal funpack mcp verb (80baaa5)
- feat(mcp): extract pure fmt_drift seam from fmt verb (e5128b2)
- feat(mcp): extract pure open_session_for_artifact seam from attach (33a1021)

## [0.9.0] - 2026-06-18

### Features
- feat(runtime): map the full key alphabet scancodes for live input (36ad07d)
- feat(funpack): admit full Key/PlayerId/Bone/Slot sets + Align + Axis/Button (fa881fa)
- feat(runtime): wire restored-surface eval + Color::Rgb rasterization (fdc52cf)
- feat(funpack): restore dropped stdlib surface + add introspect dump (d7b552b)
- feat: engine.input dpad() 2D source — Pad_Quad runtime source kind (4283620)

### Fixes
- fix(funpack): widen lambda body to spec (one expr / if-expr / return) (7197a9b)

## [0.8.1] - 2026-06-16

### Other
- docs: funpack-spec repo deleted, not archived (bba89f7)

## [0.8.0] - 2026-06-15

### Features
- feat: engine.input pad/mouse sources, diagnostics, and MCP resolver fixes (mario friction) (3c7bcaf)

### Other
- refactor: vendor funpack-spec into the monorepo (b392d66)

## [0.7.0] - 2026-06-15

### Features
- feat(mcp): bundle funpack-mcp into the plugin (.mcp.json + wrapper) + serve schema preflight (357853c)
- feat(runtime): attach --port 0 ephemeral + --port-file + --token-file out-of-band handshake (b007b75)
- feat(runtime): §28 introspect surface ruling — implement despawn, drop inspect-bare/paused/reload_result (c3c94b8)
- feat(runtime): headless §28 screenshot capture via SDL dummy video driver (bf8d3fb)
- feat(funpack): report §28 introspect-schema in `funpack version` (f566d2a)
- feat(funpack): version --json machine-readable schema surface (833692c)
- feat(contract): funpack<->MCP API contract source of truth (97ddc50)

## [0.6.2] - 2026-06-15

### Other
- refactor(build): consolidate funpack + funpack-live into a single binary (47b428b)

## [0.6.1] - 2026-06-14

### Fixes
- fix(runtime): implement missing engine.math builtins in the interpreter (15c6611)

## [0.6.0] - 2026-06-14

### Features
- feat(runtime): funpack-live --help prints usage (0274367)
- feat(funpack): add `funpack run` verb that builds and launches the game (1fe890b)

## [0.5.0] - 2026-06-14

### Features
- feat(funpack): evaluate behavior-step engine constructs and localize test failures (a07482e)

### Other
- docs: add "Tests and Fixes Are Foundational" directive to CLAUDE.md (b58b0fc)

## [0.4.0] - 2026-06-14

### Features
- feat(funpack): Cobra-shaped CLI framework replacing the per-verb dispatch (cdac685)

## [0.3.0] - 2026-06-14

### Features
- feat(funpack): `funpack version` verb embedding the release VERSION mirror (5bf7974)

### Other
- docs(docs): regenerate CLAUDE.md for prove plugin v4.2.1 (9df4af4)

## [0.2.0] - 2026-06-14

### Features
- feat(funpack): structured fix-criteria diagnostics for test/check/build (34aa95c)
- feat(funpack): fmt --check prints a unified diff (cb261bd)

### Fixes
- fix(funpack): anchor every diagnostic arm on a real source position (d7e10d0)

## [0.1.0] - 2026-06-13

Initial tagged release: the funpack compiler/toolchain (`funpack`) and the
runtime (`funpack-live`), with the native-matrix release build and Homebrew tap.
