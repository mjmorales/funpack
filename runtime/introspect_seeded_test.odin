package funpack_runtime

import "core:fmt"
import "core:strings"
import "core:testing"

@(private = "file")
SEEDED_SESSION_SEED :: i64(42)

@(private = "file")
SEEDED_SESSION_TICKS :: 16

@(private = "file")
SEEDED_MOVE_DOWN :: ActionId(1)

@(private = "file")
SEEDED_TURN_TICK :: 6

@(private = "file")
seeded_session_inputs :: proc(allocator := context.allocator) -> []Input {
	inputs := make([]Input, SEEDED_SESSION_TICKS, allocator)
	for i in 0 ..< SEEDED_SESSION_TICKS {
		inputs[i] = i == SEEDED_TURN_TICK ? with_pressed(empty(), .P1, SEEDED_MOVE_DOWN) : empty()
	}
	return inputs
}

@(private = "file")
seeded_snake_session :: proc(
	t: ^testing.T,
	allocator := context.allocator,
) -> (
	program: ^Program,
	inputs: []Input,
	session: Debug_Session,
) {
	program = new(Program, allocator)
	loaded, err := load_program(GOLDEN_SNAKE_ARTIFACT, allocator)
	testing.expect(t, err == .None, "golden snake artifact must load")
	program^ = loaded
	inputs = seeded_session_inputs(allocator)
	session = open_debug_session(program, inputs, seeded_run(SEEDED_SESSION_SEED), allocator)
	return program, inputs, session
}

@(private = "file")
seeded_reference_fold :: proc(
	program: ^Program,
	inputs: []Input,
	seed: i64,
	allocator := context.allocator,
) -> (
	capture: Frame_Capture,
	final: World_Version,
	rngs: []Rng,
) {
	world := new_world(program^, allocator)
	base := initial_version(world, allocator)
	version, current := run_startup_seeded(program, base, rand_seed(seed), allocator)
	tick_hz := program.entrypoint.tick_hz
	rngs = make([]Rng, len(inputs) + 1, allocator)
	per_tick := make([dynamic]Frame_Digest, 0, len(inputs), allocator)
	for snapshot, i in inputs {
		rngs[i] = current
		time := time_resource_at(tick_hz, i, allocator)
		version = step_tick(program, version, snapshot, time, allocator, &current)
		draw := render_version(program, version, snapshot, time, allocator)
		append(&per_tick, capture_frame(version, draw, allocator))
	}
	rngs[len(inputs)] = current
	return finish_capture(per_tick[:], allocator), version, rngs
}

@(private = "file")
seeded_rng_draw_tick :: proc(rngs: []Rng) -> (tick: int, ok: bool) {
	for i in 0 ..< len(rngs) - 1 {
		if rngs[i + 1].state != rngs[i].state {
			return i, true
		}
	}
	return 0, false
}

@(test)
test_introspect_seeded_session_retains_rng_chain :: proc(t: ^testing.T) {
	program, inputs, session := seeded_snake_session(t)
	s := session
	_, _, reference := seeded_reference_fold(program, inputs, SEEDED_SESSION_SEED)

	if !testing.expect_value(t, len(s.rngs), len(inputs) + 1) {
		return
	}
	for rng, i in reference {
		testing.expect_value(t, s.rngs[i].state, rng.state)
	}
	_, drew := seeded_rng_draw_tick(reference)
	testing.expect(t, drew, "the scripted seeded run must consume the Rng (the eat tick's replenish draw)")
}

@(test)
test_introspect_seeded_refold_tick_reproduces_committed :: proc(t: ^testing.T) {
	program, inputs, session := seeded_snake_session(t)
	s := session
	_, _, reference := seeded_reference_fold(program, inputs, SEEDED_SESSION_SEED)
	eat_tick, drew := seeded_rng_draw_tick(reference)
	if !testing.expect(t, drew, "the seeded run must have an RNG-drawing tick to re-fold") {
		return
	}

	obs := new_tick_observe()
	committed, ok := session_refold_tick(&s, eat_tick, &obs)
	if !testing.expect(t, ok, "the eat tick must re-fold") {
		return
	}
	testing.expect(
		t,
		world_versions_equal(committed, s.versions[eat_tick]),
		"the seeded re-fold must reproduce the retained committed version — the retained rngs[tick] is the entering state",
	)
}

@(test)
test_introspect_seeded_observe_non_perturbing_digest_pin :: proc(t: ^testing.T) {
	program, inputs, session := seeded_snake_session(t)
	s := session
	baseline, baseline_final, reference := seeded_reference_fold(program, inputs, SEEDED_SESSION_SEED)
	eat_tick, drew := seeded_rng_draw_tick(reference)
	if !testing.expect(t, drew, "the seeded run must have an RNG-drawing tick to observe") {
		return
	}

	battery := [?]string {
		`{"id":1,"cmd":"pipeline"}`,
		fmt.tprintf(`{{"id":2,"cmd":"signals","args":{{"tick":%d}}}}`, eat_tick),
		fmt.tprintf(`{{"id":3,"cmd":"trace","args":{{"tick":%d,"behavior":"replenish"}}}}`, eat_tick),
		fmt.tprintf(`{{"id":4,"cmd":"diff","args":{{"from":%d,"to":%d}}}}`, eat_tick - 1, eat_tick),
		fmt.tprintf(`{{"id":5,"cmd":"replay_behavior","args":{{"tick":%d,"behavior":"advance"}}}}`, eat_tick),
		`{"id":6,"cmd":"draw_list","args":{"tick":0}}`,
		fmt.tprintf(`{{"id":7,"cmd":"draw_list","args":{{"tick":%d}}}}`, len(inputs) - 1),
	}
	for request, i in battery {
		response := session_request(&s, request)
		testing.expect(t, strings.contains(response, `"ok":true`), "every seeded observe in the battery must succeed")
		if i == 1 {
			testing.expect(
				t,
				strings.contains(response, `"signal":"Eaten"`),
				"the eat tick's re-fold must route the Eaten signal",
			)
		}
	}

	observed := session_capture(&s)
	if !testing.expect_value(t, len(observed.per_tick), len(baseline.per_tick)) {
		return
	}
	for frame, i in observed.per_tick {
		testing.expect_value(t, frame.tick, baseline.per_tick[i].tick)
		testing.expect_value(t, frame.digest, baseline.per_tick[i].digest)
	}
	testing.expect_value(t, observed.session, baseline.session)
	testing.expect(
		t,
		world_versions_equal(s.versions[len(s.versions) - 1], baseline_final),
		"the observed seeded session's final committed world must equal the unobserved run's",
	)
}

@(test)
test_control_seeded_fork_rng_matches_canonical :: proc(t: ^testing.T) {
	program, inputs, session := seeded_snake_session(t)
	s := session
	_, _, reference := seeded_reference_fold(program, inputs, SEEDED_SESSION_SEED)
	eat_tick, drew := seeded_rng_draw_tick(reference)
	if !testing.expect(t, drew, "the seeded run must have an RNG-drawing tick to fork before") {
		return
	}
	if !testing.expect(t, eat_tick > 0 && eat_tick != SEEDED_TURN_TICK, "the eat tick must be an empty-input tick") {
		return
	}

	fork_tick := eat_tick - 1
	forked := session_request(&s, fmt.tprintf(`{{"id":1,"cmd":"branch","args":{{"tick":%d}}}}`, fork_tick))
	testing.expect(t, strings.contains(forked, `"ok":true`), "the seeded fork must succeed")
	testing.expect(t, s.has_branch, "the branch must be live")
	testing.expect(t, s.branch.has_rng, "a seeded session's branch must carry a forked Rng thread")
	testing.expect_value(t, s.branch.rng.state, reference[fork_tick + 1].state)

	stepped := session_request(&s, `{"id":2,"cmd":"inject_input","args":{"ticks":1}}`)
	testing.expect(t, strings.contains(stepped, `"ok":true`), "the branch fold must succeed")
	testing.expect(
		t,
		world_versions_equal(s.branch.head, s.versions[eat_tick]),
		"one branch fold over the recorded empty snapshot must reproduce the canonical eat tick — RNG-drawn food included",
	)
	testing.expect_value(t, s.branch.rng.state, reference[eat_tick + 1].state)
	testing.expect(
		t,
		s.branch.rng.state != reference[eat_tick].state,
		"the eat tick's replenish draw must advance the branch Rng",
	)
}

@(test)
test_control_seeded_battery_canonical_digest_pinned :: proc(t: ^testing.T) {
	program, inputs, session := seeded_snake_session(t)
	s := session
	baseline, baseline_final, reference := seeded_reference_fold(program, inputs, SEEDED_SESSION_SEED)
	eat_tick, drew := seeded_rng_draw_tick(reference)
	if !testing.expect(t, drew, "the seeded run must have an RNG-drawing tick to fork before") {
		return
	}

	battery := [?]string {
		fmt.tprintf(`{{"id":1,"cmd":"branch","args":{{"tick":%d}}}}`, eat_tick - 1),
		`{"id":2,"cmd":"inject_input","args":{"ticks":3,"pressed":[{"player":"P1","action":"Move::Down"}]}}`,
		`{"id":3,"cmd":"set","args":{"thing":"Snake","instance":0,"field":"head","value":"Cell(x=1,y=1)"}}`,
	}
	for request in battery {
		response := session_request(&s, request)
		testing.expect(t, strings.contains(response, `"ok":true`), "every seeded control in the battery must succeed")
		testing.expect(t, strings.contains(response, `"warranted":false`), "every seeded control lineage is non-warranted")
	}

	rng_before_emit := s.branch.rng.state
	emitted := session_request(&s, `{"id":4,"cmd":"emit","args":{"signal":"Eaten","value":"Eaten(cell=Cell(x=1,y=1))"}}`)
	testing.expect(t, strings.contains(emitted, `"ok":true`), "the seeded emit must succeed")
	testing.expect(
		t,
		s.branch.rng.state != rng_before_emit,
		"the emitted Eaten must force a replenish draw that advances the branch Rng",
	)

	testing.expect(
		t,
		!world_versions_equal(s.branch.head, s.versions[len(s.versions) - 1]),
		"the seeded control battery must have perturbed the branch",
	)

	controlled := session_capture(&s)
	if !testing.expect_value(t, len(controlled.per_tick), len(baseline.per_tick)) {
		return
	}
	for frame, i in controlled.per_tick {
		testing.expect_value(t, frame.tick, baseline.per_tick[i].tick)
		testing.expect_value(t, frame.digest, baseline.per_tick[i].digest)
	}
	testing.expect_value(t, controlled.session, baseline.session)
	testing.expect(
		t,
		world_versions_equal(s.versions[len(s.versions) - 1], baseline_final),
		"the controlled seeded session's canonical final world must equal the untouched run's",
	)
}
