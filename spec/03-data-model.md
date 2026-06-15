# 03 — Data model

The value kinds and the synthesized batteries every value carries. `thing`/`singleton` (stateful
entities) are [`06`](06-things-behaviors.md); this file covers `data`, `enum`, `signal`-as-value,
the prelude types, container generics, kind ascription, serialization, and mutation.

---

## 1. `data` — the value record

```funpack
data Cell { x: Int, y: Int }
data Paddle { player: PlayerId, side: Side, x: Fixed, y: Fixed, speed: Fixed }
data Stride { cadence: Fixed, top_speed: Fixed }
data Length { value: Fixed }          // newtype over Fixed
```

A `data` type is a **typed, schema'd map** — declared keys with struct-sugar access (`p.x`) — that
the compiler **ptr-backs** with copy-on-write and structural sharing (the Hack-shape model at the
representation level). This buys cheap `with`, cheap optional keys, and free serialization,
while the compiler is free to inline known-key access. Fields may carry defaults (`on: Bool =
false`); a defaulted field may be omitted from a literal.

### Synthesized batteries — unconditional, never opted into

Every `data` value carries, compiler-synthesized:

- **Totality / non-null** — absence is expressible *only* as `Option[T]`, which forces a `match`.
  There is no `null`.
- **Serialization** — see §5.
- **Value semantics + immutability** — values are immutable by default; `with` produces a new value.
- **`Eq` / `Ord` / `Hash`** — so any `data` (fixed-point throughout) is comparable and usable as a
  `Map` key.
- **copy / `with`** — `v with { field: new }`.

There is **no `derives`** anywhere. Capabilities beyond the universal batteries are ascribed by a
**kind** on the declaration line (`Name: Kind`, §4), never derived and never searched.

---

## 2. `enum` — the sum type

```funpack
enum Dir { Up, Down, Left, Right }                 // plain
enum Side { Left, Right }
enum Color { White, Black, …, Rgb{ r: Fixed, g: Fixed, b: Fixed } }   // struct payload
enum PathOp { MoveTo(Vec2), LineTo(Vec2), CubicTo{ c1: Vec2, c2: Vec2, to: Vec2 }, Close }
```

A variant is plain, tuple-payload `Variant(T, …)`, or struct-payload `Variant{ f: T }`. Variants are
selected with `::` ([`02`](02-language-core.md)) and matched **exhaustively** — a non-total `match`
is a compile error. Enums may be generic on stdlib/engine containers (§3).

**Forced-totality across load.** Exhaustiveness is a compile-time property of the *current* schema, so
a committed token from an older schema could otherwise smuggle in a variant no live `match` arm names.
It cannot: on restore/reload a committed enum token naming **no variant in the new schema** is
**refused** — the load fails closed rather than carry an unmatchable token ([`05`](05-directives.md)
§6). Variant rename/removal is migrated through `@migrate` on the variant; the refusal is the floor
beneath it ([`05`](05-directives.md) §6, [`24`](24-persistence.md)).

---

## 3. The prelude & container generics

Always in scope, no import (`stdlib/engine/prelude.fun`):

| Type | Definition |
|---|---|
| `Bool`, `Int`, `Fixed`, `Float`, `String` | primitives (`extern type`); `Float` is render-only |
| `Ordering` | `{ Less, Equal, Greater }` |
| `Option[T]` | `{ Some(T), None }` — the only way to express absence |
| `Result[T, E]` | `{ Ok(T), Err(E) }` — errors are values, handled exhaustively |

Prelude functions: `is_some`, `or_else`, `to_fixed(Int) -> Fixed`, `to_int(Fixed) -> Int` (truncates
toward zero), `compare(a, b) -> Ordering`.

**Generics exist only on engine/stdlib containers**, written `[]` ([`02`](02-language-core.md) §3):
`Option[T]`, `Result[T, E]`, the list `[T]`, `Map[K, V]`, `View[T]`, `Ref[T]`, `Owned[T]`,
`Choice[T]`. **User code authors no generics** — no type parameters on user `data`/`enum`/`fn`.

---

## 4. Kinds — type ascription on a declaration

A **kind** ascribes one of a closed, engine-defined set of roles to a type, written as a
type-ascription after the type name on the declaration line — `enum Name: Kind`, `data Name: Num` —
the same `:` glyph as `field: T` and `let x: T` ([`02`](02-language-core.md) §3, subject-then-classifier).
A kind is **type-constitutive**: it changes the type's role at *every* use site (only an
`Axis`-kinded enum binds to an analog input), so it lives in the declaration grammar, not in the
descriptive directive family. Kind names are **contextual** — valid only in the post-colon position,
never reserved words. Kinds are never a typeclass and never an instance search.

```funpack
enum Drive: Axis { Forward, Strafe }              // analog input actions
enum Cmd: Button { Jump, Fire }                   // digital input actions
enum Layer: CollisionLayer { World, Player, Item }
```

| `Name: Kind` | On | Meaning |
|---|---|---|
| `: Axis` | an enum | analog input actions ([`23`](23-input.md)) |
| `: Button` | an enum | digital input actions ([`23`](23-input.md)) |
| `: CollisionLayer` | an enum | a registered closed layer set ([`11`](11-physics.md)) |
| `: Num` | engine `data` | arithmetic-overloadable numeric (`Vec2`/`Vec3`) — engine-only |

The per-tick message capability is **not** a kind — it is the `signal` keyword (§6).

---

## 5. Serialization closure — a theorem, not a convention

A `data`/`signal`/`thing` field's type must itself be serializable, recursively:
`data`-family / primitive / `Option` / list / `Map` / `Ref` / `Owned`. **Function-typed fields are
rejected** (a behavior is not data). Because the *only* way to declare simulation state is the
`data` family, **all simulation state is serializable by construction** — replay, save, and lockstep
are total ([`08`](08-state.md), [`24`](24-persistence.md), [`25`](25-netcode.md)). Composition is
nesting; nested members are implicitly `data`.

---

## 6. `signal` — the message value

```funpack
signal Goal { side: Side }
signal Died {}
```

A `signal` is a `data` value declared with the `signal` keyword — the **sole** surface for the only
cross-thing channel; there is no alternate form and no `Signal` kind. It is per-tick (bump-arena
allocated, [`01`](01-axioms.md)), routed by the engine, and subject to effect closure — every emitted
signal needs a downstream consumer ([`04`](04-effects.md), [`07`](07-pipelines.md)). Routing and the
read/write rules are [`06`](06-things-behaviors.md).

---

## 7. Mutation — opt-in, declared, the only sanctioned channel

A `data` value is **COW-replaced** by default (immutable; state evolves by returning new values via
`with`). Marking a declaration `mut data` makes the engine update it **in place** instead —
conspicuous, registered in the task DB, operator-auditable, **never inferred**. This is the *only*
sanctioned mutation in the language; there is no `var`/`set`.

`mut` is declared on the type, so every instance is mutable, for operator legibility
([`01`](01-axioms.md) §4).
