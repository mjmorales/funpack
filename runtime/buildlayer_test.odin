// The §18 §4 BuildLayer APPLICATION fixtures — SetTile's WHOLE-LAYER twin: the
// tick-end fold's whole-layer arm (buildlayer_apply — fill every cell, then the
// (Cell, tile) overrides in list order, last write wins, COW at the layer level),
// the five NAMED refusal arms (malformed / unknown layer / unknown fill /
// unknown override tile / override out-of-grid — all-or-nothing, the layer left
// untouched on any refusal), the SetTile/BuildLayer SAME-TICK ordering over the
// one collection-order terrain-command stream, and the proof that a BuildLayer-
// produced layer rides the EXISTING producer-agnostic downstream paths with no
// code change: nav re-derives a routed corridor, the hot-reload carry kernel
// carries it, the §24 save snapshot rides it, and a seeded fold pins a
// bit-identical frame digest (same seed → same built layer → same digest).
package funpack_runtime

import "core:testing"

// --- BuildLayer command builders --------------------------------------------

// buildlayer_override builds one `(Cell, String)` override tuple element — the
// `node tuple 2` shape funpack lowers a cells-list entry to (position 0 a Cell
// record, position 1 the tile-name String).
buildlayer_override :: proc(x, y: i64, tile: string) -> Tuple_Value {
	elems := make([]Value, 2, context.temp_allocator)
	elems[0] = tilemap_cell_record(x, y)
	elems[1] = String_Value{text = tile}
	return Tuple_Value{elements = elems}
}

// buildlayer_record hand-builds one collected BuildLayer command Record_Value —
// the shape the fold's [BuildLayer] emit queues (tick.odin
// queue_buildlayer_commands): `map` handle, `fill` String, `cells` a List_Value
// of (Cell, String) override tuples.
buildlayer_record :: proc(layer: string, fill: string, overrides: ..Tuple_Value) -> Record_Value {
	cell_elems := make([]Value, len(overrides), context.temp_allocator)
	for ov, i in overrides {
		cell_elems[i] = ov
	}
	fields := make(map[string]Value, context.temp_allocator)
	fields["map"] = tilemap_handle_value(layer)
	fields["fill"] = String_Value{text = fill}
	fields["cells"] = List_Value{elements = cell_elems}
	return Record_Value{type_name = "BuildLayer", fields = fields}
}

// queue_buildlayer_record appends a hand-built BuildLayer onto the tick's ordered
// terrain-command stream tagged .Build_Layer — the kind-tagged shape
// queue_buildlayer_commands produces.
queue_buildlayer_record :: proc(state: ^Tick_State, layer: string, fill: string, overrides: ..Tuple_Value) {
	append(&state.terrain_commands, Terrain_Command{kind = .Build_Layer, record = buildlayer_record(layer, fill, ..overrides)})
}

// --- the whole-layer fold kernel --------------------------------------------

@(test)
test_buildlayer_fold_fills_and_overrides :: proc(t: ^testing.T) {
	// AC (whole-layer replacement + overrides): a BuildLayer over the 4×3 fixture
	// REPLACES every cell with `fill` ("floor", index 1), then applies the
	// overrides in list order — (0,0)→"wall"(0) and (2,1)→"wall"(0). Every other
	// cell is the fill, the PRIOR version is untouched (COW), and the copy is a
	// FRESH backing.
	prior := settile_prior_version()
	state := new_tick_state(prior, context.temp_allocator, context.temp_allocator)
	queue_buildlayer_record(&state, "terrain", "floor", buildlayer_override(0, 0, "wall"), buildlayer_override(2, 1, "wall"))

	next := fold_tile_layers(prior, &state)
	testing.expect_value(t, len(next), 1)
	testing.expect_value(t, len(state.tile_refusals), 0)
	// The fill replaced the bake's tile-less + wall cells uniformly.
	for cell, i in next[0].cells {
		col := i % 4
		row := i / 4
		expected := 1 // "floor" fill
		if (col == 0 && row == 0) || (col == 2 && row == 1) {
			expected = 0 // "wall" override
		}
		testing.expect_value(t, cell, expected)
	}
	// The prior version's cells are the pristine bake — COW left them alone.
	testing.expect_value(t, prior.tilemaps[0].cells[1 * 4 + 1], TILE_CELL_EMPTY)
	testing.expect(t, raw_data(next[0].cells) != raw_data(prior.tilemaps[0].cells))
}

@(test)
test_buildlayer_overrides_last_write_wins :: proc(t: ^testing.T) {
	// AC (override order): two overrides to the SAME cell apply in list order —
	// the last wins ("wall" then "floor" leaves floor), a pure function of the
	// override sequence (the SetTile last-write-wins discipline within one
	// command).
	prior := settile_prior_version()
	state := new_tick_state(prior, context.temp_allocator, context.temp_allocator)
	queue_buildlayer_record(&state, "terrain", "wall", buildlayer_override(1, 1, "wall"), buildlayer_override(1, 1, "floor"))

	next := fold_tile_layers(prior, &state)
	testing.expect_value(t, len(state.tile_refusals), 0)
	testing.expect_value(t, next[0].cells[1 * 4 + 1], 1) // "floor" — the last override
}

@(test)
test_buildlayer_empty_cells_is_uniform_fill :: proc(t: ^testing.T) {
	// AC (empty overrides): a BuildLayer with no overrides fills every cell with
	// `fill` uniformly — the bare procedural-floor base.
	prior := settile_prior_version()
	state := new_tick_state(prior, context.temp_allocator, context.temp_allocator)
	queue_buildlayer_record(&state, "terrain", "wall")

	next := fold_tile_layers(prior, &state)
	testing.expect_value(t, len(state.tile_refusals), 0)
	for cell in next[0].cells {
		testing.expect_value(t, cell, 0) // every cell is "wall"
	}
}

@(test)
test_buildlayer_refusals_are_named_and_all_or_nothing :: proc(t: ^testing.T) {
	// AC (named refusals, all-or-nothing): each BuildLayer failure mode — unknown
	// layer, unknown fill, an override naming an unknown tile, an override cell
	// out of grid, and a malformed record — fails THAT command closed with the
	// named arm tagged .Build_Layer, recorded in application order, never halting
	// the tick. Crucially the refused command leaves the layer UNTOUCHED (the
	// whole-layer write is all-or-nothing — no partial fill), while a valid
	// BuildLayer in the same batch still applies.
	prior := settile_prior_version()
	state := new_tick_state(prior, context.temp_allocator, context.temp_allocator)

	queue_buildlayer_record(&state, "cavern", "floor") // unknown layer
	queue_buildlayer_record(&state, "terrain", "lava") // unknown fill tile
	queue_buildlayer_record(&state, "terrain", "floor", buildlayer_override(0, 0, "lava")) // override unknown tile
	queue_buildlayer_record(&state, "terrain", "floor", buildlayer_override(4, 0, "wall")) // override out of grid (col)
	queue_buildlayer_record(&state, "terrain", "floor", buildlayer_override(0, -1, "wall")) // override out of grid (row)
	malformed := buildlayer_record("terrain", "floor")
	delete_key(&malformed.fields, "fill")
	append(&state.terrain_commands, Terrain_Command{kind = .Build_Layer, record = malformed})
	queue_buildlayer_record(&state, "terrain", "wall") // valid — fills all "wall"

	next := fold_tile_layers(prior, &state)
	testing.expect_value(t, len(state.tile_refusals), 6)
	testing.expect_value(t, state.tile_refusals[0].command, Terrain_Command_Kind.Build_Layer)
	testing.expect_value(t, state.tile_refusals[0].kind, Tile_Command_Refusal_Kind.Unknown_Layer)
	testing.expect_value(t, state.tile_refusals[0].layer, "cavern")
	testing.expect_value(t, state.tile_refusals[1].kind, Tile_Command_Refusal_Kind.Unknown_Tile)
	testing.expect_value(t, state.tile_refusals[1].tile, "lava") // the fill name
	testing.expect_value(t, state.tile_refusals[2].kind, Tile_Command_Refusal_Kind.Unknown_Tile)
	testing.expect_value(t, state.tile_refusals[2].tile, "lava") // the override name
	testing.expect_value(t, state.tile_refusals[3].kind, Tile_Command_Refusal_Kind.Cell_Out_Of_Grid)
	testing.expect_value(t, state.tile_refusals[3].col, 4)
	testing.expect_value(t, state.tile_refusals[4].kind, Tile_Command_Refusal_Kind.Cell_Out_Of_Grid)
	testing.expect_value(t, state.tile_refusals[4].row, -1)
	testing.expect_value(t, state.tile_refusals[5].kind, Tile_Command_Refusal_Kind.Malformed_Command)
	testing.expect_value(t, state.tile_refusals[5].layer, "terrain")

	// All-or-nothing: every refused command left the layer untouched; only the
	// valid trailing BuildLayer landed (every cell "wall").
	for cell in next[0].cells {
		testing.expect_value(t, cell, 0)
	}
}

@(test)
test_buildlayer_refused_override_leaves_layer_untouched :: proc(t: ^testing.T) {
	// AC (all-or-nothing on a mid-list bad override): a BuildLayer whose SECOND
	// override is out of grid is refused WHOLE — the fill is NOT applied and the
	// first (valid) override is NOT applied. The prior bake's cells survive
	// verbatim (the partial-generation defect the all-or-nothing contract bars).
	prior := settile_prior_version()
	state := new_tick_state(prior, context.temp_allocator, context.temp_allocator)
	queue_buildlayer_record(&state, "terrain", "floor", buildlayer_override(0, 0, "wall"), buildlayer_override(9, 9, "wall"))

	next := fold_tile_layers(prior, &state)
	testing.expect_value(t, len(state.tile_refusals), 1)
	testing.expect_value(t, state.tile_refusals[0].kind, Tile_Command_Refusal_Kind.Cell_Out_Of_Grid)
	// The layer is the prior bake's cells, byte-for-byte — nothing was written.
	for cell, i in next[0].cells {
		testing.expect_value(t, cell, prior.tilemaps[0].cells[i])
	}
}

// --- SetTile / BuildLayer same-tick ordering --------------------------------

@(test)
test_terrain_commands_fold_in_collection_order :: proc(t: ^testing.T) {
	// THE ordering AC: SetTile and BuildLayer share ONE ordered terrain-command
	// stream, folded in collection order — the load-bearing same-tick interplay.
	//
	// (a) SetTile-then-BuildLayer: the BuildLayer reached LATER resets the whole
	//     layer, erasing the earlier SetTile edit (the build is a replacement,
	//     not a delta over prior edits).
	{
		prior := settile_prior_version()
		state := new_tick_state(prior, context.temp_allocator, context.temp_allocator)
		queue_settile_record(&state, "terrain", 1, 1, "wall") // edit cell (1,1)→wall(0)
		queue_buildlayer_record(&state, "terrain", "floor") // then build: every cell floor(1)
		next := fold_tile_layers(prior, &state)
		testing.expect_value(t, len(state.tile_refusals), 0)
		for cell in next[0].cells {
			testing.expect_value(t, cell, 1) // the build erased the SetTile — all floor
		}
	}

	// (b) BuildLayer-then-SetTile: the SetTile reached LATER edits the freshly
	//     built layer — the build sets the base, the edit lands on top.
	{
		prior := settile_prior_version()
		state := new_tick_state(prior, context.temp_allocator, context.temp_allocator)
		queue_buildlayer_record(&state, "terrain", "floor") // build: every cell floor(1)
		queue_settile_record(&state, "terrain", 2, 2, "wall") // then edit (2,2)→wall(0)
		next := fold_tile_layers(prior, &state)
		testing.expect_value(t, len(state.tile_refusals), 0)
		for cell, i in next[0].cells {
			expected := 1 // floor fill
			if i == 2 * 4 + 2 {
				expected = 0 // the trailing SetTile edit
			}
			testing.expect_value(t, cell, expected)
		}
	}

	// (c) BuildLayer between two SetTiles: the earlier SetTile is erased by the
	//     build, the later SetTile survives on top — one stream, strict order.
	{
		prior := settile_prior_version()
		state := new_tick_state(prior, context.temp_allocator, context.temp_allocator)
		queue_settile_record(&state, "terrain", 0, 0, "wall") // erased by the build
		queue_buildlayer_record(&state, "terrain", "floor") // reset
		queue_settile_record(&state, "terrain", 0, 0, "wall") // survives on the built layer
		next := fold_tile_layers(prior, &state)
		testing.expect_value(t, len(state.tile_refusals), 0)
		testing.expect_value(t, next[0].cells[0], 0) // (0,0) is wall — the LATER SetTile
		testing.expect_value(t, next[0].cells[1], 1) // everything else floor — the build
	}
}

// --- downstream paths re-derive over a built layer (producer-agnostic) ------

// buildlayer_fold_version folds ONE BuildLayer over a prior version and returns
// the committed result — the real fold output the downstream-agnostic tests run
// over (nav / carry / save read `version.tilemaps`, never the command kind).
buildlayer_fold_version :: proc(prior: World_Version, record: Record_Value) -> World_Version {
	state := new_tick_state(prior, context.temp_allocator, context.temp_allocator)
	append(&state.terrain_commands, Terrain_Command{kind = .Build_Layer, record = record})
	return World_Version{tilemaps = fold_tile_layers(prior, &state)}
}

@(test)
test_buildlayer_nav_rederives_corridor :: proc(t: ^testing.T) {
	// AC (nav re-derives over a BUILT layer, no nav code change): a BuildLayer
	// paints the 3×3 "ground" layer all-floor with a solid center override
	// (exactly los_grid_layer's topology); path() over the BUILT committed layer
	// routes the SAME detour the bake's static graph gives, proving nav reads the
	// materialized cells producer-agnostically. Then a second BuildLayer fills the
	// center too — path routes STRAIGHT through, the built corridor.
	left_mid := Vec2{x = to_fixed(8), y = to_fixed(24)} // cell (0,1) center
	right_mid := Vec2{x = to_fixed(40), y = to_fixed(24)} // cell (2,1) center
	center := Vec2{x = to_fixed(24), y = to_fixed(24)} // cell (1,1) center

	// (a) build all-floor with a solid center — the wall is one override over the
	//     floor fill. path must DETOUR (cost 64, 5 steps) around the solid center.
	{
		prior := los_version(nav_layer_with_cells([]int{1, 1, 1, 1, 0, 1, 1, 1, 1}))
		built := buildlayer_fold_version(prior, buildlayer_record("ground", "floor", buildlayer_override(1, 1, "wall")))
		res, ok := eval_engine_nav(&built, "path", left_mid, right_mid)
		testing.expect(t, ok)
		steps, cost, decoded := nav_path_steps(res)
		testing.expect(t, decoded)
		testing.expect_value(t, len(steps), 5) // the detour around the built wall
		testing.expect_value(t, cost, to_fixed(64))
	}

	// (b) build all-floor with NO override (a clear corridor): path routes STRAIGHT
	//     through the center (cost 32, 3 steps) — the corridor a generation builds.
	{
		prior := los_version(nav_layer_with_cells([]int{1, 1, 1, 1, 0, 1, 1, 1, 1}))
		built := buildlayer_fold_version(prior, buildlayer_record("ground", "floor"))
		res, ok := eval_engine_nav(&built, "path", left_mid, right_mid)
		testing.expect(t, ok)
		steps, cost, decoded := nav_path_steps(res)
		testing.expect(t, decoded)
		testing.expect_value(t, len(steps), 3) // straight through the built corridor
		testing.expect_value(t, steps[1], center) // the freshly-built center cell is a waypoint
		testing.expect_value(t, cost, to_fixed(32))
	}
}

@(test)
test_buildlayer_carries_across_hot_reload :: proc(t: ^testing.T) {
	// AC (hot-reload carry, producer-agnostic): a BuildLayer-produced committed
	// layer rides the SAME tile_carry kernel a SetTile delta does — the carry
	// diffs live cells vs the bake and re-applies name-keyed onto the new bake,
	// never asking which command wrote them. Build the 4×3 layer all-floor with
	// two wall overrides; diff vs the pristine bake; carry onto an identical
	// reload bake; assert the built topology survives.
	prior := settile_prior_version() // bake: wall row + tile-less center + floor (fixture_layer)
	built := buildlayer_fold_version(prior, buildlayer_record("terrain", "floor", buildlayer_override(0, 0, "wall"), buildlayer_override(3, 2, "wall")))

	a := context.temp_allocator
	new_bake := make([]Tile_Layer, 1, a)
	new_bake[0] = fixture_layer() // identical recompile of the same level

	delta := tile_carry_delta(prior.tilemaps, built.tilemaps, a)
	carried := tile_carry_apply(delta, new_bake, a)
	ver := World_Version{tilemaps = carried}
	layer := version_tilemap(&ver, "terrain")
	testing.expect(t, layer != nil)
	// The two overrides are walls; every other cell is the built floor — the whole
	// built topology carried across the swap.
	for i in 0 ..< len(layer.cells) {
		col := i % 4
		row := i / 4
		name, has := tilemap_tile_at(layer, col, row)
		testing.expect(t, has)
		if (col == 0 && row == 0) || (col == 3 && row == 2) {
			testing.expect_value(t, name, "wall")
		} else {
			testing.expect_value(t, name, "floor")
		}
	}
}

@(test)
test_buildlayer_rides_save_restore :: proc(t: ^testing.T) {
	// AC (save/restore, producer-agnostic): a BuildLayer-produced committed layer
	// rides the §24 v6 snapshot codec exactly as a SetTile delta does —
	// serialize_snapshot diffs live vs the saving bake (the same Tile_Carry_Delta
	// kernel), deserialize reconstructs it, tile_carry_apply re-bases onto the
	// restoring bake. The built topology survives the bytes.
	context.allocator = context.temp_allocator
	a := context.temp_allocator

	prior := settile_prior_version()
	built := buildlayer_fold_version(prior, buildlayer_record("terrain", "floor", buildlayer_override(1, 1, "wall")))

	program := Program{tilemaps = prior.tilemaps}
	committed := World_Version{tick = 9, tilemaps = built.tilemaps}

	bytes := serialize_snapshot(&program, committed)
	_, _, delta, ok := deserialize_snapshot(bytes)
	if !testing.expect(t, ok) {
		return
	}
	// The codec carried the built layer's diff from the bake — every cell the
	// build changed (the bake's tile-less cells became floor, the bake's walls
	// became floor except the (1,1) override which is wall).
	restoring_bake := make([]Tile_Layer, 1, a)
	restoring_bake[0] = fixture_layer()
	carried := tile_carry_apply(delta, restoring_bake, a)
	ver := World_Version{tilemaps = carried}
	layer := version_tilemap(&ver, "terrain")
	testing.expect(t, layer != nil)
	for i in 0 ..< len(layer.cells) {
		col := i % 4
		row := i / 4
		name, has := tilemap_tile_at(layer, col, row)
		testing.expect(t, has)
		if col == 1 && row == 1 {
			testing.expect_value(t, name, "wall") // the override
		} else {
			testing.expect_value(t, name, "floor") // the fill
		}
	}
}

// --- seeded determinism pin -------------------------------------------------

@(test)
test_buildlayer_seeded_digest_is_bit_identical :: proc(t: ^testing.T) {
	// AC (seeded determinism, §28 warranty): a seeded generation FOLDS a procedural
	// layer from an Rng draw — the SAME seed run TWICE through the real fold +
	// render + digest produces a bit-identical built layer and therefore a
	// bit-identical frame digest (same Rng seed → same drawn overrides → same
	// committed cells → same digest). The seed drives the override tile NAMES via
	// the proven rand_pick draw (snake's replenish path), so the built layer is a
	// pure function of the seed — the determinism bet over runtime generation.
	digest_a := buildlayer_seeded_digest(t, 7)
	digest_b := buildlayer_seeded_digest(t, 7)
	testing.expect_value(t, len(digest_a), len(digest_b))
	identical := len(digest_a) == len(digest_b)
	if identical {
		for b, i in digest_a {
			if digest_b[i] != b {
				identical = false
				break
			}
		}
	}
	testing.expect(t, identical) // same seed → bit-identical built-layer digest

	// And the digest is SENSITIVE to the built layer: a DIFFERENT seed draws
	// different override tiles and diverges the digest (the build is not a
	// constant — the seed is genuinely load-bearing in the committed cells).
	digest_c := buildlayer_seeded_digest(t, 40)
	differs := len(digest_a) != len(digest_c)
	if !differs {
		for b, i in digest_a {
			if digest_c[i] != b {
				differs = true
				break
			}
		}
	}
	testing.expect(t, differs) // a different seed → a different built layer → a different digest
}

// buildlayer_seeded_digest folds ONE seeded BuildLayer over the 4×3 fixture and
// returns the frame-digest bytes of the rendered built layer — the seeded-
// generation determinism surface. The override tile NAMES are drawn from the
// palette via rand_pick threaded forward (the §26 / §04 §1 seeded-draw kernel a
// generation behavior uses), so the built layer is a pure function of `seed`. The
// fold (fold_tile_layers), the render (render_version → Draw_Tilemap), and the
// digest (frame_bytes) are the real production path — only the BuildLayer record
// is test-seeded, standing in for the artifact's seeded `gen` behavior.
buildlayer_seeded_digest :: proc(t: ^testing.T, seed: i64) -> []u8 {
	prior := settile_prior_version()
	record := seeded_buildlayer_record(seed)
	built := buildlayer_fold_version(prior, record)
	testing.expect_value(t, len(built.tilemaps), 1)

	program := Program{tilemaps = prior.tilemaps}
	time := tilemap_time_resource()
	draw := render_version(&program, built, empty(), time, context.temp_allocator)
	return frame_bytes(World_Version{}, draw, context.temp_allocator)
}

// seeded_buildlayer_record draws a procedural BuildLayer from `seed`: every cell
// of the 4×3 "terrain" layer takes a tile NAME drawn from the palette by
// rand_pick, threaded forward so each cell's draw advances the Rng (the §04 §1
// no-silent-advance discipline). A pure function of the seed — two calls with the
// same seed build the identical record, two different seeds build different cell
// overrides — so the digest pin reads the seed through the real generation draw.
seeded_buildlayer_record :: proc(seed: i64) -> Record_Value {
	tiles := []string{"wall", "floor"} // the fixture_layer palette names
	rng := rand_seed(seed)
	overrides := make([dynamic]Tuple_Value, context.temp_allocator)
	for row in 0 ..< 3 {
		for col in 0 ..< 4 {
			tile, ok, next := rand_pick(tiles, rng)
			rng = next
			if !ok {
				continue
			}
			append(&overrides, buildlayer_override(i64(col), i64(row), tile))
		}
	}
	return buildlayer_record("terrain", "floor", ..overrides[:])
}
