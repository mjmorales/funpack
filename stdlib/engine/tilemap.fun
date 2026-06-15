@doc("Tilesets and the runtime tilemap surface. A tilemap is authored as an ASCII grid + legend inside a level and bakes to a tile layer (rendered batched by the engine) plus [Spawn]s for marker chars; the per-level seam exposes the layer as a TilemapHandle (see spec/18-tilemaps.md, spec/17-levels.md). This module holds what the running game touches: tile/collision queries against the baked layer, cell<->world conversion, and the SetTile command for dynamic terrain. Tile collision is sim-side and deterministic (fixed-point grid).")

import engine.prelude.{Bool, Int, String, Option}
import engine.math.Vec2
import engine.grid.Cell

@doc("A baked tileset (tile types: each tile's atlas cell and collision), by stable name. Bake-time reference; the legend of a tilemap draws tile names from it.")
data TilesetHandle { name: String }

@doc("The tileset handle for a baked tileset name.")
extern fn tileset(name: String) -> TilesetHandle

@doc("A baked tile layer of a level. Carried in the level seam; the engine renders it batched and collides against it.")
data TilemapHandle { name: String }

@doc("The tile name at a cell, or None if the cell is empty.")
extern fn tile_at(self: TilemapHandle, cell: Cell) -> Option[String]
@doc("Whether the tile at a cell is solid (a wall). The deterministic collision query.")
extern fn solid_at(self: TilemapHandle, cell: Cell) -> Bool
@doc("The grid cell containing a world position.")
extern fn cell_of(self: TilemapHandle, pos: Vec2) -> Cell
@doc("The world-space center of a grid cell.")
extern fn center_of(self: TilemapHandle, cell: Cell) -> Vec2

@doc("A fixture tile layer for behavior tests: seeds (cell, tile, solid) rows in the layer's own grid-local space anchored at the origin, and the four queries answer over it — the deterministic stand-in a test passes where a baked layer would be, mirroring View.of/Nav.of. An unseeded cell reads None/not-solid, never a fault. Invoked TilemapHandle.of(cell_size, cells).")
extern fn of(cell_size: Int, cells: [(Cell, String, Bool)]) -> TilemapHandle

@doc("A command to change the tile at a cell at runtime (destructible/altering terrain). Applied deterministically at tick end; render and collision update from the same data.")
data SetTile { map: TilemapHandle, cell: Cell, tile: String }

@doc("SetTile's whole-layer twin: a seeded generation behavior folds an Rng into a whole tile layer and emits one BuildLayer to replace the layer's contents (a procedural floor, a generated map). `fill` is the base tile every cell takes; `cells` the explicit (cell, tile-name) overrides. Applied atomically at tick end as committed world state — render, collision, and the nav graph re-derive from the new layer, and it carries across hot-reload and the save snapshot like a SetTile delta, bounded by the layer's extent (see spec/18-tilemaps.md §4).")
data BuildLayer { map: TilemapHandle, fill: String, cells: [(Cell, String)] }
