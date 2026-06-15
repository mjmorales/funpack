# 01 — Axioms & design principles

The first principles funpack derives from. Three layers: **roots** (irreducible premises),
**principles** (derived, each traced to roots), and **mechanisms** (the concrete *how*). When a
design question arises it is answered by tracing to a root — not by taste. A proposal that serves
no root does not ship.

---

## 1. Roots

Irreducible. Two are empirical claims about how LLM agents fail; one is a value; one scopes the
domain. Everything else in funpack derives from these.

### R1 — Agents are weak where meaning is ambiguous or behavior is nondeterministic
The deepest premise. An agent loses accuracy when a symbol means two things, when control flow is
implicit, or when results are not reproducible. Two faces, one root:
- **Surface ambiguity** — a glyph or construct with more than one reading.
- **Semantic nondeterminism** — a result that varies across runs, machines, or orderings.

funpack removes both at the source rather than asking the agent to cope.

### R2 — Agents are stateless across runs and build top-down
An agent loses its context between runs and constructs code top-down — signatures before bodies,
consumers before producers. It cannot hold a whole codebase in mind and it re-derives, or
re-implements, what it cannot recall. funpack gives the agent sanctioned ways to anchor itself and
its successors **without leaving rot**, and a persistent surface to resume from.

R2 is co-equal with R1 and is the source of the entire self-anchoring and governance surface.

### R3 — Optimize for the next editor, not the author
Code is read and edited far more than it is written, and most edits are made by an agent that did
not write it. Every trade-off favors the next reader. "Clever" is a defect; there is one obvious way
to do each thing.

### Domain premise — funpack is a game language
The domain is deliberately narrow. A game language can push expressiveness into a rich engine and
keep the *language* small, which is what makes R1/R3 affordable. funpack is not a general-purpose
language with a game framework bolted on; things, behaviors, determinism, and fixed-point are
first-class.

---

## 2. Principles

Each is derived. The trace to its root(s) is stated; none is itself a root.

### P1 — Determinism, two tiers, both mandatory · *from R1*
- **Build determinism:** same source → bit-identical artifact.
- **Simulation determinism:** same inputs + seed → bit-identical frame *N* on every machine.

Determinism is **not** a dev-time-only convenience. It is load-bearing at runtime — lockstep
multiplayer, peer-to-peer, and shared recordings are direct payoffs (see
[`25-netcode.md`](25-netcode.md)) — *and* in the dev loop, where it makes replay-repro and testing
exact. What funpack does **not** provide is runtime fault-recovery: there is no rollback, rewind, or
self-repair at play time. Determinism's runtime payoff is reproducibility and lockstep, not
self-healing.

Consequences: fixed-point is the default numeric type for simulation state (float is visual-only and
flagged as an effect); RNG is engine-abstracted and seeded, never ambient; time is logical, advanced
in a fixed timestep; iteration order is defined and stable wherever it is observable.

### P2 — Legibility mechanisms · *from R1 ∧ R3*
One concept per glyph (which is exactly the LL(1) guarantee: no glyph needs more than one token of
lookahead to resolve its role); word logicals (`and`/`or`/`not`); string building by interpolation,
never `+`; a canonical, mandatory, idempotent formatter with the AST as source of truth. No macros,
no user-defined operators, no inheritance, no reflection.

### P3 — Power in the engine, not the language · *from R1 ∧ R3, enabled by the domain premise*
The resolution of the tension between "the language must be boring" and "games need
expressiveness": expressiveness is a property of the **batteries**, never of user-authored
abstraction. The engine ships rich primitives (asset pipeline, UI, rendering, physics, the
scheduler); user/agent code is boring glue over them. **Stdlib-first** — the standard library *is*
the engine and the vast majority of games never leave it; external packages exist only as a
barebones, content-hashed, pinned escape hatch. Generics exist only on engine/stdlib containers,
never user-authored.

### P4 — Testability by construction · *from R1*
Unit tests are first-class because the language guarantees the conditions they need: determinism and
pure-by-default functions over plain data. A pure function over plain data is trivially testable;
that is the default unit of code. Tests are a top-level declaration (`test "…" { assert … }`) and
the engine supplies deterministic fixtures (`View.of`, `Input.empty`, `Time.at`).

### P5 — The compiler is a quality gate, not just a translator · *from R3 ∧ R2*
Structural quality is enforced at compile time as **errors, not warnings**: cyclomatic complexity,
nesting depth, function size, parameter count, and code duplication all have hard ceilings.
Duplication is the mechanical symptom of R2 — an agent re-implementing a helper it could not recall.

The budgets are **fixed compiler constants with no per-site waiver**. The only sanctioned escape for
*incomplete* (never *complex*) code is the typed hole (P8). The "no knobs" rule is scoped precisely:
it bans **quality-gate budget configuration and per-site waivers**. It does **not** ban configuration
in general — the `.fcfg` project layer (entrypoints, builds, tags), tick rates, input
bindings, and UI themes are legitimate, first-class configuration.

### P6 — Documentation is structured and timeless; free comments are illegal · *from R1 ∧ R2*
Free-text comments rot, and stale residue (`// TODO`, `// old way was`) misleads every later
amnesiac agent (R2) and introduces ambiguity (R1). Comments do not exist in the declarative-source
family. Documentation is the `@doc("…")` directive: attached to a declaration, auditable, and
timeless — it states what a thing *is*, never what happened to it. Temporal intent is channeled into
expiring `@todo` and typed `@stub` (P8), never free text. Scope: the ban governs `.fun` and the
`.fcfg` config layer; the imperative bake DSL (`.fpm`) permits `//` for geometry intent no directive
captures.

### P7 — Code self-indexes · *from R2 ∧ R3*
A codebase is a queryable index, not a text blob to grep — because an agent cannot hold it all in
mind (R2). The `@gtag("…")` directive labels declarations from a **declared registry**; the compiler
builds the index and agents query it ("all behaviors tagged `combat`") instead of spraying greps.
Unregistered tags are a compile error, so the namespace never rots into synonyms.

### P8 — Agents self-anchor through typed holes, expiring debt, and the queryable index · *from R2*
R2's primary consequence.
- **Typed holes (`@stub`)** — a declaration may stand with a typed but unfilled body. Callers
  typecheck against the type, so top-down construction and dependency injection work by
  construction. Holes compile in **dev** builds, are tracked in the index, and are **forbidden in
  release**: you cannot ship a hole.
- **Expiring debt (`@todo`)** — the only legal temporal note. It carries a mandatory window; past
  the window it is a **compile error**. Debt has a deadline the compiler enforces, so it cannot pile
  up.
- **The queryable index** — funpack indexes every `@stub` and `@todo` from source. The `funpack
  warden` sub-toolchain projects open holes, pending debt, and tags ([`29`](29-architecture-governance.md)),
  so agents resume from the committed source and its index instead of re-deriving context. There is
  no separate stateful task store in the engine; durable swarm coordination, if wanted, is the
  operator's agent-governance tooling, not an engine mechanism.

### P9 — The operator governs the swarm · *from R2, dev-time governance*
A dev-time ethos, not a runtime concurrency model and not a language axiom: unattended amnesiac
agents (R2) will rot a codebase, so a human operator owns policy, agents obey, and the compiler
enforces. The operator reviews debt and intent through the index — the `funpack warden` projection
([`29`](29-architecture-governance.md)) — there are no threshold knobs to tune (P5).

---

## 3. Mechanisms (the *how*)

Concrete realizations, each serving one or more principles. Specified in detail in their own
components.

- **Syntax** — pragmatic LL(1): statements are strictly LL(1), each opening with a unique keyword;
  expressions use a Pratt/precedence-climbing parser. *(P2; → [`02`](02-language-core.md))*
- **Numerics** — one `Fixed` format, total saturating arithmetic, integer-kernel transcendentals
  (bit-identical), `Vec`/`Quat`/`Mat4`. *(P1; → [`10`](10-numerics.md))*
- **Runtime model** — things own colocated state; behaviors are pure `step` transitions attached to
  a thing; signals are the only cross-thing channel, delivered synchronously in pipeline order; a
  pipeline is the explicit ordered schedule; a tick is a fold over the flattened pipeline.
  *(P1/P3/P4; → [`06`](06-things-behaviors.md), [`07`](07-pipelines.md))*
- **Data model** — `data` is a map-backed value record with unconditional synthesized batteries
  (totality/non-null via `Option`, serialization, value semantics, `Eq`/`Ord`/`Hash`, copy/`with`);
  `enum` is a sum type; no `derives`; capabilities are ascribed by a kind on the declaration line
  (`Name: Kind`). All
  simulation state is serializable by construction. *(P1/P4; → [`03`](03-data-model.md))*
- **Errors & effects** — errors are values (`Result`) with compiler-enforced exhaustive handling;
  user code is pure by default; effects are **data** — a function causes an effect iff its return
  type carries a command (`[Spawn]`, `[Draw]`, `[Save]`) and observes the world iff it takes an
  engine resource (`Input`, `Time`, `Rng`). Absence of both is a positive purity guarantee. Effect
  **closure**: every emitted signal/command must have a consuming stage downstream in the flattened
  pipeline, checked at compile time. There are no effect rows. *(P1/P4; → [`04`](04-effects.md))*
- **Toolchain** — one first-party binary over one versioned contract: `funpack` (pure
  `source → artifact`: parse, typecheck, gates, format, test, index, assets), plus the `funpack
  warden` sub-toolchain — a pure projection of the index — and the warden *ethos* the directives and
  gates enforce. Purity is **by construction**: the impure, clock-bearing swarm coordination a
  stateful governor would carry is out of the engine's scope, not exiled to a second process. No
  external build system, no plugin ecosystem. *(P3/P5/P8/P9; → [`29`](29-architecture-governance.md))*
- **Memory** — no manual memory, no borrow checker. Cross-tick blackboards live in a COW-persistent
  store (structural sharing); per-tick signals/commands use a bump arena reset each tick. *(P1)*
- **`extern` native boundary** — the stdlib bottoms out in native code via `extern fn` / `extern
  type`; gated off by default (a compile error in ordinary projects), opt-in only via custom-runtime
  mode. The type still states the effect surface; stdlib externs are audited to honor their
  contract. *(P3; → [`26`](26-stdlib.md))*
- **Directives** — inert toward user logic (no codegen, no control flow): `@doc`, `@gtag`,
  `@stub`, `@todo`, `@expose`, `@index`, the realm family `@server`/`@client`, and the dev-only debug
  family `@break`/`@log`/`@watch`/`@trace`. The category is closed; individual directives are not
  user-definable. *(P5–P9; → [`05`](05-directives.md))*

---

## 4. Policy and parameter values

The spec distinguishes a **policy** from any **value** it parameterizes. The policy is authoritative;
the value parameterizes it.

| Policy | Value |
|---|---|
| Structural budgets are fixed compiler constants, no per-site waiver (P5) | cyclomatic ≤ 10, nesting ≤ 3, function ≤ 40 statements, parameters ≤ 5 |
| One canonical `Fixed` format for sim state (P1) | exact bit width / fractional precision |
| Duplication is a compile error; decompose, no waiver (P5) | the duplication-detection threshold |
| `@todo` carries a mandatory enforced window (P8) | the four window forms — relative duration / absolute date / build count / task ref `T-NNNN` ([`05`](05-directives.md) §2, [`29`](29-architecture-governance.md) §4) |
| `mut data` is the only sanctioned, declared mutation channel | `mut` is declared on the type (every instance mutable) |

There is a single top-level tick over shared state: no dynamic per-member fan-out of sub-pipelines,
no multi-rate ticks, no disjoint state partitioning across pipelines.

---

## 5. Maintenance principle

The live `.fun` examples and stdlib lead; the prose follows. When sources disagree — including when
examples contradict the stdlib or each other — **this spec is the tie-breaker**, and the resolution
is recorded with its rationale. funpack does not grammar-include what it cannot run.
