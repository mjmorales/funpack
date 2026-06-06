// Per-tick RNG-threading acceptance (spec §04 §1, §07 §4, §26, §10): a synthetic
// seeded-draw program — the shape snake's `replenish` + `setup` take — folds two
// ticks deterministically through the SAME run_startup_seeded + step_tick seam the
// production loop drives. The proof is two-fold and is THIS story's scoped floor:
//
//   1. DETERMINISM — re-running from the same seed + the same per-tick fold produces
//      bit-identical committed state every run (the seeded population, every drawn
//      Mote, and the final Rng all reproduce). A seed CHANGE diverges, so the seed is
//      a genuine determinism input.
//   2. THREADING — the Rng is advanced FORWARD across draws within and across ticks:
//      each draw's next_rng is what the next draw observes (the fold-forward order
//      §07 §4 enforces), never silently re-seeded. The advanced Rng read back at each
//      tick boundary equals the kernel sequence threaded by hand.
//
// The artifact does not exist yet (it lands in wave 4), so the program is built by
// hand — the same hand-built-node-forest strategy the kernel/interp surface tests
// use. The program is `setup(rng) -> (Rng,[Spawn])` spawning a Spawner singleton +
// one seeded Mote, and a `seed_draw on Spawner` behavior `(self, rng) -> (Rng,[Spawn])`
// that draws a cell and spawns a Mote each tick.
package funpack_runtime

import "core:strconv"
import "core:strings"
import "core:testing"

// --- synthetic-program node builders (file-private) ------------------------

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

// sr_int builds an `int` literal node.
@(private = "file")
sr_int :: proc(value: string) -> Node {
	return Node{kind = .Int, fields = sr_fields(value)}
}

// sr_name builds a `name` reference node.
@(private = "file")
sr_name :: proc(ident: string) -> Node {
	return Node{kind = .Name, fields = sr_fields(ident)}
}

// sr_cell_list builds the fixed candidate-cell list `[0, 1, …, n-1]` the draw picks
// from — a deterministic source pool standing in for snake's free-cell set. Each
// element's `int` token is rendered through core:strconv (no hand-rolled itoa).
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

// sr_mote_spawn builds `Spawn(Mote{cell: <cell_expr>})` — the command-wrapped record
// a draw queues. cell_expr is the bound `cell` name in the Some arm.
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

// sr_spawner_spawn builds `Spawn(Spawner{})` — the no-field singleton spawn setup
// mints so the per-tick behavior has a row to fold over.
@(private = "file")
sr_spawner_spawn :: proc() -> Node {
	spawner := Node{kind = .Record, fields = sr_fields("Spawner", "0")}
	return Node{kind = .Call, children = sr_children(sr_name("Spawn"), spawner)}
}

// sr_draw_match builds the body match common to setup and the behavior:
//   match pick(free, rng) {
//     (Option::Some(cell), next) => (next, <some_spawns>)
//     (Option::None, next)       => (next, [])
//   }
// some_spawns is the `[Spawn …]` list for the hit arm; the miss arm spawns nothing.
@(private = "file")
sr_draw_match :: proc(some_spawns, none_spawns: Node) -> Node {
	// Scrutinee: pick(free, rng).
	pick := Node {
		kind     = .Call,
		children = sr_children(sr_name("pick"), sr_name("free"), sr_name("rng")),
	}

	// Some arm pattern: tuple( variant_binds Option Some 1 cell , bare_binder - - 1 next ).
	some_pat := Node {
		kind     = .Arm,
		fields   = sr_fields("tuple", "-", "-", "0"),
		children = sr_children(
			Node{kind = .Arm, fields = sr_fields("variant_binds", "Option", "Some", "1", "cell")},
			Node{kind = .Arm, fields = sr_fields("bare_binder", "-", "-", "1", "next")},
		),
	}
	// Some arm body: (next, some_spawns).
	some_body := Node{kind = .Tuple, children = sr_children(sr_name("next"), some_spawns)}

	// None arm pattern: tuple( variant_binds Option None 0 , bare_binder - - 1 next ).
	none_pat := Node {
		kind     = .Arm,
		fields   = sr_fields("tuple", "-", "-", "0"),
		children = sr_children(
			Node{kind = .Arm, fields = sr_fields("variant_binds", "Option", "None", "0")},
			Node{kind = .Arm, fields = sr_fields("bare_binder", "-", "-", "1", "next")},
		),
	}
	// None arm body: (next, none_spawns).
	none_body := Node{kind = .Tuple, children = sr_children(sr_name("next"), none_spawns)}

	return Node {
		kind     = .Match,
		fields   = sr_fields("2", "5"),
		children = sr_children(pick, some_pat, some_body, none_pat, none_body),
	}
}

// sr_let_free builds `let free = [0..<n]` — the candidate pool bound before the draw.
@(private = "file")
sr_let_free :: proc(n: int) -> Node {
	return Node{kind = .Let, fields = sr_fields("free"), children = sr_children(sr_cell_list(n))}
}

// seeded_draw_program assembles the whole synthetic program: a Spawner singleton, a
// Mote thing with a `cell: Int` column, the `seed_draw` per-tick behavior, the setup
// startup body, and a one-step pipeline. Built entirely from hand node forests so the
// fold runs the real interpreter without an artifact.
@(private = "file")
seeded_draw_program :: proc(pool: int) -> Program {
	// --- things: Spawner (singleton, no columns) + Mote (cell: Int) ---
	things := make([]Thing_Decl, 2, context.temp_allocator)
	things[0] = Thing_Decl{name = "Spawner", singleton = true}
	mote_fields := make([]Field_Decl, 1, context.temp_allocator)
	mote_fields[0] = Field_Decl{name = "cell", type = "Int", has_default = true, default_encoded = "0"}
	things[1] = Thing_Decl{name = "Mote", fields = mote_fields}

	// --- setup body: let free; return match pick(free,rng) { … } ---
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

	// --- behavior body: let free; return match pick(free,rng) { … } ---
	beh_some := Node{kind = .List, children = sr_children(sr_mote_spawn(sr_name("cell")))}
	beh_none := Node{kind = .List} // empty [] spawn list on the None arm
	beh_return := Node {
		kind     = .Return,
		children = sr_children(sr_draw_match(beh_some, beh_none)),
	}
	beh_body := make([]Node, 2, context.temp_allocator)
	beh_body[0] = sr_let_free(pool)
	beh_body[1] = beh_return

	// --- functions: the Startup setup body ---
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

	// --- behaviors: seed_draw on Spawner ---
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

	// --- pipeline: one executed step running seed_draw ---
	pipeline := make([]Pipeline_Step, 1, context.temp_allocator)
	pipeline[0] = Pipeline_Step{ordinal = 0, stage = "eat", behavior = "seed_draw"}

	return Program {
		things    = things,
		functions = functions,
		behaviors = behaviors,
		pipeline  = pipeline,
	}
}

// sr_run runs setup (seeded) then n ticks, returning the final committed version and
// the final advanced Rng — the closed seeded fold the determinism assertion repeats.
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

// --- acceptance: deterministic seeded fold ---------------------------------

// A synthetic seeded-draw program folds two ticks deterministically: two independent
// runs from the SAME seed produce a bit-identical committed world AND an identical
// final Rng — the determinism floor (§07 §4, §04 §1). The seed drives every draw, so
// reproducing the seed reproduces the whole run.
@(test)
test_seeded_draw_two_ticks_deterministic :: proc(t: ^testing.T) {
	program := seeded_draw_program(10)

	first, first_rng := sr_run(&program, 42, 2, context.temp_allocator)
	second, second_rng := sr_run(&program, 42, 2, context.temp_allocator)

	testing.expect(t, world_versions_equal(first, second))
	testing.expect_value(t, first_rng.state, second_rng.state)

	// The fold actually drew and spawned: setup spawns one Mote (seeded), each of the
	// two ticks spawns one more — three Motes after two ticks, plus the Spawner.
	motes := view_of_type(&first, "Mote")
	testing.expect_value(t, view_count(motes), 3)
	testing.expect_value(t, view_count(view_of_type(&first, "Spawner")), 1)
}

// A DIFFERENT seed yields a DIFFERENT committed world — so the seed is a genuine
// determinism input, not ambient: changing it changes the recorded run identity. The
// drawn cells diverge, so at least one Mote's cell differs run-to-run.
@(test)
test_seeded_draw_seed_change_diverges :: proc(t: ^testing.T) {
	program := seeded_draw_program(10)

	seed42, _ := sr_run(&program, 42, 2, context.temp_allocator)
	seed7, _ := sr_run(&program, 7, 2, context.temp_allocator)

	// Same shape (3 Motes), different drawn cells — the worlds are NOT bit-identical.
	testing.expect(t, !world_versions_equal(seed42, seed7))
}

// The Rng is THREADED FORWARD across draws within and across ticks: the final Rng a
// run reports equals the seed advanced once per draw (setup + one per tick), threaded
// by hand through the kernel — proving no draw silently re-seeds and the next draw
// observes the prior draw's next_rng (§04 §1, fold-forward order §07 §4).
@(test)
test_seeded_draw_rng_threads_forward :: proc(t: ^testing.T) {
	program := seeded_draw_program(10)
	_, run_rng := sr_run(&program, 42, 2, context.temp_allocator)

	// Hand-thread the kernel: one draw in setup, one per tick = three draws total.
	// Each pick over a 10-element list advances by exactly one rand_bounded step.
	hand := rand_seed(42)
	for _ in 0 ..< 3 {
		_, hand = rand_bounded(hand, 10)
	}
	testing.expect_value(t, run_rng.state, hand.state)

	// The threaded Rng is NOT the seed (it advanced) — a positive divergence guard so
	// a no-op threading bug (returning the seed unchanged) is caught.
	testing.expect(t, run_rng.state != rand_seed(42).state)
}

// The drawn cells follow the GOLDEN bounded sequence: setup draws index 0 of the
// seed-42 stream, tick 1 draws index 1, tick 2 draws index 2 — so each Mote's cell is
// pinned to the kernel's bit-exact draw order, not a hand-guessed value. This is the
// observable that ties the fold's draw order to the deterministic flattened-pipeline
// order (§07 §4): the draws happen in setup-then-tick order, one per fold step.
@(test)
test_seeded_draw_cells_follow_golden_order :: proc(t: ^testing.T) {
	program := seeded_draw_program(10)
	final, _ := sr_run(&program, 42, 2, context.temp_allocator)

	motes := view_of_type(&final, "Mote")
	testing.expect_value(t, view_count(motes), 3)

	// The pool is [0..<10] and pick selects pool[index] == index, so each Mote's cell
	// IS the bounded index for its draw. Rows are Id-ascending in spawn order: setup's
	// Mote (Id 0), tick-1's (Id 1), tick-2's (Id 2) — draws 0,1,2 of the golden stream.
	for i in 0 ..< 3 {
		row, _ := view_at(motes, i)
		cell, present := row_field(row, "cell")
		testing.expect(t, present)
		testing.expect_value(t, cell.(i64), i64(RAND_SEED_42_BOUNDED_10[i]))
	}
}

// The None arm threads the Rng too: with an EMPTY candidate pool every draw misses,
// spawns nothing, yet the Rng still advances each fold step — a draw is never a silent
// no-op (§04 §1). After two ticks no Mote was spawned (None each time) but the Rng
// advanced three times (setup + two ticks).
@(test)
test_seeded_draw_empty_pool_threads_but_spawns_nothing :: proc(t: ^testing.T) {
	program := seeded_draw_program(0) // empty candidate pool → always the None arm
	final, run_rng := sr_run(&program, 42, 2, context.temp_allocator)

	// No Mote ever spawned — every draw took the None arm.
	testing.expect_value(t, view_count(view_of_type(&final, "Mote")), 0)
	// Yet the Rng advanced once per draw (empty pick advances via rand_next).
	hand := rand_seed(42)
	for _ in 0 ..< 3 {
		_, hand = rand_next(hand)
	}
	testing.expect_value(t, run_rng.state, hand.state)
}
