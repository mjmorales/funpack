package funpack_runtime

import "core:testing"

buildlayer_override :: proc(x, y: i64, tile: string) -> Tuple_Value {
	elems := make([]Value, 2, context.temp_allocator)
	elems[0] = tilemap_cell_record(x, y)
	elems[1] = String_Value{text = tile}
	return Tuple_Value{elements = elems}
}

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

queue_buildlayer_record :: proc(state: ^Tick_State, layer: string, fill: string, overrides: ..Tuple_Value) {
	append(&state.terrain_commands, Terrain_Command{kind = .Build_Layer, record = buildlayer_record(layer, fill, ..overrides)})
}

@(test)
test_buildlayer_fold_fills_and_overrides :: proc(t: ^testing.T) {
	prior := settile_prior_version()
	state := new_tick_state(prior, context.temp_allocator, context.temp_allocator)
	queue_buildlayer_record(&state, "terrain", "floor", buildlayer_override(0, 0, "wall"), buildlayer_override(2, 1, "wall"))

	next := fold_tile_layers(prior, &state)
	testing.expect_value(t, len(next), 1)
	testing.expect_value(t, len(state.tile_refusals), 0)
	for cell, i in next[0].cells {
		col := i % 4
		row := i / 4
		expected := 1
		if (col == 0 && row == 0) || (col == 2 && row == 1) {
			expected = 0
		}
		testing.expect_value(t, cell, expected)
	}
	testing.expect_value(t, prior.tilemaps[0].cells[1 * 4 + 1], TILE_CELL_EMPTY)
	testing.expect(t, raw_data(next[0].cells) != raw_data(prior.tilemaps[0].cells))
}

@(test)
test_buildlayer_overrides_last_write_wins :: proc(t: ^testing.T) {
	prior := settile_prior_version()
	state := new_tick_state(prior, context.temp_allocator, context.temp_allocator)
	queue_buildlayer_record(&state, "terrain", "wall", buildlayer_override(1, 1, "wall"), buildlayer_override(1, 1, "floor"))

	next := fold_tile_layers(prior, &state)
	testing.expect_value(t, len(state.tile_refusals), 0)
	testing.expect_value(t, next[0].cells[1 * 4 + 1], 1)
}

@(test)
test_buildlayer_empty_cells_is_uniform_fill :: proc(t: ^testing.T) {
	prior := settile_prior_version()
	state := new_tick_state(prior, context.temp_allocator, context.temp_allocator)
	queue_buildlayer_record(&state, "terrain", "wall")

	next := fold_tile_layers(prior, &state)
	testing.expect_value(t, len(state.tile_refusals), 0)
	for cell in next[0].cells {
		testing.expect_value(t, cell, 0)
	}
}

@(test)
test_buildlayer_refusals_are_named_and_all_or_nothing :: proc(t: ^testing.T) {
	prior := settile_prior_version()
	state := new_tick_state(prior, context.temp_allocator, context.temp_allocator)

	queue_buildlayer_record(&state, "cavern", "floor")
	queue_buildlayer_record(&state, "terrain", "lava")
	queue_buildlayer_record(&state, "terrain", "floor", buildlayer_override(0, 0, "lava"))
	queue_buildlayer_record(&state, "terrain", "floor", buildlayer_override(4, 0, "wall"))
	queue_buildlayer_record(&state, "terrain", "floor", buildlayer_override(0, -1, "wall"))
	malformed := buildlayer_record("terrain", "floor")
	delete_key(&malformed.fields, "fill")
	append(&state.terrain_commands, Terrain_Command{kind = .Build_Layer, record = malformed})
	queue_buildlayer_record(&state, "terrain", "wall")

	next := fold_tile_layers(prior, &state)
	testing.expect_value(t, len(state.tile_refusals), 6)
	testing.expect_value(t, state.tile_refusals[0].command, Terrain_Command_Kind.Build_Layer)
	testing.expect_value(t, state.tile_refusals[0].kind, Tile_Command_Refusal_Kind.Unknown_Layer)
	testing.expect_value(t, state.tile_refusals[0].layer, "cavern")
	testing.expect_value(t, state.tile_refusals[1].kind, Tile_Command_Refusal_Kind.Unknown_Tile)
	testing.expect_value(t, state.tile_refusals[1].tile, "lava")
	testing.expect_value(t, state.tile_refusals[2].kind, Tile_Command_Refusal_Kind.Unknown_Tile)
	testing.expect_value(t, state.tile_refusals[2].tile, "lava")
	testing.expect_value(t, state.tile_refusals[3].kind, Tile_Command_Refusal_Kind.Cell_Out_Of_Grid)
	testing.expect_value(t, state.tile_refusals[3].col, 4)
	testing.expect_value(t, state.tile_refusals[4].kind, Tile_Command_Refusal_Kind.Cell_Out_Of_Grid)
	testing.expect_value(t, state.tile_refusals[4].row, -1)
	testing.expect_value(t, state.tile_refusals[5].kind, Tile_Command_Refusal_Kind.Malformed_Command)
	testing.expect_value(t, state.tile_refusals[5].layer, "terrain")

	for cell in next[0].cells {
		testing.expect_value(t, cell, 0)
	}
}

@(test)
test_buildlayer_refused_override_leaves_layer_untouched :: proc(t: ^testing.T) {
	prior := settile_prior_version()
	state := new_tick_state(prior, context.temp_allocator, context.temp_allocator)
	queue_buildlayer_record(&state, "terrain", "floor", buildlayer_override(0, 0, "wall"), buildlayer_override(9, 9, "wall"))

	next := fold_tile_layers(prior, &state)
	testing.expect_value(t, len(state.tile_refusals), 1)
	testing.expect_value(t, state.tile_refusals[0].kind, Tile_Command_Refusal_Kind.Cell_Out_Of_Grid)
	for cell, i in next[0].cells {
		testing.expect_value(t, cell, prior.tilemaps[0].cells[i])
	}
}

@(test)
test_terrain_commands_fold_in_collection_order :: proc(t: ^testing.T) {
	{
		prior := settile_prior_version()
		state := new_tick_state(prior, context.temp_allocator, context.temp_allocator)
		queue_settile_record(&state, "terrain", 1, 1, "wall")
		queue_buildlayer_record(&state, "terrain", "floor")
		next := fold_tile_layers(prior, &state)
		testing.expect_value(t, len(state.tile_refusals), 0)
		for cell in next[0].cells {
			testing.expect_value(t, cell, 1)
		}
	}

	{
		prior := settile_prior_version()
		state := new_tick_state(prior, context.temp_allocator, context.temp_allocator)
		queue_buildlayer_record(&state, "terrain", "floor")
		queue_settile_record(&state, "terrain", 2, 2, "wall")
		next := fold_tile_layers(prior, &state)
		testing.expect_value(t, len(state.tile_refusals), 0)
		for cell, i in next[0].cells {
			expected := 1
			if i == 2 * 4 + 2 {
				expected = 0
			}
			testing.expect_value(t, cell, expected)
		}
	}

	{
		prior := settile_prior_version()
		state := new_tick_state(prior, context.temp_allocator, context.temp_allocator)
		queue_settile_record(&state, "terrain", 0, 0, "wall")
		queue_buildlayer_record(&state, "terrain", "floor")
		queue_settile_record(&state, "terrain", 0, 0, "wall")
		next := fold_tile_layers(prior, &state)
		testing.expect_value(t, len(state.tile_refusals), 0)
		testing.expect_value(t, next[0].cells[0], 0)
		testing.expect_value(t, next[0].cells[1], 1)
	}
}

buildlayer_fold_version :: proc(prior: World_Version, record: Record_Value) -> World_Version {
	state := new_tick_state(prior, context.temp_allocator, context.temp_allocator)
	append(&state.terrain_commands, Terrain_Command{kind = .Build_Layer, record = record})
	return World_Version{tilemaps = fold_tile_layers(prior, &state)}
}

@(test)
test_buildlayer_nav_rederives_corridor :: proc(t: ^testing.T) {
	left_mid := Vec2{x = to_fixed(8), y = to_fixed(24)}
	right_mid := Vec2{x = to_fixed(40), y = to_fixed(24)}
	center := Vec2{x = to_fixed(24), y = to_fixed(24)}

	{
		prior := los_version(nav_layer_with_cells([]int{1, 1, 1, 1, 0, 1, 1, 1, 1}))
		built := buildlayer_fold_version(prior, buildlayer_record("ground", "floor", buildlayer_override(1, 1, "wall")))
		res, ok := eval_engine_nav(&built, "path", left_mid, right_mid)
		testing.expect(t, ok)
		steps, cost, decoded := nav_path_steps(res)
		testing.expect(t, decoded)
		testing.expect_value(t, len(steps), 5)
		testing.expect_value(t, cost, to_fixed(64))
	}

	{
		prior := los_version(nav_layer_with_cells([]int{1, 1, 1, 1, 0, 1, 1, 1, 1}))
		built := buildlayer_fold_version(prior, buildlayer_record("ground", "floor"))
		res, ok := eval_engine_nav(&built, "path", left_mid, right_mid)
		testing.expect(t, ok)
		steps, cost, decoded := nav_path_steps(res)
		testing.expect(t, decoded)
		testing.expect_value(t, len(steps), 3)
		testing.expect_value(t, steps[1], center)
		testing.expect_value(t, cost, to_fixed(32))
	}
}

@(test)
test_buildlayer_carries_across_hot_reload :: proc(t: ^testing.T) {
	prior := settile_prior_version()
	built := buildlayer_fold_version(prior, buildlayer_record("terrain", "floor", buildlayer_override(0, 0, "wall"), buildlayer_override(3, 2, "wall")))

	a := context.temp_allocator
	new_bake := make([]Tile_Layer, 1, a)
	new_bake[0] = fixture_layer()

	delta := tile_carry_delta(prior.tilemaps, built.tilemaps, a)
	carried := tile_carry_apply(delta, new_bake, a)
	ver := World_Version{tilemaps = carried}
	layer := version_tilemap(&ver, "terrain")
	testing.expect(t, layer != nil)
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
			testing.expect_value(t, name, "wall")
		} else {
			testing.expect_value(t, name, "floor")
		}
	}
}

@(test)
test_buildlayer_seeded_digest_is_bit_identical :: proc(t: ^testing.T) {
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
	testing.expect(t, identical)

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
	testing.expect(t, differs)
}

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

seeded_buildlayer_record :: proc(seed: i64) -> Record_Value {
	tiles := []string{"wall", "floor"}
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
