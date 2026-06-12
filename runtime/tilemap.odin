// The §18 §3 baked tile layer, its §18 §4 query surface, and the §18 §4
// SetTile tick-end application: the environment a tilemap's ASCII grid bakes
// to, decoded from the artifact's [tilemaps] section (docs/artifact-format.md
// §17, schema v12) into the Program, rendered BATCHED (one layer-level draw
// command, never per-tile Draw::Sprite rows — render.odin), and queried
// through the level seam's TilemapHandle (tile_at / solid_at / cell_of /
// center_of, interp_call.odin → eval_tilemap_method here).
//
// Tile state is COMMITTED WORLD STATE: the program's decoded tables are the
// pristine BAKE, aliased onto version -1 and carried forward COW on the
// World_Version chain — a behavior-returned SetTile{map, cell, tile} (the
// [Spawn]-class command path) folds into the NEXT version's layer tables at
// the commit boundary (fold_tile_layers), so next tick's render, collision,
// and queries all update from the same data and every recorded version
// re-folds over its own tick's terrain (replay, §28, branches).
//
// Collision is the QUERY surface (§18 §2, §18 §4): tile collision is sim-side
// and deterministic — a behavior gates its own movement through solid_at over
// the fixed-point grid (the dungeon's `enterable` reads tile_at + solid_at and
// refuses the step), exactly as §18 §4 contracts. The runtime owns no movement
// system for tilemap actors (movement is behavior-authored), so there is no
// solver registration here: the deterministic query IS the collision contract,
// and the §11 physics solver remains the Body-carrying things' path.
//
// Every query is a pure function of (layer, argument): no map iteration, no
// float, all arithmetic over the Q32.32 kernel — bit-identical everywhere
// (§10.5), so the §18 §4 "stable cell order ⇒ deterministic" clause holds by
// construction.
package funpack_runtime

// TILE_CELL_EMPTY marks a tile-less grid cell in Tile_Layer.cells — an `empty`
// legend bind or a spawn-marker cell (a marker places an entity, it paints no
// terrain). The artifact carries it as `-` (§17).
TILE_CELL_EMPTY :: -1

// Tile_Def is one palette entry of a baked tile layer: the project-global tile
// name and its §18 §2 baked collision verdict — the (name, solid) pair the
// artifact's `tile NAME SOLID` sub-records carry. The bake already resolved
// the name through the tileset table, so both fields are final here.
Tile_Def :: struct {
	name:  string,
	solid: bool,
}

// Tile_Layer is one decoded [tilemaps] record (§17): the layer name (also the
// level seam's TilemapHandle constant name), the per-cell logical size in
// integer world units, the grid dimensions, the palette in legend order, and
// the row-major per-cell palette indices (TILE_CELL_EMPTY = no tile).
//
// `top_left` is the grid→world anchor: the world point of the grid's top-left
// corner — the doc's `(bounds_min.x, bounds_max.y)` (§17: row 0 is the level's
// TOP edge, col grows +x, row grows -y). The v12 lead line carries it as
// authoritative format data (the tilemap-anchor ADR), so the loader READS it
// — the record is self-describing for any level bounds, and the query kernel
// stays anchor-general (the anchor is an explicit field, never re-derived per
// query).
Tile_Layer :: struct {
	name:      string,
	cell_size: i64, // per-cell logical size in integer world units (> 0)
	cols:      int, // grid width in cells (> 0)
	rows:      int, // grid height in cells (> 0)
	top_left:  Vec2, // world point of the grid's top-left corner (Q32.32)
	palette:   []Tile_Def, // legend-order tile types with baked solid verdicts
	cells:     []int, // row-major palette index per cell; TILE_CELL_EMPTY = no tile
}

// program_tilemap finds a decoded tile layer by its TilemapHandle name, or nil
// — the BAKE-side lookup (the program's pristine decoded tables). The query
// and render surfaces resolve through version_tilemap instead: tile state is
// committed world state (§18 §4 SetTile), so a read always answers over its
// own version's terrain, never the bake's.
program_tilemap :: proc(program: ^Program, name: string) -> ^Tile_Layer {
	for &layer in program.tilemaps {
		if layer.name == name {
			return &layer
		}
	}
	return nil
}

// version_tilemap finds a committed tile layer by its TilemapHandle name at one
// World_Version, or nil — the lookup the handle-method dispatch resolves a
// `TilemapHandle{name}` receiver through (mirroring program_function's
// bare-name contract), against THIS version's COW tile state.
version_tilemap :: proc(version: ^World_Version, name: string) -> ^Tile_Layer {
	if version == nil {
		return nil
	}
	for &layer in version.tilemaps {
		if layer.name == name {
			return &layer
		}
	}
	return nil
}

// tile_layers_equal compares two decoded layers structurally — the
// determinism assertion's comparison (same artifact ⇒ same tables) and the
// Draw_Tilemap arm of draw_cmd_equal. Slices compare element-wise; Fixed
// anchors compare by raw bits.
tile_layers_equal :: proc(a, b: Tile_Layer) -> bool {
	if a.name != b.name ||
	   a.cell_size != b.cell_size ||
	   a.cols != b.cols ||
	   a.rows != b.rows ||
	   a.top_left != b.top_left {
		return false
	}
	if len(a.palette) != len(b.palette) || len(a.cells) != len(b.cells) {
		return false
	}
	for tile, i in a.palette {
		if tile != b.palette[i] {
			return false
		}
	}
	for cell, i in a.cells {
		if cell != b.cells[i] {
			return false
		}
	}
	return true
}

// --- The §18 §4 query kernel (pure, fixed-point, total) --------------------

// tilemap_tile_at is `tile_at(cell) -> Option[String]` as the bare kernel: the
// palette name of the tile at (col, row), or has=false for a tile-less cell —
// an `empty`/marker cell, an out-of-grid cell (the void is not floor: the
// dungeon's `enterable` reads None as not-enterable), or a cell whose palette
// index has no entry (unreachable past the load gate, refused defensively).
tilemap_tile_at :: proc(layer: ^Tile_Layer, col, row: int) -> (name: string, has: bool) {
	if col < 0 || col >= layer.cols || row < 0 || row >= layer.rows {
		return "", false
	}
	index := layer.cells[row * layer.cols + col]
	if index == TILE_CELL_EMPTY {
		return "", false
	}
	if index < 0 || index >= len(layer.palette) {
		return "", false
	}
	return layer.palette[index].name, true
}

// tilemap_solid_at is `solid_at(cell) -> Bool`: the baked §18 §2 collision
// verdict of the tile at (col, row). A tile-less or out-of-grid cell is NOT
// solid — solidity is a property of a tile, and the void carries none (the
// dungeon's chasm blocks through tile_at's None, not through solid_at) — so
// the query is total and the two queries compose into the §18 §4 movement
// gate without overlapping meanings.
tilemap_solid_at :: proc(layer: ^Tile_Layer, col, row: int) -> bool {
	if col < 0 || col >= layer.cols || row < 0 || row >= layer.rows {
		return false
	}
	index := layer.cells[row * layer.cols + col]
	if index < 0 || index >= len(layer.palette) {
		return false // TILE_CELL_EMPTY, or an index past the palette (gated at load)
	}
	return layer.palette[index].solid
}

// tilemap_cell_of is `cell_of(pos) -> Cell`: the grid cell containing a world
// position — floor division of the anchored offset by the cell size, exact
// over raw Q32.32 bits (both operands carry the same 2^32 scale, so the
// integer ratio is the true cell index; no fixed_div precision loss, no
// float). A position outside the grid yields the out-of-grid cell index the
// arithmetic names (negative or >= the extent) — total, and tile_at/solid_at
// answer None/false over it, so the composition stays closed.
tilemap_cell_of :: proc(layer: ^Tile_Layer, pos: Vec2) -> (col, row: i64) {
	cell_bits := i64(to_fixed(layer.cell_size)) // > 0, gated at load
	dx_bits := i64(fixed_sub(pos.x, layer.top_left.x))
	dy_bits := i64(fixed_sub(layer.top_left.y, pos.y)) // row grows -y (§17)
	return floor_div_i64(dx_bits, cell_bits), floor_div_i64(dy_bits, cell_bits)
}

// tilemap_center_of is `center_of(cell) -> Vec2`: the world-space center of a
// grid cell, computed with the same kernel ops in the same order as the
// bake's marker-placement math, so the runtime's center is bit-identical to
// the point the bake gives a cell's markers and cell() anchors: render,
// collision, and spawns share one mapping (§17). Total over any cell — the
// formula extrapolates outside the grid deterministically.
tilemap_center_of :: proc(layer: ^Tile_Layer, col, row: i64) -> Vec2 {
	half := fixed_div(to_fixed(layer.cell_size), to_fixed(2))
	x := fixed_add(layer.top_left.x, fixed_add(to_fixed(int_mul(col, layer.cell_size)), half))
	y := fixed_sub(layer.top_left.y, fixed_add(to_fixed(int_mul(row, layer.cell_size)), half))
	return Vec2{x = x, y = y}
}

// floor_div_i64 is exact floor division (quotient rounded toward negative
// infinity) — the cell_of rounding rule. Odin's `/` truncates toward zero, so
// a negative non-exact quotient is corrected by one. The divisor is positive
// here (cell sizes are gated > 0 at load), but the correction reads both signs
// so the helper is sound stand-alone.
floor_div_i64 :: proc(a, b: i64) -> i64 {
	q := a / b
	if a % b != 0 && (a < 0) != (b < 0) {
		q -= 1
	}
	return q
}

// --- The §12 §3 los occupancy kernel (segment supercover vs solids) --------

// SEGMENT_COORD_LIMIT bounds the anchored segment coordinates (and the cell
// size) tilemap_segment_clear admits: 2^62 raw Q32.32 bits = 2^30 world units,
// far past any level while keeping every intermediate product inside i128
// (worst term: a clamped window numerator times the v-delta, < 2^63 · 2^63;
// the guarded sum stays under 2^127). A coordinate past the limit fails closed
// — total and deterministic, never a wrapped product.
SEGMENT_COORD_LIMIT: i128 : 1 << 62

// tilemap_segment_clear is the §12 §3 engine-los verdict over one committed
// tile layer: true iff NO solid cell's CLOSED cell box intersects the closed
// segment from→to — the conservative supercover the spec pins (a lattice-corner
// crossing checks all four incident cells, a segment grazing a wall's face
// reads blocked, from == to degenerates to the point's touched cells). Solids
// block; tile-less cells and the out-of-grid void do not (solidity is a
// property of a tile — tilemap_solid_at's totality), so sight crosses a chasm
// feet cannot (§12 §3: los is sight, reachable is feet).
//
// The sweep is exact integer arithmetic over anchored Q32.32 coordinates — no
// division of coordinates, no float, no iteration-order dependence: for each
// column whose closed x-band the segment touches (closed-box bounds: c from
// ceil(u_min/S)-1 through floor(u_max/S), clamped to the grid), the segment's
// v-extent inside that band is formed as RATIONALS over the common denominator
// du (numerators v0·du + p·dv at the clamped window ends p), and the touched
// row range comes from the same closed-box floor/ceil bounds cross-multiplied
// by the denominator — i128 throughout, so every comparison is exact and the
// verdict is bit-identical on every machine (§10.5).
tilemap_segment_clear :: proc(layer: ^Tile_Layer, from, to: Vec2) -> bool {
	cell := i128(i64(to_fixed(layer.cell_size))) // S, > 0 (gated at load)
	u0 := i128(i64(from.x)) - i128(i64(layer.top_left.x))
	v0 := i128(i64(layer.top_left.y)) - i128(i64(from.y)) // row grows -y (§17)
	u1 := i128(i64(to.x)) - i128(i64(layer.top_left.x))
	v1 := i128(i64(layer.top_left.y)) - i128(i64(to.y))
	if !segment_coord_ok(u0) ||
	   !segment_coord_ok(v0) ||
	   !segment_coord_ok(u1) ||
	   !segment_coord_ok(v1) ||
	   cell > SEGMENT_COORD_LIMIT {
		return false // out of the exactness envelope: refuse, never wrap
	}
	if u1 < u0 {
		u0, u1 = u1, u0
		v0, v1 = v1, v0 // direction is immaterial to the touched-cell set
	}
	du := u1 - u0 // >= 0 after the swap
	dv := v1 - v0
	// The common denominator of the per-column v-extent rationals: du for a
	// genuinely sloped/horizontal segment, 1 for a vertical one (where the
	// v-extent is the whole segment in every touched column).
	den: i128 = 1
	if du != 0 {
		den = du
	}
	row_den := cell * den
	c_lo := ceil_div_i128(u0, cell) - 1 // closed box: an exact-boundary u touches both columns
	c_hi := floor_div_i128(u1, cell)
	if c_lo < 0 {
		c_lo = 0
	}
	if c_hi > i128(layer.cols - 1) {
		c_hi = i128(layer.cols - 1) // solids exist only in-grid; the void blocks nothing
	}
	for c := c_lo; c <= c_hi; c += 1 {
		vmin_num, vmax_num: i128
		if du == 0 {
			vmin_num = min(v0, v1)
			vmax_num = max(v0, v1)
		} else {
			// The segment's parameter window inside this column's closed x-band,
			// as numerators p over the denominator du (p ∈ [0, du]).
			p_enter := c * cell - u0
			if p_enter < 0 {
				p_enter = 0
			}
			p_exit := (c + 1) * cell - u0
			if p_exit > du {
				p_exit = du
			}
			va := v0 * du + p_enter * dv
			vb := v0 * du + p_exit * dv
			vmin_num = min(va, vb)
			vmax_num = max(va, vb)
		}
		r_lo := ceil_div_i128(vmin_num, row_den) - 1 // closed box, as the column bounds
		r_hi := floor_div_i128(vmax_num, row_den)
		if r_lo < 0 {
			r_lo = 0
		}
		if r_hi > i128(layer.rows - 1) {
			r_hi = i128(layer.rows - 1)
		}
		for r := r_lo; r <= r_hi; r += 1 {
			if tilemap_solid_at(layer, int(c), int(r)) {
				return false
			}
		}
	}
	return true
}

// segment_coord_ok admits one anchored coordinate into the i128 exactness
// envelope (|coord| <= SEGMENT_COORD_LIMIT) — the tilemap_segment_clear guard.
segment_coord_ok :: proc(coord: i128) -> bool {
	return coord >= -SEGMENT_COORD_LIMIT && coord <= SEGMENT_COORD_LIMIT
}

// floor_div_i128 / ceil_div_i128 are exact floor/ceiling division over i128 —
// the closed-box cell-range bounds of tilemap_segment_clear. Odin's `/`
// truncates toward zero; the corrections read both signs so the helpers are
// sound stand-alone (divisors here are positive: cell sizes gate > 0 at load
// and the denominator is normalized > 0).
floor_div_i128 :: proc(a, b: i128) -> i128 {
	q := a / b
	if a % b != 0 && (a < 0) != (b < 0) {
		q -= 1
	}
	return q
}

ceil_div_i128 :: proc(a, b: i128) -> i128 {
	q := a / b
	if a % b != 0 && (a < 0) == (b < 0) {
		q += 1
	}
	return q
}

// --- The TilemapHandle method dispatch (the behavior-call surface) ---------

// eval_tilemap_method lowers the §18 §4 queries reached as value-methods on a
// level seam's `TilemapHandle{name}` record receiver — the calling convention
// the dungeon's behaviors use (`map.tile_at(target)`, `map.cell_of(self.pos)`,
// the §26 self-first extern fns in method form, the apply_impulse mold). The
// handle's `name` field resolves the decoded layer through program_tilemap;
// an unknown layer name, a missing/non-String name field, or a malformed
// argument fails closed (ok=false), never a guessed answer.
// is_tilemap_method is false for a method name outside the §18 §4 set so a
// non-query member falls through to the next receiver arm.
eval_tilemap_method :: proc(
	interp: ^Interp,
	node: ^Node,
	env: ^Env,
	handle: Record_Value,
	method: string,
) -> (
	value: Value,
	ok: bool,
	is_tilemap_method: bool,
) {
	switch method {
	case "tile_at", "solid_at", "cell_of", "center_of":
	case:
		return nil, false, false
	}
	layer := tilemap_of_handle(interp, handle)
	if layer == nil || len(node.children) != 2 {
		return nil, false, true
	}
	arg, arg_ok := eval(interp, &node.children[1], env)
	if !arg_ok {
		return nil, false, true
	}

	switch method {
	case "tile_at":
		col, row, cell_ok := cell_arg(arg)
		if !cell_ok {
			return nil, false, true
		}
		name, has := tilemap_tile_at(layer, col, row)
		if !has {
			return none_value(), true, true
		}
		return some_value(interp, String_Value{text = name}), true, true
	case "solid_at":
		col, row, cell_ok := cell_arg(arg)
		if !cell_ok {
			return nil, false, true
		}
		return tilemap_solid_at(layer, col, row), true, true
	case "cell_of":
		pos, is_vec2 := arg.(Vec2)
		if !is_vec2 {
			return nil, false, true
		}
		col, row := tilemap_cell_of(layer, pos)
		return cell_value(interp, col, row), true, true
	case "center_of":
		col, row, cell_ok := cell_arg(arg)
		if !cell_ok {
			return nil, false, true
		}
		return tilemap_center_of(layer, i64(col), i64(row)), true, true
	}
	return nil, false, true
}

// tilemap_of_handle resolves a TilemapHandle record receiver to its committed
// layer: the handle's `name` String field keys version_tilemap against the
// interp's version — mid-fold that is the tick's ENTERING version, so a query
// reads the terrain the tick started from and a SetTile applied at tick end is
// first visible to the NEXT tick's queries (§18 §4). nil when the field is
// absent, not a String, or names no committed layer — the caller fails closed.
tilemap_of_handle :: proc(interp: ^Interp, handle: Record_Value) -> ^Tile_Layer {
	name, ok := tilemap_handle_name(handle)
	if !ok {
		return nil
	}
	return version_tilemap(interp.version, name)
}

// tilemap_handle_name reads the `name` String field off a `TilemapHandle{name}`
// record value — the one field the handle carries. ok=false on a missing or
// non-String field (a malformed handle fails closed, never a guessed layer).
tilemap_handle_name :: proc(handle: Record_Value) -> (name: string, ok: bool) {
	field, present := handle.fields["name"]
	if !present {
		return "", false
	}
	text, is_string := field.(String_Value)
	if !is_string {
		return "", false
	}
	return text.text, true
}

// cell_arg reads a `Cell{x, y}` record argument into its integer cell
// coordinates. The §26 Cell is {x: Int, y: Int}, so both fields must be Int
// columns — any other shape fails closed (the queries are defined over the
// integer grid only, never a lifted Fixed).
cell_arg :: proc(arg: Value) -> (col, row: int, ok: bool) {
	cell, is_record := arg.(Record_Value)
	if !is_record {
		return 0, 0, false
	}
	x, x_present := cell.fields["x"]
	y, y_present := cell.fields["y"]
	if !x_present || !y_present {
		return 0, 0, false
	}
	xi, x_is_int := x.(i64)
	yi, y_is_int := y.(i64)
	if !x_is_int || !y_is_int {
		return 0, 0, false
	}
	return int(xi), int(yi), true
}

// cell_value builds the `Cell{x, y}` record cell_of returns — the §26
// engine.grid Cell shape (two Int fields) a behavior feeds straight back into
// step_cell / neighbors / a Cell == Cell comparison.
cell_value :: proc(interp: ^Interp, col, row: i64) -> Value {
	fields := make(map[string]Value, interp.allocator)
	fields["x"] = col
	fields["y"] = row
	return Record_Value{type_name = "Cell", fields = fields}
}

// --- The §18 §4 SetTile tick-end application (the [Spawn]-class command path) -

// Set_Tile_Refusal_Kind is the closed set of ways one SetTile command fails its
// tick-end application. Each is a NAMED per-command refusal — the §24 persist
// Result::Err mold (the command fails closed, the tick completes, nothing is
// silently dropped) — recorded into Tick_State.settile_refusals in application
// order, deterministic under replay (same inputs, same refusals).
Set_Tile_Refusal_Kind :: enum {
	Malformed_Command, // the record is not the SetTile{map, cell, tile} shape
	Unknown_Layer,     // `map` names no committed tile layer
	Unknown_Tile,      // `tile` names no palette entry of the layer
	Cell_Out_Of_Grid,  // `cell` lies outside the layer's grid
}

// Set_Tile_Refusal names one refused SetTile command: the refusal arm plus the
// offending coordinates the diagnostic needs ("" / 0 where the malformed shape
// never yielded them). The strings alias the command record's same-tick eval
// values — refusals are a same-tick read, never carried across the boundary.
Set_Tile_Refusal :: struct {
	kind:  Set_Tile_Refusal_Kind,
	layer: string, // the named layer ("" when the map handle itself is malformed)
	tile:  string, // the named tile ("" when absent/malformed)
	col:   int, // the target cell, when the command carried one
	row:   int,
}

// tilemap_palette_index finds a tile's palette index by its project-global
// name, or -1 — the name → index resolution one applied SetTile performs
// against the layer's legend-order palette.
tilemap_palette_index :: proc(layer: ^Tile_Layer, tile: string) -> int {
	for def, i in layer.palette {
		if def.name == tile {
			return i
		}
	}
	return -1
}

// fold_tile_layers folds one tick's collected SetTile commands into the next
// committed version's tile-layer state — the §18 §4 tick-end application,
// applied in COMMAND COLLECTION ORDER (flattened pipeline order, stable Id
// order within a behavior, list order within a return — the same order the
// spawn batch fixes), so the fold is a pure function of the tick's command
// sequence and the last write to a cell wins deterministically.
//
// COW at the layer level: a tick with no commands SHARES the prior slice by
// reference (the structural-sharing discipline tables get); a command-carrying
// tick allocates a fresh layers slice on the COMMIT allocator and copies only
// the TOUCHED layers' cells once each — names and palettes alias the prior
// version (ultimately the program's pristine decode) forever, so the only
// per-version ownership is the cells backing the live reclaimer retires.
//
// Every invalid command is a NAMED refusal (Set_Tile_Refusal) appended to
// state.settile_refusals — fail the COMMAND closed, never the tick, and never
// a silent drop (the spawn batch's unknown-thing `continue` is deliberately
// NOT matched; the persist Result::Err per-command arm is).
fold_tile_layers :: proc(prior: World_Version, state: ^Tick_State) -> []Tile_Layer {
	if len(state.settile_commands) == 0 {
		return prior.tilemaps
	}
	layers := make([]Tile_Layer, len(prior.tilemaps), state.commit_allocator)
	copy(layers, prior.tilemaps)
	// Which layers' cells are already fresh THIS tick — copy once, then write
	// in place within the tick's own copy.
	fresh := make([]bool, len(layers), state.allocator)

	for command in state.settile_commands {
		layer_name, cell, tile, shape_ok := settile_command_parts(command)
		if !shape_ok {
			append(&state.settile_refusals, Set_Tile_Refusal{kind = .Malformed_Command, layer = layer_name})
			continue
		}
		index := -1
		for &layer, i in layers {
			if layer.name == layer_name {
				index = i
				break
			}
		}
		if index < 0 {
			append(&state.settile_refusals, Set_Tile_Refusal{kind = .Unknown_Layer, layer = layer_name, tile = tile, col = cell.x, row = cell.y})
			continue
		}
		layer := &layers[index]
		palette := tilemap_palette_index(layer, tile)
		if palette < 0 {
			append(&state.settile_refusals, Set_Tile_Refusal{kind = .Unknown_Tile, layer = layer_name, tile = tile, col = cell.x, row = cell.y})
			continue
		}
		if cell.x < 0 || cell.x >= layer.cols || cell.y < 0 || cell.y >= layer.rows {
			append(&state.settile_refusals, Set_Tile_Refusal{kind = .Cell_Out_Of_Grid, layer = layer_name, tile = tile, col = cell.x, row = cell.y})
			continue
		}
		if !fresh[index] {
			cells := make([]int, len(layer.cells), state.commit_allocator)
			copy(cells, layer.cells)
			layer.cells = cells
			fresh[index] = true
		}
		layer.cells[cell.y * layer.cols + cell.x] = palette
	}
	return layers
}

// Settile_Cell is the integer target cell one parsed SetTile command names.
Settile_Cell :: struct {
	x: int,
	y: int,
}

// settile_command_parts reads one collected SetTile record into its
// application parts: the `map` handle's layer name, the `cell` record's
// integer coordinates, and the `tile` String. ok=false on any missing or
// mis-shaped field — the Malformed_Command refusal arm (typecheck admits only
// the closed schema, so this is the artifact-tamper fail-closed floor, not a
// reachable source-level shape). The layer name is returned even on a
// malformed cell/tile so the refusal can still point at the layer.
settile_command_parts :: proc(command: Record_Value) -> (layer: string, cell: Settile_Cell, tile: string, ok: bool) {
	map_field, has_map := command.fields["map"]
	if !has_map {
		return "", {}, "", false
	}
	handle, is_record := map_field.(Record_Value)
	if !is_record {
		return "", {}, "", false
	}
	name, name_ok := tilemap_handle_name(handle)
	if !name_ok {
		return "", {}, "", false
	}
	cell_field, has_cell := command.fields["cell"]
	if !has_cell {
		return name, {}, "", false
	}
	col, row, cell_ok := cell_arg(cell_field)
	if !cell_ok {
		return name, {}, "", false
	}
	tile_field, has_tile := command.fields["tile"]
	if !has_tile {
		return name, {}, "", false
	}
	text, is_string := tile_field.(String_Value)
	if !is_string {
		return name, {}, "", false
	}
	return name, Settile_Cell{x = col, y = row}, text.text, true
}
