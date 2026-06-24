---
name: funpack-engine-api
description: The funpack `engine.*` standard library — the API surface a game calls. Use when you need a function or type signature — vectors & fixed-point math, the world (View/Spawn/Ref), device-agnostic input, 2D/3D draw commands, audio, UI widgets, navigation, list/map/grid/string/rand, and the model/anim/render3 trio. Triggers on "engine.math", "engine.world", "engine.input", "engine.render", "what function does/returns", "how do I clamp/fold/draw/spawn", "Vec2", "View[T]", "Draw::", "Bindings", "Input.value/axis", "funpack stdlib/API". Also matches capability goals phrased without an API name — "how do I draw a sprite", "how do I read the keyboard or gamepad", "how do I play a sound", "distance between two points", "pick a random number", "clamp a value".
---

# funpack engine API — the `engine.*` stdlib

funpack is a small language over a **rich engine**: all expressiveness lives here. A game's first
lines are its imports; everything is `Fixed`-point and replay-deterministic; nothing panics
(partiality is in the return type, `Option`/`Result`); `Float` is render-only.

This SKILL.md covers the **core modules every 2D game touches** and how to read a signature. For the
**complete per-module reference** (audio, ui, nav, map, grid, string, rand, geom, level, tilemap,
model, anim, render3), read `references/modules.md` in this skill directory.

## How to read a signature (call conventions)

The first parameter tells you how to call it:
- **`self`-first** → a method: `input.value(p, a)`, `xs.fold(init, f)`.
- **No `self`, qualified by its return type** → an associated constructor: `Bindings.empty()`,
  `Time.at(0.5)`, `View.of([…])`, `Pose.empty()`.
- **No `self`, imported bare** → a free function: `clamp(x, lo, hi)`, `length(v)`, `sin(x)`.

A method call and a free call are the same function (UFCS): `length(v)` ≡ `v.length()`.

## engine.prelude — always in scope, no import

`Bool`, `Int`, `Fixed`, `Float`, `String`; `Option[T] { Some(T), None }`,
`Result[T,E] { Ok(T), Err(E) }`, `Ordering { Less, Equal, Greater }`.
`is_some(opt) -> Bool`, `or_else(opt, default) -> T`, `to_fixed(Int) -> Fixed`,
`to_int(Fixed) -> Int` (truncates toward zero), `compare(a, b) -> Ordering`.

## engine.math — numbers & space (the first import of any game)

```funpack
data Vec2: Num { x: Fixed, y: Fixed }     // supports + - * (scalar & component-wise) via the Num kind
data Vec3: Num { x: Fixed, y: Fixed, z: Fixed }
data Quat { x: Fixed, y: Fixed, z: Fixed, w: Fixed }
let pi:  Fixed = 3.14159265
let tau: Fixed = 6.28318531
```
Scalar: `sin cos tan atan2 sqrt abs floor ceil round min max` (all `Fixed -> Fixed`),
`clamp(x, lo, hi)`, `lerp(a, b, t)`. Vector: `length(v: Vec2) -> Fixed` (2D), `length3(v: Vec3)`,
`dot(a: Vec3, b: Vec3) -> Fixed`, `cross`, `normalize`. Quat/Mat4 for 3D (see reference).

> `/`, `dot`, `cross`, `length` are **named functions, not operators** — the `Num` kind confers only
> `+ - *` and equality. Extended numerics (`Fixed.MAX/MIN/EPSILON`, `checked_div`, `pow/exp/log`,
> `remap`, `wrap_angle`, `length_sq`, `distance`, `reflect`, `%`) are specified in the numerics
> contract but thinner in the stdlib signature file — see `funpack-determinism`, and verify exotic
> ones against your toolchain.

## engine.core — the clock

```funpack
data Time { dt: Fixed, t: Fixed }     // dt = fixed step; t = accumulated logical time
```
`Time.at(dt) -> Time` and `Time.tick(dt, t) -> Time` are the test fixtures. Logical time only — no
wall clock in sim code. Usage: `self.pos + self.vel * time.dt`.

## engine.world — entities & population commands

```funpack
data Id { raw: Int }
data Ref[T] { id: Id }        // weak, serializable; resolve to Option[T]
data Owned[T] { id: Id }      // exclusive owning ref; despawn cascades
extern type Spawn             // command: Spawn(<thing-literal>)
data Despawn { id: Id }       // command: Despawn() self-despawns
extern type View[T]           // read-only iterable view of matching things
```
`View[T]` methods: `count() -> Int`, `at(i) -> T`, `ref(i) -> Ref[T]`, `resolve(ref) -> Option[T]`,
and the test fixture `View.of([items]) -> View[T]`. Behaviors take `View[Other]` to read other
things; return `Spawn( Thing{…} )` / `Despawn()` to change population (applied at the tick boundary).

## engine.input — device-agnostic input

Game logic queries **semantic actions, never devices**. `Axis` and `Button` are **role-kind
ascriptions written after the enum name — never imported**: `enum Move: Button { Up, Down }`,
`enum Steer: Axis { Move }`, per player `PlayerId::{P1,P2,P3,P4}`.

```funpack
// queries are receiver methods on the Input resource (not imports), per player + action:
input.pressed(player, action: Button)  -> Bool     // down-edge this tick
input.released(player, action: Button) -> Bool     // up-edge this tick
input.held(player, action: Button)     -> Bool     // level: down now
input.value(player, action: Axis)      -> Fixed    // 1D axis in [-1, +1]
input.axis(player, action: Axis)       -> Vec2     // 2D axis, each component [-1, +1]
```
Devices appear in **one place**: a `fn bindings() -> Bindings` lifted into the entrypoint.
`Bindings.empty().axis(P1, Steer::Move, keys_axis(Key::W, Key::S))…`. Importable from `engine.input`:
types `Input Bindings PlayerId Key PadButton MouseButton Stick`, source-helper funcs
`keys_axis stick_x stick_y wasd arrows stick pad mouse`. Binding sources:
- **Button:** the key-list `[Key::W, Key::Up]` (a single key is `[Key::W]`), `pad(PadButton::A)`,
  `mouse(MouseButton::Left)` — there is **no `key(…)` helper**.
- **Axis 1D:** `keys_axis(neg, pos)`, `stick_x/stick_y(Stick)` (read via `value`).
- **Axis 2D:** `wasd()`/`arrows()`/`stick(Stick)` (each a `Vec2`, read via `axis`).

Test doubles: `Input.empty().with_pressed(p, a)`, `.with_value(p, a, x)`, `.with_axis(p, a, v)`.

> Sources **stack** (a key-list may mix devices: `[Key::W, PadButton::DpadUp]`). 2D orientation is
> y-down — `W` and stick-up read negative y. `dpad()` (the d-pad as a single 2D `Vec2`) is spec-named
> but not yet on the surface; bind the d-pad directions as digital buttons via `pad(PadButton::DpadUp)`.
> See `references/modules.md` and spec §23 §3. All analog values are fixed-point in [-1,1],
> engine-deadzoned; no `Float` reaches sim code.

## engine.render — 2D draw commands

A render behavior is a pure `fn(state) -> [Draw]`.

```funpack
enum Color { White, Black, Red, Green, Blue, Yellow, Cyan, Magenta, Gray, Rgb{ r: Fixed, g: Fixed, b: Fixed } }
enum Flip { None, X, Y, XY }
enum Draw {
  Rect{ at: Vec2, size: Vec2, color: Color }            // at is the TOP-LEFT corner, not center
  Line{ a: Vec2, b: Vec2, color: Color }
  Text{ at: Vec2, text: String, color: Color }
  Fill{ path: Sketch, color: Color }
  Stroke{ path: Sketch, width: Fixed, color: Color }
  Sprite{ atlas: AtlasHandle, cell: String, at: Vec2, size: Vec2, tint: Color, flip: Flip, layer: Int }
}
```
`return [Draw::Rect{at: self.pos, size: Vec2{x:3.0,y:3.0}, color: Color::White}]`. Text uses
interpolation: `Draw::Text{at: …, text: "{self.left}   {self.right}", color: Color::White}`. For
sprites/atlases see the `funpack-content` skill. 3D draws (`Draw3`, `Camera`, `Light`) live in
`engine.render3` — see `references/modules.md`.

## engine.list — immutable `[T]` (every game uses this)

Every op returns a new list; lookups are total (`Option`).
```funpack
len, is_empty, get(i)->Option[T], first()->Option, last()->Option,
prepend(item), append(item), concat(other), reverse, contains(item),
find(pred: fn(T)->Bool) -> Option[T],
map(f: fn(T)->U) -> [U], filter(pred) -> [T],
fold(init: A, step: fn(A,T)->A) -> A          // THE deterministic loop primitive (left-to-right)
```
`fold(goals, self, add_goal)`, `filter(all_cells(), fn(c){ return not contains(occ, c) })`,
`map(cells, fn(c){ return Cell{x: c.x, y: c.y} })`.

> For the predicate "find one matching" use `find(xs, pred)`. Some examples write `first(xs, pred)`;
> the signature file separates `first(xs)` (the head) from `find(xs, pred)` — prefer `find` for the
> predicate form and verify against your toolchain.

## Everything else

For **audio** (`Sound`/`Audio`, the two regimes), **ui** (widgets, `View[Msg]`), **nav**
(pathfinding), **map/grid/string/rand**, **geom** (`Sketch`), **level/tilemap**, and the
**model/anim/render3** 3D trio, read `references/modules.md` — it has the full signatures. The
content-authoring side (atlases, levels, models, UI templates) is the `funpack-content` skill.

## Accuracy note

These signatures are distilled from the in-repo `stdlib/engine/*.fun` files and the worked
examples. Where the signature files, the prose spec, and the examples diverge, `references/modules.md`
flags it. funpack is under active design — to confirm a signature, search the docs corpus with the
funpack-mcp `docs_search` tool (then `docs_get` on a hit); for a load-bearing call, the final
tie-breaker is a real compile (`check`).
