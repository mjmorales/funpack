package funpack_runtime

import "core:testing"

DUNGEON_ARTIFACT := #load("testdata/dungeon.artifact", string)

@(private = "file")
DUNGEON_UP :: ActionId(0)
@(private = "file")
DUNGEON_DOWN :: ActionId(1)
@(private = "file")
DUNGEON_LEFT :: ActionId(2)
@(private = "file")
DUNGEON_RIGHT :: ActionId(3)
@(private = "file")
DUNGEON_DIG :: ActionId(4)

@(private = "file")
DUNGEON_SESSION_TICKS :: 27

@(private = "file")
dungeon_center :: proc(c, r: i64) -> Vec2 {
	return Vec2{x = to_fixed(16 * c + 8), y = to_fixed(136 - 16 * r)}
}

@(private = "file")
dungeon_session_inputs :: proc(allocator := context.allocator) -> []Input {
	inputs := make([]Input, DUNGEON_SESSION_TICKS, allocator)
	script := [](struct {
		tick:   int,
		action: ActionId,
	}) {
		{0, DUNGEON_RIGHT},
		{1, DUNGEON_UP},
		{2, DUNGEON_UP},
		{3, DUNGEON_DOWN},
		{4, DUNGEON_DOWN},
		{5, DUNGEON_RIGHT},
		{6, DUNGEON_RIGHT},
		{7, DUNGEON_RIGHT},
		{8, DUNGEON_RIGHT},
		{9, DUNGEON_DIG},
		{10, DUNGEON_RIGHT},
		{11, DUNGEON_RIGHT},
		{12, DUNGEON_RIGHT},
		{13, DUNGEON_RIGHT},
		{14, DUNGEON_DOWN},
		{15, DUNGEON_RIGHT},
		{16, DUNGEON_RIGHT},
		{17, DUNGEON_RIGHT},
		{18, DUNGEON_DOWN},
	}
	for i in 0 ..< DUNGEON_SESSION_TICKS {
		inputs[i] = empty()
	}
	for press in script {
		inputs[press.tick] = with_pressed(empty(), .P1, press.action)
	}
	return inputs
}

@(private = "file")
load_dungeon :: proc(t: ^testing.T) -> (program: Program, ok: bool) {
	loaded, err := load_program(DUNGEON_ARTIFACT, context.temp_allocator)
	if !testing.expectf(t, err == .None, "golden dungeon artifact must load, got %v", err) {
		return {}, false
	}
	return loaded, true
}

@(private = "file")
dungeon_row :: proc(version: ^World_Version, thing: string, idx: int) -> Row {
	table := version_find_table(version, thing)
	if table == nil || idx < 0 || idx >= len(table.rows) {
		return Row{}
	}
	return table.rows[idx]
}

@(test)
test_dungeon :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator

	program, ok := load_dungeon(t)
	if !ok {
		return
	}
	world := new_world(program, context.temp_allocator)
	version := run_startup(&program, initial_version(world, context.temp_allocator))

	player_table := version_find_table(&version, "Player")
	slime_table := version_find_table(&version, "Slime")
	chest_table := version_find_table(&version, "Chest")
	if !testing.expect(t, player_table != nil && slime_table != nil && chest_table != nil) {
		return
	}
	testing.expect_value(t, len(player_table.rows), 1)
	testing.expect_value(t, len(slime_table.rows), 2)
	testing.expect_value(t, len(chest_table.rows), 1)

	hero := dungeon_row(&version, "Player", 0)
	testing.expect_value(t, hero.fields["pos"].(Vec2), dungeon_center(2, 2))
	testing.expect_value(t, hero.fields["dir"].(string), "Dir::Down")
	testing.expect_value(t, hero.fields["gems"].(i64), 0)
	testing.expect_value(t, dungeon_row(&version, "Slime", 0).fields["pos"].(Vec2), dungeon_center(11, 2))
	testing.expect_value(t, dungeon_row(&version, "Slime", 0).fields["rest"].(Fixed), Fixed(0))
	testing.expect_value(t, dungeon_row(&version, "Slime", 1).fields["pos"].(Vec2), dungeon_center(3, 6))
	chest := dungeon_row(&version, "Chest", 0)
	testing.expect_value(t, chest.fields["pos"].(Vec2), dungeon_center(13, 4))
	testing.expect_value(t, chest.fields["gems"].(i64), 5)
	testing.expect_value(t, chest.fields["opened"].(bool), false)

	inputs := dungeon_session_inputs()
	for input, i in inputs {
		time := time_resource_at(program.entrypoint.tick_hz, i, context.temp_allocator)
		version = step_tick(&program, version, input, time, context.temp_allocator)

		hero_pos := dungeon_row(&version, "Player", 0).fields["pos"].(Vec2)
		switch i {
		case 0:
			testing.expect_value(t, hero_pos, dungeon_center(3, 2))
			testing.expect_value(t, dungeon_row(&version, "Player", 0).fields["dir"].(string), "Dir::Right")
			testing.expect_value(t, dungeon_row(&version, "Slime", 0).fields["pos"].(Vec2), dungeon_center(10, 2))
			testing.expect_value(t, dungeon_row(&version, "Slime", 0).fields["rest"].(Fixed), Fixed(1717986918))
			testing.expect_value(t, dungeon_row(&version, "Slime", 1).fields["pos"].(Vec2), dungeon_center(3, 5))
		case 2:
			testing.expect_value(t, hero_pos, dungeon_center(3, 1))
			testing.expect_value(t, dungeon_row(&version, "Player", 0).fields["dir"].(string), "Dir::Up")
		case 4:
			testing.expect_value(t, hero_pos, dungeon_center(3, 3))
		case 8:
			testing.expect_value(t, hero_pos, dungeon_center(6, 3))
			testing.expect_value(t, dungeon_row(&version, "Player", 0).fields["dir"].(string), "Dir::Right")
			layer := version_tilemap(&version, "terrain")
			testing.expect_value(t, tilemap_solid_at(layer, 7, 3), true)
		case 9:
			testing.expect_value(t, hero_pos, dungeon_center(6, 3))
			layer := version_tilemap(&version, "terrain")
			testing.expect_value(t, tilemap_solid_at(layer, 7, 3), false)
			name, has := tilemap_tile_at(layer, 7, 3)
			testing.expect_value(t, has, true)
			testing.expect_value(t, name, "floor")
		case 10:
			testing.expect_value(t, hero_pos, dungeon_center(7, 3))
		case 14:
			testing.expect_value(t, hero_pos, dungeon_center(10, 3))
			testing.expect_value(t, dungeon_row(&version, "Player", 0).fields["dir"].(string), "Dir::Down")
		case 18:
			testing.expect_value(t, hero_pos, dungeon_center(13, 4))
			testing.expect_value(t, dungeon_row(&version, "Chest", 0).fields["opened"].(bool), true)
			testing.expect_value(t, dungeon_row(&version, "Player", 0).fields["gems"].(i64), 5)
		case 19:
			testing.expect_value(t, hero_pos, dungeon_center(13, 4))
			testing.expect_value(t, dungeon_row(&version, "Player", 0).fields["gems"].(i64), 5)
		case 26:
			testing.expect_value(t, dungeon_row(&version, "Slime", 0).fields["pos"].(Vec2), dungeon_center(10, 3))
			testing.expect_value(t, dungeon_row(&version, "Slime", 1).fields["pos"].(Vec2), dungeon_center(3, 4))
			testing.expect_value(t, dungeon_row(&version, "Slime", 0).fields["rest"].(Fixed), Fixed(1717986918))
			testing.expect_value(t, hero_pos, dungeon_center(13, 4))
			testing.expect_value(t, dungeon_row(&version, "Player", 0).fields["gems"].(i64), 5)
		}
	}
}

@(test)
test_dungeon_live_run_and_refold_have_identical_digests :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator

	live_program, ok := load_dungeon(t)
	if !ok {
		return
	}
	inputs := dungeon_session_inputs()

	world := new_world(live_program, context.temp_allocator)
	version := run_startup(&live_program, initial_version(world, context.temp_allocator))
	tick_hz := live_program.entrypoint.tick_hz
	per_tick := make([dynamic]Frame_Digest, 0, len(inputs), context.temp_allocator)
	for input, i in inputs {
		time := time_resource_at(tick_hz, i, context.temp_allocator)
		version = step_tick(&live_program, version, input, time, context.temp_allocator)
		draw := render_version(&live_program, version, input, time, context.temp_allocator)
		append(&per_tick, capture_frame(version, draw, context.temp_allocator))
	}
	live := finish_capture(per_tick[:], context.temp_allocator)

	identity := identity_from_program(live_program, DUNGEON_ARTIFACT)
	writer := open_replay_writer(identity, context.temp_allocator)
	defer delete_replay_writer(&writer)
	for input in inputs {
		record_tick(&writer, input, context.temp_allocator)
	}
	log_bytes := finish_replay(&writer, context.temp_allocator)
	log, parse_ok := read_replay(log_bytes)
	if !testing.expect(t, parse_ok) {
		return
	}

	refold_program, refold_ok := load_dungeon(t)
	if !refold_ok {
		return
	}
	result := replay_capture(&refold_program, DUNGEON_ARTIFACT, log)
	if !testing.expect_value(t, result.refusal, Replay_Refusal.None) {
		return
	}
	if !testing.expect_value(t, len(result.capture.per_tick), len(live.per_tick)) {
		return
	}
	for frame, i in live.per_tick {
		testing.expect_value(t, result.capture.per_tick[i].tick, frame.tick)
		testing.expect_value(t, result.capture.per_tick[i].digest, frame.digest)
	}
	testing.expect_value(t, result.capture.session, live.session)
}
