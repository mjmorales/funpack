package funpack_runtime

import "core:strconv"
import "core:strings"
import "core:testing"

@(private = "file")
sr_fields :: proc(tokens: ..string) -> []string {
	out := make([]string, len(tokens), context.temp_allocator)
	copy(out, tokens)
	return out
}

@(private = "file")
sr_children :: proc(nodes: ..Node) -> []Node {
	out := make([]Node, len(nodes), context.temp_allocator)
	copy(out, nodes)
	return out
}

@(private = "file")
sr_int :: proc(value: string) -> Node {
	return Node{kind = .Int, fields = sr_fields(value)}
}

@(private = "file")
sr_name :: proc(ident: string) -> Node {
	return Node{kind = .Name, fields = sr_fields(ident)}
}

@(private = "file")
sr_cell_list :: proc(n: int) -> Node {
	cells := make([dynamic]Node, 0, n, context.temp_allocator)
	for i in 0 ..< n {
		buf := make([]u8, 32, context.temp_allocator)
		token := strconv.write_int(buf, i64(i), 10)
		append(&cells, sr_int(strings.clone(token, context.temp_allocator)))
	}
	return Node{kind = .List, children = sr_children(..cells[:])}
}

@(private = "file")
sr_mote_spawn :: proc(cell_expr: Node) -> Node {
	recfield := Node{kind = .Recfield, fields = sr_fields("cell"), children = sr_children(cell_expr)}
	mote := Node {
		kind     = .Record,
		fields   = sr_fields("Mote", "1"),
		children = sr_children(recfield),
	}
	spawn_callee := sr_name("Spawn")
	return Node{kind = .Call, children = sr_children(spawn_callee, mote)}
}

@(private = "file")
sr_spawner_spawn :: proc() -> Node {
	spawner := Node{kind = .Record, fields = sr_fields("Spawner", "0")}
	return Node{kind = .Call, children = sr_children(sr_name("Spawn"), spawner)}
}

@(private = "file")
sr_draw_match :: proc(some_spawns, none_spawns: Node) -> Node {
	pick := Node {
		kind     = .Call,
		children = sr_children(sr_name("pick"), sr_name("rng"), sr_name("free")),
	}

	some_pat := Node {
		kind     = .Arm,
		fields   = sr_fields("tuple", "-", "-", "0"),
		children = sr_children(
			Node{kind = .Arm, fields = sr_fields("variant_binds", "Option", "Some", "1", "cell")},
			Node{kind = .Arm, fields = sr_fields("bare_binder", "-", "-", "1", "next")},
		),
	}
	some_body := Node{kind = .Tuple, children = sr_children(sr_name("next"), some_spawns)}

	none_pat := Node {
		kind     = .Arm,
		fields   = sr_fields("tuple", "-", "-", "0"),
		children = sr_children(
			Node{kind = .Arm, fields = sr_fields("variant_binds", "Option", "None", "0")},
			Node{kind = .Arm, fields = sr_fields("bare_binder", "-", "-", "1", "next")},
		),
	}
	none_body := Node{kind = .Tuple, children = sr_children(sr_name("next"), none_spawns)}

	return Node {
		kind     = .Match,
		fields   = sr_fields("2", "5"),
		children = sr_children(pick, some_pat, some_body, none_pat, none_body),
	}
}

@(private = "file")
sr_let_free :: proc(n: int) -> Node {
	return Node{kind = .Let, fields = sr_fields("free"), children = sr_children(sr_cell_list(n))}
}

@(private = "file")
seeded_draw_program :: proc(pool: int) -> Program {
	things := make([]Thing_Decl, 2, context.temp_allocator)
	things[0] = Thing_Decl{name = "Spawner", singleton = false}
	mote_fields := make([]Field_Decl, 1, context.temp_allocator)
	mote_fields[0] = Field_Decl{name = "cell", type = "Int", has_default = true, default_encoded = "0"}
	things[1] = Thing_Decl{name = "Mote", fields = mote_fields}

	setup_some := Node {
		kind     = .List,
		children = sr_children(sr_spawner_spawn(), sr_mote_spawn(sr_name("cell"))),
	}
	setup_none := Node{kind = .List, children = sr_children(sr_spawner_spawn())}
	setup_return := Node {
		kind     = .Return,
		children = sr_children(sr_draw_match(setup_some, setup_none)),
	}
	setup_body := make([]Node, 2, context.temp_allocator)
	setup_body[0] = sr_let_free(pool)
	setup_body[1] = setup_return

	beh_some := Node{kind = .List, children = sr_children(sr_mote_spawn(sr_name("cell")))}
	beh_none := Node{kind = .List}
	beh_return := Node {
		kind     = .Return,
		children = sr_children(sr_draw_match(beh_some, beh_none)),
	}
	beh_body := make([]Node, 2, context.temp_allocator)
	beh_body[0] = sr_let_free(pool)
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
		things    = things,
		functions = functions,
		behaviors = behaviors,
		pipeline  = pipeline,
	}
}

@(private = "file")
sr_run :: proc(
	program: ^Program,
	seed: i64,
	ticks: int,
	allocator := context.temp_allocator,
) -> (
	final: World_Version,
	rng: Rng,
) {
	world := new_world(program^, allocator)
	base := initial_version(world, allocator)
	version, threaded := run_startup_seeded(program, base, rand_seed(seed), allocator)
	current := threaded
	for _ in 0 ..< ticks {
		version = step_tick(program, version, empty(), Record_Value{}, allocator, &current)
	}
	return version, current
}

@(test)
test_seeded_draw_two_ticks_deterministic :: proc(t: ^testing.T) {
	program := seeded_draw_program(10)

	first, first_rng := sr_run(&program, 42, 2, context.temp_allocator)
	second, second_rng := sr_run(&program, 42, 2, context.temp_allocator)

	testing.expect(t, world_versions_equal(first, second))
	testing.expect_value(t, first_rng.state, second_rng.state)

	motes := view_of_type(&first, "Mote")
	testing.expect_value(t, view_count(motes), 3)
	testing.expect_value(t, view_count(view_of_type(&first, "Spawner")), 1)
}

@(test)
test_seeded_draw_seed_change_diverges :: proc(t: ^testing.T) {
	program := seeded_draw_program(10)

	seed42, _ := sr_run(&program, 42, 2, context.temp_allocator)
	seed7, _ := sr_run(&program, 7, 2, context.temp_allocator)

	testing.expect(t, !world_versions_equal(seed42, seed7))
}

@(test)
test_seeded_draw_rng_threads_forward :: proc(t: ^testing.T) {
	program := seeded_draw_program(10)
	_, run_rng := sr_run(&program, 42, 2, context.temp_allocator)

	hand := rand_seed(42)
	for _ in 0 ..< 3 {
		_, hand = rand_bounded(hand, 10)
	}
	testing.expect_value(t, run_rng.state, hand.state)

	testing.expect(t, run_rng.state != rand_seed(42).state)
}

@(test)
test_seeded_draw_cells_follow_golden_order :: proc(t: ^testing.T) {
	program := seeded_draw_program(10)
	final, _ := sr_run(&program, 42, 2, context.temp_allocator)

	motes := view_of_type(&final, "Mote")
	testing.expect_value(t, view_count(motes), 3)

	for i in 0 ..< 3 {
		row, _ := view_at(motes, i)
		cell, present := row_field(row, "cell")
		testing.expect(t, present)
		testing.expect_value(t, cell.(i64), i64(RAND_SEED_42_BOUNDED_10[i]))
	}
}

@(test)
test_seeded_draw_empty_pool_threads_but_spawns_nothing :: proc(t: ^testing.T) {
	program := seeded_draw_program(0)
	final, run_rng := sr_run(&program, 42, 2, context.temp_allocator)

	testing.expect_value(t, view_count(view_of_type(&final, "Mote")), 0)
	hand := rand_seed(42)
	for _ in 0 ..< 3 {
		_, hand = rand_next(hand)
	}
	testing.expect_value(t, run_rng.state, hand.state)
}

@(private = "file")
per_tick_rng_program :: proc(pool: int) -> Program {
	things := make([]Thing_Decl, 2, context.temp_allocator)
	things[0] = Thing_Decl{name = "Spawner", singleton = false}
	mote_fields := make([]Field_Decl, 1, context.temp_allocator)
	mote_fields[0] = Field_Decl{name = "cell", type = "Int", has_default = true, default_encoded = "0"}
	things[1] = Thing_Decl{name = "Mote", fields = mote_fields}

	setup_return := Node {
		kind     = .Return,
		children = sr_children(Node{kind = .List, children = sr_children(sr_spawner_spawn())}),
	}
	setup_body := make([]Node, 1, context.temp_allocator)
	setup_body[0] = setup_return

	beh_some := Node{kind = .List, children = sr_children(sr_mote_spawn(sr_name("cell")))}
	beh_none := Node{kind = .List}
	beh_return := Node{kind = .Return, children = sr_children(sr_draw_match(beh_some, beh_none))}
	beh_body := make([]Node, 2, context.temp_allocator)
	beh_body[0] = sr_let_free(pool)
	beh_body[1] = beh_return

	functions := make([]Function_Decl, 1, context.temp_allocator)
	functions[0] = Function_Decl {
		name        = "setup",
		kind        = .Startup,
		return_type = "[Spawn]",
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

	return Program{things = things, functions = functions, behaviors = behaviors, pipeline = pipeline}
}

@(private = "file")
pr_run :: proc(
	program: ^Program,
	seed: i64,
	ticks: int,
	allocator := context.temp_allocator,
) -> (
	final: World_Version,
	rng: Rng,
) {
	world := new_world(program^, allocator)
	base := initial_version(world, allocator)
	version, current := run_startup_rooted(program, base, seed, allocator)
	for _ in 0 ..< ticks {
		version = step_tick(program, version, empty(), Record_Value{}, allocator, &current)
	}
	return version, current
}

@(test)
test_per_tick_rng_seedless_setup_folds :: proc(t: ^testing.T) {
	program := per_tick_rng_program(10)

	testing.expect(t, program_uses_rng(&program))
	testing.expect(t, !program_is_seeded(&program))

	final, _ := pr_run(&program, 42, 2, context.temp_allocator)

	testing.expect_value(t, view_count(view_of_type(&final, "Spawner")), 1)
	testing.expect_value(t, view_count(view_of_type(&final, "Mote")), 2)
}

@(test)
test_per_tick_rng_seedless_setup_deterministic :: proc(t: ^testing.T) {
	program := per_tick_rng_program(10)

	first, first_rng := pr_run(&program, 42, 2, context.temp_allocator)
	second, second_rng := pr_run(&program, 42, 2, context.temp_allocator)
	testing.expect(t, world_versions_equal(first, second))
	testing.expect_value(t, first_rng.state, second_rng.state)

	other, _ := pr_run(&program, 7, 2, context.temp_allocator)
	testing.expect(t, !world_versions_equal(first, other))
}

@(test)
test_run_startup_rooted_routes_by_setup_seeding :: proc(t: ^testing.T) {
	seeded := seeded_draw_program(10)
	sworld := new_world(seeded, context.temp_allocator)
	sbase := initial_version(sworld, context.temp_allocator)
	rooted_v, rooted_rng := run_startup_rooted(&seeded, sbase, 42, context.temp_allocator)

	seeded2 := seeded_draw_program(10)
	s2world := new_world(seeded2, context.temp_allocator)
	s2base := initial_version(s2world, context.temp_allocator)
	ref_v, ref_rng := run_startup_seeded(&seeded2, s2base, rand_seed(42), context.temp_allocator)
	testing.expect(t, world_versions_equal(rooted_v, ref_v))
	testing.expect_value(t, rooted_rng.state, ref_rng.state)
	testing.expect(t, rooted_rng.state != rand_seed(42).state)

	pertick := per_tick_rng_program(10)
	pworld := new_world(pertick, context.temp_allocator)
	pbase := initial_version(pworld, context.temp_allocator)
	prooted_v, prooted_rng := run_startup_rooted(&pertick, pbase, 42, context.temp_allocator)

	pertick2 := per_tick_rng_program(10)
	p2world := new_world(pertick2, context.temp_allocator)
	p2base := initial_version(p2world, context.temp_allocator)
	bare_v := run_startup(&pertick2, p2base, context.temp_allocator)
	testing.expect(t, world_versions_equal(prooted_v, bare_v))
	testing.expect_value(t, prooted_rng.state, rand_seed(42).state)
}

@(test)
test_program_is_seeded_keys_on_rng_param :: proc(t: ^testing.T) {
	snake, snake_err := load_program(GOLDEN_SNAKE_ARTIFACT, context.temp_allocator)
	testing.expect(t, snake_err == .None)
	testing.expect(t, program_is_seeded(&snake))

	yard, yard_err := load_program(YARD_ARTIFACT, context.temp_allocator)
	testing.expect(t, yard_err == .None)
	testing.expect(t, !program_is_seeded(&yard))

	pong, pong_err := load_program(GOLDEN_ARTIFACT, context.temp_allocator)
	testing.expect(t, pong_err == .None)
	testing.expect(t, !program_is_seeded(&pong))
}

@(test)
test_run_startup_seeded_non_tuple_body_falls_back_to_batch :: proc(t: ^testing.T) {
	program, err := load_program(YARD_ARTIFACT, context.temp_allocator)
	testing.expect(t, err == .None)

	world := new_world(program, context.temp_allocator)
	base := initial_version(world, context.temp_allocator)
	version, rng := run_startup_seeded(&program, base, rand_seed(42), context.temp_allocator)

	testing.expect_value(t, view_count(view_of_type(&version, "Wall")), 4)
	testing.expect_value(t, view_count(view_of_type(&version, "Pad")), 1)
	testing.expect_value(t, view_count(view_of_type(&version, "Player")), 1)
	testing.expect_value(t, view_count(view_of_type(&version, "Crate")), 3)
	testing.expect_value(t, rng.state, rand_seed(42).state)

	bare_world := new_world(program, context.temp_allocator)
	bare := run_startup(&program, initial_version(bare_world, context.temp_allocator), context.temp_allocator)
	testing.expect(t, world_versions_equal(version, bare))
}
