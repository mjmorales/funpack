---
name: funpack-game-model
description: The funpack runtime model — things, behaviors, signals, commands, and pipelines. Use when designing or reasoning about how a funpack game is structured and scheduled — what a behavior's parameters/return mean, how things communicate via signals, effect closure, the pipeline schedule and tick fold, the slot contracts (Update/Render/Ui/Audio/Startup), and why behaviors are unit-testable. Triggers on "behavior", "signal", "pipeline", "thing", "tick", "spawn/despawn", "effect closure", "render/audio/ui stage", "how does a funpack game work".
---

# funpack runtime model — things, behaviors, pipelines

A funpack game is a **deterministic fold**. State lives *with* the entity, every transition is a
**pure function**, and the **only cross-entity channel is data**. This skill is the paradigm; for
syntax see `funpack-language`, for the APIs see `funpack-engine-api`.

## The one-paragraph mental model

A **`thing`** owns its state (a `data` blackboard). A **`behavior on Thing`** is a pure
`fn step(self, …reads) -> …writes` that runs once per instance per tick: **its parameters are its
reads, its return is its writes**, and it writes **only its own thing**. To influence another thing
it emits a **`signal`** — the sole cross-thing channel, delivered synchronously, same-tick, forward
in pipeline order. A **`pipeline`** is an explicit ordered schedule of stages; a tick is a **fold**
over the flattened pipeline, so a replay re-folds the same recorded inputs to a bit-identical frame.
Effects (`[Draw]`, `[Spawn]`, `[Save]`) are **returned as data**, never performed — which is why
every behavior, renderers included, is a plain function you test by calling `name.step(...)`.

## Things — entity = colocated state

A `thing` owns a **blackboard**: a `data` value holding its whole state, traveling together
(document-oriented, **not** ECS component tables). Each instance has a stable `Id` from a
deterministic spawn counter; all instances of a type form a queryable table. Things **compose**
behaviors; they never inherit.

```funpack
thing Ball { pos: Vec2, vel: Vec2 }
thing Snake { head: Cell = Cell{x:10,y:10}, body: [Cell] = [], dir: Dir = Dir::Right }
```

Use a **`singleton`** for exactly-one state — a scoreboard, a camera, a menu. The engine spawns it
before tick 0 and you access it by type (it yields `Scoreboard`, never `Option`/`[Scoreboard]`); its
behaviors run once per tick. Do **not** model single-instance state as a `thing` you `Spawn` once in
`setup` (some older examples do; `singleton` is canonical).

Because a blackboard is `data`, it serializes by construction — saves, replay, and network sync are
free. `Ref[T]`/`Owned[T]` are phantom-typed ids (not pointers), so the world is a flat id-graph that
serializes without pointer swizzling.

## Behaviors — pure transitions

```funpack
@gtag("paddle")
behavior paddle_move on Paddle {
  fn step(self: Paddle, input: Input, time: Time) -> Paddle {
    let dir = input.value(self.player, Steer::Move)
    return self with { y: clamp(self.y + dir * self.speed * time.dt, 0.0, BOARD.h) }
  }
}
```

`step` is the **reserved entry point** (the Unity `Update` / Elm `update` prior) — every behavior has
exactly one, and it runs **once per instance in stable `Id` order**.

**Parameters are the reads** — the signature *is* the effect declaration. The four legal input kinds:

| Param | Meaning |
|---|---|
| `self: Thing` | the behavior's own blackboard |
| a resource: `input: Input`, `time: Time`, `rng: Rng`, `nav: Nav` | read-only engine inputs (`Rng` is **threaded** — you must return it advanced) |
| an inbound signal list: `goals: [Goal]` | signals routed to this stage this tick |
| `paddles: View[Paddle]` | a **read-only** view of other things (collision, targeting) |

**The return is the writes** — one or a tuple of:

| Return | Meaning |
|---|---|
| `-> Thing` (a new `self`) | the new blackboard, built with `self with { … }` or a fresh literal |
| `-> [Signal]` | emit signals (the only way to influence another thing) |
| `-> [Command]` | engine effects-as-data (`[Spawn]`, `[Draw]`, `[Despawn]`, …) |
| `-> (Rng, [Spawn])`, `-> ([Despawn], [Delivered])` | combinations (threaded rng + commands; commands + signals) |

**The core invariant — read your own, signal the rest:** a behavior writes **only its own thing's
blackboard**. It may *read* other things through a `View`, but never *write* one. To change a
different thing — including a singleton — it **emits a signal** the target's own behavior folds
downstream. This single rule is what makes the model deterministic and every behavior testable.

A behavior with no resource param "observes nothing"; with no command/signal return "causes nothing"
and is provably pure. Taking a resource you don't need, or emitting a signal nothing consumes, is
caught at compile time.

## Signals — the sole cross-thing channel

```funpack
signal Goal { side: Side }      // plain data the engine routes
signal Died {}                  // empty payload is legal
```

- **Emit** by returning `[Signal]`: `score.step(self) -> [Goal]` returns `[Goal{side}]` or `[]`.
- **Consume** by taking a `[Signal]` param: `tally.step(self, goals: [Goal])`. There is **no
  separate `on Signal(...)` handler** — a stage's *position* is the collector. The idiom is a fold
  over the signal list: `fold(goals, self, add_goal)`.
- **Delivery is forward, synchronous, same-tick, in pipeline order.** A signal emitted in an earlier
  stage is visible to every later stage the same tick. Canonical chain (pong's `scoring:` stage):
  `score` emits `Goal` → `tally` folds it into the score → `serve` reads it to reset the ball — all
  one tick, ordered by list position.

**Effect closure (a compile-time gate):** every emitted signal **must** have a downstream consumer —
emitting a `Goal` nothing tallies, or dropping a `Saved`, is a compile error. The exception is
**deferred edges** (UI `Msg`, IO results like `Saved`/`Restored`): they arrive **next tick** and may
be consumed anywhere, not strictly downstream.

## Commands — effects as data

Effects are **returned as plain data, never performed as IO** — this is why behaviors are pure.
There are no ambient IO primitives in scope, so hidden IO is unrepresentable. The closed engine
command set:

```
[Spawn] [Despawn] [Draw] [Draw3] [Sound] [Audio] [Save] [Restore]
[ApplySettings] [Load] [Unload] [SetTile]   (+ emitted signal lists [S])
```

```funpack
Spawn( Food{cell: cell} )    // PARENS — command-wrap is call syntax (Spawn{...} is wrong)
[Despawn()]                  // self-despawn needs no id
[Draw::Rect{at: self.pos, size: Vec2{x:3.0,y:3.0}, color: Color::White}]
```

**Population is fixed within a tick** — `Spawn`/`Despawn` apply as one deterministic batch at the
tick boundary; a thing spawned this tick is first queryable next tick. **IO is a deferred,
unignorable result:** a command (e.g. `[Save]`) requests IO; the outcome arrives next tick as a
signal carrying a `Result[…, IoError]` whose error arm a `match` must cover — a failed write can
never be silently dropped.

## Pipelines — the explicit ordered schedule

```funpack
pipeline Pong {
  startup:   [setup]
  control:   [paddle_move, ball_move]
  collision: [wall_bounce, paddle_bounce]
  scoring:   [score, tally, serve]
  render:    [draw_paddle, draw_ball, draw_score]
}
```

A pipeline is **nothing but its ordered named stages**, run top-to-bottom. Stage names are
documentary; their **position is the contract** (no numeric priorities). A stage value is one of
three kinds:

- a **`[behavior]` list** — `control: [paddle_move, ball_move]`;
- a single **engine-stage symbol** (a bare `LOWER_IDENT`) — `physics: solve` — an engine-owned
  stage (the solver integrates `pos`/`vel` and routes contacts/triggers as inbound signals); the
  discriminator is the *bare symbol value*, not the colon;
- a **sub-pipeline name** (`UPPER_IDENT`) for fan-out — the engine flattens the tree **depth-first**
  into one total order; fan-out is deterministic, sequential, synchronous (never concurrent) and
  static.

**Reserved slots:** `startup:` runs once before tick 0; `render:` / `ui:` / `audio:` are the
terminal projection stages; everything between is Update.

**The tick is a deterministic fold over the flattened pipeline.** Blackboard writes fold forward —
each stage sees every earlier stage's writes and signals. Two ordering rules close all determinism
holes: *inter-stage* (the flattened pipeline is one total order) and *intra-stage* (listed behaviors
run top-to-bottom; a per-thing behavior runs over its instances in stable `Id` order).

Runtime wiring (`tick` rate, `bindings`, `logical` resolution, `net`) lives in the **entrypoint**
(`funpack_configs/entrypoints.fcfg`), not the pipeline — see `funpack-project`. The `fn bindings()`
is wired in by the entrypoint, not listed as a stage.

## Slot contracts — node check vs edge check

A behavior takes a contract **implicitly, by occupying a stage slot** (Go-interface style, no
annotation). The set is closed:

| Contract | Stage | Inputs | Return |
|---|---|---|---|
| **Update** | any interior stage | blackboard / resources / signals / `View` | own blackboard and/or `[Signal]`/`[Command]` — must write or emit *something* |
| **Render** | terminal `render:` | blackboard / resources / `View` — **no signals, no `Rng`** | `[Draw]` / `[Draw3]` only — cannot emit, command, or write a blackboard |
| **Ui** | `ui:` (after `render:`) | blackboard / resources / `View` | `View[Msg]` — the engine hit-tests pointer input and delivers each `Msg` as a deferred signal next tick |
| **Audio** | `audio:` | blackboard / resources / `View` (output-only) | `[Audio]` — engine diffs the keyed set and reconciles |
| **Startup** | `startup:` | engine resources incl. `Rng`; no reads of unspawned things | `[Spawn]` (or a tuple ending in it); runs once before tick 0 |

Render is the strictest (output-only); Ui is the one visual contract with an inbound edge (its
`Msg`). Writing another thing's blackboard, or returning anything other than the blackboard / a
signal list / a command list, is a compile error.

**Two layers, both must pass:** the per-behavior **node check** ("is this behavior well-formed for
its slot?") and the cross-behavior **edge check** = effect closure ("does every emitted signal have
a consumer?").

## Testability falls out of purity

Every behavior — renderers included — is a plain function, invoked by its reserved entry point
`name.step(args)` with deterministic fixtures (`View.of([…])`, `Input.empty()`, `Time.at(dt)`,
`Nav.of(route)`). No world or harness.

```funpack
test "score emits a left goal past the right edge" {              // emit side: assert the signal list
  assert score.step(Ball{pos: Vec2{x: 161.0, y: 60.0}, vel: Vec2{x: 70.0, y: 40.0}}) == [Goal{side: Side::Left}]
}
test "tally folds goals into the score" {                          // consume side: feed signals, assert new state
  assert tally.step(Scoreboard{left: 0, right: 0}, [Goal{side: Side::Left}, Goal{side: Side::Left}]) == Scoreboard{left: 2, right: 0}
}
test "draw_ball emits one white rect at the ball position" {       // renderers are pure too: assert the draw list
  assert draw_ball.step(Ball{pos: Vec2{x: 10.0, y: 20.0}, vel: Vec2{x: 0.0, y: 0.0}}) == [Draw::Rect{at: Vec2{x: 10.0, y: 20.0}, size: Vec2{x: 3.0, y: 3.0}, color: Color::White}]
}
```

## Designing a game — the standard `.fun` skeleton

`enum`s for state/actions → `data`/`thing`/`signal` declarations → pure `fn` helpers → `behavior`s →
`fn bindings() -> Bindings` (device mapping) → `fn setup() -> [Spawn]` (initial population) →
`pipeline Name { … }` → `test` blocks. Put the schedule in stage order: gather input → mutate state
→ resolve collisions/physics → emit & fold signals → project to `render:`/`ui:`/`audio:`.
