# dungeon

A one-screen dungeon crawl whose point is the **tilemap pipeline**
([`spec/18-tilemaps.md`](../../spec/18-tilemaps.md)): the grid is the viewport. One ASCII
picture both paints the terrain and places the entities; the baked layer answers every
collision question; destructible terrain is a plain `SetTile` command.

Two rooms split by a wall whose rubble segments are the only way through. Dig them
(`Space`) and the right room's chest is yours — if you skirt the chasm. Slimes crawl the
same open cells you do, so a dug passage opens to them too.

What it exercises, by §18 anchor:

- **A tileset (`assets/dungeon.tiles`, §2)** — `floor`/`wall`/`water`/`rubble`, each naming
  its atlas cell and carrying sim-side `solid` collision; `water` and `rubble` show `tags`.
  Bakes to a `TilesetHandle`. The `.tiles` and `.atlas` sources live in `assets/` with the
  committed manifest, per the enforced tree
  ([`spec/14-project-config.md`](../../spec/14-project-config.md) §1).
- **The ASCII grid layer (`levels/dungeon.flvl`, §3)** — a `tilemap terrain cell 16` layer:
  a legend of tiles, anonymous `g` spawn markers, the named `P spawn Player hero` marker
  (exactly once), and `' ' empty` (the chasm); a rectangular grid read as a picture. The
  relational few use `place Chest loot { gems: 5 } at cell(13, 4)` — the grid/place split.
- **Collision & queries (§4)** — behaviors in `src/dungeon_game.fun` query the baked layer
  through the seam's `TilemapHandle`: movement is `cell_of` → `step_cell` → `solid_at`/
  `tile_at` → `center_of`, with the gate decomposed into the pure `enterable` (the void is
  not floor). Slime pursuit uses the canonical `engine.grid` helpers (`neighbors`,
  `in_bounds`) over the same gate.
- **Dynamic tiles (§4)** — `dig` returns `SetTile{ map, cell, tile: "floor" }` when the
  faced tile is rubble; render, collision, and the nav graph update from the same data at
  tick end.
- **Sprites (§1)** — the hero, slimes, and chest draw as `Draw::Sprite` through the typed
  `assets.dungeon_atlas` handle; the tile layer itself is engine-rendered, batched — no
  behavior emits per-tile sprites.

The schema/seam/behavior split follows [`spec/17-levels.md`](../../spec/17-levels.md) §2:
`src/dungeon_world.fun` holds the placeable things, the level bakes `gen/dungeon.gen.fun`
(derived, gitignored, rebuilt — not committed here), and `src/dungeon_game.fun` consumes
both. Every decision the behaviors make — the movement gate, diggability, greedy pursuit,
loot folding — is a pure function over plain values, asserted exactly in inline tests.
