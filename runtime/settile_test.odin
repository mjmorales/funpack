package funpack_runtime

import "core:mem"
import "core:testing"

settile_record :: proc(layer: string, x, y: i64, tile: string) -> Record_Value {
	fields := make(map[string]Value, context.temp_allocator)
	fields["map"] = tilemap_handle_value(layer)
	fields["cell"] = tilemap_cell_record(x, y)
	fields["tile"] = String_Value{text = tile}
	return Record_Value{type_name = "SetTile", fields = fields}
}

queue_settile_record :: proc(state: ^Tick_State, layer: string, x, y: i64, tile: string) {
	append(&state.terrain_commands, Terrain_Command{kind = .Set_Tile, record = settile_record(layer, x, y, tile)})
}

settile_prior_version :: proc() -> World_Version {
	layers := make([]Tile_Layer, 1, context.temp_allocator)
	layers[0] = fixture_layer()
	return World_Version{tilemaps = layers}
}

@(test)
test_settile_fold_applies_and_cows :: proc(t: ^testing.T) {
	prior := settile_prior_version()
	state := new_tick_state(prior, context.temp_allocator, context.temp_allocator)
	queue_settile_record(&state, "terrain", 1, 1, "floor")

	next := fold_tile_layers(prior, &state)
	testing.expect_value(t, len(next), 1)
	testing.expect_value(t, next[0].cells[1 * 4 + 1], 1)
	testing.expect_value(t, prior.tilemaps[0].cells[1 * 4 + 1], TILE_CELL_EMPTY)
	testing.expect_value(t, len(state.tile_refusals), 0)
	for cell, i in prior.tilemaps[0].cells {
		if i != 1 * 4 + 1 {
			testing.expect_value(t, next[0].cells[i], cell)
		}
	}
	testing.expect(t, raw_data(next[0].cells) != raw_data(prior.tilemaps[0].cells))
}

@(test)
test_settile_fold_orders_last_write_wins :: proc(t: ^testing.T) {
	prior := settile_prior_version()
	state := new_tick_state(prior, context.temp_allocator, context.temp_allocator)
	queue_settile_record(&state, "terrain", 1, 1, "floor")
	queue_settile_record(&state, "terrain", 1, 1, "wall")

	next := fold_tile_layers(prior, &state)
	testing.expect_value(t, next[0].cells[1 * 4 + 1], 0)
	testing.expect_value(t, len(state.tile_refusals), 0)
}

@(test)
test_settile_fold_shares_prior_without_commands :: proc(t: ^testing.T) {
	prior := settile_prior_version()
	state := new_tick_state(prior, context.temp_allocator, context.temp_allocator)
	next := fold_tile_layers(prior, &state)
	testing.expect(t, raw_data(next) == raw_data(prior.tilemaps))
}

@(test)
test_settile_refusals_are_named :: proc(t: ^testing.T) {
	prior := settile_prior_version()
	state := new_tick_state(prior, context.temp_allocator, context.temp_allocator)

	queue_settile_record(&state, "cavern", 0, 0, "floor")
	queue_settile_record(&state, "terrain", 0, 0, "lava")
	queue_settile_record(&state, "terrain", 4, 0, "floor")
	queue_settile_record(&state, "terrain", 0, -1, "floor")
	malformed := settile_record("terrain", 0, 0, "floor")
	delete_key(&malformed.fields, "tile")
	append(&state.terrain_commands, Terrain_Command{kind = .Set_Tile, record = malformed})
	queue_settile_record(&state, "terrain", 2, 1, "wall")

	next := fold_tile_layers(prior, &state)
	testing.expect_value(t, len(state.tile_refusals), 5)
	testing.expect_value(t, state.tile_refusals[0].kind, Tile_Command_Refusal_Kind.Unknown_Layer)
	testing.expect_value(t, state.tile_refusals[0].command, Terrain_Command_Kind.Set_Tile)
	testing.expect_value(t, state.tile_refusals[0].layer, "cavern")
	testing.expect_value(t, state.tile_refusals[1].kind, Tile_Command_Refusal_Kind.Unknown_Tile)
	testing.expect_value(t, state.tile_refusals[1].tile, "lava")
	testing.expect_value(t, state.tile_refusals[2].kind, Tile_Command_Refusal_Kind.Cell_Out_Of_Grid)
	testing.expect_value(t, state.tile_refusals[2].col, 4)
	testing.expect_value(t, state.tile_refusals[3].kind, Tile_Command_Refusal_Kind.Cell_Out_Of_Grid)
	testing.expect_value(t, state.tile_refusals[3].row, -1)
	testing.expect_value(t, state.tile_refusals[4].kind, Tile_Command_Refusal_Kind.Malformed_Command)
	testing.expect_value(t, state.tile_refusals[4].layer, "terrain")

	testing.expect_value(t, next[0].cells[1 * 4 + 2], 0)
	testing.expect_value(t, next[0].cells[0], 0)
	testing.expect_value(t, next[0].cells[1 * 4 + 1], TILE_CELL_EMPTY)
}

SETTILE_ARTIFACT :: "funpack-artifact 19\n" +
	"[meta 2]\n" +
	"project settile\n" +
	"version L5:0.1.0\n" +
	"[things 2]\n" +
	"thing Digger false 0 1\n" +
	"field t Fixed =0\n" +
	"thing Prober false 0 1\n" +
	"field seen Bool =false\n" +
	"[behaviors 2]\n" +
	"behavior dig on:Digger stage:control contract:Update 0 1 1 1\n" +
	"param self Digger\n" +
	"emit [SetTile]\n" +
	"node return 1\n" +
	"node list 1 1\n" +
	"node record SetTile 3 3\n" +
	"node recfield map 1\n" +
	"node record TilemapHandle 1 1\n" +
	"node recfield name 1\n" +
	"node string L7:terrain 0\n" +
	"node recfield cell 1\n" +
	"node record Cell 2 2\n" +
	"node recfield x 1\n" +
	"node int 1 0\n" +
	"node recfield y 1\n" +
	"node int 1 0\n" +
	"node recfield tile 1\n" +
	"node string L4:wall 0\n" +
	"behavior probe on:Prober stage:control contract:Update 0 1 1 1\n" +
	"param self Prober\n" +
	"emit Prober\n" +
	"node return 1\n" +
	"node with 1 2\n" +
	"node name self 0\n" +
	"node recfield seen 1\n" +
	"node call 2\n" +
	"node field solid_at 1\n" +
	"node record TilemapHandle 1 1\n" +
	"node recfield name 1\n" +
	"node string L7:terrain 0\n" +
	"node record Cell 2 2\n" +
	"node recfield x 1\n" +
	"node int 1 0\n" +
	"node recfield y 1\n" +
	"node int 1 0\n" +
	"[pipeline_flattened 2]\n" +
	"step 0 stage:control behavior:dig\n" +
	"step 1 stage:control behavior:probe\n" +
	"[setup 2]\n" +
	"spawn Digger 0\n" +
	"spawn Prober 0\n" +
	"[entrypoint 1]\n" +
	"entrypoint main pipeline:Dig tick_hz:60 logical:160x120 bindings:bindings\n" +
	"[tilemaps 1]\n" +
	"tilemap terrain 16 4 3 0 206158430208 - 2\n" +
	"tile wall true 0 0\n" +
	"tile floor false 1 0\n" +
	"row 0 0 0 0\n" +
	"row 0 - 1 -\n" +
	"row 0 - 0 0\n"

settile_prober_seen :: proc(t: ^testing.T, version: ^World_Version) -> bool {
	table := version_find_table(version, "Prober")
	testing.expect(t, table != nil)
	if table == nil || len(table.rows) != 1 {
		return false
	}
	seen, is_bool := table.rows[0].fields["seen"].(bool)
	testing.expect(t, is_bool)
	return seen
}

@(test)
test_settile_end_to_end_next_tick_visibility :: proc(t: ^testing.T) {
	program, err := load_program(SETTILE_ARTIFACT, context.temp_allocator)
	testing.expect_value(t, err, Artifact_Error.None)
	if err != .None {
		return
	}
	world := new_world(program, context.temp_allocator)
	base := initial_version(world, context.temp_allocator)
	v0 := run_startup(&program, base, context.temp_allocator)
	time := time_resource(program.entrypoint.tick_hz, context.temp_allocator)

	testing.expect_value(t, v0.tilemaps[0].cells[1 * 4 + 1], TILE_CELL_EMPTY)

	v1 := step_tick(&program, v0, empty(), time, context.temp_allocator)
	testing.expect_value(t, v1.tilemaps[0].cells[1 * 4 + 1], 0)
	testing.expect_value(t, settile_prober_seen(t, &v1), false)
	testing.expect_value(t, v0.tilemaps[0].cells[1 * 4 + 1], TILE_CELL_EMPTY)
	testing.expect_value(t, program_tilemap(&program, "terrain").cells[1 * 4 + 1], TILE_CELL_EMPTY)

	v2 := step_tick(&program, v1, empty(), time, context.temp_allocator)
	testing.expect_value(t, settile_prober_seen(t, &v2), true)

	draw := render_version(&program, v1, empty(), time, context.temp_allocator)
	testing.expect(t, len(draw.cmds) >= 1)
	cmd, is_tilemap := draw.cmds[0].(Draw_Tilemap)
	testing.expect(t, is_tilemap)
	if is_tilemap {
		testing.expect_value(t, cmd.layer.cells[1 * 4 + 1], 0)
	}
}

@(test)
test_settile_digest_moves_and_replay_is_bit_identical :: proc(t: ^testing.T) {
	program, err := load_program(SETTILE_ARTIFACT, context.temp_allocator)
	testing.expect_value(t, err, Artifact_Error.None)
	if err != .None {
		return
	}
	world := new_world(program, context.temp_allocator)
	base := initial_version(world, context.temp_allocator)
	v0 := run_startup(&program, base, context.temp_allocator)
	time := time_resource(program.entrypoint.tick_hz, context.temp_allocator)
	v1 := step_tick(&program, v0, empty(), time, context.temp_allocator)
	v2 := step_tick(&program, v1, empty(), time, context.temp_allocator)

	before := frame_bytes(World_Version{}, render_version(&program, v0, empty(), time, context.temp_allocator), context.temp_allocator)
	after := frame_bytes(World_Version{}, render_version(&program, v1, empty(), time, context.temp_allocator), context.temp_allocator)
	identical := len(before) == len(after)
	if identical {
		for b, i in before {
			if after[i] != b {
				identical = false
				break
			}
		}
	}
	testing.expect(t, !identical)

	replay_program, replay_err := load_program(SETTILE_ARTIFACT, context.temp_allocator)
	testing.expect_value(t, replay_err, Artifact_Error.None)
	snapshots := make([]Input, 2, context.temp_allocator)
	snapshots[0] = empty()
	snapshots[1] = empty()
	log := Replay_Log {
		identity  = identity_from_program(replay_program, SETTILE_ARTIFACT),
		snapshots = snapshots,
	}
	result := replay(&replay_program, SETTILE_ARTIFACT, log, context.temp_allocator)
	testing.expect_value(t, result.refusal, Replay_Refusal.None)
	testing.expect(t, world_versions_equal(v2, result.world))

	moved := v0
	moved.tilemaps = v1.tilemaps
	testing.expect(t, !world_versions_equal(v0, moved))
}

@(test)
test_settile_reclaim_alias_guards :: proc(t: ^testing.T) {
	track: mem.Tracking_Allocator
	mem.tracking_allocator_init(&track, context.allocator)
	defer mem.tracking_allocator_destroy(&track)
	persistent := mem.tracking_allocator(&track)

	layers := make([]Tile_Layer, 1, context.temp_allocator)
	layers[0] = fixture_layer()
	program := Program {
		tilemaps = layers,
	}
	v0 := World_Version {
		tilemaps = program.tilemaps,
	}

	state_a := new_tick_state(v0, context.temp_allocator, persistent)
	queue_settile_record(&state_a, "terrain", 1, 1, "floor")
	v1 := World_Version {
		tilemaps = fold_tile_layers(v0, &state_a),
	}
	testing.expect_value(t, len(track.allocation_map), 2)

	free_version_tilemaps(v0, v1, &program, persistent)
	testing.expect_value(t, len(track.allocation_map), 2)

	state_b := new_tick_state(v1, context.temp_allocator, persistent)
	v2 := World_Version {
		tilemaps = fold_tile_layers(v1, &state_b),
	}
	free_version_tilemaps(v1, v2, &program, persistent)
	testing.expect_value(t, len(track.allocation_map), 2)

	state_c := new_tick_state(v2, context.temp_allocator, persistent)
	queue_settile_record(&state_c, "terrain", 2, 1, "wall")
	v3 := World_Version {
		tilemaps = fold_tile_layers(v2, &state_c),
	}
	testing.expect_value(t, len(track.allocation_map), 4)
	free_version_tilemaps(v2, v3, &program, persistent)
	testing.expect_value(t, len(track.allocation_map), 2)
	testing.expect_value(t, len(track.bad_free_array), 0)
	testing.expect_value(t, v3.tilemaps[0].cells[1 * 4 + 2], 0)

	free_version_tilemaps(v3, World_Version{}, &program, persistent)
	testing.expect_value(t, len(track.allocation_map), 0)
}
