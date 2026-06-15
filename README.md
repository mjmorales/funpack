# funpack

The implementation of **funpack** — an LL(1), agent-first programming language for game
development. This repository builds the toolchain that
[**funpack-spec**](https://github.com/mjmorales/funpack-spec) defines; the spec repo is the
doctrine, this repo is the machine that satisfies it.

> Prime directive: **programming with LLMs should be fun.**

## What gets built here

One first-party binary over one versioned contract — the pure compiler and the runtime in a
single executable
([spec §29](https://github.com/mjmorales/funpack-spec/blob/main/spec/29-architecture-governance.md)):

- **`funpack`** — the language toolchain. Parses, typechecks, runs the structural quality
  gates, formats, tests, resolves dependencies, runs the asset pipeline, and emits the
  versioned **Index Contract**. A pure `source → artifact` function: no clock, no database,
  no network, no mutable cross-run state — bit-identical by construction.
- **`funpack warden`** — the governance *sub-toolchain* and *ethos*, not a separate binary.
  A pure projection of the index funpack already emitted (`find`/`holes`/`debt`/`graph`),
  plus the discipline the directives and gates enforce. No clock, no authored state; it
  reports, the agent edits, recompilation re-projects — it never writes source. General
  swarm orchestration (a stateful task DB, leases, dispatch) is the operator's agent
  tooling, deliberately out of the engine's scope.
- **the runtime** — executes the artifact, surfaced as the `funpack run` / `funpack live` /
  `funpack attach` verbs of the same binary. It is the one impure consumer of the pure
  compiler's output (the only part that links SDL); the compiler verbs stay a pure
  `source → artifact` function. Packaged together, the purity boundary holds at the
  artifact, not at a binary split — `odin test` per package keeps the deterministic floor
  SDL-free.

```text
agent → │ funpack (pure: src → artifact + index; `funpack warden` projects the index) │ ── artifact ──► runtime
        └──────────────────────────────────────────────────────────────────────────────┘  ← operator
                one-way data: source → index → projection.  warden NEVER writes source.
```

## The contract with the spec

The spec repo is normative; this repo is measured against it. Three sources bind the
implementation, in this precedence:

1. **`spec/`** — the 30-component numbered specification. The tie-breaker when sources
   disagree.
2. **`examples/`** — nine golden reference projects (`pong`, `snake`, `hunt`, `yard`,
   `arena`, `krognid`, `hud`, `assets`, `numerics`). These are the acceptance suite: the
   implementation is **done** for a surface area when it compiles and deterministically runs
   the examples that exercise it. funpack does not grammar-include what it cannot run.
3. **`stdlib/`** — the engine surface as funpack signatures (`engine.*` modules). The
   implementation provides these; their shape is not negotiable here.

Divergence discovered during implementation is a **spec bug or an implementation bug, never
a silent fork**: file it against funpack-spec, resolve it there with rationale recorded, then
conform. This repo carries no doctrine of its own.

## Non-negotiables the implementation inherits

- **Determinism** — same source builds the same artifact; same inputs + seed produce
  bit-identical simulation on every machine. Simulation state is fixed-point, never float.
- **The purity split** — everything impure (clock, DB, network) lives in the runtime or
  the operator's agent tooling; `funpack` stays a pure function — including the
  `funpack warden` surface, which only projects the index it already emitted. The Index
  Contract is the structured interface: exact-match, all fields mandatory, schema-versioned,
  NDJSON transport.
- **Structured diagnostics** — the compiler is a quality gate emitting fix-criteria
  diagnostics so agent write → check → fix loops converge.

## Status

Pre-bootstrap. No implementation language, build system, or module layout is committed yet —
those are the first decisions to make and record. Until then, the spec repo's reading order
applies here too: start at
[`spec/index.md`](https://github.com/mjmorales/funpack-spec/blob/main/spec/index.md),
foundations first (`01-axioms`, `02-language-core`), then the runtime model
(`06-things-behaviors`, `07-pipelines`), then the toolchain seam
(`29-architecture-governance`).

For local development the spec is expected as a sibling checkout at `../funpack-spec`.

## Claude Code plugin

This repo is also the **funpack Claude Code marketplace** — the `.claude-plugin/marketplace.json`
at the root publishes the `funpack` plugin under [`plugins/funpack/`](plugins/funpack/README.md):
skills for the language, the `engine.*` stdlib, the things/behaviors/pipelines model, the bake
pipelines, and the determinism contract; `/funpack:*` commands to scaffold, build, test, run, and
query a game; and the `funpack-author` / `funpack-reviewer` agents.

```
/plugin marketplace add mjmorales/funpack
/plugin install funpack@funpack
```

The plugin is versioned independently of the toolchain binary (its own `plugin-v*` release line);
see [`plugins/funpack/README.md`](plugins/funpack/README.md) for the full surface.
