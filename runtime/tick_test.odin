// Per-tick transaction acceptance (spec §07 §4, §08): the pong fold is a
// deterministic transaction over the flattened pipeline. These tests prove the
// load-bearing guarantees against the GOLDEN pong program — not a hand-built
// stand-in — so the determinism thesis is asserted on the real workload:
//
//   - setup's [Spawn] runs before tick 0, so tick 0 sees the initial population;
//   - N ticks over fixed inputs commit a BIT-IDENTICAL world version every run;
//   - a Goal emitted in the scoring stage is consumed SAME-TICK by tally (the
//     score advances) and serve (the ball re-centers) — forward synchronous
//     in-pipeline-order routing with no mailbox/concurrency;
//   - every committed Version_Table keeps its rows ASCENDING by Id, even when a
//     spawn batch appends them out of order — the find_row_by_id binary-search
//     invariant View iteration and Ref resolution both rest on.
package funpack_runtime

import "core:testing"

// dt_60hz_value is the fixed 60hz step the Time resource carries each tick: 1/60
// in Q32.32 through the kernel — no float, identical bits every machine.
@(private = "file")
dt_60hz_value :: proc() -> Fixed {
	return fixed_div(to_fixed(1), to_fixed(60))
}

// time_resource is the Time resource a behavior's `time` param binds to: the one
// `dt` field at the fixed 60hz step. The fold consumes this minimal record as
// behaviors need dt — the full Time-resource surface is the resource-wiring layer
// that owns Input/Time plumbing.
@(private = "file")
time_resource :: proc(allocator := context.allocator) -> Record_Value {
	fields := make(map[string]Value, allocator)
	fields["dt"] = dt_60hz_value()
	return Record_Value{type_name = "Time", fields = fields}
}

// startup_version runs setup's [Spawn] batch against the empty initial version,
// returning the populated base tick 0 reads — the pre-tick-0 population step.
@(private = "file")
startup_version :: proc(program: ^Program, allocator := context.allocator) -> World_Version {
	world := new_world(program^, allocator)
	base := initial_version(world, allocator)
	return run_startup(program, base, allocator)
}

// setup runs BEFORE tick 0: the populated base carries the artifact's initial
// population (two Paddles, one Ball, one Scoreboard) with every blackboard field
// decoded bit-exact through the kernel, so tick 0 already sees the spawned world.
@(test)
test_startup_populates_before_tick_zero :: proc(t: ^testing.T) {
	program, ok := load_golden(t)
	if !ok {
		return
	}
	base := startup_version(&program, context.temp_allocator)

	// Two paddles, one ball, one scoreboard — the setup batch's four spawns.
	testing.expect_value(t, view_count(view_of_type(&base, "Paddle")), 2)
	testing.expect_value(t, view_count(view_of_type(&base, "Ball")), 1)
	testing.expect_value(t, view_count(view_of_type(&base, "Scoreboard")), 1)

	// The ball spawned at (80, 60) with velocity (70, 40) — fixed-point bit-exact.
	ball, ball_ok := view_at(view_of_type(&base, "Ball"), 0)
	testing.expect(t, ball_ok)
	pos, pos_present := row_field(ball, "pos")
	vel, vel_present := row_field(ball, "vel")
	testing.expect(t, pos_present && vel_present)
	testing.expect_value(t, pos.(Vec2), Vec2{to_fixed(80), to_fixed(60)})
	testing.expect_value(t, vel.(Vec2), Vec2{to_fixed(70), to_fixed(40)})

	// The scoreboard spawned at 0/0 via the thing's field defaults (left/right are
	// omitted in setup and default to Int 0).
	scoreboard, sb_ok := view_at(view_of_type(&base, "Scoreboard"), 0)
	testing.expect(t, sb_ok)
	left, l_present := row_field(scoreboard, "left")
	right, r_present := row_field(scoreboard, "right")
	testing.expect(t, l_present && r_present)
	testing.expect_value(t, left.(i64), i64(0))
	testing.expect_value(t, right.(i64), i64(0))
}

// One tick over empty input advances the ball by vel*dt and leaves the paddles
// and score put: the §07 §4 forward fold computes the next world from the prior.
// With no input the paddle dir is 0 (clamp leaves y), no wall/paddle bounce, no
// goal — the deterministic baseline the determinism test repeats.
@(test)
test_single_tick_advances_ball :: proc(t: ^testing.T) {
	program, ok := load_golden(t)
	if !ok {
		return
	}
	base := startup_version(&program, context.temp_allocator)
	dt := dt_60hz_value()

	next := step_tick(&program, base, empty(), time_resource(context.temp_allocator), context.temp_allocator)
	testing.expect_value(t, next.tick, base.tick + 1)

	// Ball advanced by vel*dt from (80,60), vel (70,40) — bit-exact kernel result.
	ball, ball_ok := view_at(view_of_type(&next, "Ball"), 0)
	testing.expect(t, ball_ok)
	pos, _ := row_field(ball, "pos")
	want := Vec2 {
		fixed_add(to_fixed(80), fixed_mul(to_fixed(70), dt)),
		fixed_add(to_fixed(60), fixed_mul(to_fixed(40), dt)),
	}
	testing.expect_value(t, pos.(Vec2), want)

	// Score unchanged at 0/0 (the ball is in-bounds, no goal this tick).
	scoreboard, _ := view_at(view_of_type(&next, "Scoreboard"), 0)
	left, _ := row_field(scoreboard, "left")
	right, _ := row_field(scoreboard, "right")
	testing.expect_value(t, left.(i64), i64(0))
	testing.expect_value(t, right.(i64), i64(0))
}

// N ticks over a FIXED input run produce a BIT-IDENTICAL committed world version
// every run (spec §07 §4, §10.5 determinism thesis): folding the same program
// from the same setup with the same per-tick input twice yields a byte-identical
// final world. This is the determinism acceptance — stable-Id dispatch, forward
// routing, and the spawn batch all fold to one reproducible result.
@(test)
test_n_ticks_deterministic :: proc(t: ^testing.T) {
	program, ok := load_golden(t)
	if !ok {
		return
	}

	first := run_n_ticks(&program, 600, empty_input, context.temp_allocator)
	second := run_n_ticks(&program, 600, empty_input, context.temp_allocator)

	// The two independent runs commit identical world versions — same tick, same
	// rows, same fixed-point bits, in the same stable Id order.
	testing.expect(t, world_versions_equal(first, second))

	// The 600-tick fold is non-trivial: the ball crosses the board edge and serves
	// multiple times, so the scoring + serve + signal-route paths are exercised by
	// the determinism run, not just a straight-line ball advance. The score has
	// advanced past zero.
	scoreboard, _ := view_at(view_of_type(&first, "Scoreboard"), 0)
	left, _ := row_field(scoreboard, "left")
	right, _ := row_field(scoreboard, "right")
	testing.expect(t, left.(i64) + right.(i64) > 0)
}

// Input-driven N ticks are ALSO bit-identical run-to-run (spec §23 §4: input is
// the only nondeterminism source, and a fixed input run is deterministic). Two
// runs that hold P1's paddle up via the same per-tick snapshot fold to an
// identical world, so the input-read path (paddle_move's input.value → clamp) is
// as reproducible as the input-free fold.
@(test)
test_n_ticks_with_input_deterministic :: proc(t: ^testing.T) {
	program, ok := load_golden(t)
	if !ok {
		return
	}

	first := run_n_ticks(&program, 120, hold_p1_up, context.temp_allocator)
	second := run_n_ticks(&program, 120, hold_p1_up, context.temp_allocator)
	testing.expect(t, world_versions_equal(first, second))

	// The input moved P1's paddle: its y is no longer the spawned 60.0 (the input
	// drove paddle_move's clamp each tick), proving the input path actually folded.
	paddle, _ := view_at(view_of_type(&first, "Paddle"), 0)
	y, _ := row_field(paddle, "y")
	testing.expect(t, y.(Fixed) != to_fixed(60))
}

// Input_Fn supplies one tick's snapshot to the fold — a fixed input run keys
// every tick's input off the tick index, so two runs see the identical sequence.
@(private = "file")
Input_Fn :: proc(tick: int, allocator: Runtime_Allocator) -> Input

// empty_input is the no-input fold: every tick reads the all-zero snapshot, so
// no paddle moves and the ball flies on its spawned velocity. The snapshot's
// tables are built in the tick arena so they share the fold's lifetime.
@(private = "file")
empty_input :: proc(tick: int, allocator: Runtime_Allocator) -> Input {
	context.allocator = allocator
	return empty()
}

// hold_p1_up drives P1's Steer::Move axis to +1 every tick — the fixed input
// that holds the left paddle moving each tick. Steer::Move is the program's sole
// Axis action, minted as ActionId 0 (the first Axis variant in declaration walk),
// so the snapshot keys it directly without re-deriving the registry. Built in the
// tick arena, so the producer's intermediate tables share the fold's lifetime.
@(private = "file")
hold_p1_up :: proc(tick: int, allocator: Runtime_Allocator) -> Input {
	context.allocator = allocator
	return with_value(empty(), .P1, ActionId(0), to_fixed(1))
}

// run_n_ticks runs setup then N ticks, supplying each tick's input from `input_fn`
// and the fixed 60hz dt. Each tick reads the prior version — the closed,
// input-fixed fold the determinism tests repeat.
@(private = "file")
run_n_ticks :: proc(
	program: ^Program,
	n: int,
	input_fn: Input_Fn,
	allocator := context.allocator,
) -> World_Version {
	version := startup_version(program, allocator)
	for tick in 0 ..< n {
		snapshot := input_fn(tick, allocator)
		version = step_tick(program, version, snapshot, time_resource(allocator), allocator)
	}
	return version
}

// A Goal emitted in the scoring stage is consumed SAME-TICK downstream by tally
// (the score advances) and serve (the ball re-centers): the canonical forward
// synchronous in-pipeline-order route (§12). The ball starts past the right edge,
// so score emits Goal{Left}, tally folds it onto the scoreboard (+1 left), and
// serve re-centers the ball — all within one tick, no mailbox, no next-tick lag.
@(test)
test_goal_consumed_same_tick_advances_score :: proc(t: ^testing.T) {
	program, ok := load_golden(t)
	if !ok {
		return
	}
	// Start from the populated base, then commit a version whose ball sits past
	// the right board edge (x = 200 > BOARD.w 160) so this tick scores.
	base := startup_version(&program, context.temp_allocator)
	scored_setup := place_ball(&program, base, Vec2{to_fixed(200), to_fixed(60)}, Vec2{to_fixed(70), to_fixed(40)})

	next := step_tick(&program, scored_setup, empty(), time_resource(context.temp_allocator), context.temp_allocator)

	// tally consumed the Goal THIS tick: left advanced 0 → 1, right untouched.
	scoreboard, _ := view_at(view_of_type(&next, "Scoreboard"), 0)
	left, _ := row_field(scoreboard, "left")
	right, _ := row_field(scoreboard, "right")
	testing.expect_value(t, left.(i64), i64(1))
	testing.expect_value(t, right.(i64), i64(0))

	// serve consumed the SAME Goal this tick: the ball re-centered to the board
	// midpoint (80, 60) and took the Left serve velocity (+70, +40).
	ball, _ := view_at(view_of_type(&next, "Ball"), 0)
	pos, _ := row_field(ball, "pos")
	vel, _ := row_field(ball, "vel")
	testing.expect_value(t, pos.(Vec2), Vec2{to_fixed(80), to_fixed(60)})
	testing.expect_value(t, vel.(Vec2), Vec2{to_fixed(70), to_fixed(40)})
}

// place_ball commits a version identical to `prior` except the single Ball row
// carries the supplied pos/vel — the scoring-scenario fixture. It re-folds the
// ball table through commit_version so the result is a real committed version the
// tick reads, not a hand-poked struct.
@(private = "file")
place_ball :: proc(
	program: ^Program,
	prior: World_Version,
	pos, vel: Vec2,
	allocator := context.temp_allocator,
) -> World_Version {
	prior_version := prior
	ball, _ := view_at(view_of_type(&prior_version, "Ball"), 0)
	fields := make(map[string]Field_Value, allocator)
	fields["pos"] = pos
	fields["vel"] = vel
	// The committed rows slice must outlive this helper — a slice literal is
	// stack-temporary, so allocate the one-row slice in the supplied allocator.
	rows := make([]Row, 1, allocator)
	rows[0] = Row{id = ball.id, fields = fields}
	changed := make(map[string]Version_Table, allocator)
	changed["Ball"] = Version_Table {
		thing   = "Ball",
		rows    = rows,
		next_id = Thing_Id(1),
	}
	return commit_version(prior, changed, allocator)
}

// Every committed Version_Table keeps its rows ASCENDING by Id — the
// find_row_by_id binary-search invariant (§08 §2). An out-of-order spawn batch
// (Ids appended 2, 0, 1) still commits an ascending table, so iteration walks Id
// order and every Ref resolves through the binary search. This is the criterion
// added at review handoff: a committed world is ALWAYS Id-sorted, regardless of
// the order the batch produced its rows.
@(test)
test_committed_table_is_id_ascending :: proc(t: ^testing.T) {
	// A two-thing world; build a tick state and queue spawns out of Id order.
	world := make([]Thing_Table, 1, context.temp_allocator)
	world[0] = Thing_Table{thing = "Mote", singleton = false, next_id = Thing_Id(0)}
	prior := initial_version(World{tables = world}, context.temp_allocator)

	state := new_tick_state(prior, context.temp_allocator)
	// Queue three spawns in Id order (apply_spawn_batch mints Ids 0,1,2 in queue
	// order, so each row's seq equals its minted Id), THEN scramble the working
	// rows out of Id order. The commit-time sort is the only thing that can restore
	// ascending Id — proving the invariant is the commit's job, not an accident of
	// insertion order.
	queue_spawn(&state, "Mote", mote_blackboard(0))
	queue_spawn(&state, "Mote", mote_blackboard(1))
	queue_spawn(&state, "Mote", mote_blackboard(2))
	apply_spawn_batch(&state)

	// Scramble the working rows so the slice is NOT ascending by Id before commit.
	table := find_tick_table(state.tables, "Mote")
	testing.expect(t, table != nil)
	table.rows[0], table.rows[2] = table.rows[2], table.rows[0]

	next := commit_tick_state(prior, &state, context.temp_allocator)
	committed := view_of_type(&next, "Mote")
	testing.expect_value(t, view_count(committed), 3)

	// Iteration walks ASCENDING Id order (0, 1, 2) regardless of the scrambled
	// working order — the commit sorted the table.
	for i in 0 ..< view_count(committed) {
		row, _ := view_at(committed, i)
		testing.expect_value(t, row.id, Id{raw = Thing_Id(i)})
	}

	// Every Ref resolves through the binary search the ascending invariant enables:
	// a Ref to each Id finds exactly its row.
	for want_id in 0 ..< 3 {
		ref := Ref{thing = "Mote", id = Id{raw = Thing_Id(want_id)}}
		row, some := resolve_ref(&next, ref)
		testing.expect(t, some)
		seq, _ := row_field(row, "seq")
		testing.expect_value(t, seq.(i64), i64(want_id))
	}
}

// mote_blackboard builds a one-field Mote row carrying its sequence number, so
// the ascending-Id test can read each committed row back by Id and confirm the
// row a Ref resolves is the one minted for that Id.
@(private = "file")
mote_blackboard :: proc(seq: i64, allocator := context.temp_allocator) -> map[string]Field_Value {
	fields := make(map[string]Field_Value, allocator)
	fields["seq"] = seq
	return fields
}

// Spawn applies as ONE deterministic batch at the tick boundary: a row queued
// this tick is NOT visible until the batch commits, so a thing spawned this tick
// is first queryable NEXT tick (population fixed within a tick, §07 §4). The
// despawn half removes its row in the same batch, applied before the spawns.
@(test)
test_spawn_batch_at_tick_boundary :: proc(t: ^testing.T) {
	world := make([]Thing_Table, 1, context.temp_allocator)
	world[0] = Thing_Table{thing = "Mote", singleton = false, next_id = Thing_Id(0)}
	prior := initial_version(World{tables = world}, context.temp_allocator)

	// Tick A: spawn two motes. They are queued, then applied at the boundary.
	state := new_tick_state(prior, context.temp_allocator)
	queue_spawn(&state, "Mote", mote_blackboard(0))
	queue_spawn(&state, "Mote", mote_blackboard(1))

	// Mid-tick (before apply), the working table still reflects the PRIOR
	// population — zero rows — so a behavior this tick never sees the spawn.
	table := find_tick_table(state.tables, "Mote")
	testing.expect(t, table != nil)
	testing.expect_value(t, len(table.rows), 0)

	apply_spawn_batch(&state)
	tick_a := commit_tick_state(prior, &state, context.temp_allocator)
	// Next tick the spawned motes are queryable.
	testing.expect_value(t, view_count(view_of_type(&tick_a, "Mote")), 2)

	// Tick B: despawn mote Id 0 and spawn one more — the despawn drops its row,
	// the spawn mints the next Id (2), applied as one batch at the boundary.
	state_b := new_tick_state(tick_a, context.temp_allocator)
	queue_despawn(&state_b, Ref{thing = "Mote", id = Id{raw = Thing_Id(0)}})
	queue_spawn(&state_b, "Mote", mote_blackboard(2))
	apply_spawn_batch(&state_b)
	tick_b := commit_tick_state(tick_a, &state_b, context.temp_allocator)

	// Mote 0 is gone, motes 1 and 2 remain — committed ascending by Id.
	motes := view_of_type(&tick_b, "Mote")
	testing.expect_value(t, view_count(motes), 2)
	row0, _ := view_at(motes, 0)
	row1, _ := view_at(motes, 1)
	testing.expect_value(t, row0.id, Id{raw = Thing_Id(1)})
	testing.expect_value(t, row1.id, Id{raw = Thing_Id(2)})
	// The despawned Id 0 no longer resolves — referential integrity by the batch.
	_, gone := resolve_ref(&tick_b, Ref{thing = "Mote", id = Id{raw = Thing_Id(0)}})
	testing.expect(t, !gone)
}

// The determinism assertions read world_versions_equal — the package-visible
// bit-identity comparison (state.odin). The replay re-fold acceptance shares the
// same comparison, so it lives in the read layer rather than file-private here.
