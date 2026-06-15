// The dungeon runtime golden (the warren mold): #load the PRODUCER-REAL
// committed runtime/testdata/dungeon.artifact (built by funpack stage_build from
// examples/dungeon — the cross-package byte seam
// test_emit_dungeon_matches_runtime_testdata pins the committed copy to the
// live build) and tick the game LIVE through the real pipeline — run_startup
// over the v15 level-backed [setup] batch, step_tick over scripted Input
// snapshots through the real pressed() edge path — pinning EVERY arm of the
// level-execution surface EXACTLY, never a range:
//
//   (a) tick-0 spawn from [setup]: 4 things — the hero from the named P marker,
//       two anonymous slimes, the placed chest with gems=5 — every omitted
//       field (dir/gems, rest, opened) filled from the v15-carried [things]
//       defaults;
//   (b) the hero step gated by `enterable` over the terrain layer: floor
//       enters at the cell center, a wall refuses, WATER enters (the palette
//       bakes water solid=false), the void refuses (a marker/void cell carries
//       no tile, and the gate demands one);
//   (c) dig flips the rubble at (7,3) to floor via SetTile folded at the
//       commit boundary — the dig tick's committed version already answers
//       solid_at=false, and the next tick's step enters the dug cell;
//   (d) slime ooze steps through the neighbors/in_bounds gate toward the hero
//       on its exact 26-tick rest cadence, never entering a tile-less marker
//       cell;
//   (e) the chest loots exactly once — opened flips, the Looted signal folds
//       gems into the hero the SAME tick (loot stage order), and a second
//       visit tick emits nothing.
//
// Every pin below is computed BY HAND from dungeon.flvl + dungeon_game.fun
// (bounds (0,0)(256,144), cell 16, y-down rows from the top edge: center of
// cell (c,r) = (16c+8, 136-16r)), never read back from the implementation.
// The artifact is #load-embedded, so the golden runs hermetically — no
// filesystem, no cwd, no funpack source (the hunt/krognid acceptance mold).
//
// THE 26-TICK SLIME CADENCE (the rest arithmetic, derived from the kernel):
// SLIME_REST = 0.4 lowers to round-half-up(0.4·2^32) = 1717986918 raw bits
// (funpack fixed_from_decimal); dt = fixed_div(1, 60) = trunc(2^32/60) =
// 71582788 raw bits. A step sets rest = 1717986918; ooze decrements per tick
// while rest > 0: after 24 decrements rest = 6 (still > 0), the 25th leaves
// it negative, so the NEXT tick steps — steps land on ticks 0, 26, 52, …
package funpack_runtime

import "core:testing"

DUNGEON_ARTIFACT := #load("testdata/dungeon.artifact", string)

// The Act enum is the artifact's only Button-kinded enum (Dir carries kind
// `-`), so the registry mints its variants the first five ActionIds in
// declaration order: Up, Down, Left, Right, Dig.
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

// DUNGEON_SESSION_TICKS spans the scripted crawl (ticks 0–18 walk + dig + loot,
// 19–25 idle) through the second slime step at tick 26, so both slime moves and
// the loots-exactly-once tail are inside the session.
@(private = "file")
DUNGEON_SESSION_TICKS :: 27

// dungeon_center is the world center of grid cell (c, r): the level bounds are
// (0,0)(256,144) with cell 16 and row 0 at the TOP edge, so x = 16c+8 and
// y = 144 - 16r - 8 = 136 - 16r — the same mapping the bake gives the spawn
// markers and tilemap_center_of answers.
@(private = "file")
dungeon_center :: proc(c, r: i64) -> Vec2 {
	return Vec2{x = to_fixed(16 * c + 8), y = to_fixed(136 - 16 * r)}
}

// dungeon_session_inputs is the scripted crawl, one press per tick through the
// real edge-triggered pressed() path (idle ticks are the empty snapshot):
// walk right and probe the top wall (ticks 0–3), wade into the water pool
// (tick 4), cross to the rubble wall and face it (ticks 5–8), dig (tick 9),
// cross the dug passage and probe the chasm void (ticks 10–15), reach the
// chest cell (ticks 16–18), then idle out to the tick-26 slime step.
@(private = "file")
dungeon_session_inputs :: proc(allocator := context.allocator) -> []Input {
	inputs := make([]Input, DUNGEON_SESSION_TICKS, allocator)
	script := [](struct {
		tick:   int,
		action: ActionId,
	}) {
		{0, DUNGEON_RIGHT}, // (2,2) -> (3,2): floor enters
		{1, DUNGEON_UP}, // (3,2) -> (3,1): floor enters
		{2, DUNGEON_UP}, // (3,0) is wall: the gate refuses, dir turns Up
		{3, DUNGEON_DOWN}, // back to (3,2)
		{4, DUNGEON_DOWN}, // (3,3) is WATER, solid=false: enters
		{5, DUNGEON_RIGHT}, // (4,3) water
		{6, DUNGEON_RIGHT}, // (5,3) floor
		{7, DUNGEON_RIGHT}, // (6,3) floor
		{8, DUNGEON_RIGHT}, // (7,3) is RUBBLE (solid): refuses, dir faces Right
		{9, DUNGEON_DIG}, // dig (7,3): rubble -> floor at the commit boundary
		{10, DUNGEON_RIGHT}, // (7,3) now floor: the dug passage opens
		{11, DUNGEON_RIGHT}, // (8,3)
		{12, DUNGEON_RIGHT}, // (9,3)
		{13, DUNGEON_RIGHT}, // (10,3)
		{14, DUNGEON_DOWN}, // (10,4) is the chasm VOID (no tile): refuses
		{15, DUNGEON_RIGHT}, // (11,3)
		{16, DUNGEON_RIGHT}, // (12,3)
		{17, DUNGEON_RIGHT}, // (13,3)
		{18, DUNGEON_DOWN}, // (13,4): the chest's cell — loot fires this tick
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

// dungeon_row reads row `idx` of a thing's committed table, failing closed on
// an absent table/row so a pin reads a zero Row rather than panicking.
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
	// The AC golden: the committed producer-real dungeon artifact ticks LIVE
	// through run_startup + step_tick over the scripted session, and every
	// committed checkpoint pins exactly — the (a)–(e) arms documented in the
	// file header. Input drives through the real registry-resolved pressed()
	// edge path, never a hand-poked blackboard.
	context.allocator = context.temp_allocator

	program, ok := load_dungeon(t)
	if !ok {
		return
	}
	world := new_world(program, context.temp_allocator)
	version := run_startup(&program, initial_version(world, context.temp_allocator))

	// (a) tick-0 spawn from [setup]: the named P marker's hero at cell (2,2),
	// the two anonymous slimes row-major ((11,2) then (3,6)), the placed chest
	// at (13,4) with its inline gems=5 — and every omitted field filled from
	// the v15-carried [things] defaults (dir=Dir::Down, gems=0, rest=0,
	// opened=false).
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
			// (b) floor enters; (d) the FIRST slime step (rest spawned 0): each
			// slime moves to its strictly-distance-closing open neighbor toward
			// the hero's post-control cell (3,2) — the right-room slime to
			// (10,2), the left-room slime to (3,5) — and arms rest to the
			// SLIME_REST raw bits.
			testing.expect_value(t, hero_pos, dungeon_center(3, 2))
			testing.expect_value(t, dungeon_row(&version, "Player", 0).fields["dir"].(string), "Dir::Right")
			testing.expect_value(t, dungeon_row(&version, "Slime", 0).fields["pos"].(Vec2), dungeon_center(10, 2))
			testing.expect_value(t, dungeon_row(&version, "Slime", 0).fields["rest"].(Fixed), Fixed(1717986918))
			testing.expect_value(t, dungeon_row(&version, "Slime", 1).fields["pos"].(Vec2), dungeon_center(3, 5))
		case 2:
			// (b) the wall refuses: the step from (3,1) into (3,0) '#' stays
			// put, but the hero still turns to face the heading (walk sets dir
			// either way — the next dig aims where the player faces).
			testing.expect_value(t, hero_pos, dungeon_center(3, 1))
			testing.expect_value(t, dungeon_row(&version, "Player", 0).fields["dir"].(string), "Dir::Up")
		case 4:
			// (b) WATER enters: the palette bakes water solid=false, so the
			// gate passes — derived from the layer's actual solids, not a
			// floor-only assumption.
			testing.expect_value(t, hero_pos, dungeon_center(3, 3))
		case 8:
			// (b) rubble is baked solid: the step from (6,3) into (7,3) '%'
			// refuses; the hero faces Right, aiming the dig.
			testing.expect_value(t, hero_pos, dungeon_center(6, 3))
			testing.expect_value(t, dungeon_row(&version, "Player", 0).fields["dir"].(string), "Dir::Right")
			layer := version_tilemap(&version, "terrain")
			testing.expect_value(t, tilemap_solid_at(layer, 7, 3), true)
		case 9:
			// (c) the dig tick: SetTile{terrain, (7,3), floor} folds at THIS
			// tick's commit boundary, so the committed version already answers
			// floor/not-solid; the hero has not moved.
			testing.expect_value(t, hero_pos, dungeon_center(6, 3))
			layer := version_tilemap(&version, "terrain")
			testing.expect_value(t, tilemap_solid_at(layer, 7, 3), false)
			name, has := tilemap_tile_at(layer, 7, 3)
			testing.expect_value(t, has, true)
			testing.expect_value(t, name, "floor")
		case 10:
			// (c) the next tick's step enters the dug cell — next tick's
			// solid_at sees the flip.
			testing.expect_value(t, hero_pos, dungeon_center(7, 3))
		case 14:
			// (b) the chasm void refuses: (10,4) is a tile-less ' ' cell and
			// `enterable` demands a tile (the void is not floor).
			testing.expect_value(t, hero_pos, dungeon_center(10, 3))
			testing.expect_value(t, dungeon_row(&version, "Player", 0).fields["dir"].(string), "Dir::Down")
		case 18:
			// (e) the loot tick: the hero enters the chest's cell (13,4) in
			// control, open_chest sees the post-move View, flips opened, and
			// emits Looted{gems:5}; collect folds it into the hero the SAME
			// tick (loot stage order: open_chest then collect).
			testing.expect_value(t, hero_pos, dungeon_center(13, 4))
			testing.expect_value(t, dungeon_row(&version, "Chest", 0).fields["opened"].(bool), true)
			testing.expect_value(t, dungeon_row(&version, "Player", 0).fields["gems"].(i64), 5)
		case 19:
			// (e) the second visit tick emits NOTHING: opened short-circuits
			// open_chest, so the hero's gems are unchanged.
			testing.expect_value(t, hero_pos, dungeon_center(13, 4))
			testing.expect_value(t, dungeon_row(&version, "Player", 0).fields["gems"].(i64), 5)
		case 26:
			// (d) the SECOND slime step on the exact 26-tick rest cadence (the
			// header's kernel arithmetic), chasing the hero's cell (13,4): the
			// right-room slime's only strict improvement is down to (10,3) —
			// its right neighbor (11,2) is a tile-less marker cell the
			// enterable gate FILTERS from neighbors() — and the left-room
			// slime wades up into the water at (3,4).
			testing.expect_value(t, dungeon_row(&version, "Slime", 0).fields["pos"].(Vec2), dungeon_center(10, 3))
			testing.expect_value(t, dungeon_row(&version, "Slime", 1).fields["pos"].(Vec2), dungeon_center(3, 4))
			testing.expect_value(t, dungeon_row(&version, "Slime", 0).fields["rest"].(Fixed), Fixed(1717986918))
			// The hero idled since the loot: position and gems are stable.
			testing.expect_value(t, hero_pos, dungeon_center(13, 4))
			testing.expect_value(t, dungeon_row(&version, "Player", 0).fields["gems"].(i64), 5)
		}
	}
}

@(test)
test_dungeon_live_run_and_refold_have_identical_digests :: proc(t: ^testing.T) {
	// The real-input-path proof (the pong/hunt replay/capture harness mold): a
	// live dungeon run captured per-tick and the production re-fold of its
	// RECORDED log — recorded through the production recorder against the
	// artifact's pinned identity, re-read by the production parser, re-folded
	// through the identity-gated replay_capture driver — produce bit-identical
	// per-tick AND session frame digests. The digest folds committed state and
	// the §20 draw-list (whose batched Draw_Tilemap carries the dug terrain),
	// so the dig's SetTile is inside the comparison surface. The dungeon is
	// SEEDLESS: input is the sole recorded nondeterminism source.
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

	// Record the scripted session through the production recorder, then re-fold
	// against a FRESH program load through the production capturing driver.
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
