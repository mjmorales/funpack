@doc("Integer tile-grid helpers for grid games (Snake, roguelikes, board games). Cell is plain Eq/Hash data, so it works as a Map key and in a View join.")

import engine.prelude.{Int, Bool}

@doc("An integer grid cell.")
data Cell { x: Int, y: Int }

@doc("Every cell of a size.x×size.y grid, from (0,0) to (size.x-1, size.y-1) in stable row-major order (y outer). The canonical form (§18 §4).")
extern fn grid_cells(size: Cell) -> [Cell]
@doc("Every cell of a w×h grid, built by calling builder(x, y) per cell in stable row-major order (y outer). Non-idiomatic mapper form — map over the canonical cell list instead.")
extern fn grid_cells(w: Int, h: Int, builder: fn(Int, Int) -> Cell) -> [Cell]
@doc("The four orthogonally adjacent cells.")
extern fn neighbors(cell: Cell) -> [Cell]
@doc("Whether a cell lies within a grid of the given size.")
extern fn in_bounds(cell: Cell, size: Cell) -> Bool
