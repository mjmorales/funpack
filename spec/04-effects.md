# 04 — Effects, purity & errors

How a caller knows what a function does, entirely from its signature. There are **no effect rows**
(`performs`/`!{…}`): the type *is* the effect signature.

---

## 1. Purity by signature

User code is **pure by default**. There are no ambient IO primitives in scope, so hidden IO is
*unrepresentable*. Two signature facts decide everything:

- **Causes an effect ⇔ the return type carries a command.** Command types are the closed engine set:
  `[Spawn]`, `[Despawn]`, `[Draw]`, `[Draw3]`, `[Sound]`, `[Audio]`, `[Save]`, `[Restore]`,
  `[ApplySettings]`, `[Load]`, `[Unload]`, `[SetTile]`, and emitted **signal** lists `[S]`. No
  command in the return ⇒ the function causes nothing.
- **Observes the world ⇔ it takes an engine resource.** Resources are the read-only engine inputs:
  `Input`, `Time`, `Rng`, `Nav`/`Nav3`, and inbound IO-result signals. No such parameter ⇒ the
  function observes nothing.

A function with **neither** is **provably pure by construction** — the *absence* of effect types is
a positive purity guarantee, stronger than any `performs IO` annotation.

`Rng` is **threaded**: a function that takes an `Rng` must return the advanced `Rng` (every draw
returns `(value, next_rng)`); it is never silently advanced ([`10`](10-numerics.md)).

```funpack
fn advance(at: Vec2, vel: Vec2, dt: Fixed) -> Vec2          // pure: no resource, no command
behavior score on Ball { fn step(self: Ball) -> [Goal] }    // emits a signal (an effect)
fn setup(rng: Rng) -> (Rng, [Spawn])                        // observes Rng, causes Spawn
```

---

## 2. Errors are values

No exceptions, no panics in sim code, no undefined behavior, no `null`. Fallibility is
`Result[T, E]`, and the compiler **forces exhaustive handling** of `E` via `match`. Optional absence
is `Option[T]`, likewise forced. Arithmetic is **total** — saturating, with defined division by zero
— so it never traps and never needs a `Result` threaded through every divide; when detecting the
edge *is* the point, the explicit checked form returns an `Option` ([`10`](10-numerics.md)).

---

## 3. IO is a deferred, unignorable result

IO is requested as a command (edge-triggered, returned from an Update behavior) and its outcome
arrives **next tick** as a signal carrying a `Result`:

```funpack
behavior save_key on Menu { fn step(self: Menu, input: Input) -> [Save] { … } }   // request
behavior on_persist_result on Menu {                                              // outcome, next tick
  fn step(self: Menu, saved: [Saved]) -> Menu {
    return fold(saved, self, fn(m, r) {
      return match r.result {                       // Result[…, IoError] — both arms mandatory
        Result::Ok(_)  => m with { status: Option::Some("saved") }
        Result::Err(_) => m with { status: Option::Some("save failed") }
      }
    })
  }
}
```

A failed write can never be silently dropped: the result is a value the `match` must cover. The same
deferred-edge rule governs UI `Msg` ([`06`](06-things-behaviors.md), [`21`](21-ui.md)).

---

## 4. Effect closure — every effect is handled

Exhaustiveness extends from a value's variants to the whole effect graph. The compiler builds the
signal/command graph from all behavior signatures plus the pipeline and requires **every emitted
signal/command to have a consumer**:

- engine commands (`Spawn`/`Despawn`/`Draw`/`Save`/…) are consumed by the engine;
- a user **signal** must have a consuming stage **downstream in the flattened pipeline**
  ([`07`](07-pipelines.md));
- **deferred edges** (UI `Msg`, IO-result signals) arrive next tick, so their consumer may be
  anywhere in the pipeline, not strictly downstream.

Emitting a `Goal` nothing tallies, or dropping a `Saved`, is a **compile error**. An effect is
handled either *internally* (resolved to a plain value inside the behavior) or *on return* (its type
has a statically-guaranteed consumer). This is the **edge** check; behavior contracts are the
**node** check ([`06`](06-things-behaviors.md)).

---

## 5. Tests

`test "…" { assert … }` is a top-level declaration, deterministic by construction (purity +
fixed-point + fixed iteration order). Pure functions test directly; a behavior is invoked by its
reserved entry point, `name.step(args)`. The engine supplies deterministic fixtures so no world or
harness is needed: `View.of([…])` ([`08`](08-state.md)), `Input.empty()` ([`23`](23-input.md)),
`Time.at(dt)` ([`10`](10-numerics.md)), `Nav.of(route)` ([`12`](12-navigation.md)).

```funpack
test "score emits a left goal past the right edge" {
  assert score.step(Ball{pos: Vec2{x: 161.0, y: 60.0}, vel: Vec2{x: 70.0, y: 40.0}}) == [Goal{side: Side::Left}]
}
```
