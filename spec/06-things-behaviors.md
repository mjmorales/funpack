# 06 — Things, behaviors & signals

The runtime model: a deterministic hybrid of OO colocation and ECS discipline. State lives *with*
the entity, every transition is pure, and the only cross-entity channel is data.

---

## 1. `thing` — an entity with colocated state

```funpack
thing Snake { head: Cell = Cell{x:10,y:10}, body: [Cell] = [], dir: Dir = Dir::Right }
thing Ball  { pos: Vec2, vel: Vec2 }
```

A `thing` owns a **blackboard** — a `data` value holding its state. There are no global component
tables; state is colocated (document-oriented, [`08`](08-state.md)). Each instance has a stable
`Id` from a deterministic spawn counter, and all instances of a type form a queryable "table".
Things **compose** behaviors; they never inherit. `thing` is a contextual leading keyword, so `let
thing = …` stays legal.

## 2. `singleton` — exactly one

```funpack
singleton Scoreboard { left: Int = 0, right: Int = 0 }
singleton Camera { at: Vec2 = Vec2{x:80,y:60}, zoom: Fixed = 1.0, shake: Vec2 = Vec2{x:0,y:0} }
```

A `singleton` is a **guaranteed-single-row** thing: spawned once by the engine before tick 0,
accessed **directly by type** (yielding `Scoreboard`, never `Option`/`[Scoreboard]`), with its
behaviors running once per tick. It is the database's row-count-1 constraint as a first-class
declaration; a contextual leading keyword like `thing`.

> **Canonical.** Exactly-one state is a `singleton`, never an ordinary `thing` spawned once in
> `setup`.

---

## 3. `behavior` — a pure transition attached to a thing

```funpack
behavior paddle_move on Paddle {
  fn step(self: Paddle, input: Input, time: Time) -> Paddle {
    let dir = input.value(self.player, Steer::Move)
    return self with { y: clamp(self.y + dir * self.speed * time.dt, 0.0, BOARD.h) }
  }
}
```

- **`on Thing`** — the thing whose blackboard this behavior owns. It runs **once per instance**, in
  **stable `Id` order** (a singleton ⇒ once).
- **`fn step(…)`** — the per-tick transition. `step` is a **built-in, reserved entry point** (the
  Unity `Update` / Elm `update` / React `render` prior), not a user-chosen name; every behavior has
  exactly one. **Its parameters are its reads; its return is its writes.**
  - the **blackboard** — its own `data`, bound as `self`;
  - **resources** — `Input`, `Time`, `Rng` (threaded), `Nav`/`Nav3` — read-only engine inputs;
  - **inbound signal lists** `[S]` — signals routed to this stage this tick;
  - a read-only **`View[Other]`** — cross-thing joins (collision, targeting).
- **Return** is the blackboard type, and/or a tuple adding emitted **signal** lists `[S]` and engine
  **command** lists (`[Spawn]`, `[Despawn]`, `[Draw]`, …).

Behaviors are tested by calling the reserved entry point directly: `paddle_move.step(p, input,
time)` ([`04`](04-effects.md)).

---

## 4. Read your own, signal the rest

A behavior writes **only its own thing's blackboard**. It may **read** other things through a
read-only `View`, but may **never write** another thing's blackboard. To change a *different* thing —
including a singleton — it **emits a signal** that the target's own behavior folds downstream (the
"emit a `Goal`, let `tally` fold it" pattern). This single rule — *no cross-thing mutation, ever* —
is what makes the model deterministic and every behavior testable as a plain function.

## 5. `signal` — the only cross-thing channel

A `signal` ([`03`](03-data-model.md) §6) is plain `data` the engine routes. Delivery is
**synchronous and deterministically ordered by the pipeline** — no mailbox, no concurrency, no
"eventually". A reference to another thing addresses a *signal*; it never grants mutation. Every
emitted signal is subject to effect closure ([`04`](04-effects.md), [`07`](07-pipelines.md)).

**Per-entity processing is the stable-`Id` fold**, not a scheduling construct: a behavior folds over
its thing's instances in stable `Id` order within a stage (§3), and there is **no dynamic
per-member fan-out** of sub-pipelines ([`07`](07-pipelines.md)). Per-group isolation is expressed
through the **signal contract** — the signal types a unit consumes and emits — never a per-group
schedule. All behaviors read and write the **one** thing/blackboard space, the deterministic world
database ([`08`](08-state.md)); pipelines do **not** own disjoint state slices, and isolation between
sub-pipelines is the signal interface, never a state partition.

---

## 6. Behavior contracts — slot-conferred, engine-closed

A behavior takes on a contract **only by occupying a pipeline stage slot** (implicit, Go-interface
style; no `@behavior` annotation). The set is closed and engine-defined; diagnostics point at the
behavior, not the slot.

| Contract | Stage | Inputs | Return |
|---|---|---|---|
| **Update** | any interior stage | blackboard / resources / signals / `View` | own blackboard and/or `[Signal]` + `[Command]` — must write or emit *something* (else dead code) |
| **Render** | terminal `render:` | blackboard / resources / `View` (**no** signals, **no** `Rng`) | `[Draw]` / `[Draw3]` — cannot emit, command, or write a blackboard |
| **Ui** | `ui:` (after `render:`) | blackboard / resources / `View` | `View[Msg]`; the engine hit-tests pointer input and delivers each `Msg` as a **deferred signal** next tick |
| **Audio** | `audio:` | blackboard / resources / `View` (output-only) | `[Audio]`; the engine diffs the keyed set and reconciles ([`22`](22-audio.md)) |
| **Startup** | `startup:` | engine resources (incl. `Rng`); no unspawned-thing reads | `[Spawn]` (or a tuple ending in it); runs once before tick 0 |

Render and Audio are output-only; **Ui** is the one visual contract with an inbound edge (its `Msg`),
which is exactly why it cannot be a Render behavior. Writing another thing's blackboard, or returning
a value that is neither the blackboard, a signal list, nor a command list, is a compile error.

**Two layers, kept separate:** contracts are the per-behavior **node** check ("well-formed for its
slot?"); effect closure ([`04`](04-effects.md), [`07`](07-pipelines.md)) is the cross-behavior
**edge** check ("does every emitted signal have a consumer?"). Both must pass.

---

## 7. Signal consumption

A behavior consumes signals by taking a `[Signal]` param on `step`; there is no separate
`on Signal(...)` reactive-handler form.
