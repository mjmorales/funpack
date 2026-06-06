// Replay re-fold acceptance (spec §07 §4, §09 §5, §23 §4): the driver restarts
// the golden pong artifact and re-feeds a recorded snapshot stream over the SAME
// tick loop a live run uses, committing a world bit-identical to the original
// run's. The tests prove the two load-bearing guarantees against the REAL golden
// program — not a hand-built stand-in:
//
//   - a recorded session re-folds tick-by-tick to the recorded tick count,
//     supplying the recorded Input each tick, and the world it commits is
//     bit-identical to the original run's (world_versions_equal) — the only
//     substitution is the input source, so the replay reproduces the run exactly;
//   - a log whose pinned artifact hash differs from the loaded artifact is REFUSED
//     with a diagnostic (Replay_Refusal.Identity_Mismatch), not silently re-folded
//     against the wrong build (§09 §5).
//
// The snapshot stream is built in the device-free producer vocabulary (input.odin)
// — RAW device state never appears — and recorded through the production recorder,
// so the replay exercises the recorder → reader → driver path end to end.
package funpack_runtime

import "core:strconv"
import "core:strings"
import "core:testing"

// REPLAY_TICK_COUNT is the recorded session length: long enough that the ball
// crosses the board edge and serves (the scoring + serve + signal-route paths
// fold), so the replay reproduces a non-trivial run, not a straight-line advance.
@(private = "file")
REPLAY_TICK_COUNT :: 600

// replay_input_at builds the recorded snapshot for one tick of the session: P1
// holds Steer::Move at +1 for the first stretch, then releases it — a sequence
// that moves the left paddle and then lets it sit, so the recorded stream is not a
// single constant snapshot. Steer::Move is the program's sole Axis action, minted
// as ActionId 0 (the first Axis variant in the declaration walk), matching the
// tick-fold determinism fixture. Built on the supplied allocator so the snapshot
// shares the fold/record lifetime.
@(private = "file")
replay_input_at :: proc(tick: int, allocator: Runtime_Allocator) -> Input {
	context.allocator = allocator
	if tick < REPLAY_TICK_COUNT / 2 {
		return with_value(empty(), .P1, ActionId(0), to_fixed(1))
	}
	return empty()
}

// replay_time builds the Time resource the original live fold steps at — the one
// `dt` field at the golden's fixed tick rate (1/tick_hz), the same value the
// replay driver derives. Sharing the derivation is what makes the original run and
// the re-fold step at identical dt, so any divergence is the input source, not the
// clock.
@(private = "file")
replay_time :: proc(tick_hz: int, allocator: Runtime_Allocator) -> Record_Value {
	fields := make(map[string]Value, allocator)
	fields["dt"] = fixed_div(to_fixed(1), to_fixed(i64(tick_hz)))
	return Record_Value{type_name = "Time", fields = fields}
}

// run_live folds the recorded input sequence over the live tick loop — the
// ORIGINAL run the replay must reproduce. It restarts from setup (run_startup) and
// drives step_tick once per tick with the snapshot replay_input_at produces, the
// same seam the replay driver re-folds; the world it returns is the ground truth
// the bit-identity assertion compares against.
@(private = "file")
run_live :: proc(
	program: ^Program,
	tick_count: int,
	allocator := context.allocator,
) -> World_Version {
	world := new_world(program^, allocator)
	version := run_startup(program, initial_version(world, allocator), allocator)
	time := replay_time(program.entrypoint.tick_hz, allocator)
	for tick in 0 ..< tick_count {
		snapshot := replay_input_at(tick, allocator)
		version = step_tick(program, version, snapshot, time, allocator)
	}
	return version
}

// record_session records the SAME input sequence run_live folds into a replay log
// through the production recorder, returning the finished log bytes. The header
// pins the golden's identity (derived from the real artifact bytes), so the log a
// replay re-feeds is the exact byte-stable record the recorder produces.
@(private = "file")
record_session :: proc(
	program: ^Program,
	tick_count: int,
	allocator := context.allocator,
) -> string {
	identity := identity_from_program(program^, GOLDEN_ARTIFACT)
	writer := open_replay_writer(identity, allocator)
	defer delete_replay_writer(&writer)
	for tick in 0 ..< tick_count {
		snapshot := replay_input_at(tick, allocator)
		record_tick(&writer, snapshot, allocator)
	}
	return finish_replay(&writer, allocator)
}

@(test)
test_replay_refolds_to_bit_identical_world :: proc(t: ^testing.T) {
	// A recorded pong session re-folds tick-by-tick to the recorded tick count,
	// supplying the recorded Input each tick, and the world it commits is
	// bit-identical to the original run's (§07 §4, §23 §4). The original run and the
	// replay share only the artifact and the recorded snapshots — the replay
	// substitutes nothing but the input source — so equality proves the re-fold
	// reproduces the run.
	program, ok := load_golden(t)
	if !ok {
		return
	}

	original := run_live(&program, REPLAY_TICK_COUNT, context.temp_allocator)

	log_bytes := record_session(&program, REPLAY_TICK_COUNT, context.temp_allocator)
	log, parse_ok := read_replay(log_bytes, context.temp_allocator)
	if !testing.expect(t, parse_ok) {
		return
	}

	// The driver re-folds the parsed log against the freshly-loaded artifact.
	result := replay(&program, GOLDEN_ARTIFACT, log, context.temp_allocator)
	if !testing.expect_value(t, result.refusal, Replay_Refusal.None) {
		return
	}

	// The replay reached the recorded tick count: run_startup commits the populated
	// base as version tick 0, then each of the N recorded snapshots commits one more
	// version, so the final committed ordinal is the tick count.
	testing.expect_value(t, result.world.tick, REPLAY_TICK_COUNT)

	// The replayed world is bit-identical to the original run's — same tick, same
	// rows in stable Id order, same fixed-point bits.
	testing.expect(t, world_versions_equal(result.world, original))

	// The session is non-trivial: the ball crossed the edge and scored, so the
	// scoring + serve + signal-route paths folded in both the live run and the
	// replay, not just a straight-line ball advance.
	scoreboard, _ := view_at(view_of_type(&result.world, "Scoreboard"), 0)
	left, _ := row_field(scoreboard, "left")
	right, _ := row_field(scoreboard, "right")
	testing.expect(t, left.(i64) + right.(i64) > 0)
}

@(test)
test_replay_refuses_header_hash_mismatch :: proc(t: ^testing.T) {
	// A replay log whose pinned artifact hash differs from the loaded artifact is
	// REFUSED with a diagnostic, not silently re-folded against the wrong build
	// (§09 §5). The log here carries the golden's schema/name/version/tick rate but
	// a content hash from a DIFFERENT build, so only the content-hash field diverges
	// — the gate must still fire, since the hash is the build-specific fingerprint.
	program, ok := load_golden(t)
	if !ok {
		return
	}

	matching := identity_from_program(program, GOLDEN_ARTIFACT)
	// A log recorded against a one-byte-different artifact: every identity field
	// matches the golden EXCEPT the content hash, which is the build fingerprint.
	mismatched := matching
	mismatched.content_hash = matching.content_hash ~ 0x1

	writer := open_replay_writer(mismatched, context.temp_allocator)
	defer delete_replay_writer(&writer)
	snap := with_value(empty(), .P1, ActionId(0), to_fixed(1))
	defer delete_input(snap)
	record_tick(&writer, snap, context.temp_allocator)
	log_bytes := finish_replay(&writer, context.temp_allocator)

	log, parse_ok := read_replay(log_bytes, context.temp_allocator)
	if !testing.expect(t, parse_ok) {
		return
	}

	// replay(artifact_A, log_with_hash_B) refuses with Identity_Mismatch rather than
	// re-folding the recorded snapshot over the wrong program.
	result := replay(&program, GOLDEN_ARTIFACT, log, context.temp_allocator)
	testing.expect_value(t, result.refusal, Replay_Refusal.Identity_Mismatch)

	// The refusal carries a diagnostic naming the mismatch, and folds NO tick — the
	// returned world is the empty zero value, never a partial re-fold.
	testing.expect(t, len(result.diagnostic) > 0)
	testing.expect_value(t, result.world.tick, 0)
	testing.expect_value(t, len(result.world.tables), 0)
}

// --- Seeded re-fold acceptance (§25 §60, §01 §50, §04 §1) ------------------
//
// pong and hunt are SEEDLESS — Input is the sole nondeterminism source (Lore #7) —
// so the golden-pong tests above prove the seedless header/gate/re-fold path. A
// SEEDED program (snake's shape: the tick-0 food cell is drawn from the seed) is
// what proves the seed half of this story. The snake artifact lands in a later
// story, so the seeded program is built by hand here — the same hand-built-node-
// forest strategy the kernel/interp/RNG-threading surface tests use (tick_rng_test
// builds the identical `setup(rng)->(Rng,[Spawn])` + `seed_draw` shape). The
// builders below are this file's own copy (rps_ prefix), so the seedless golden
// tests and the seeded tests share no builder state.

// rps_fields / rps_children clone variadic token/node lists onto the temp arena —
// the node forest is built per test and reclaimed at the test boundary.
@(private = "file")
rps_fields :: proc(tokens: ..string) -> []string {
	out := make([]string, len(tokens), context.temp_allocator)
	copy(out, tokens)
	return out
}

@(private = "file")
rps_children :: proc(nodes: ..Node) -> []Node {
	out := make([]Node, len(nodes), context.temp_allocator)
	copy(out, nodes)
	return out
}

@(private = "file")
rps_int :: proc(value: string) -> Node {
	return Node{kind = .Int, fields = rps_fields(value)}
}

@(private = "file")
rps_name :: proc(ident: string) -> Node {
	return Node{kind = .Name, fields = rps_fields(ident)}
}

// rps_cell_list builds the fixed candidate-cell list `[0, 1, …, n-1]` the draw picks
// from — a deterministic source pool standing in for snake's free-cell set, rendered
// through core:strconv (no hand-rolled itoa).
@(private = "file")
rps_cell_list :: proc(n: int) -> Node {
	cells := make([dynamic]Node, 0, n, context.temp_allocator)
	for i in 0 ..< n {
		buf := make([]u8, 32, context.temp_allocator)
		token := strconv.write_int(buf, i64(i), 10)
		append(&cells, rps_int(strings.clone(token, context.temp_allocator)))
	}
	return Node{kind = .List, children = rps_children(..cells[:])}
}

// rps_mote_spawn builds `Spawn(Mote{cell: <cell_expr>})` — the command-wrapped record
// a draw queues, with cell_expr the bound `cell` name in the Some arm.
@(private = "file")
rps_mote_spawn :: proc(cell_expr: Node) -> Node {
	recfield := Node{kind = .Recfield, fields = rps_fields("cell"), children = rps_children(cell_expr)}
	mote := Node{kind = .Record, fields = rps_fields("Mote", "1"), children = rps_children(recfield)}
	return Node{kind = .Call, children = rps_children(rps_name("Spawn"), mote)}
}

// rps_spawner_spawn builds `Spawn(Spawner{})` — the no-field Spawner spawn setup mints
// so the per-tick behavior has a row to fold over (an ordinary single-instance thing,
// not a singleton).
@(private = "file")
rps_spawner_spawn :: proc() -> Node {
	spawner := Node{kind = .Record, fields = rps_fields("Spawner", "0")}
	return Node{kind = .Call, children = rps_children(rps_name("Spawn"), spawner)}
}

// rps_draw_match builds `match pick(free, rng) { (Some(cell), next) => (next,
// some_spawns); (None, next) => (next, none_spawns) }` — the seeded draw common to
// setup and the per-tick behavior. The matched cell is what the seed selects, so the
// committed spawn depends on the seed.
@(private = "file")
rps_draw_match :: proc(some_spawns, none_spawns: Node) -> Node {
	pick := Node {
		kind     = .Call,
		children = rps_children(rps_name("pick"), rps_name("free"), rps_name("rng")),
	}
	some_pat := Node {
		kind     = .Arm,
		fields   = rps_fields("tuple", "-", "-", "0"),
		children = rps_children(
			Node{kind = .Arm, fields = rps_fields("variant_binds", "Option", "Some", "1", "cell")},
			Node{kind = .Arm, fields = rps_fields("bare_binder", "-", "-", "1", "next")},
		),
	}
	some_body := Node{kind = .Tuple, children = rps_children(rps_name("next"), some_spawns)}
	none_pat := Node {
		kind     = .Arm,
		fields   = rps_fields("tuple", "-", "-", "0"),
		children = rps_children(
			Node{kind = .Arm, fields = rps_fields("variant_binds", "Option", "None", "0")},
			Node{kind = .Arm, fields = rps_fields("bare_binder", "-", "-", "1", "next")},
		),
	}
	none_body := Node{kind = .Tuple, children = rps_children(rps_name("next"), none_spawns)}
	return Node {
		kind     = .Match,
		fields   = rps_fields("2", "5"),
		children = rps_children(pick, some_pat, some_body, none_pat, none_body),
	}
}

@(private = "file")
rps_let_free :: proc(n: int) -> Node {
	return Node{kind = .Let, fields = rps_fields("free"), children = rps_children(rps_cell_list(n))}
}

// rps_seeded_program assembles the whole synthetic seeded program: a setup-spawned
// Spawner (an ordinary single-instance thing, NOT a singleton — a singleton is
// engine-spawned before tick 0 and is never setup-spawned, §08/§13, runtime Lore),
// a Mote thing with a `cell: Int` column, the `seed_draw` per-tick behavior, the
// `setup(rng)->(Rng,[Spawn])` startup body, and a one-step pipeline — the
// snake-shaped seeded fold the seeded re-fold tests record and replay. Every drawn
// cell (setup's first Mote and each tick's Mote) is selected by the threaded Rng, so
// the committed state — and its frame digest — depends on the tick-0 seed.
@(private = "file")
rps_seeded_program :: proc(pool: int) -> Program {
	things := make([]Thing_Decl, 2, context.temp_allocator)
	things[0] = Thing_Decl{name = "Spawner", singleton = false}
	mote_fields := make([]Field_Decl, 1, context.temp_allocator)
	mote_fields[0] = Field_Decl{name = "cell", type = "Int", has_default = true, default_encoded = "0"}
	things[1] = Thing_Decl{name = "Mote", fields = mote_fields}

	setup_some := Node {
		kind     = .List,
		children = rps_children(rps_spawner_spawn(), rps_mote_spawn(rps_name("cell"))),
	}
	setup_none := Node{kind = .List, children = rps_children(rps_spawner_spawn())}
	setup_return := Node{kind = .Return, children = rps_children(rps_draw_match(setup_some, setup_none))}
	setup_body := make([]Node, 2, context.temp_allocator)
	setup_body[0] = rps_let_free(pool)
	setup_body[1] = setup_return

	beh_some := Node{kind = .List, children = rps_children(rps_mote_spawn(rps_name("cell")))}
	beh_none := Node{kind = .List}
	beh_return := Node{kind = .Return, children = rps_children(rps_draw_match(beh_some, beh_none))}
	beh_body := make([]Node, 2, context.temp_allocator)
	beh_body[0] = rps_let_free(pool)
	beh_body[1] = beh_return

	functions := make([]Function_Decl, 1, context.temp_allocator)
	setup_params := make([]Param_Decl, 1, context.temp_allocator)
	setup_params[0] = Param_Decl{name = "rng", type = "Rng"}
	functions[0] = Function_Decl {
		name        = "setup",
		kind        = .Startup,
		params      = setup_params,
		return_type = "(Rng, [Spawn])",
		body        = setup_body,
	}

	behaviors := make([]Behavior_Decl, 1, context.temp_allocator)
	beh_params := make([]Param_Decl, 2, context.temp_allocator)
	beh_params[0] = Param_Decl{name = "self", type = "Spawner"}
	beh_params[1] = Param_Decl{name = "rng", type = "Rng"}
	beh_emits := make([]string, 1, context.temp_allocator)
	beh_emits[0] = "(Rng, [Spawn])"
	behaviors[0] = Behavior_Decl {
		name     = "seed_draw",
		on_thing = "Spawner",
		stage    = "eat",
		params   = beh_params,
		emits    = beh_emits,
		body     = beh_body,
	}

	pipeline := make([]Pipeline_Step, 1, context.temp_allocator)
	pipeline[0] = Pipeline_Step{ordinal = 0, stage = "eat", behavior = "seed_draw"}

	// A name/version/tick_hz so the seeded identity has the same observable shape a
	// real seeded artifact would; the entrypoint tick rate drives replay_time_resource.
	return Program {
		meta       = Project_Meta{name = "seeded", version = "0.1.0"},
		entrypoint = Entrypoint{tick_hz = 60},
		things     = things,
		functions  = functions,
		behaviors  = behaviors,
		pipeline   = pipeline,
	}
}

// rps_seeded_artifact_bytes is a stable byte string standing in for the seeded
// program's artifact bytes — the content hash is over these, so the same string
// pins the same build across the record and the re-fold (the seeded program is
// hand-built, so there are no real artifact bytes to hash).
@(private = "file")
rps_seeded_artifact_bytes :: "funpack-artifact 1\n[meta seeded]\n"

// rps_record_seeded records a seeded session: it runs run_startup_seeded from the
// seed, threads the Rng through step_tick for every tick (empty Input — the seed is
// the nondeterminism source here, not input), and writes a log whose header pins the
// SEEDED identity (identity_from_program_seeded). Empty snapshots are recorded so the
// re-fold re-feeds the same (empty) input stream; the seed is what the gate carries.
@(private = "file")
rps_record_seeded :: proc(
	program: ^Program,
	seed: i64,
	tick_count: int,
	allocator := context.temp_allocator,
) -> string {
	identity := identity_from_program_seeded(program^, rps_seeded_artifact_bytes, seed)
	writer := open_replay_writer(identity, allocator)
	for _ in 0 ..< tick_count {
		record_tick(&writer, empty(), allocator)
	}
	return finish_replay(&writer, allocator)
}

@(test)
test_seeded_header_carries_seed_round_trip :: proc(t: ^testing.T) {
	// A seeded run's recorded header carries the tick-0 seed (§25 §60) and round-trips
	// back to it through the production reader: has_seed is true and the seed value is
	// exactly the one the run started from. A seedless run records has_seed = false —
	// the explicit absence, not a value sentinel — so the two are distinguishable.
	context.allocator = context.temp_allocator
	program := rps_seeded_program(10)

	log_bytes := rps_record_seeded(&program, 42, 4)
	log, parse_ok := read_replay(log_bytes)
	if !testing.expect(t, parse_ok) {
		return
	}
	testing.expect_value(t, log.identity.has_seed, true)
	testing.expect_value(t, log.identity.seed, i64(42))

	// A seedless identity over the same program records has_seed = false, seed 0 — the
	// pong/hunt header shape, encoded to different bytes than the seeded log.
	seedless := identity_from_program(program, rps_seeded_artifact_bytes)
	testing.expect_value(t, seedless.has_seed, false)
	testing.expect_value(t, seedless.seed, i64(0))
}

@(test)
test_seeded_refold_reproduces_committed_state :: proc(t: ^testing.T) {
	// A seeded re-fold STARTS from the recorded seed (run_startup_seeded + the threaded
	// step_tick(&rng)) and reproduces the recorded committed state bit-identically
	// (§25 §60, §01 §50, §04 §1). The re-fold and a fresh live seeded run from the same
	// seed must commit the same world — the seed is re-fed, so every drawn Mote and the
	// seeded setup cell reproduce. The re-fold runs through the production replay driver
	// (identity-gated), not a test-only loop.
	context.allocator = context.temp_allocator
	TICKS :: 4
	SEED :: i64(42)

	record_program := rps_seeded_program(10)
	log_bytes := rps_record_seeded(&record_program, SEED, TICKS)
	log, parse_ok := read_replay(log_bytes)
	if !testing.expect(t, parse_ok) {
		return
	}

	// The independent ground-truth run: a fresh seeded fold from the same seed.
	live_program := rps_seeded_program(10)
	live_world := initial_version(new_world(live_program), context.temp_allocator)
	version, rng := run_startup_seeded(&live_program, live_world, rand_seed(SEED))
	current := rng
	time := golden_seeded_time(live_program.entrypoint.tick_hz)
	for _ in 0 ..< TICKS {
		version = step_tick(&live_program, version, empty(), time, context.temp_allocator, &current)
	}

	// The production re-fold against a freshly-loaded program, started under the SAME
	// seed the log was recorded with — the gate matches and the re-fold re-feeds it.
	refold_program := rps_seeded_program(10)
	result := replay(&refold_program, rps_seeded_artifact_bytes, log, run_seed = seeded_run(SEED))
	if !testing.expect_value(t, result.refusal, Replay_Refusal.None) {
		return
	}

	// The re-fold reached the recorded tick count and committed a world bit-identical
	// to the independent seeded run — the seed was re-fed, so the run reproduced.
	testing.expect_value(t, result.world.tick, TICKS)
	testing.expect(t, world_versions_equal(result.world, version))

	// The fold actually drew and spawned: setup spawns one seeded Mote, each tick spawns
	// one more — so the committed Mote population is non-trivial and seed-dependent.
	motes := view_of_type(&result.world, "Mote")
	testing.expect_value(t, view_count(motes), TICKS + 1)
}

@(test)
test_seeded_log_refuses_different_seed :: proc(t: ^testing.T) {
	// A log recorded under one seed REFUSES to re-fold against a run started under a
	// different seed (§09 §5, §25 §60): the seed is recorded determinism input, so a
	// seed change yields a different recorded identity. The log's header carries seed
	// 42; the loaded run's identity carries seed 99, so the gate fires Identity_Mismatch
	// and folds NO tick — the seed change is caught exactly as a build change would be.
	context.allocator = context.temp_allocator
	program := rps_seeded_program(10)

	// The log is recorded under seed 42; the re-fold is started under seed 99. The gate
	// compares the recorded seed against the run's seed, so the seed change is refused.
	log_bytes := rps_record_seeded(&program, 42, 4)
	log, parse_ok := read_replay(log_bytes)
	if !testing.expect(t, parse_ok) {
		return
	}

	result := replay(&program, rps_seeded_artifact_bytes, log, run_seed = seeded_run(99))
	testing.expect_value(t, result.refusal, Replay_Refusal.Identity_Mismatch)
	testing.expect(t, len(result.diagnostic) > 0)
	testing.expect_value(t, result.world.tick, 0)
}

@(test)
test_seedless_log_refuses_seeded_run :: proc(t: ^testing.T) {
	// A SEEDLESS log refuses to re-fold against a SEEDED run and vice versa — the
	// has_seed boolean is part of the gate, so "seedless" and "seeded with 0" are
	// distinct identities (§25 §60). The recorded identity here is seedless; the loaded
	// run carries a seed, so the gate refuses even though every build field matches.
	context.allocator = context.temp_allocator
	program := rps_seeded_program(10)

	// Record with a SEEDLESS identity (has_seed = false), then re-fold demanding a seed.
	identity := identity_from_program(program, rps_seeded_artifact_bytes)
	writer := open_replay_writer(identity)
	record_tick(&writer, empty())
	log_bytes := finish_replay(&writer)
	log, parse_ok := read_replay(log_bytes)
	if !testing.expect(t, parse_ok) {
		return
	}

	// The recorded log is seedless; the run is started under seed 0. has_seed differs,
	// so the gate refuses even though every build field matches and the seed VALUE is 0
	// — "seedless" and "seeded with 0" are distinct identities.
	result := replay(&program, rps_seeded_artifact_bytes, log, run_seed = seeded_run(0))
	testing.expect_value(t, result.refusal, Replay_Refusal.Identity_Mismatch)
}

// golden_seeded_time builds the Time resource the seeded live run and the re-fold
// both step at — the one `dt` field at the program's fixed tick rate (1/tick_hz in
// Q32.32, no float), the same value replay_time_resource derives. Sharing the
// derivation is what makes the live seeded run and the seeded re-fold step at
// identical dt, so any digest divergence would be the seed source, not the clock.
@(private = "file")
golden_seeded_time :: proc(tick_hz: int, allocator := context.temp_allocator) -> Record_Value {
	fields := make(map[string]Value, allocator)
	fields["dt"] = fixed_div(to_fixed(1), to_fixed(i64(tick_hz)))
	return Record_Value{type_name = "Time", fields = fields}
}
