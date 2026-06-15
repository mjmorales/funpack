# 18 — Sprites & tilemaps

2D content is two layers: **sprites** (the textured-quad draw primitive) and **tilemaps** (grids of
tiles that make up the environment). A tilemap is a **level layer** ([`17`](17-levels.md)), and its
authored form answers the level module's hardest problem head-on:

> **The grid is the viewport.** A tilemap is an **ASCII grid** the agent reads, edits, and diffs *as
> a picture*; the same grid both paints the environment and places the entities.

## 1. Sprites

A sprite is a region of a texture **atlas** drawn as a quad — a `Draw` command, as data
([`20`](20-render.md)):

```funpack
Draw::Sprite{ atlas: assets.pickups, cell: "coin", at: self.pos, size: Vec2{x:8.0, y:8.0},
              tint: Color::White, flip: Flip::None, layer: 5 }
```

- **Atlas** — a baked sprite sheet of named regions (`atlas("items") -> AtlasHandle`, an asset).
  Authored in an `.atlas` file: `atlas Pickups { image "pickups.png"; grid 8 8; cell coin at (0,0);
  clip spin cells ["coin","gem","key"] fps 8 }`.
- **Cell** — a region id (`String`): a named region (`"coin"`) or a grid cell `atlas.cell(col, row)`.
  Names, not pixel rects — legible and diffable (P7).
- **`layer: Int`** — explicit back-to-front draw order, a stated number.
- **`flip`** — `X`/`Y`/`XY` mirroring (the rig-mirror idea in 2D).

**Animation is a pure projection:** a named clip (ordered cells + rate); `atlas.frame(clip, t)` is
total and deterministic (fixed-point clock ⇒ replay-identical), so an animated sprite is unit-tested
by exact equality like any other render.

## 2. Tilesets (`.tiles`)

A **tileset** names the tile types a map draws from — each tile's atlas cell and its **collision** —
and bakes to a `TilesetHandle`:

```
tileset Dungeon {
  atlas dungeon_atlas
  tile floor { cell: (0, 0), solid: false }
  tile wall  { cell: (1, 0), solid: true  }
  tile water { cell: (2, 0), solid: false, tags: ["liquid"] }
}
```

Tile collision is **sim-side and deterministic** (fixed-point grid), baked into the tilemap so
behaviors query it without per-tile things.

## 3. Tilemaps — the ASCII grid

Authored inside a `level` as a layer: a **legend** mapping single characters to a *tile* (static
environment) or a *spawn* (an entity), and a **grid** of those characters.

```
tilemap floor cell 16 {            // layer `floor`; each cell is 16 logical units
  legend {
    '#' wall                       // a tile (static, solid)
    '.' floor                      // a tile (passable)
    'g' spawn Goblin               // an anonymous marker — spawn a thing at this cell
    'P' spawn Player hero          // a named marker (must be unique)
    ' ' empty
  }
  grid """
    ################
    #..........g...#
    #...P.....####.#
    ################
  """
}
place Switch lever at cell(5, 3)   // the relational few use explicit place + the cell() anchor
place Door   exit  { gate: lever } at cell(11, 2)
```

The **grid** handles the spatial bulk (walls, floors, swarms of anonymous entities — what the agent
reasons about as a picture); **`place`** handles the relational few (named, referenced, precisely
positioned), tied into the grid via the `cell(col, row)` anchor. A **named marker** must appear
exactly once (a duplicate is a bake error); anonymous markers repeat freely.

A legend's tile name resolves through the **project-global tile namespace**: every `.tiles`
tileset in the project contributes its tiles to one flat name set, the same bare-name style an
`atlas` reference uses — a tilemap names no tileset. Two tilesets declaring the same tile name
is a bake error (one name, one tile), the duplicate-named-marker discipline applied to tiles.

It bakes to: a **tile layer** (a 2D array the engine renders **batched** and collides against — you
never emit per-tile `Draw::Sprite`); a **`[Spawn]`** per marker at its cell center (row-major
declaration order ⇒ deterministic ids); and the level **seam** gains the named markers as `Ref`s and
the layer as a `TilemapHandle`.

## 4. Collision, queries & dynamic tiles

Behaviors query the baked layer through the `TilemapHandle` — no per-tile entities, fixed-point and
replay-safe (`stdlib/engine/tilemap.fun`): `tile_at(cell) -> Option[String]`, `solid_at(cell) ->
Bool`, `cell_of(pos) -> Cell`, `center_of(cell) -> Vec2`; stable cell order makes every query
deterministic. A handle-touching behavior is tested with `TilemapHandle.of(cell_size, cells)` (the
`View.of`/`Nav.of` mold): the fixture seeds a small layer from `(cell, tile, solid)` rows in its
own grid-local space anchored at the origin — no legend, no tileset — and the four queries answer
over it; an unseeded cell reads `Option::None`/not-solid, never a fault. Destructible terrain is a command: a behavior returns `SetTile{ map, cell, tile }`
(the `[Spawn]`-class path), applied deterministically at tick end; render, collision, and the nav
graph ([`12`](12-navigation.md)) update from the same data. The rewritten cells are committed world
state, not bake decoration: across a hot-reload swap the live `SetTile` delta carries onto the new
bake ([`09`](09-runtime.md) §4), and across save/restore it rides the snapshot
([`24`](24-persistence.md) §1).

**Runtime generation — the whole-layer twin.** `SetTile` *edits* a cell; a seeded behavior that
*builds* a layer (a procedural floor, a generated map) emits its bulk twin: `BuildLayer{ map, fill,
cells }` — `fill` is the base tile every cell takes and `cells: [(Cell, String)]` the explicit
overrides — applied atomically at tick end as one committed-state write that **replaces** the layer's
contents (not a delta accreted over prior edits). It is an ordinary pipeline behavior result threaded
with the seeded `Rng` ([`04`](04-effects.md) §1, [`26`](26-stdlib.md)) — the engine compiles and runs
it like any behavior, so **generation never makes the runtime compile source** (the engine boundary,
[`01`](01-axioms.md)); per-floor entities are the ordinary `[Spawn]` path. Everything `SetTile`
guarantees holds: render, collision, and the nav graph ([`12`](12-navigation.md)) re-derive from the
new layer; the materialized layer is committed world state that carries across a hot-reload swap
([`09`](09-runtime.md) §4) and rides the save snapshot ([`24`](24-persistence.md) §1), bounded by the
layer's extent rather than an unbounded edit log. The layer's **extent and tileset are still declared
once by its authored `.flvl`** (the canvas); generation paints it. A level remains an initial snapshot
([`17`](17-levels.md) §3) — a generated layer is runtime committed state, never `.flvl` sugar
re-evaluated live (the lowering is one-way). Variable per-floor extent is out of scope here: a built
layer fills its declared extent.

The integer-grid helpers (`stdlib/engine/grid.fun`): `Cell { x, y }`, `grid_cells(size: Cell) ->
[Cell]`, `neighbors(cell)`, `in_bounds(cell, size)`. *(Canonical: `grid_cells` takes a `Cell` and
returns the cells; the 3-argument mapper form `grid_cells(w, h, fn)` used by `examples/snake` is
non-idiomatic — map over the cell list instead.)*

## 5. 2D / 3D & determinism

Textured tile *rendering* is 2D, but the **grid-with-legend authoring generalizes to 3D**: a marker
char places a **prefab** per cell (the classic blockout grid), with stacked `tilemap` layers giving
the third axis. Spawn/render order is row-major then explicit `place`s in declaration order
(bit-identical load). Bake gates (P5): a char not in the legend, a non-rectangular grid, a tile name
not in the tileset, a duplicate named marker, a marker without a `pos` of the level's arity, an
unresolved reference, or a `cell()` outside the grid are all compile errors.
