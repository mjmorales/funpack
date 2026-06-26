# 28 — Introspection & debugging

The runtime does not merely execute the artifact — it is **fully observable and controllable by an
agent at every tick, by construction**. The **introspection contract** is the fourth structured
contract (`runtime → agent`). There is no visual debugger; the channel is programmatic, flat-text,
and JSON-first, and the lone visual artifact (a screenshot) is requested programmatically.

> **Total observability is a theorem, not a feature.** Every lever an agent needs is already a
> consequence of an axiom; the contract only exposes it.

## 1. Observability is a theorem

| Axiom / mechanism | Lever it already grants |
|---|---|
| Serialization closure | dump any blackboard, or the whole world, at any tick — no instrumentation |
| Simulation determinism | replay, step, rewind, branch — bit-identical; no heisenbugs |
| Pure behaviors | replay one behavior in isolation from captured inputs |
| Explicit pipeline | stepping granularity *is* the schedule: tick → stage → behavior → instance |
| Signals are data | the live dataflow is observable; causality = walk the recorded graph backward |
| Self-index (`@gtag`) / world-as-DB (`query`, `@index`) | query live state by tag, index, relationship, nearest — no bespoke engine |
| COW-persistent store | snapshots ≈ retaining a root pointer → cheap rewind |

The work is the *surface*, not the observability.

## 2. The contract & the warranty line

Transport is **NDJSON** over a local duplex stream; the shape is a **JSON envelope** carrying
**three closed message kinds**, each a fixed-order field tuple, **versioned exact-match** (every
envelope stamps `v`; a consumer refuses a version or field-shape mismatch rather than best-effort
parsing — the §29 Index-Contract discipline applied to the wire):

- **request** — `{v, id, cmd, args}`. `id` correlates the response; `cmd` is the command name; `args`
  is its argument object.
- **response** — `{v, id, ok, cmd, result | error}`. `ok` is the success boolean; exactly one of
  `result` (when `ok`) or `error` (otherwise) is present — never both, never neither.
- **async-event** — `{v, event, …}`, an unsolicited push correlated by `event` name (not `id`). The
  event names are the §3 closed set; `breakpoint_hit` and `watch_fired` are the two that carry probe
  payloads (the firing probe's target and value).

**The value language is node-forest-only; the runtime never compiles funpack source live.** An
*expression* the channel evaluates — a breakpoint predicate, an injected or computed value, a query —
is **never** a funpack source string the runtime parses and compiles. The runtime owns no funpack
compiler and never imports one ([`29`](29-architecture-governance.md) §1: the runtime consumes the
**artifact**, never the compiler), so the only evaluable form is a **node forest** the runtime's
existing interpreter ([`09`](09-runtime.md)) folds:

- **probe predicate bodies** (§ 4) are compiled funpack-side to node forests and **ride the
  artifact** (§ 4) — they are evaluated at run time, never compiled at run time.
- **client-injected and client-computed values** ship **pre-encoded in the artifact's value
  encoding** (the same `decode_default_value` form the artifact already carries). A richer
  client-supplied expression takes the **same node-forest-over-the-wire** form — the client (or
  funpack) does the compilation; the runtime only interprets.

This keeps the channel inside both the **engine boundary** (no compiler seam in the runtime) and the
**determinism boundary** (every evaluation is an interpreter fold of nodes the artifact or wire
supplied). **There is no debugger DSL**: query and value semantics are funpack's, exactly as the test
doubles are — but realized as node forests, not live-compiled source.

**Remote attach** serves the same contract on an **auth-gated port** — auth is **required**, never
optional; the auth mechanism (token, mTLS) is **operator deployment configuration, not language
doctrine**. Addressing **reuses index identity** — `Snake`, `Food#1`, `Eaten`, `Snake.eat` — so
static structure and live state share one namespace.

**A session over a live artifact is seeded by the run-time seed contract** ([`09`](09-runtime.md) §6).
Opening a session **without a recorded log** folds a fresh window, and for a `uses_rng` game it resolves
the root seed by the same precedence `funpack run`/`live` use (an explicit session seed argument, then
the config seed, then the fixed engine default) — so the debug surface reproduces the **real seeded
run** (state populated, draw-list non-empty), not a seedless empty one. Opening **over a recorded
replay log** folds that log's **pinned seed** instead. Either way the session reports its seededness, so
an agent distinguishes a genuinely seedless (no-RNG) game from a seeded one it is now observing.

**Observe addressing — canonical chain by default, `branch` to fork.** An `observe`-class command
reads the **canonical version chain** by default. It accepts an optional `branch` argument naming a
forked branch (created by `checkout`); when present, the command reads that branch's lineage, and
when **absent ⇒ canonical**. The `draw_list` command is the deterministic, **sim-pure draw-list
dump** — an observe command that reports the draw list the simulation produced, computed without
crossing the render/present boundary. It is kept **distinct from `screenshot(include_drawlist)`**,
which *does* cross into render/present; `draw_list` is non-perturbing and warranty-preserving,
`screenshot` is not sim-pure.

Commands split into two classes, and the split **is** the determinism warranty:

- **Observe — non-perturbing by construction.** Reading immutable serialized state copies nothing
  (structural sharing); replay is a pure re-fold; predicates are pure funpack. Observation can never
  change behavior — **no heisenbugs.** An observe-only session is safe to run in CI against a
  warranted recording.
- **Control — perturbing, so it forks.** Injecting input, forcing a field, spawning, emitting, or
  hot-reloading creates a **branch**: a new recording lineage off a snapshot, marked
  **non-warranted**; the trunk recording is never mutated. "What if?" is a git-like fork.

This is [`08`](08-state.md)'s CQRS split exposed: observe is the read side; control is a debug-only
write *outside* the normal own-blackboard/signal/command path, which is why it forks.

## 3. Time travel & the command surface

**Rewind** = nearest snapshot ≤ target + bounded replay forward, over a **fixed-cadence ring of COW
snapshots** (structural sharing makes the ring nearly free; cadence is a fixed engine constant). The
trace/time-travel buffer is **bounded by a fixed engine budget and is dev-only** — no spec numbers,
no per-build size knob. Time-travel and introspection are **dev-build only by construction and
stripped from release builds** — like the debug directives (§ 4), not a per-build opt-in toggle: a
release artifact carries no introspection machinery to enable.
**Causality is recomputed, not stored** — `trace "Snake.body"` answers *why is this so?* by a bounded
re-fold capturing the writes and signals that touched the target, so there is no always-on provenance
tax. **Sessions are themselves replayable** — the command stream is NDJSON and logged, so a debug
session (recording + command log) re-runs bit-identically and is shareable.

**Cadence and ring depth are fixed engine constants — no spec numbers.** The snapshot cadence and the
COW-snapshot ring depth are values the **engine owns**; the spec pins their *existence and fixedness*,
never their magnitudes, so this contract carries no number and no per-build knob. The chosen values
are **observably pinned by goldens**, so a change is a deliberate golden regen, never silent drift.

**`run` is synchronous to its target; `pause` is idempotent.** `run` advances to its target tick and
**returns only once the target is reached** — its response is the run's completion, never an early
acknowledgement of a still-advancing simulation. `pause` is **idempotent**: pausing an
already-paused session is a no-op that succeeds and reports the same paused state. `status` returns
the **fixed status-payload shape** — the current tick, the run/paused state, and the active branch
(canonical when none is forked) — the same shape every time, so a consumer parses one structure.

| Group | Commands | Class |
|---|---|---|
| time | `load run pause step rewind reset status` | observe |
| break | `break watch clear` (`break{when:<pred>}`, `break{on_signal}`) | observe |
| inspect | `signals pipeline trace diff replay_behavior draw_list screenshot` | observe |
| control | `inject_input set spawn despawn emit reload branch checkout` | control |
| self-heal | `capture_test audit` | observe |

Async events flow back: `breakpoint_hit`, `watch_fired`, `diverged`. The async channel carries
only unsolicited pushes — the two probe fires and the determinism-warranty break; `pause` and
`reload` report their outcome **synchronously** in the command response (`pause` reports the
paused state, `reload` its result), never as an async event.

## 4. Debug directives — the in-code, auditable form

The command surface is the *live* face; its in-code counterpart is the debug-directive family that
puts the same primitives in **source, where they are auditable** — the persisted, reviewed form of a
live command:

| Directive | On | Effect (debug mode) |
|---|---|---|
| `@break(<pred>)` | a behavior | pause when `<pred>` (over `self`/signals/resources) holds |
| `@log(<expr>)` | a behavior | emit the **structured, serialized value** each step, with tick/thing context |
| `@watch(<expr>)` | a behavior, or a `data` field (index-only — see note) | fire `watch_fired` when the value changes |
| `@trace` | a behavior or stage | record the full per-step `(in → out)` transition |

Three properties make them safe (the `@stub`/`@todo` discipline applied to debugging): **inert
w.r.t. logic / observe-class** (non-perturbing, warranty-preserving — active only in debug mode);
**dev-only, release-forbidden** (a `@break`/`@log` in a `--release` build is a compile error, so debug
residue cannot rot or ship); **task-DB-registered** (each auto-registers via the index contract, so
the operator sees every outstanding probe). `@log` is the printf-debugging killer — there is no
`print("here")`; there is `@log(self.head)`, which emits typed, queryable NDJSON.
Their persistence is the R2 argument: a live `break` evaporates with the session, a `@break` is
re-read on the next run and appears in the diff the operator reviews.

**Probes ride the executable artifact.** The index contract ([`29`](29-architecture-governance.md) §2)
is the **funpack-side** record of every probe (for operator review); it does not reach the runtime.
For a **live** debug session to honor an in-code `@break`/`@watch`/`@log`/`@trace`, the directive must
travel in the thing the runtime executes. The **executable artifact therefore carries a probe
section**, and a dev-build artifact emits it:

- Each probe entry carries its **kind** (`@break`/`@watch`/`@log`/`@trace`), its **target** (the
  behavior, stage, or `data` field it is attached to), and its **predicate/expression body as a node
  forest** — never as funpack source (§ 2: the runtime never compiles source live; the body is
  compiled funpack-side and rides the artifact, folded by the interpreter when the probe is honored).
- **funpack emits** the probe section into a dev-build artifact; **the runtime loads it and honors
  every probe** in a live session — `@break` pauses on its predicate, `@watch` fires `watch_fired` on
  change, `@log` emits its structured value, `@trace` records the per-step transition — so the
  operator sees every in-code probe live, not merely in the index.
- Adding the probe section **bumps `ARTIFACT_SCHEMA_VERSION`** — the closed-section discipline a new
  artifact section requires. A `--release` artifact carries **no** probe section (the
  release-forbidden property above): release artifacts hold no introspection machinery.

**A `@watch` on a `data` field is index-only — governed, indexed, and release-banned, but not honored
live.** A `data` ([`03`](03-data-model.md) §1) is a value record with no rows and no runtime identity;
it exists only embedded on a thing's blackboard, so there is no identity-bearing site at which a bare
`<data>.<field>` watch could fire (which embedding? a `data` never embedded in any thing has no live
instance at all). The live watch of an embedded data value is expressed instead through a **behavior
`@watch` on the carrying thing** — `@watch(self.<field>.<member>)`, where `self` is the identity-bearing
thing row. A data-field `@watch` therefore rides the index contract (§29 §2) for operator review and
takes the `--release` ban, but the runtime loads it and honors nothing — the one exception to "the
runtime honors every probe live." A `@trace` on a pipeline stage and every behavior-attached probe
honor live as stated; probe targets carry the §2 `Owner.member` qualified address (`<data>.<field>`,
`<pipeline>.<stage>`) so a sub-declaration site is named without ambiguity.

## 5. Debugging runs interpreted; the capture → test loop

Full stepping needs the interpreter (the semantic ground truth, [`09`](09-runtime.md)): setting a
behavior breakpoint **deoptimizes** that behavior from the JIT for the session; an `extern` body is
observable only at its call boundary; mods are always interpreted, so always fully debuggable.

The surface exists for one payoff — **the debugger's output is a regression test**. A watchpoint
predicate *is* a test assertion; **`capture_test`** extracts a behavior's `(self, resources, inbound
signals)` at tick N from the recording, runs the pure `step`, and emits a complete, idiomatic `test
"…" { … }` from the deterministic constructors — indistinguishable from a hand-written test. The
agent fixes the behavior, **hot-reloads**, re-runs the captured test, and the captured `test` lands in
source as a permanent, never-flaky regression. The live channel is hosted by the runtime (impure); the
durable artifacts (captured tests, branch recordings) flow into the ordinary `funpack` pipeline — the
governance surface never hosts the live channel.

**`audit` is the verification twin of `capture_test`.** Where `capture_test` extracts a regression
*from* a recording, **`audit` proves the recording itself is still warranted**: it re-folds the
recording from its snapshot + seed and confirms the re-run reproduces the recorded frame digests
bit-identically. A divergence is reported with the **first diverging tick** and the digest diff (the
`diverged` event), so an agent detects a broken **determinism warranty** — the failure mode that
silently invalidates replay, `capture_test`, and `rewind`, and every observe-class guarantee that rests
on bit-identical re-folding. `audit` is **observe-class** (a pure re-fold, non-perturbing); it is the
live self-heal diagnostic for the one property the whole introspection contract is built on.
