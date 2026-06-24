# 07 — Pipelines & scheduling

The pipeline is funpack's schedule: the **explicit, ordered** plan for a tick. Stage *order is its
meaning*; there are no numeric priorities or layers (magic-number ordering is the knob
[`01`](01-axioms.md) P5 bans).

---

## 1. The surface

```funpack
pipeline Pong {
  startup:   [setup]
  control:   [paddle_move, ball_move]
  collision: [wall_bounce, paddle_bounce]
  scoring:   [score, tally, serve]
  render:    [draw_paddle, draw_ball, draw_score]
}
```

- A pipeline is **nothing but its ordered named stages**, run top-to-bottom. Stage names are
  documentary; their *position* is the contract.
- A **stage value** is one of: a **`[behavior]` list**; a single **engine-stage symbol** (e.g.
  `physics: solve`, an engine-owned stage — [`11`](11-physics.md)); or a **sub-pipeline name**
  (fan-out, §3).
- **`startup:`** runs once before tick 0 (Startup); **`render:`** / **`ui:`** / **`audio:`** are the
  terminal projection stages; everything between is Update ([`06`](06-things-behaviors.md)).

### Wiring lives in the entrypoint, never in the pipeline

A pipeline carries **no configuration**. Its runtime wiring — the fixed `tick`, the input
`bindings`, and the optional `net:` topology ([`25`](25-netcode.md)) — is not logic; it lifts into a
named **entrypoint** in `funpack_configs/entrypoints.fcfg` ([`14`](14-project-config.md)):

```
use hunt.{Hunt, bindings}
entrypoint main {
  pipeline = Hunt
  tick     = 60hz
  bindings = bindings
}
```

`tick` and `net:` are entrypoint-level and top-level only (sub-pipelines inherit them; there are no
multi-rate ticks). `bindings` is build-time wiring, not tick state.

> **Canonical.** An in-pipeline `data { tick: …, bindings: … }` block is **rejected**: it
> reintroduces the order-vs-config ambiguity the entrypoint split exists to remove. Everything inside
> a `pipeline` is a stage.

---

## 2. Ordering, the "collector", and signals

Signals flow **forward**: a signal emitted in an earlier stage is visible to every later stage the
same tick. **There is no collector construct — a stage's position *is* the collector.** Two rules
close the determinism holes:

- **Inter-stage** — the flattened pipeline (§3) is one total order; each stage sees all earlier
  blackboard writes and signals.
- **Intra-stage** — listed behaviors run top-to-bottom; a per-thing behavior runs over its instances
  in **stable `Id` order**, and that order is **observable**: within the step a later instance (higher
  `Id`) sees earlier instances' same-step blackboard writes through a direct `View` — the per-instance
  run is **instance-granular** (evolving columns *within* the step, [`08`](08-state.md)), **not** a
  simultaneous `map` over a step-entry snapshot. A reflection-symmetric population is therefore decided
  by `Id` order (the lower `Id` moves first).

**Effect closure over the pipeline:** every signal a behavior emits must have a consuming stage
**downstream in the flattened order** (deferred edges — UI `Msg`, IO results — may be consumed next
tick anywhere). This edge-check complements the behavior-contract node-check
([`06`](06-things-behaviors.md)).

---

## 3. Fan-out — small, isolated units

A stage can be a sub-pipeline, so a game decomposes into focused pipelines:

```funpack
pipeline Game { startup: [setup], input: Input, combat: Combat, physics: Physics, render: Render }
pipeline Combat { detect: [detect_hits], resolve: [apply_damage, check_death] }
```

The engine flattens the tree **depth-first** into one total order
(`setup → input.* → combat.detect → combat.resolve → physics.* → render.*`). Fan-out is
**deterministic, sequential, synchronous** — never concurrent. **Pipeline composition is static**:
the tree is fixed at compile time, and there is **no dynamic per-member fan-out** (no one
sub-pipeline instantiated per group member). Per-entity processing is the **stable-`Id` fold of a
behavior over its instances** within a stage ([`06`](06-things-behaviors.md)), and per-group
isolation is expressed through **signal contracts**, never a scheduling construct. A sub-pipeline's
interface is the **signals it consumes and emits** — its signal contract — so an agent loads one
sub-pipeline and its signal types, never the whole game (the P7 bounded-context payoff). Isolation is
**logic + signal-contract, not state**: pipelines share the thing/blackboard space and are ordered
over it.

**Nesting is uncapped** (each level is a small signal-bounded unit — decomposition done right). The
risk is navigability, an P7 concern solved by tooling, not a cap: the toolchain **derives and renders
the whole flattened tree** plus a `signal → producer(s) → consumer` routing map. Because the view is
derived, it never drifts, and effect closure runs on the same derived graph.

---

## 4. The tick is the transaction

A tick is a **fold over the flattened pipeline**, which makes it the transaction manager — ACID is
free ([`08`](08-state.md)):

- **Population is fixed within a tick** — `Spawn`/`Despawn` are commands applied as one deterministic
  batch at the **tick boundary**; a thing spawned this tick is first queryable next tick.
- **Blackboard writes fold forward** — a stage sees every earlier stage's writes, and *within* a
  per-thing stage a later instance (higher `Id`) sees earlier instances' same-stage writes through a
  direct `View` (instance-granular, [`08`](08-state.md)). The tick is a **fold**, never a simultaneous
  `map` over a pre-tick snapshot — modeling it as one silently diverges from the live `Id`-ordered
  schedule.
- Replay re-folds recorded inputs to a bit-identical frame.

There is a **single top-level tick** over **shared state**.

---

## 5. Single tick, shared state

There is no dynamic fan-out (one sub-pipeline per group member), no multi-rate ticks, and no
per-pipeline state partitioning: a single top-level tick runs over shared state, and isolation is via
signal contracts only ([`01`](01-axioms.md) §4). Pipelines do **not** own disjoint state slices —
all pipelines share the one thing/blackboard space, the deterministic world database
([`08`](08-state.md)); isolation between sub-pipelines is the **signal interface** (the consumed and
emitted signal types), never a state partition.
