# funpack

The implementation of **funpack** — an LL(1), agent-first programming language for game
development. This repository builds the toolchain that
[**funpack-spec**](https://github.com/mjmorales/funpack-spec) defines; the spec repo is the
doctrine, this repo is the machine that satisfies it.

> Prime directive: **programming with LLMs should be fun.**

## What gets built here

Two first-party binaries over one versioned contract, plus a runtime
([spec §29](https://github.com/mjmorales/funpack-spec/blob/main/spec/29-architecture-governance.md)):

- **`funpack`** — the language toolchain. Parses, typechecks, runs the structural quality
  gates, formats, tests, resolves dependencies, runs the asset pipeline, and emits the
  versioned **Index Contract**. A pure `source → artifact` function: no clock, no database,
  no network, no mutable cross-run state — bit-identical by construction.
- **`warden`** — the governance binary. Owns the task DB, leases, swarm dispatch, `@todo`
  expiry, escalation, and provenance. Language- and engine-decoupled: it consumes the Index
  Contract over a process boundary and never writes source.
- **the runtime** — executes the artifact. `warden` and the runtime are the two impure
  consumers of the one pure compiler's output.

```text
agent → │ funpack (pure: src → artifact + index) │ ──Index Contract──► │ warden (impure: clock, DB, leases) │ ← operator
        └────────────────────────────────────────┘                     └────────────────────────────────────┘
                one-way data: source → index → warden.  warden NEVER writes source.
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
- **The purity split** — everything impure (clock, DB, network) lives in `warden` or the
  runtime; `funpack` stays a pure function. The Index Contract is the only coupling:
  exact-match, all fields mandatory, schema-versioned, NDJSON transport.
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
