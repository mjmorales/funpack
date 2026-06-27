package funpack_runtime

import "core:strconv"
import "core:strings"
import "core:testing"

@(private = "file")
REPLAY_TICK_COUNT :: 600

@(private = "file")
replay_input_at :: proc(tick: int, allocator: Runtime_Allocator) -> Input {
	context.allocator = allocator
	if tick < REPLAY_TICK_COUNT / 2 {
		return with_value(empty(), .P1, ActionId(0), to_fixed(1))
	}
	return empty()
}

@(private = "file")
replay_time :: proc(tick_hz: int, allocator: Runtime_Allocator) -> Record_Value {
	return time_resource(tick_hz, allocator)
}

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

	result := replay(&program, GOLDEN_ARTIFACT, log, context.temp_allocator)
	if !testing.expect_value(t, result.refusal, Replay_Refusal.None) {
		return
	}

	testing.expect_value(t, result.world.tick, REPLAY_TICK_COUNT)

	testing.expect(t, world_versions_equal(result.world, original))

	scoreboard, _ := view_at(view_of_type(&result.world, "Scoreboard"), 0)
	left, _ := row_field(scoreboard, "left")
	right, _ := row_field(scoreboard, "right")
	testing.expect(t, left.(i64) + right.(i64) > 0)
}

@(test)
test_replay_refuses_header_hash_mismatch :: proc(t: ^testing.T) {
	program, ok := load_golden(t)
	if !ok {
		return
	}

	matching := identity_from_program(program, GOLDEN_ARTIFACT)
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

	result := replay(&program, GOLDEN_ARTIFACT, log, context.temp_allocator)
	testing.expect_value(t, result.refusal, Replay_Refusal.Identity_Mismatch)

	testing.expect(t, len(result.diagnostic) > 0)
	testing.expect_value(t, result.world.tick, 0)
	testing.expect_value(t, len(result.world.tables), 0)
}

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

@(private = "file")
rps_mote_spawn :: proc(cell_expr: Node) -> Node {
	recfield := Node{kind = .Recfield, fields = rps_fields("cell"), children = rps_children(cell_expr)}
	mote := Node{kind = .Record, fields = rps_fields("Mote", "1"), children = rps_children(recfield)}
	return Node{kind = .Call, children = rps_children(rps_name("Spawn"), mote)}
}

@(private = "file")
rps_spawner_spawn :: proc() -> Node {
	spawner := Node{kind = .Record, fields = rps_fields("Spawner", "0")}
	return Node{kind = .Call, children = rps_children(rps_name("Spawn"), spawner)}
}

@(private = "file")
rps_draw_match :: proc(some_spawns, none_spawns: Node) -> Node {
	pick := Node {
		kind     = .Call,
		children = rps_children(rps_name("pick"), rps_name("rng"), rps_name("free")),
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

	return Program {
		meta       = Project_Meta{name = "seeded", version = "0.1.0"},
		entrypoint = Entrypoint{tick_hz = 60},
		things     = things,
		functions  = functions,
		behaviors  = behaviors,
		pipeline   = pipeline,
	}
}

@(private = "file")
rps_seeded_artifact_bytes :: "funpack-artifact 1\n[meta seeded]\n"

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
	context.allocator = context.temp_allocator
	program := rps_seeded_program(10)

	log_bytes := rps_record_seeded(&program, 42, 4)
	log, parse_ok := read_replay(log_bytes)
	if !testing.expect(t, parse_ok) {
		return
	}
	testing.expect_value(t, log.identity.has_seed, true)
	testing.expect_value(t, log.identity.seed, i64(42))

	seedless := identity_from_program(program, rps_seeded_artifact_bytes)
	testing.expect_value(t, seedless.has_seed, false)
	testing.expect_value(t, seedless.seed, i64(0))
}

@(test)
test_seeded_refold_reproduces_committed_state :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	TICKS :: 4
	SEED :: i64(42)

	record_program := rps_seeded_program(10)
	log_bytes := rps_record_seeded(&record_program, SEED, TICKS)
	log, parse_ok := read_replay(log_bytes)
	if !testing.expect(t, parse_ok) {
		return
	}

	live_program := rps_seeded_program(10)
	live_world := initial_version(new_world(live_program), context.temp_allocator)
	version, rng := run_startup_seeded(&live_program, live_world, rand_seed(SEED))
	current := rng
	time := golden_seeded_time(live_program.entrypoint.tick_hz)
	for _ in 0 ..< TICKS {
		version = step_tick(&live_program, version, empty(), time, context.temp_allocator, &current)
	}

	refold_program := rps_seeded_program(10)
	result := replay(&refold_program, rps_seeded_artifact_bytes, log, run_seed = seeded_run(SEED))
	if !testing.expect_value(t, result.refusal, Replay_Refusal.None) {
		return
	}

	testing.expect_value(t, result.world.tick, TICKS)
	testing.expect(t, world_versions_equal(result.world, version))

	motes := view_of_type(&result.world, "Mote")
	testing.expect_value(t, view_count(motes), TICKS + 1)
}

@(test)
test_seeded_log_refuses_different_seed :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	program := rps_seeded_program(10)

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
	context.allocator = context.temp_allocator
	program := rps_seeded_program(10)

	identity := identity_from_program(program, rps_seeded_artifact_bytes)
	writer := open_replay_writer(identity)
	record_tick(&writer, empty())
	log_bytes := finish_replay(&writer)
	log, parse_ok := read_replay(log_bytes)
	if !testing.expect(t, parse_ok) {
		return
	}

	result := replay(&program, rps_seeded_artifact_bytes, log, run_seed = seeded_run(0))
	testing.expect_value(t, result.refusal, Replay_Refusal.Identity_Mismatch)
}

@(private = "file")
golden_seeded_time :: proc(tick_hz: int, allocator := context.temp_allocator) -> Record_Value {
	return time_resource(tick_hz, allocator)
}
