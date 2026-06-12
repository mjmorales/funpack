// The §18 §3/§4 tile-layer acceptance fixtures: the v12 [tilemaps] decode (the
// populated-section flip, the named malformed-record refusal sweep, and the
// v12 anchor read), the four §18 §4 queries pinned to exact fixed-point values
// over hand-built layers (including the dungeon-parity cells the bake
// hand-verified), the TilemapHandle method dispatch through the interpreter,
// the BATCHED render emission (one command per layer, never per-tile), and the
// digest fold's determinism over a tile-layer-carrying draw-list.
package funpack_runtime

import "core:testing"

// --- fixtures ---------------------------------------------------------------

// TILEMAP_FIXTURE_ARTIFACT is a minimal v12 artifact carrying a 4×3 layer
// with two palette entries and the three cell classes (tile, tile-less, tile)
// — the same layer shape funpack's emit_tilemap_test pins byte-for-byte. The
// lead line's anchor (0, 48·2^32) is the grid's top-left world corner the v12
// carry makes authoritative.
TILEMAP_FIXTURE_ARTIFACT ::
	"funpack-artifact 15\n" +
	"[tilemaps 1]\n" +
	"tilemap terrain 16 4 3 0 206158430208 2\n" +
	"tile wall true\n" +
	"tile floor false\n" +
	"row 0 0 0 0\n" +
	"row 0 - 1 -\n" +
	"row 0 - 0 0\n"

// fixture_layer hand-builds the same 4×3 layer the artifact fixture decodes
// to — the query fixtures' direct subject (cell 16; the carried anchor puts
// the grid's top-left at world (0, 48)).
fixture_layer :: proc() -> Tile_Layer {
	palette := make([]Tile_Def, 2, context.temp_allocator)
	palette[0] = Tile_Def{name = "wall", solid = true}
	palette[1] = Tile_Def{name = "floor", solid = false}
	cells := make([]int, 12, context.temp_allocator)
	copy(cells, []int{0, 0, 0, 0, 0, TILE_CELL_EMPTY, 1, TILE_CELL_EMPTY, 0, TILE_CELL_EMPTY, 0, 0})
	return Tile_Layer {
		name      = "terrain",
		cell_size = 16,
		cols      = 4,
		rows      = 3,
		top_left  = Vec2{x = to_fixed(0), y = to_fixed(48)},
		palette   = palette,
		cells     = cells,
	}
}

// dungeon_layer hand-builds a 16×9 cell-16 layer matching the dungeon
// example's grid geometry (bounds (0,0)..(256,144)) so the grid→world parity
// values the wave-2 bake hand-verified pin the runtime mapping bit-exactly.
// Cell content is immaterial to the mapping; a single all-floor palette keeps
// the fixture small.
dungeon_layer :: proc() -> Tile_Layer {
	palette := make([]Tile_Def, 1, context.temp_allocator)
	palette[0] = Tile_Def{name = "floor", solid = false}
	cells := make([]int, 16 * 9, context.temp_allocator)
	return Tile_Layer {
		name      = "terrain",
		cell_size = 16,
		cols      = 16,
		rows      = 9,
		top_left  = Vec2{x = to_fixed(0), y = to_fixed(144)},
		palette   = palette,
		cells     = cells,
	}
}

// --- the v12 decode (the populated-section flip) ----------------------------

@(test)
test_load_tilemaps_populated_decodes :: proc(t: ^testing.T) {
	// AC (decode): a POPULATED [tilemaps] section now loads — the prior
	// fail-closed Malformed_Header refusal is replaced by the real decode —
	// and every carried field lands exactly: name, cell size, dimensions,
	// the v12 grid→world anchor READ off the lead line (never derived), the
	// legend-order palette with its baked solid verdicts, and the row-major
	// cells with `-` as TILE_CELL_EMPTY.
	program, err := load_program(TILEMAP_FIXTURE_ARTIFACT, context.temp_allocator)
	testing.expect_value(t, err, Artifact_Error.None)
	testing.expect_value(t, len(program.tilemaps), 1)
	layer := program.tilemaps[0]
	testing.expect_value(t, layer.name, "terrain")
	testing.expect_value(t, layer.cell_size, 16)
	testing.expect_value(t, layer.cols, 4)
	testing.expect_value(t, layer.rows, 3)
	testing.expect_value(t, layer.top_left.x, to_fixed(0))
	testing.expect_value(t, layer.top_left.y, to_fixed(48))
	testing.expect_value(t, len(layer.palette), 2)
	testing.expect_value(t, layer.palette[0], Tile_Def{name = "wall", solid = true})
	testing.expect_value(t, layer.palette[1], Tile_Def{name = "floor", solid = false})
	expected_cells := []int{0, 0, 0, 0, 0, TILE_CELL_EMPTY, 1, TILE_CELL_EMPTY, 0, TILE_CELL_EMPTY, 0, 0}
	testing.expect_value(t, len(layer.cells), len(expected_cells))
	for cell, i in expected_cells {
		testing.expect_value(t, layer.cells[i], cell)
	}
	// And the hand-built fixture is the decoded table — the two construction
	// paths agree structurally.
	testing.expect(t, tile_layers_equal(layer, fixture_layer()))
}

@(test)
test_load_tilemaps_empty_section_still_loads :: proc(t: ^testing.T) {
	// The `[tilemaps 0]` tail every level-less artifact emits keeps loading
	// clean with zero layers (the pre-decode behavior, unchanged).
	program, err := load_program("funpack-artifact 15\n[tilemaps 0]\n", context.temp_allocator)
	testing.expect_value(t, err, Artifact_Error.None)
	testing.expect_value(t, len(program.tilemaps), 0)
}

@(test)
test_load_tilemaps_malformed_refused :: proc(t: ^testing.T) {
	// AC (refusals): every malformed [tilemaps] record fails closed with
	// .Bad_Field — the coverage the wave-2 reviewer flagged. Each case bends
	// exactly one §17 shape rule of the well-formed fixture.
	malformed := [?]string {
		// lead line: the retired v11 arity (no anchor fields)
		"funpack-artifact 15\n[tilemaps 1]\ntilemap terrain 16 4 3 2\ntile wall true\nrow 0 0 0 0\n",
		// lead line: non-numeric anchor
		"funpack-artifact 15\n[tilemaps 1]\ntilemap terrain 16 2 1 0 y 1\ntile wall true\nrow 0 0\n",
		// lead line: zero cell size (cell_of divides by it)
		"funpack-artifact 15\n[tilemaps 1]\ntilemap terrain 0 2 1 0 0 1\ntile wall true\nrow 0 0\n",
		// lead line: zero cols
		"funpack-artifact 15\n[tilemaps 1]\ntilemap terrain 16 0 1 0 0 1\ntile wall true\nrow\n",
		// lead line: non-numeric rows
		"funpack-artifact 15\n[tilemaps 1]\ntilemap terrain 16 2 x 0 0 1\ntile wall true\nrow 0 0\n",
		// sub-record run: a missing row line (declared ROWS=2, one present)
		"funpack-artifact 15\n[tilemaps 1]\ntilemap terrain 16 2 2 0 0 1\ntile wall true\nrow 0 0\n",
		// sub-record run: a surplus palette line (declared 1, two present)
		"funpack-artifact 15\n[tilemaps 1]\ntilemap terrain 16 2 1 0 0 1\ntile wall true\ntile floor false\nrow 0 0\n",
		// palette: a row line where a tile line is declared (the windows split positionally)
		"funpack-artifact 15\n[tilemaps 1]\ntilemap terrain 16 2 1 0 0 1\nrow 0 0\ntile wall true\n",
		// palette: non-bool SOLID
		"funpack-artifact 15\n[tilemaps 1]\ntilemap terrain 16 2 1 0 0 1\ntile wall yes\nrow 0 0\n",
		// palette: wrong arity (missing SOLID)
		"funpack-artifact 15\n[tilemaps 1]\ntilemap terrain 16 2 1 0 0 1\ntile wall\nrow 0 0\n",
		// row: wrong arity (one cell on a 2-col grid)
		"funpack-artifact 15\n[tilemaps 1]\ntilemap terrain 16 2 1 0 0 1\ntile wall true\nrow 0\n",
		// row: a palette index past the declared palette
		"funpack-artifact 15\n[tilemaps 1]\ntilemap terrain 16 2 1 0 0 1\ntile wall true\nrow 0 1\n",
		// row: a negative palette index (the `-` form is the only tile-less spelling)
		"funpack-artifact 15\n[tilemaps 1]\ntilemap terrain 16 2 1 0 0 1\ntile wall true\nrow 0 -2\n",
		// row: a non-numeric cell
		"funpack-artifact 15\n[tilemaps 1]\ntilemap terrain 16 2 1 0 0 1\ntile wall true\nrow 0 z\n",
	}
	for artifact in malformed {
		_, err := load_program(artifact, context.temp_allocator)
		testing.expect_value(t, err, Artifact_Error.Bad_Field)
	}
}

@(test)
test_load_tilemaps_deterministic :: proc(t: ^testing.T) {
	// AC (determinism): same artifact ⇒ same tables — two independent loads
	// decode structurally identical layers (slice-order walks, no map ever
	// touches the decode).
	first, err1 := load_program(TILEMAP_FIXTURE_ARTIFACT, context.temp_allocator)
	second, err2 := load_program(TILEMAP_FIXTURE_ARTIFACT, context.temp_allocator)
	testing.expect_value(t, err1, Artifact_Error.None)
	testing.expect_value(t, err2, Artifact_Error.None)
	testing.expect_value(t, len(first.tilemaps), len(second.tilemaps))
	for layer, i in first.tilemaps {
		testing.expect(t, tile_layers_equal(layer, second.tilemaps[i]))
	}
}

// --- the §18 §4 query kernel ------------------------------------------------

@(test)
test_tilemap_tile_at_exact :: proc(t: ^testing.T) {
	// tile_at over every cell class: a named tile, the OTHER named tile, a
	// tile-less cell, and the out-of-grid void (all four edges) — exact names,
	// has=false for every no-tile answer.
	layer := fixture_layer()
	name, has := tilemap_tile_at(&layer, 0, 0)
	testing.expect(t, has)
	testing.expect_value(t, name, "wall")
	name, has = tilemap_tile_at(&layer, 2, 1)
	testing.expect(t, has)
	testing.expect_value(t, name, "floor")
	_, has = tilemap_tile_at(&layer, 1, 1) // the `-` cell
	testing.expect(t, !has)
	_, has = tilemap_tile_at(&layer, -1, 0) // left of the grid
	testing.expect(t, !has)
	_, has = tilemap_tile_at(&layer, 4, 0) // right of the grid
	testing.expect(t, !has)
	_, has = tilemap_tile_at(&layer, 0, -1) // above the grid
	testing.expect(t, !has)
	_, has = tilemap_tile_at(&layer, 0, 3) // below the grid
	testing.expect(t, !has)
}

@(test)
test_tilemap_solid_at_exact :: proc(t: ^testing.T) {
	// solid_at reads the baked §18 §2 verdict: the wall is solid, the floor is
	// not, and a tile-less or out-of-grid cell is NOT solid (the void blocks
	// through tile_at's None, never through solid_at — the dungeon's
	// `enterable` composition).
	layer := fixture_layer()
	testing.expect(t, tilemap_solid_at(&layer, 0, 0)) // wall
	testing.expect(t, !tilemap_solid_at(&layer, 2, 1)) // floor
	testing.expect(t, !tilemap_solid_at(&layer, 1, 1)) // tile-less
	testing.expect(t, !tilemap_solid_at(&layer, 9, 9)) // out of grid
}

@(test)
test_tilemap_cell_of_exact :: proc(t: ^testing.T) {
	// cell_of is exact floor division over raw Q32.32 bits: a cell center maps
	// to its cell, a corner lands in the cell it opens (row 0's top-left corner
	// is (0, 48) — exactly cell (0,0)), an interior boundary belongs to the
	// LATER cell on each axis, and a position outside the grid yields the
	// out-of-grid index the arithmetic names (total, never clamped).
	layer := fixture_layer()
	col, row := tilemap_cell_of(&layer, Vec2{x = to_fixed(8), y = to_fixed(40)}) // center of (0,0)
	testing.expect_value(t, col, 0)
	testing.expect_value(t, row, 0)
	col, row = tilemap_cell_of(&layer, Vec2{x = to_fixed(0), y = to_fixed(48)}) // the grid's top-left corner
	testing.expect_value(t, col, 0)
	testing.expect_value(t, row, 0)
	col, row = tilemap_cell_of(&layer, Vec2{x = to_fixed(16), y = to_fixed(32)}) // the (1,1) corner boundary
	testing.expect_value(t, col, 1)
	testing.expect_value(t, row, 1)
	col, row = tilemap_cell_of(&layer, Vec2{x = to_fixed(63), y = to_fixed(1)}) // inside the last cell
	testing.expect_value(t, col, 3)
	testing.expect_value(t, row, 2)
	col, row = tilemap_cell_of(&layer, Vec2{x = to_fixed(-1), y = to_fixed(49)}) // outside both axes
	testing.expect_value(t, col, -1)
	testing.expect_value(t, row, -1)
}

@(test)
test_tilemap_center_of_exact :: proc(t: ^testing.T) {
	// center_of matches the bake's marker-placement math: cell (0,0)
	// centers at (8, 40) on the 4×3 fixture, the far cell (3,2) at (56, 8),
	// and the formula extrapolates outside the grid deterministically.
	layer := fixture_layer()
	center := tilemap_center_of(&layer, 0, 0)
	testing.expect_value(t, center.x, to_fixed(8))
	testing.expect_value(t, center.y, to_fixed(40))
	center = tilemap_center_of(&layer, 3, 2)
	testing.expect_value(t, center.x, to_fixed(56))
	testing.expect_value(t, center.y, to_fixed(8))
	center = tilemap_center_of(&layer, 4, 3) // one past both extents
	testing.expect_value(t, center.x, to_fixed(72))
	testing.expect_value(t, center.y, to_fixed(-8))
}

@(test)
test_tilemap_dungeon_grid_parity :: proc(t: ^testing.T) {
	// GRID→WORLD PARITY: on the dungeon's 16×9 cell-16 geometry the runtime
	// mapping reproduces the bake's hand-verified anchors bit-exactly —
	// cell(13,4) → (216, 72) (the wave-2 bake fixture) and the hero marker's
	// cell (2,2) → (40, 104) — and cell_of inverts center_of over every cell
	// of the grid (the round trip the dungeon's step/dig behaviors fold
	// through every tick).
	layer := dungeon_layer()
	chest := tilemap_center_of(&layer, 13, 4)
	testing.expect_value(t, chest.x, to_fixed(216))
	testing.expect_value(t, chest.y, to_fixed(72))
	hero := tilemap_center_of(&layer, 2, 2)
	testing.expect_value(t, hero.x, to_fixed(40))
	testing.expect_value(t, hero.y, to_fixed(104))
	for row in 0 ..< layer.rows {
		for col in 0 ..< layer.cols {
			center := tilemap_center_of(&layer, i64(col), i64(row))
			back_col, back_row := tilemap_cell_of(&layer, center)
			testing.expect_value(t, back_col, i64(col))
			testing.expect_value(t, back_row, i64(row))
		}
	}
}

@(test)
test_tilemap_kernel_general_over_anchor :: proc(t: ^testing.T) {
	// The kernel is general over the anchor — the property the v12 carry
	// rests on: a layer anchored at (-32, 16) answers the same doc formula
	// exactly — center_of(0,0) = (-32 + 8, 16 - 8) — and the cell_of round
	// trip holds, so any bounds the bake emits map faithfully.
	layer := fixture_layer()
	layer.top_left = Vec2{x = to_fixed(-32), y = to_fixed(16)}
	center := tilemap_center_of(&layer, 0, 0)
	testing.expect_value(t, center.x, to_fixed(-24))
	testing.expect_value(t, center.y, to_fixed(8))
	col, row := tilemap_cell_of(&layer, center)
	testing.expect_value(t, col, 0)
	testing.expect_value(t, row, 0)
	col, row = tilemap_cell_of(&layer, Vec2{x = to_fixed(-33), y = to_fixed(17)})
	testing.expect_value(t, col, -1)
	testing.expect_value(t, row, -1)
}

@(test)
test_floor_div_i64_rounds_toward_negative_infinity :: proc(t: ^testing.T) {
	// The cell_of rounding rule pinned at the leaf: exact quotients pass
	// through, positive non-exact truncate down, negative non-exact round AWAY
	// from zero (floor), on both divisor signs.
	testing.expect_value(t, floor_div_i64(6, 3), 2)
	testing.expect_value(t, floor_div_i64(7, 3), 2)
	testing.expect_value(t, floor_div_i64(-6, 3), -2)
	testing.expect_value(t, floor_div_i64(-7, 3), -3)
	testing.expect_value(t, floor_div_i64(7, -3), -3)
	testing.expect_value(t, floor_div_i64(-7, -3), 2)
}

// --- the TilemapHandle method dispatch (interp) ------------------------------

// tilemap_test_interp builds an Interp over a Program carrying the fixture
// layer — the minimal world the handle-method dispatch needs (no things, no
// pipeline; the queries read only the decoded layer).
tilemap_test_interp :: proc(program: ^Program, version: ^World_Version) -> Interp {
	return new_interp(program, version, nil, empty(), tilemap_time_resource(), context.temp_allocator)
}

// tilemap_time_resource builds the minimal Time record the interp threads —
// the queries never read it, so a 60hz dt is an arbitrary observable-only
// value (the tick_test time_resource mold, prefixed per the test-helper
// naming convention).
tilemap_time_resource :: proc() -> Record_Value {
	fields := make(map[string]Value, context.temp_allocator)
	fields["dt"] = fixed_div(to_fixed(1), to_fixed(60))
	return Record_Value{type_name = "Time", fields = fields}
}

// tilemap_handle_value builds the level seam's `TilemapHandle{name}` record —
// the receiver shape the seam constant evaluates to.
tilemap_handle_value :: proc(name: string) -> Record_Value {
	fields := make(map[string]Value, context.temp_allocator)
	fields["name"] = String_Value{text = name}
	return Record_Value{type_name = "TilemapHandle", fields = fields}
}

// tilemap_cell_record builds a §26 `Cell{x, y}` record argument (two Int
// fields) — the cell shape the dungeon's behaviors pass the queries.
tilemap_cell_record :: proc(x, y: i64) -> Record_Value {
	fields := make(map[string]Value, context.temp_allocator)
	fields["x"] = x
	fields["y"] = y
	return Record_Value{type_name = "Cell", fields = fields}
}

// eval_tilemap_query hand-builds the `m.METHOD(c)` call forest (the
// eval_axis_call mold) and evaluates it with the handle bound to `m` and the
// argument bound to `c` — so the eval_method_call dispatch arm is exercised,
// never the kernel in isolation.
eval_tilemap_query :: proc(
	interp: ^Interp,
	method: string,
	handle: Record_Value,
	arg: Value,
) -> (
	result: Value,
	ok: bool,
) {
	recv := Node{kind = .Name, fields = tilemap_node_fields("m")}
	field := Node{kind = .Field, fields = tilemap_node_fields(method), children = tilemap_node_children(recv)}
	arg_node := Node{kind = .Name, fields = tilemap_node_fields("c")}
	call := Node {
		kind     = .Call,
		children = tilemap_node_children(field, arg_node),
	}
	env := Env {
		names = make(map[string]Value, context.temp_allocator),
	}
	env.names["m"] = handle
	env.names["c"] = arg
	return eval(interp, &call, &env)
}

// tilemap_node_fields / tilemap_node_children heap-allocate a hand-built
// node's slices from the temp arena (the interp_test mold — a compound slice
// literal cannot escape its constructing stack frame).
tilemap_node_fields :: proc(tokens: ..string) -> []string {
	out := make([]string, len(tokens), context.temp_allocator)
	copy(out, tokens)
	return out
}

tilemap_node_children :: proc(nodes: ..Node) -> []Node {
	out := make([]Node, len(nodes), context.temp_allocator)
	copy(out, nodes)
	return out
}

@(test)
test_tilemap_method_dispatch :: proc(t: ^testing.T) {
	// AC (the behavior-call surface): all four §18 §4 queries answer through
	// the TilemapHandle method dispatch — tile_at boxes Option::Some(String) /
	// Option::None, solid_at answers Bool, cell_of returns a Cell{x,y} record,
	// center_of a Vec2 — each value exact against the kernel fixtures above.
	layers := make([]Tile_Layer, 1, context.temp_allocator)
	layers[0] = fixture_layer()
	program := Program{}
	// Tile state is committed world state (§18 §4): the dispatch resolves the
	// layer through the interp's VERSION, never the program's bake.
	version := World_Version {
		tilemaps = layers,
	}
	interp := tilemap_test_interp(&program, &version)
	handle := tilemap_handle_value("terrain")

	// tile_at(Cell{0,0}) → Option::Some("wall")
	result, ok := eval_tilemap_query(&interp, "tile_at", handle, tilemap_cell_record(0, 0))
	testing.expect(t, ok)
	some := result.(Variant_Value)
	testing.expect_value(t, some.enum_type, "Option")
	testing.expect_value(t, some.case_name, "Some")
	payload := some.payload^.(String_Value)
	testing.expect_value(t, payload.text, "wall")

	// tile_at(Cell{1,1}) → Option::None (the tile-less cell)
	result, ok = eval_tilemap_query(&interp, "tile_at", handle, tilemap_cell_record(1, 1))
	testing.expect(t, ok)
	none := result.(Variant_Value)
	testing.expect_value(t, none.case_name, "None")

	// solid_at over the wall and the floor
	result, ok = eval_tilemap_query(&interp, "solid_at", handle, tilemap_cell_record(0, 0))
	testing.expect(t, ok)
	testing.expect_value(t, result.(bool), true)
	result, ok = eval_tilemap_query(&interp, "solid_at", handle, tilemap_cell_record(2, 1))
	testing.expect(t, ok)
	testing.expect_value(t, result.(bool), false)

	// cell_of(Vec2{8,40}) → Cell{0,0}
	result, ok = eval_tilemap_query(&interp, "cell_of", handle, Vec2{x = to_fixed(8), y = to_fixed(40)})
	testing.expect(t, ok)
	cell := result.(Record_Value)
	testing.expect_value(t, cell.type_name, "Cell")
	testing.expect_value(t, cell.fields["x"].(i64), 0)
	testing.expect_value(t, cell.fields["y"].(i64), 0)

	// center_of(Cell{3,2}) → Vec2{56,8}
	result, ok = eval_tilemap_query(&interp, "center_of", handle, tilemap_cell_record(3, 2))
	testing.expect(t, ok)
	center := result.(Vec2)
	testing.expect_value(t, center.x, to_fixed(56))
	testing.expect_value(t, center.y, to_fixed(8))
}

@(test)
test_tilemap_method_dispatch_fails_closed :: proc(t: ^testing.T) {
	// The dispatch refuses, never guesses: an unknown layer name, a non-Cell
	// argument to a cell query, a non-Vec2 argument to cell_of, and a
	// non-query member on the handle all answer ok=false.
	layers := make([]Tile_Layer, 1, context.temp_allocator)
	layers[0] = fixture_layer()
	program := Program{}
	version := World_Version {
		tilemaps = layers,
	}
	interp := tilemap_test_interp(&program, &version)

	_, ok := eval_tilemap_query(&interp, "tile_at", tilemap_handle_value("nowhere"), tilemap_cell_record(0, 0))
	testing.expect(t, !ok)
	_, ok = eval_tilemap_query(&interp, "tile_at", tilemap_handle_value("terrain"), i64(3))
	testing.expect(t, !ok)
	_, ok = eval_tilemap_query(&interp, "cell_of", tilemap_handle_value("terrain"), tilemap_cell_record(0, 0))
	testing.expect(t, !ok)
	_, ok = eval_tilemap_query(&interp, "warp_to", tilemap_handle_value("terrain"), tilemap_cell_record(0, 0))
	testing.expect(t, !ok)
}

// --- the batched render emission ---------------------------------------------

@(test)
test_render_emits_one_batched_tilemap_command :: proc(t: ^testing.T) {
	// AC (batched render): a 12-tile layer joins the draw-list as EXACTLY ONE
	// layer-level Draw_Tilemap carrying the whole layer — never per-tile
	// commands (§18 §3) — leading the list in declaration order. The layers
	// come from the rendered VERSION's committed tile state (§18 §4 — render
	// updates from the same data a SetTile rewrites), never the program bake.
	layers := make([]Tile_Layer, 1, context.temp_allocator)
	layers[0] = fixture_layer()
	program := Program{}
	version := World_Version {
		tilemaps = layers,
	}
	draw := render_version(&program, version, empty(), tilemap_time_resource(), context.temp_allocator)
	testing.expect_value(t, len(draw.cmds), 1)
	cmd, is_tilemap := draw.cmds[0].(Draw_Tilemap)
	testing.expect(t, is_tilemap)
	testing.expect(t, tile_layers_equal(cmd.layer, fixture_layer()))
	testing.expect(t, draw_cmd_equal(draw.cmds[0], Draw_Tilemap{layer = fixture_layer()}))
}

@(test)
test_render_layer_free_program_emits_no_tilemap_command :: proc(t: ^testing.T) {
	// A layer-less program's draw-list is unchanged by the emission seam — the
	// goldens' regression floor (every committed artifact carries [tilemaps 0]).
	program := Program{}
	draw := render_version(&program, World_Version{}, empty(), tilemap_time_resource(), context.temp_allocator)
	testing.expect_value(t, len(draw.cmds), 0)
}

// --- the digest fold ----------------------------------------------------------

@(test)
test_tilemap_digest_deterministic_and_content_sensitive :: proc(t: ^testing.T) {
	// AC (digest): the canonical byte stream over a tile-layer-carrying
	// draw-list is bit-stable across two folds of the same layer, and a single
	// flipped cell changes the bytes (the surface the SetTile story will
	// move). The tag ordinal is pinned: append-only at 7.
	testing.expect_value(t, u8(Cmd_Tag.Tilemap), 7)

	cmds := make([]Draw_Cmd, 1, context.temp_allocator)
	cmds[0] = Draw_Tilemap{layer = fixture_layer()}
	draw := Draw_List{cmds = cmds}
	first := frame_bytes(World_Version{}, draw, context.temp_allocator)
	second := frame_bytes(World_Version{}, draw, context.temp_allocator)
	testing.expect(t, len(first) > 0)
	testing.expect_value(t, len(first), len(second))
	for b, i in first {
		testing.expect_value(t, second[i], b)
	}

	flipped_layer := fixture_layer()
	flipped_cells := make([]int, len(flipped_layer.cells), context.temp_allocator)
	copy(flipped_cells, flipped_layer.cells)
	flipped_cells[5] = 1 // the tile-less cell becomes a floor tile
	flipped_layer.cells = flipped_cells
	flipped_cmds := make([]Draw_Cmd, 1, context.temp_allocator)
	flipped_cmds[0] = Draw_Tilemap{layer = flipped_layer}
	flipped := frame_bytes(World_Version{}, Draw_List{cmds = flipped_cmds}, context.temp_allocator)
	identical := len(flipped) == len(first)
	if identical {
		for b, i in first {
			if flipped[i] != b {
				identical = false
				break
			}
		}
	}
	testing.expect(t, !identical)
}
