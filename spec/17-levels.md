# 17 — Levels (`.flvl`)

There is no scene editor — funpack is flat text. A level is, in the runtime model, just an **initial
world**: placed `thing`s with their blackboard params and the references between them — the same
thing `setup() -> [Spawn]` builds by hand and the same shape a save deserializes to
([`08`](08-state.md)). A `.flvl` bakes to a generated `*.gen.fun` seam the game consumes, and is
**incrementally replaceable**. One format serves 2D and 3D; only the coordinate arity changes.

> **Thesis:** a level is an initial snapshot. The `.flvl` is ergonomic authoring sugar (anchors,
> loops, prefabs, references-by-name) that bakes to a deterministic spawn list and a typed seam; that
> baked output is the canonical world-data a save also produces.

The problem it solves is **spatial reasoning without a viewport**: an LLM can't see that `(152, 60)`
is "the right paddle," so every choice replaces absolute coordinates with names, relationships,
repetition, and symmetry.

## 1. The `.flvl` surface

```
level Arena 2d {
  bounds (0, 0) (160, 120)
  things  arena_world                 // the schema module whose thing types this level places

  prefab Turret {
    place Base   base   at origin
    place Cannon cannon { rate: 2.0 } at base.offset(y: 6)
  }

  place Player hero  at center
  place Switch plate at center.offset(y: 40)
  place Door   exit  { gate: plate } at center.offset(y: -40)   // gate: Ref[Switch] resolved from `plate`
  for i in 0..5 { place Pillar at center.offset(x: -48 + i * 24, y: 0) }
  place Turret right_gun { cannon.rate: 4.0 } at right_edge.center.offset(x: -12)  // override nested by path
}
```

- **`place <Type> <name> { params } at <where> [facing <rot>]`** — instantiates a `thing`, setting
  blackboard fields inline (typechecked against the thing's schema), under a stable **name** — the
  level's anti-hallucination currency and what the seam exposes. `<name>` is optional for one-off
  scenery (anonymous instances don't appear in the seam).
- **`2d` / `3d`** is the header word: coordinates are `(x, y)` / `(x, y, z)`; `facing` is an angle /
  an orientation.

### Reserved fields

`at` and `facing` write ordinary blackboard fields (position is gameplay state, not a hidden engine
transform): **`at` writes `pos`** (`Vec2` in a 2d level, `Vec3` in 3d) and **`facing` writes
`facing`**. The *name*, not the type, is the contract — a thing may also carry a `vel: Vec2`. A thing
placed with `at` **must** declare a matching `pos` of the level's arity (also the dimensionality
check); a spatial-less thing is placed without `at`.

### Killing raw coordinates

Positions resolve against things a model reasons about well: **bounds anchors** (`center`,
`left_edge`, `right_edge.center`, … with `.offset(x:, y:[, z:])`); **instance-relative** (`base.top`,
`left_of(door, 2)`, `above(table)`); **model sockets** (`table.socket("cup")`, baked by a `.fpm`);
**repetition** (`for i in 0..N`, `grid`/`row` helpers).

### References by name → typed `Ref[T]`

A param pointing at another thing is written as that thing's **name**; the bake resolves it to a typed
`Ref[T]` ([`08`](08-state.md)) and checks it. A nonexistent name, a duplicate name, or a target whose
type doesn't match the field's `Ref[T]` is a **compile error** — dangling references are
unrepresentable.

### Prefabs

A named bundle of placements with its own local origin and names; placing it stamps the bundle —
**data composition**, not user code. Prefabs **nest to arbitrary depth** (a prefab places other
prefabs, with no depth cap); each placement carries its own local origin and name, so a member at any
depth is addressed by its **dotted name-path** (`right_gun.cannon.rate`). Overrides are by dotted path
into the prefab's members (`{ cannon.rate: 4.0 }`) and apply at **any depth** the name-path reaches;
an override of a nonexistent field is a compile error. The bake resolves overrides **deterministically**
— outer placement over nested default, declaration order — so a stamp is a pure expansion of nested
data regardless of nesting depth.

## 2. The generated seam

Committed, formatter-canonical funpack: a deterministic spawn list plus a **typed symbol table** of
the level's named instances (a prefab instance expands to a small `data` of its members' `Ref`s):

```funpack
data Arena { hero: Ref[Player], plate: Ref[Switch], exit: Ref[Door], right_gun: ArenaTurret }
fn arena_spawns() -> [Spawn]        // deterministic, declaration order, prefabs/loops expanded in place
fn arena() -> Arena                 // the symbol table, valid once the level is loaded
```

**Stable ids by name:** a named instance's `Id` is derived from its level-qualified name, so its
`Ref` is constant across loads/saves/replays; anonymous scenery takes counter ids in declaration
order. The propagation property holds — rename `plate` in the level and `Arena.plate` disappears,
so every reader stops compiling at exactly the spot to fix.

### Module layering — schema / seam / behavior

A general 3-way split (required whenever a generated seam names your types — levels, netcode, save,
modding), keeping the import graph **acyclic by construction**:

- **Schema module** — only `thing`/`data`/`enum`/`signal`; imports engine types only
  (`arena_world`).
- **Generated seam** — imports **schema modules only**; a `.gen.fun` importing a behavior module is a
  compile error (`arena`).
- **Behavior module** — imports schema + seam; declares the `behavior`s and the `pipeline`
  (`arena_game`).

A small game with no type-referencing seam (Pong) needs no split.

## 3. Levels are snapshots are saves

The baked output is the **canonical world-data** ([`08`](08-state.md)): a **level** is an initial
snapshot (authored), a **save** is a runtime snapshot, a **replay seed** is the tick-0 snapshot. The
`.flvl` sugar is a **one-way** lowering to that flat data — a running world dumps *back* to the flat
form (for a save, or for an agent to inspect via [`28`](28-introspection.md)), never back into the
sugar.

## 4. Streaming, determinism & gates

`include "town/market.flvl"` splits a big level across files; **chunks** stream via `Load{ level, at
}` / `Unload{ level }` commands over a content-hashed `LevelHandle` (the `[Spawn]`-class path,
`stdlib/engine/level.fun`). `Volume` ({`Rect`/`Box`/`Sphere`}) models regions/triggers. Spawn order is
declaration order (prefabs expanded in place); named ids are name-derived; coordinates are
fixed-point — so a level loads bit-identically on every machine. Bake gates (P5): unresolved/duplicate
names, type-mismatched references, params/overrides not on the schema, an `at` without a matching
`pos`, placement outside `bounds`, a seam importing a behavior module, and a prefab member referenced
but not placed are all **compile errors**.

The `.flvl` lowering is one-way: on a snapshot dump, names survive; the sugar does not.
