# Changelog

All notable changes to funpack are documented here.

This file is maintained automatically by the release workflow: every push to
`main` derives the next semver from the conventional-commit history and prepends
a version block here in the `chore(release)` commit. Edit older entries by hand
only — the newest block is generated.

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
