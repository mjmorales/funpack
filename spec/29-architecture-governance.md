# 29 — Architecture & governance

funpack's dev toolchain is **one first-party binary over one versioned contract**, plus a runtime:

- **`funpack`** — the language toolchain. Parses, typechecks, runs the structural quality gates,
  formats, tests, resolves dependencies, runs the asset pipeline, and **emits a versioned Index
  Contract**. A pure `source → artifact` function. funpack also carries the **`warden`
  sub-toolchain** (`funpack warden …`) — a *pure projection surface* over its own emitted index
  (`find`/`holes`/`probes`/`debt`/`graph`/`tags`/`pipeline`) — and the **warden ethos**: the governance discipline
  the language's own mechanisms (the directives, the gates, the index) enforce.
- **the runtime** ([`09`](09-runtime.md)) — executes the artifact. It is the **one impure consumer of
  the pure compiler's output**: the engine never depends on the compiler.

**`warden` is not a separate binary, process, or clock.** It is two things built atop funpack: a
*pure sub-toolchain* (`funpack warden`) that reads the index and projects, and an *ethos* — the
self-anchoring, debt-with-a-deadline, earned-not-asserted discipline that the directives ([`05`](05-directives.md))
and the structural gates already mechanize. Everything warden does is a pure function of compiled
source, so it lives inside the one binary without a clock and without touching the determinism
boundary. General agent-swarm orchestration — a stateful task DB, leases, dispatch, cross-run
escalation — is **out of scope**: it is the operator's agent-governance tooling, not an engine
mechanism, and funpack neither owns nor reimplements it.

## 1. Purity is by construction, not by a process boundary

`funpack` has no clock, no database, no network, and no mutable cross-run state in scope — it is
bit-identical **by construction**. It is pure not because a separate process quarantines the clock,
but because the impure, clock-bearing, run-spanning work that would break determinism is **simply not
in the engine's job**. Every mechanism funpack *does* own sorts onto the pure side with no leftovers:
the structural gates (cyclomatic/nesting/fn-size/arity, exhaustiveness, effect-closure, duplication,
the `--release` hole-ban — pure AST or a mode flag) are compile-time verdicts; the `funpack warden`
query surface is a **pure projection of the already-emitted index**, reading a build product and
re-presenting it, never advancing a clock or writing authored state.

```
agent → │ funpack: src → artifact + index, and `funpack warden` projects the index │ ── artifact ──► runtime
        └─────────────────────────────────────────────────────────────────────────┘
                one-way data: source → index → projection.  warden NEVER writes source.
```

What is deliberately *absent* is the impure half a stateful governor would carry: a build clock that
expires debt by wall-time, leases that arbitrate concurrent agents, a dispatch queue, an escalation
loop over run history. Those need a clock or run-history; funpack has neither, so they belong to the
operator's chosen agent-governance tool, **above** the engine — not inside it.

## 2. The Index Contract

The **one** structured interface funpack exposes: a versioned data contract emitted per build. The
compiler *produces* it; the `funpack warden` sub-toolchain (and any other tool) *consumes* it as a
plain, greppable build product — a **data contract, not a control surface** (the Unix way applied to
the compiler's own output). It is a **structural interface** (the [`06`](06-things-behaviors.md) idea
applied to the toolchain seam): closed, versioned, **exact-match with all fields mandatory** —
`funpack` stamps the schema version and a consumer refuses a mismatch with a fix-it rather than
best-effort parsing; an under- or over-shaped contract is an error, **there are no optional fields**.
The contract is a **whole-stream emission per build** — its meaning is the complete index;
**incremental per-file deltas are an invisible compiler optimization** that does not change the
contract's meaning. The transport is NDJSON (greppable, diffable, an ephemeral build product).
Payload: a `schema_version`; one **`decl`** record per declaration (`qualified_name`, `kind`,
file/span, `@doc`, `gtags`, `stub`, `todo`, `debug` probes, `emits`/`consumes`, `calls`, `dup_class`
normalized-AST hash, `mut_data`); and one **`project`** record — the authored `entrypoints`, `builds`,
and `tag_registry` lifted from `.fcfg` plus the derived `capabilities`, `pipeline_flattened`, and
`gate_results` projected from source ([`14`](14-project-config.md) §3 owns this enumeration; this
section defers to it). The `todo` projection is **not a presence boolean** — it carries the parsed
`@todo`'s **message** and its **window**: the expiry form (the closed enum of how the deadline is
expressed) and the window components (which window, and when it expires). The debt review surface
([§4](#4-governance--the-engines-swarm-backstops-are-compile-time)) reads *which* todo and *when* it
expires from this field, not merely that one exists; an absent `@todo` projects an empty/null `todo`,
never a fabricated window. Surfacing the message + window is the operator-visibility doctrine applied
to the contract — the field carries the facts the debt surface presents, no richer index field ahead
of this spec text. Package identity (`name`/`version`) is `project.fcfg`'s
([`15`](15-modules.md) §5), **not** a record field — lifting it in is a deliberate contract reshape
behind a schema-version bump, never silent drift.
Records carry **no record-level kind tag** — each kind is discriminated **structurally** by its
mandatory field signature, **disjoint** across kinds by construction: every kind includes at least one
mandatory marker field absent from every other kind (`decl`: `qualified_name` / `dup_class` /
`mut_data`; `project`: `pipeline_flattened` / `gate_results`), so no two records alias. The consumer
dispatches on that signature and never fabricates a tag the producer omits; introducing a kind that
cannot be made disjoint is a contract reshape behind a schema-version bump, not an optional tag.
Sufficient for every `warden` query — never the AST, never the grammar. The governance surface reads
**facts the compiler already proved**, not the source. This is the **first** of five structured
contracts (then stdlib-interface, modapi, introspection, netcode); a single contract definition,
shared by producer and consumer, is the schema's single source of truth, so producer and consumer
cannot drift.

## 3. One-way data flow

The `warden` surface **never writes source** — it reports ("`T-0042`'s hole is still open"); the
*agent* edits source; recompilation regenerates the index; the projection re-derives. The agent is the
sole writer; this removes the two-writers-on-one-file class before it starts. The storage split
follows: **derived** data (holes, todos, tags — a projection of the index; ephemeral, gitignored,
rebuilt) vs. **authored** data (the source itself, the `.fcfg` config, the directives in it —
committed). funpack carries **one** determinism tier: source → bit-identical artifact. (There is no
second event-log tier, because there is no stateful task store in the engine.) The operator lives at
the front door — `funpack build`/`check`/`test`/`warden` — and the engine never depends on
governance. **`--release` is a `funpack` compiler mode** — it gates holes and debug directives, and
the mode lives in the pure compiler, so the release-defining decision stays on the pure side.

### `funpack check` — the verdict-only verb

**`funpack check`** is the front door's adjudication verb: it runs the **full checked pipeline**
over the [`14`](14-project-config.md) project tree — project-tree read → per-module parse → the
structural gates → resolve → typecheck → contracts → pipeline flattening / effect closure — every
module against **one project-wide module index**, exactly the path `funpack build` compiles. What
it removes is the emission half: `check` writes **no product** — no `.funpack/`, no artifact, no
Index Contract. It is `build`'s verdict with the write deleted, so the compiler's full judgment is
available without touching the tree.

The exit contract mirrors `build`'s **two tiers**: **0** — the tree compiles clean; **2** — a
malformed tree or **any** compile/gate failure. There is deliberately **no exit-1 tier**: counted
assertion failures belong to `funpack test`, and a compile error is **never a counted failure** —
`check` refuses, it does not tally.

The one-line verdict on stdout is operator-facing and **advisory**; a verb's machine contract is
**exclusively its exit code** — tooling must never parse verdict wording. This holds for every
front-door verb, not `check` alone.

**`check --release` applies the §4 hole-ban**: a typed hole ([`05`](05-directives.md)) anywhere in
the tree is the `Holed_Declaration` refusal — exit 2. **Shippability is adjudicable without
emission**: the verdict is a pure function of `(AST, mode)`, consistent with §1's gate enumeration
("pure AST or a mode flag") and [`14`](14-project-config.md) §7's compiler-owned `--release` mode.

`check` keeps this section's split intact: it **recompiles** — it never consumes the emitted index
(`funpack warden` is the index *projection*; `check` is the source *adjudication*), so a stale or
absent index changes nothing about a `check` verdict, and the one-way arrow
source → index → projection gains no back-edge.

### `funpack render-check` — green ≠ works

A check-clean, test-green build can still ship a **black screen**: `funpack test` folds **pure
behavior functions in isolation** ([`04`](04-effects.md)) and never runs the live
thing → pipeline → render wiring, so a game whose render stage produces an empty draw-list passes
every gate and renders nothing. **`funpack render-check`** closes that gap with the one thing a unit
test cannot do — it **builds the project, then folds the whole pipeline headlessly from a cold seeded
startup for N ticks** and asserts the projected [`20`](20-render.md) draw-list is **non-empty** on at
least one frame.

The fold is **faithful**: render is a deterministic post-commit projection of the committed world
([`20`](20-render.md) §5), so the headless projection is the **same** one the live present path
shows — a `render-check` failure is exactly the black screen the window would. The check is
**seed-correct**: a `uses_rng` game ([`09`](09-runtime.md) §6) folds under the same resolved
root seed the live window uses, so its first frame populates rather than freezing at declared
defaults. It needs **no display** — it links no present boundary and runs inside the deterministic,
SDL-free test floor.

The exit contract adds the **third tier** `check` deliberately omits: **0** — the game drew, **or**
it declares no `render:` stage (a ui-only or non-visual project draws an empty draw-list by design,
so there is nothing to assert); **1** — the game **has** a `render:` stage but drew nothing across
the window (the counted black-screen failure); **2** — a build/gate refusal or no entrypoint. The
window is a fixed compiler default; a game whose first frame is genuinely delayed widens it
(`--ticks`). The verdict is scoped to the `render:` stage because that is the slot whose emptiness is
a fault — the singleton-vs-`thing` modeling choice it grew out of is *not* a structural property
(see [`06`](06-things-behaviors.md) §2).

## 4. Governance — the engine's swarm backstops are compile-time

"Keep agents on track" is an enumerated set of failure modes. The ones the **engine** can answer are
each bound to a **compile-time backstop** — no advisory warnings, no knobs. The ones that need a clock
or run-history are **not** engine mechanisms; they are the operator's agent-governance tool's job, and
funpack only supplies the facts (via the index) that such a tool reads.

| Agent failure mode | Engine backstop (compile-time) |
|---|---|
| reimplements an existing helper | duplication gate (post-hoc) + `funpack warden find` (pre-hoc, a pure index query) |
| ships incomplete code | `@stub` forbidden under `--release` |
| scope creep inside one function | fixed per-function budgets force decomposition |
| tag namespace rots | `@gtag` registry; an unregistered tag is a compile error |
| leaves debt with no record | `@todo` is a directive the index reports; `funpack warden debt` surfaces it for review |

The clock- and run-history-bearing modes — `@todo` *wall-clock expiry* to a build error, lease
conflict between concurrent agents, fix-loop auto-escalation, dispatch — are **out of the engine's
scope** (§1). If a project wants hard `@todo` expiry, the build-clock is supplied as a **recorded input
to `funpack build`** (an argument, never ambient state), keeping funpack a pure function of
`(source, clock)` exactly as the runtime is a pure function of `(state, input, seed)`; otherwise debt
is indexed and reviewed, not auto-failed.

### The `warden` query surface

`funpack warden`'s query surface (`find`/`holes`/`probes`/`debt`/`graph`/`tags`/`pipeline`) is **reuse-before-write**,
a pure projection of the index — it answers over the contract, **never the AST**. `probes` is the
first-class enumeration of every **probed declaration** — the `decl` record's `debug` probes
([§2](#2-the-index-contract)) — exactly as `holes` enumerates `@stub` declarations and `debt`
enumerates `@todo` debt: a single index projection, one row per probed decl, **never** the bare
debug-field bytes a `find` query incidentally exposes. This is [`28`](28-introspection.md) §4's mandate
that the operator sees **every outstanding probe** discharged as a first-class read, since probes
auto-register via the index; without `probes` an outstanding probe would be visible only as a debug
field threaded through `find`, not the enumeration `holes` already provides. **Acceptance is
earned, not self-attested** — a task's completion is proven by recompile (a named `test` passes, a
`@gtag` query returns the expected cardinality, a structural gate clears, a diff property holds), so
"done" is a fact the compiler establishes, not a claim an agent makes. The operator reviews **debt and
intent** through these projections — there are no threshold knobs (there are none) — and because the
authored surface is the committed source and its directives, operator review is **code review of the
source diff**, with a full provenance chain (code change → anchor → index → review).

## 5. Strategic payoff — governance falls out of the contract

Because the compiler is a quality gate that emits its verdicts as a structured contract, governance is
not a second product to build — it is a **thin ethos plus a pure projection** that *falls out of* the
index for free. The un-copyable value is the **welding**: governance earned from a deterministic
quality-gate compiler, where "reuse before write", "debt has a deadline", and "done is proven, not
asserted" are enforced by the language's own mechanisms rather than by an advisory layer bolted
alongside. A monolithic *language* toolchain that also projects its own governance surface over one
internal contract is an internal boundary, not a plugin ecosystem — and not a general swarm-governance
substrate, which is the operator's tooling, deliberately not the engine's.
