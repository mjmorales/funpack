# Changelog

All notable changes to funpack are documented here.

This file is maintained automatically by the release workflow: every push to
`main` derives the next semver from the conventional-commit history and prepends
a version block here in the `chore(release)` commit. Edit older entries by hand
only — the newest block is generated.

## [0.19.0] - 2026-06-25

### Features
- feat(editors): VS Code/Cursor extension — TextMate base + tree-sitter semantic tokens (0ad3e49)
- feat(editors): scaffold 6 deferred grammar stubs + family docs (f194c54)
- feat(editors): .fcfg tree-sitter grammar + queries + corpus (842641e)
- feat(editors): .fun highlight/locals/injections queries (b9499d7)
- feat(editors): .fun tree-sitter grammar + same-line scanner (e8981d9)
- feat(mcp): materialize docs corpus to on-disk deep-link projection (fbacb29)
- feat(editors): scaffold tree-sitter-funpack monorepo + shared lexical core (973a172)

## [0.18.1] - 2026-06-25

### Other
- docs(funpack): document the SDL2 runtime dependency + agent self-heal (7005f68)

## [0.18.0] - 2026-06-25

### Features
- feat(funpack): carry let-tuple destructure into the v19 gameplay artifact wire (f537c3a)

## [0.17.0] - 2026-06-24

### Features
- feat(lang): let destructures a tuple return — let (a, b) = expr (ee43f7f)
- feat(funpack): name file:line:col + expected shape on malformed project.fcfg (3cbf06b)

### Other
- docs: add "Optimize for Long-Term Correctness, Not Low Churn" directive (62fb9df)

## [0.16.0] - 2026-06-24

### Features
- feat(mcp): capture_tick asserts a hand-rolled whole-tick twin equals the live schedule (64962f4)

### Fixes
- fix(spec): state the uniform evolving same-tick read model (no query memo) (871a2f8)
- fix(runtime): same-tick query reads are evolving, not within-tick memoized (4a531b8)
- fix(runtime): honor-or-reject the branch= selector on time advance verbs (friction 4102ea74) (f620f9e)
- fix(funpack): nesting refusal remedy fits the depth cause (friction 174cbae9) (d73f013)
- fix(funpack): align `funpack run --help` with the entrypoint-selection refusal (friction 02bb25ec) (baeed2c)

### Other
- docs(spec): state instance-granular intra-stage same-thing read visibility (ADR intra-stage-read-consistency) (0792563)

## [0.15.0] - 2026-06-24

### Features
- feat(mcp): add an optional replay_log arg to session_start so MCP can pre-fold a recorded replay (2fb40fd)
- feat(mcp): emit InitializeResult.instructions with the invariant-core prefix (9d2aaac)

### Fixes
- fix(mcp): consume uses_rng so a no-RNG game's empty inspect is not blamed on a missing seed (706d13a)
- fix(friction): drop colliding --id ordinal from task-create; key idempotency on report UUID (be5b0f4)
- fix(runtime): fold control edits forward on a writable branch and anchor the implicit fork at the rewound cursor (fd14bd3)
- fix(runtime): fold a seedless programmatic startup body so a fresh debug session populates (c9e37b2)

### Other
- docs: document funpack↔MCP contract shared-seam co-ownership rule (df1b372)
- docs: regenerate CLAUDE.md managed block (new doc-parity validator + devtools team) (d217d82)

## [0.14.0] - 2026-06-24

### Features
- feat(funpack): recursive multi-project mode for funpack check (1b23c52)

### Fixes
- fix(funpack): admit Rng.seed as a static constructor so chained unknown methods report Unknown_Method (33f79f6)
- fix(funpack): introspect surfaces call-site-inferred combinators with a marker (62eb36b)

## [0.13.1] - 2026-06-24

### Fixes
- fix(funpack): Unknown_Method hint lists call-site-inferred combinators (61358eb)
- fix(mcp): time_status carries a next_action when the timeline is unloaded (2adc98b)
- fix(runtime): trace resolves startup behaviors through the pipeline namespace (e2c80fd)
- fix(funpack): targeted frontend diagnostics for four friction-log cases (e8dbf2a)

## [0.13.0] - 2026-06-23

### Features
- feat(funpack): restore the full engine.rand draw surface (seed/next/range/chance/split) (f058b0b)

### Fixes
- fix(funpack): make engine.rand.pick self-first (rng.pick(items)) (36855bb)
- fix(funpack): recognize (Self, Rng) as a productive update-return shape (friction-0001) (fa4cf61)
- fix(mcp): make inspect_* empty results self-describing (friction-0007) (aad9d1e)
- fix(funpack): guard argv0-less launch context so `funpack check` cannot segfault (friction-0011) (84be46d)

## [0.12.1] - 2026-06-21

### Fixes
- fix(funpack): const-fold named-const field defaults so they survive to the spawned row (F22) (4724488)

## [0.12.0] - 2026-06-21

### Features
- feat(introspect): collision-extent debug overlay for inspect_draw_list/screenshot (F16) (a8fe73b)
- feat(introspect): add inspect_state, a read-only instance/field inspector (F20) (f63e7cb)

### Fixes
- fix(control): refuse a type-mismatched set/spawn value (F21) (b7fb70a)
- fix(introspect): trace render-stage behaviors instead of empty steps (F19) (9c82806)
- fix(control): accept human source literals in set/spawn/emit (F18) (d72a5c7)
- fix(introspect): render the §28 debug projection in legible decimals (F17) (8e862b1)

### Other
- docs(runtime): drop transient friction-item refs from F16-F21 comments (4c38f7a)

## [0.11.0] - 2026-06-19

### Features
- feat(mcp): inspect_screenshot writes PNG to disk, returns a path not base64 (2790c7f)

## [0.10.3] - 2026-06-19

## [0.10.2] - 2026-06-19

### Other
- docs: list the full funpack warden subcommand surface in the README (01d55a5)

## [0.10.1] - 2026-06-19

### Other
- refactor(funpack): prune unusable engine.render::Font over-declaration (5088890)

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
