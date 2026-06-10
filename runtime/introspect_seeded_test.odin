// §28 SEEDED-session acceptance: the observe/control session contract proven
// UNDER A RECORDED SEED — the determinism input the seedless pong batteries
// (introspect_test.odin / introspect_control_test.odin) never exercise. The
// fixture is the golden snake artifact under its pinned seed 42, whose
// replenish behavior draws a replacement food from the threaded Rng on the eat
// tick — so every assertion below rides a run where the RNG visibly enters
// committed state. Four seeded paths are pinned:
//
//   - RNG RETENTION (open_debug_session's seeded arm): the session's retained
//     per-boundary Rng chain (rngs[i] = the state ENTERING tick i) is bit-exact
//     against an independent reference fold of the same seeded run;
//   - OBSERVE RE-FOLD UNDER SEED (session_refold_tick's rngs[tick] feed): the
//     eat tick re-folds in isolation to a committed version value-identical to
//     the retained canonical one — a wrong entering Rng would replace the food
//     in a different cell — and the full observe battery leaves the canonical
//     seeded chain digest-pinned against an unobserved seeded reference run;
//   - FORK RNG HANDOFF (fork_branch's rngs[tick + 1]): a branch forked at the
//     tick BEFORE the eat carries the canonical entering-Rng of the next tick
//     bit-exact, and one branch fold over the recorded (empty) snapshot
//     reproduces the canonical eat tick — including the RNG-drawn replacement
//     food — value-identically;
//   - BRANCH RNG THREADING (inject_input's and emit's has_rng arms): a control
//     battery on the seeded branch advances the branch Rng (an emitted Eaten
//     forces a replenish draw) while the canonical seeded chain stays
//     digest-pinned bit-identical to an untouched reference fold.
package funpack_runtime

import "core:fmt"
import "core:strings"
import "core:testing"

// SEEDED_SESSION_SEED is the golden snake run's pinned tick-0 seed — the same
// value the committed replay fixture records, so the session folds the exact
// canonical run the acceptance suite already warrants.
@(private = "file")
SEEDED_SESSION_SEED :: i64(42)

// SEEDED_SESSION_TICKS mirrors the golden scripted session length: long enough
// that the snake eats the seed-spawned food, firing the RNG-drawing replenish.
@(private = "file")
SEEDED_SESSION_TICKS :: 16

// SEEDED_MOVE_DOWN is snake's Move::Down Button action (ActionId 1 in the
// deterministic enum walk — Up=0, Down=1, Left=2, Right=3).
@(private = "file")
SEEDED_MOVE_DOWN :: ActionId(1)

// SEEDED_TURN_TICK is the one tick the scripted session presses Move::Down,
// steering the snake from its rightward run onto the seed-spawned food.
@(private = "file")
SEEDED_TURN_TICK :: 6

// seeded_session_inputs rebuilds the golden snake scripted session (six ticks
// Right by default heading, then one Down press) — the recorded snapshots the
// seeded session opens over. Every tick except the turn tick is empty input,
// which is what lets the fork test replay a recorded tick through an empty
// inject_input.
@(private = "file")
seeded_session_inputs :: proc(allocator := context.allocator) -> []Input {
	inputs := make([]Input, SEEDED_SESSION_TICKS, allocator)
	for i in 0 ..< SEEDED_SESSION_TICKS {
		inputs[i] = i == SEEDED_TURN_TICK ? with_pressed(empty(), .P1, SEEDED_MOVE_DOWN) : empty()
	}
	return inputs
}

// seeded_snake_session loads the golden snake artifact and opens a SEEDED
// session over the scripted run — the shared opener every seeded test folds from.
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

// seeded_reference_fold folds the seeded run with NO session and NO observe tap
// — run_startup_seeded + step_tick(&rng) through the same per-tick Time
// derivation the session opener binds — capturing per-tick digests, the final
// committed version, AND the Rng entering every tick boundary (rngs[i] enters
// tick i; rngs[n] is the final state). It is the independent ground truth the
// retention, refold, fork, and digest-pin assertions all compare against.
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

// seeded_rng_draw_tick finds the first tick whose fold actually consumed the
// Rng (the entering state of the NEXT boundary differs) — the eat tick, where
// replenish draws the replacement food. Derived from the reference chain, not
// the session's, so the tests never trust the code under test for it.
@(private = "file")
seeded_rng_draw_tick :: proc(rngs: []Rng) -> (tick: int, ok: bool) {
	for i in 0 ..< len(rngs) - 1 {
		if rngs[i + 1].state != rngs[i].state {
			return i, true
		}
	}
	return 0, false
}

// The seeded open retains the per-boundary Rng chain BIT-EXACT: rngs[i] equals
// the reference fold's state entering tick i for every boundary, including the
// final state — and the chain actually advances somewhere (the eat tick's
// replenish draw), so the equality is not vacuous.
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

// session_refold_tick feeds the RETAINED entering-Rng (rngs[tick]) into the
// isolated re-fold: re-folding the eat tick — the tick whose commit carries an
// RNG-drawn food cell — reproduces the retained committed version
// value-identically. A wrong entering Rng would draw the replacement food into
// a different cell and the version comparison would fail.
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

// THE SEEDED OBSERVE ACCEPTANCE — observation is non-perturbing UNDER SEED: a
// full observe battery (pipeline, signals/trace on the RNG-drawing eat tick,
// diff across it, replay_behavior, draw_list) over the seeded snake session
// leaves the canonical chain digest-pinned bit-identical to a seeded run nobody
// observed — per-tick digests, session digest, and the final committed world.
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
		// The eat-tick signals observe must surface the routed Eaten — the
		// seeded dataflow rendered as data, proving the re-fold ran the real tick.
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

// THE SEEDED FORK ACCEPTANCE — fork_branch hands the branch the canonical
// entering-Rng of the NEXT tick (rngs[tick + 1]) bit-exact, and the branch fold
// threads it: forked at the tick BEFORE the eat, one empty inject_input fold
// (the recorded snapshot is empty there) reproduces the canonical eat tick
// value-identically — replacement food cell included, which only the correct
// Rng can draw — and leaves the branch Rng at the canonical next boundary.
@(test)
test_control_seeded_fork_rng_matches_canonical :: proc(t: ^testing.T) {
	program, inputs, session := seeded_snake_session(t)
	s := session
	_, _, reference := seeded_reference_fold(program, inputs, SEEDED_SESSION_SEED)
	eat_tick, drew := seeded_rng_draw_tick(reference)
	if !testing.expect(t, drew, "the seeded run must have an RNG-drawing tick to fork before") {
		return
	}
	// The fold replays the recorded snapshot via an empty inject_input, so the
	// eat tick must not be the one scripted press (it is tick 9 vs the turn's 6).
	if !testing.expect(t, eat_tick > 0 && eat_tick != SEEDED_TURN_TICK, "the eat tick must be an empty-input tick") {
		return
	}

	fork_tick := eat_tick - 1
	forked := session_request(&s, fmt.tprintf(`{{"id":1,"cmd":"branch","args":{{"tick":%d}}}}`, fork_tick))
	testing.expect(t, strings.contains(forked, `"ok":true`), "the seeded fork must succeed")
	testing.expect(t, s.has_branch, "the branch must be live")
	testing.expect(t, s.branch.has_rng, "a seeded session's branch must carry a forked Rng thread")
	// The fork's Rng is the canonical state entering fork_tick + 1 — BIT-EXACT
	// against the independent reference chain, so the branch's first draw is
	// exactly what the canonical next tick would have drawn.
	testing.expect_value(t, s.branch.rng.state, reference[fork_tick + 1].state)

	stepped := session_request(&s, `{"id":2,"cmd":"inject_input","args":{"ticks":1}}`)
	testing.expect(t, strings.contains(stepped, `"ok":true`), "the branch fold must succeed")
	testing.expect(
		t,
		world_versions_equal(s.branch.head, s.versions[eat_tick]),
		"one branch fold over the recorded empty snapshot must reproduce the canonical eat tick — RNG-drawn food included",
	)
	// The fold consumed the retained Rng and threaded the advance back: the
	// branch sits at the canonical entering state of the boundary AFTER the eat,
	// which the draw moved off the fork-time state.
	testing.expect_value(t, s.branch.rng.state, reference[eat_tick + 1].state)
	testing.expect(
		t,
		s.branch.rng.state != reference[eat_tick].state,
		"the eat tick's replenish draw must advance the branch Rng",
	)
}

// THE SEEDED CONTROL ACCEPTANCE — control on a seeded branch perturbs ONLY the
// branch: a battery (explicit mid-run fork, seeded inject_input folds, a forced
// set, an emitted Eaten that forces a replenish draw through the branch Rng)
// leaves the canonical SEEDED chain digest-pinned bit-identical to an untouched
// reference fold, while the branch demonstrably diverged and its Rng advanced.
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

	// The emitted Eaten pre-routes into the branch tick's mailbox, so replenish
	// draws — through the branch's threaded Rng, never the canonical chain's.
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
