# 23 — Input

Input is the **only source of nondeterminism in user code** — everything else (state, RNG seed, time
step) is fixed or threaded. So input is where the determinism architecture is won, and where
device-independence is won.

## 1. Logic sees actions, never devices

Game logic queries **semantic actions** (`Move`, `Fire`, `Pause`) and never a `Key`, mouse button, or
gamepad button — the same action is fed by any device interchangeably. Actions are ordinary enums
ascribed a role kind after the name, and are **per player** (`PlayerId` `P1`..`P4`):

```funpack
enum Move:  Button { Up, Down, Left, Right }   // digital: pressed / released / held
enum Steer: Axis   { Move }                     // analog: a Fixed (1D) or a Vec2 (2D)
```

## 2. The query API (the entire surface a behavior sees)

Queried on the read-only `Input` resource:

```funpack
input.pressed(PlayerId, Button)  -> Bool    // edge: went down this tick
input.released(PlayerId, Button) -> Bool    // edge: went up this tick
input.held(PlayerId, Button)     -> Bool    // level: down at the tick instant
input.value(PlayerId, Axis)      -> Fixed   // 1D axis in [-1, 1]
input.axis(PlayerId, Axis)       -> Vec2    // 2D axis, each component in [-1, 1]
```

There is **no `Key`, `MouseButton`, or `Pad`** in sim code. An `Axis`-kinded action reads either 1D
(`value`) or 2D (`axis`), per its use.

## 3. Bindings — the one place devices appear

A binding maps device sources to actions in a single pure `fn() -> Bindings`. It is **build-time
wiring lifted into the entrypoint** (`funpack_configs/entrypoints.fcfg`, [`14`](14-project-config.md),
[`07`](07-pipelines.md)) — **not** a pipeline `data` block — and runs once at startup and on a rebind.
This is the *only* code that names physical devices:

```funpack
fn bindings() -> Bindings {
  return Bindings.empty()
    .button(PlayerId::P1, Move::Up, [Key::W, Key::Up])
    .axis(PlayerId::P1, Steer::Move, stick(Stick::Left))
}
```

Source helpers (engine-provided). **Button** (digital) sources: the `[Key::…]` **key-list literal**
(passed directly as the `.button(…)` source argument, the canonical keyboard form — a single key is the
one-element list `[Key::W]`), `pad(PadButton)` for a gamepad button, and `mouse(MouseButton)` for a mouse
button. **Axis** sources: `keys_axis(neg, pos)`, `stick_x(Stick)`, `stick_y(Stick)` (1D); `wasd()`,
`arrows()`, `dpad()`, `stick(Stick)` (2D). Multiple bindings for one action **stack** — any source
contributes, so keyboard and gamepad work simultaneously with no logic change; a key-list mixes devices
(`[Key::W, PadButton::DpadUp]`) and stacks one bind per element.

> There is **no `key(Key)` helper** — a single-key button source is the one-element key-list `[Key::W]`,
> which is the implemented canonical form (pong/snake/yard use the list form). `pad(PadButton)` and
> `mouse(MouseButton)` are kept because a gamepad or mouse button is **not** expressible by the
> keyboard-only key-list. `arrows()` and `dpad()` are kept because they are the **only** path to bind
> arrow-key / d-pad movement as a single 2D `Vec2` axis — `wasd()` is WASD-specific and `keys_axis` is
> 1D, so dropping them would lose that capability. See ADR
> `2026-06-15-engine-input-source-helpers-split`.
>
> **Implementation status:** `pad(PadButton)`, `mouse(MouseButton)`, `wasd()`, `arrows()`, the
> `[Key::…]` key-list, `keys_axis`, `stick`, `stick_x`, `stick_y` are implemented end-to-end. `dpad()`
> (the d-pad-as-2D-`Vec2` source) is specified but its runtime 2D pad-quad source kind is not yet
> modeled, so its surface helper is the next increment — the d-pad's directions are bindable today as
> digital buttons via `pad(PadButton::DpadUp)` etc.

A source is 1D or 2D by its **form**, not the action it feeds: `keys_axis`, `stick_x`, `stick_y`
contribute one value (the 1D slot `value` reads); `wasd()`, `arrows()`, `dpad()`, `stick(Stick)`
contribute a full `Vec2` (read via `axis`). The 2D helpers orient to the y-down draw space
([`20`](20-render.md)): left/right drive x −/+ and up/down drive y −/+, so `W` and stick-up both
read negative y — keyboard and stick contributions agree with no per-source sign fixups.

`bindings()` supplies the **defaults**. A **runtime key rebinding is a setting** — a per-machine
preference — persisted in the **settings file** ([`24`](24-persistence.md)), **never in the simulation**
(it is not blackboard state, never enters a snapshot/save/replay) and **never in `.fcfg`** (which holds
build-time defaults, not the player's local choices). The engine resolves a **rebinding overlay** from
the settings store over the `bindings()` defaults at startup and on a rebind, *before* resolving raw
device input into the action snapshot (§4) — so logic, replays, and lockstep peers see only the
device-agnostic action stream regardless of any local override.

## 4. Determinism — record the resolved actions

Each tick the engine resolves raw device input **through the bindings** into an immutable **action
snapshot**, then records that snapshot to the replay log. Because user code is a pure fold over the
snapshot:

- **Replay re-feeds recorded action snapshots** → bit-identical, regardless of which device produced
  them or whether bindings later changed;
- **Lockstep multiplayer** exchanges action snapshots (device-agnostic), so a keyboard player and a
  gamepad player produce identical streams.

Edge/level semantics are **coalesced over the window since the previous tick**, so a tap between two
ticks still registers as `pressed` even at a low tick rate. All analog values are **fixed-point**, in
`[-1, 1]`, engine-deadzoned — **no `Float` reaches user code**. Raw device state is never exposed to a
behavior and never part of the recorded snapshot, so there is no back door a recording wouldn't
capture; a rebinding screen ("press a key to bind") is an engine/config-layer concern, the one place
raw device events are read.

## 5. Producing input (tests, replays, bots, headless)

Any producer of an action snapshot is interchangeable with the live engine. Build one with the same
vocabulary the query uses:

```funpack
Input.empty()                                  -> Input
input.with_pressed(PlayerId, Button)           -> Input
input.with_released(PlayerId, Button)          -> Input
input.with_held(PlayerId, Button)              -> Input
input.with_value(PlayerId, Axis, Fixed)        -> Input
input.with_axis(PlayerId, Axis, Vec2)          -> Input
```

The two edge producers mirror §4's coalescing: `with_pressed` marks the down edge **and** the held
level (a freshly pressed action is down at the tick instant); `with_released` marks the up edge
**and clears** the held level (`released` implies not-held, §4). The pair composes: chaining
`.with_pressed(p, a).with_released(p, a)` yields the same-tick tap — pressed and released both set,
held clear — exactly what the window fold produces for a down-then-up within one tick.

So a test reads cleanly and never mentions a device:

```funpack
test "dir_from_input refuses a 180" {
  assert dir_from_input(Input.empty().with_pressed(PlayerId::P1, Move::Down), Dir::Up) == Dir::Up
}
```

## 6. Scope

Button + axis actions over keyboard / mouse / gamepad. Bindings use the builder form. `PlayerId` is
always explicit, including in single-player.
