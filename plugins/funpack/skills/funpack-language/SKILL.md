---
name: funpack-language
description: Write and understand funpack `.fun` source — the language's syntax and semantics. Use when authoring, reading, editing, or explaining funpack code — declarations (thing/behavior/signal/pipeline/fn/enum/data/let/test), types, match, the `with` update, lambdas, string interpolation, the @doc/@gtag/@stub/@todo directives, and modules/imports. Triggers on ".fun", "funpack syntax", "write a funpack ...", "how do I declare", "funpack behavior/thing/signal/pipeline", "funpack match/enum/data".
---

# funpack language — syntax & semantics

funpack is a deliberately **boring, LL(1)** language over a **rich engine**. The surface is small
and unambiguous so an LLM reasons from prior training instead of decoding novelty; all the power
lives in the `engine.*` stdlib (see the `funpack-engine-api` skill). Three commitments drive every
rule: **determinism** (same source → same artifact; fixed-point, never float), **legibility over
expressiveness** (one obvious way to do each thing), and **self-healing dev loops** (the compiler
is a quality gate emitting fix-criteria diagnostics).

For the runtime paradigm (how behaviors/signals/pipelines compose into a game) see the
`funpack-game-model` skill. This skill is the **syntax**. For the full grammar and edge cases, read
`references/grammar.md` in this skill directory.

## Read this first — the five things that trip people up

1. **Fixed-point, never float.** Sim numbers are `Fixed` (`42.5`, `0.0`, `8.0`). `42.5f` is `Float`,
   legal **only** in render/audio code; a bare `f`-literal in sim is a compile error. There is **no
   implicit `Int → Fixed`** — lift with `to_fixed(n)`.
2. **`Spawn(x)` uses parentheses, not braces** — command-wrap is call syntax: `Spawn( Ball{...} )`,
   `Despawn()`. (Older/training-data funpack may show `Spawn{ }`; that is wrong now.) A bare
   `UPPER_IDENT{...}` is **always** a record literal — this is what keeps the grammar LL(1).
3. **Lambdas are `fn(x){ return … }`** with a **single-statement** body. `=>` is the `match`-arm
   separator **only**, never lambda syntax.
4. **There are no comments.** `@doc("…")` documents (timeless — temporal words like "now"/"was" are
   rejected); `@gtag("…")` tags intent (must be registered in `tags.fcfg`); `@todo("…", window)` is
   the only dated note; `@stub(T)` is a typed hole.
5. **State is immutable; update with `with`:** `self with { y: clamp(...) }`. `let` is the only
   binding form and all locals are immutable.

## Declaration forms

A file is a flat list of declarations; each opens with a unique keyword (LL(1)). Verbatim forms
(from `pong`/`snake`/`yard`):

```funpack
import engine.math.{Fixed, Vec2, clamp}        // selected members (brace group)
import engine.world.{View, Spawn}              // absolute paths only; no relative imports
import engine.core.Time                        // a single member

enum Side { Left, Right }                       // plain sum type
enum Steer: Axis { Move }                       // kind-ascribed: an analog-input action
enum Cmd: Button { Jump, Fire }                 // kind-ascribed: digital-input actions

data Board { w: Fixed, h: Fixed }               // a value record (immutable, Eq/Ord/Hash by construction)
let BOARD: Board = Board{ w: 160.0, h: 120.0 }  // module constant (UPPER_SNAKE)

@doc("A player's paddle.")
@gtag("paddle")
thing Paddle { player: PlayerId, side: Side, x: Fixed, y: Fixed, speed: Fixed }   // an entity with state

singleton Scoreboard { delivered: Int = 0 }     // exactly one, engine-spawned before tick 0, accessed by type

signal Goal { side: Side }                       // the sole cross-thing message; plain data, engine-routed

fn advance(at: Vec2, vel: Vec2, dt: Fixed) -> Vec2 {   // free function; return type mandatory
  return at + vel * dt                                 // value produced ONLY via explicit `return`
}

behavior ball_move on Ball {                     // a pure transition attached to a thing
  fn step(self: Ball, time: Time) -> Ball {      // `step` is the reserved entry point
    return self with { pos: advance(self.pos, self.vel, time.dt) }
  }
}

pipeline Pong {                                  // the explicit ordered schedule
  startup:   [setup]
  control:   [paddle_move, ball_move]
  scoring:   [score, tally, serve]
  render:    [draw_paddle, draw_ball]
}

test "advance moves a point by velocity over dt" {     // a top-level test; deterministic by construction
  assert advance(Vec2{x: 0.0, y: 0.0}, Vec2{x: 2.0, y: 4.0}, 0.5) == Vec2{x: 1.0, y: 2.0}
}
```

`thing` vs `singleton`: use **`singleton`** for exactly-one state (a scoreboard, a camera, a menu)
— the engine spawns it before tick 0 and you access it by type. (Some examples declare a `thing`
and spawn it once in `setup`; `singleton` is the canonical form.) An ordinary `thing` is a
multi-instance table you `Spawn`/`Despawn`.

Also: `query name(p) -> [T] { … }` (read-only memoized world read), and `extern fn`/`extern type`
(the native boundary — stdlib only; you never author `extern`). See `references/grammar.md`.

## Types & the data model

- **Primitives:** `Int` (64-bit signed, **saturating**, one integer type), `Fixed` (the sim default
  number — Q32.32 fixed-point), `Float` (render-only), `Bool`, `String`.
- **Prelude (always in scope, no import):** `Option[T] { Some(T), None }` — the only way to express
  absence (**there is no `null`**); `Result[T, E] { Ok(T), Err(E) }` — errors are values, handled by
  exhaustive `match`; `Ordering { Less, Equal, Greater }`. Helpers: `is_some`, `or_else(opt, default)`,
  `to_fixed(Int)->Fixed`, `to_int(Fixed)->Int`, `compare(a,b)->Ordering`.
- **`data`** is a typed record. Every `data`/`thing`/`signal` value carries compiler-synthesized
  batteries unconditionally — serialization, value semantics + immutability, `Eq`/`Ord`/`Hash`
  (any `data` is usable as a `Map` key). **There is no `derives`.** Fields may have defaults
  (`on: Bool = false`); a defaulted field may be omitted from a literal (`Snake{}`).
- **Enums** are sum types, matched **exhaustively**. Variants may be plain (`Left`), tuple
  (`Some(T)`, `MoveTo(Vec2)`), or struct (`Rgb{ r: Fixed, g: Fixed, b: Fixed }`).
- **Generics are engine-only.** `Option[T]`, `Result[T,E]`, lists `[T]`, `Map[K,V]`, `View[T]`,
  `Ref[T]` exist; **user code authors no type parameters** on its own `data`/`enum`/`fn`.
- **Lists** are `[T]` (`[Cell]`, `[Goal]`, `[Draw]`). **Tuples exist only in return position**
  (`-> (Rng, [Spawn])`) and the `let`/`match` that destructures them — never as a stored field type;
  for any stored aggregate, use `data`.
- **Kinds** ascribe an engine role on the declaration line with `:` — `enum Drive: Axis {…}`,
  `enum Cmd: Button {…}`, `data Vec2: Num {…}` (the `Num` kind is what enables `+ - *` on vectors).
- **Mutation** is opt-in and declared: `mut data Name {…}` makes the engine update in place. It is
  the **only** sanctioned mutation — there is no `var`/`set`.

## Expressions & statements

Expression-oriented (`if` and `match` yield values), but a function produces its value **only
through explicit `return`** — no implicit last-expression return.

```funpack
return match d {                               // match: arms `Pattern => expr|block`, newline-separated, EXHAUSTIVE
  Dir::Up    => Cell{x: c.x, y: c.y - 1}
  Dir::Down  => Cell{x: c.x, y: c.y + 1}
  Dir::Left  => Cell{x: c.x - 1, y: c.y}
  Dir::Right => Cell{x: c.x + 1, y: c.y}
}

return self with { settings: self.settings with { access: a }, dirty: true }   // nested immutable update

let free = filter(all_cells(), fn(c) { return not contains(occ, c) })          // lambda: fn(params){ one statement }

text: "{self.left}   {self.right}"             // string interpolation; strings are NEVER built with `+`

return Bindings.empty()                         // left-to-right builder chains (UFCS / associated fns)
  .axis(PlayerId::P1, Steer::Move, keys_axis(Key::W, Key::S))
  .axis(PlayerId::P2, Steer::Move, keys_axis(Key::Up, Key::Down))
```

- **`let`** is the only local binding; all locals immutable. **No `for`/`while`** — iterate with the
  list combinators `map`/`filter`/`fold`/`find`; `fold(xs, init, fn(acc, x){…})` is the deterministic
  loop primitive (strictly left-to-right).
- **Calls:** `.` is the universal access/call operator (field, UFCS method, or associated fn/const —
  `recv.f(x)`, `Type.empty()`, `Fixed.MAX`); `::` is the enum-variant selector **only**
  (`Dir::Up`, `Option::Some`). A method call and a free-function call are the same function (UFCS:
  `length(v)` ≡ `v.length()`).
- **Operators:** `+ - * / %`; comparisons `== != < <= > >=`; logic is the **words** `and`/`or`/`not`
  (no `&&`/`||`/`!`). No operator overloading outside `Num`-kinded engine types. `=` is binding
  only, never equality.
- **`Option`/`Result` have no `?` operator** — propagate explicitly with `match` or `or_else`.

## Directives

Directives prefix a declaration (or, for `@stub`, stand in body/expression position). They are
**inert toward logic** (no codegen, no control flow — this holds the no-macro line). The category is
closed; you cannot define new ones.

```funpack
@doc("Timeless description of WHAT this is — never what happened to it.")
@gtag("ball", "score")                                  // intent tags; each must be in tags.fcfg or it's a compile error
fn launch_speed(boost: Fixed) -> Fixed @stub(Fixed, boost + 6.0)   // typed hole with a dev fallback
fn drag() -> Fixed @stub(Fixed)                                    // bare hole: typechecks; reaching it in dev fails closed
@todo("rebalance drops", T-0042)                        // the ONLY dated note; window mandatory; past it = compile error
```

- `@doc` is the **sole documentation channel** (there are no comments). Temporal tokens inside it
  are rejected.
- `@gtag` labels must be registered in `funpack_configs/tags.fcfg` (closed registry → no synonym rot).
- `@stub(T)` / `@stub(T, fallback)` compile in **dev** and are a **compile error under `--release`**
  ("you cannot ship a hole"). Callers typecheck against `T`, so you build top-down: signatures
  first, bodies later.
- `@todo` windows: a task ref `T-0042` (recommended), an ISO date `2026-09-01`, a relative duration
  `30d`, or a build count `50builds`.
- `@expose` is the one visibility primitive, and it matters **only across a package edge** (within a
  project, every declaration is importable — there is no `pub`).

## Modules & imports

**A module's name is its file path; nothing declares it — there is no `module` keyword.** Directory
segments are dotted, filename is the leaf: `src/pong.fun` → module `pong`; `src/combat/melee.fun` →
`combat.melee`; `stdlib/engine/math.fun` → `engine.math`. Imports are **absolute** (rooted, no
`self`/`super`/`../`). A `@doc` that is the first item in a file documents the module. `engine` is
the single reserved root namespace.

When a generated seam (e.g. a `.flvl` level's `gen/arena.gen.fun`) references your thing types,
split into three modules to keep imports acyclic: a **schema** module (things/enums/signals only,
no behaviors), the generated **seam** (imports the schema only), and the **behavior** module
(imports both). See the `funpack-project` skill.

## What funpack deliberately omits (and why)

No macros · no user-defined operators · no inheritance (compose by nesting `data`) · no reflection ·
no user generics · no `for`/`while` loops · no comments · no `null` · no `var`/`set` · no `?`
operator · no implicit numeric promotion · no `&&`/`||`/`!` · no general tuples · no string `+`. The
language is small **on purpose**: power lives in the engine, and one-concept-per-glyph keeps it
LL(1) so the next editor (usually an agent) reasons from priors, not novelty.

> funpack is under active design and "the examples lead, the prose follows; a real compile is the
> tie-breaker." Treat the grammar forms here as canonical, but verify a surprising edge case against
> your toolchain. The normative idiom lives in the funpack-spec examples
> (`pong`, `snake`, `hunt`, `yard`, `arena`, `dungeon`, `warren`, `krognid`, `hud`, `assets`,
> `numerics`, `drift`).
