// §28 control-session acceptance: every control command (inject_input / set /
// spawn / emit / reload / branch) forks the session onto a branch and perturbs
// ONLY the branch — the canonical committed chain stays bit-untouched, proven
// with a digest pin: a full control battery over the golden pong session leaves
// the canonical per-tick digests, session digest, and final committed world
// equal to an untouched reference fold, while the branch head demonstrably
// diverges. The §28 §1 observe/control theorem made mechanical: control is the
// CQRS write side, debug-only and outside the warranted path, which is exactly
// why it forks.
package funpack_runtime

import "core:strings"
import "core:testing"

// CONTROL_FIXTURE_A is the running build for the reload test — the same
// one-behavior advance-by-1.0 shape the observe fixture uses.
@(private = "file")
CONTROL_FIXTURE_A :: "funpack-artifact 17\n" +
	"[meta 2]\n" +
	"project ctl\n" +
	"version L5:0.1.0\n" +
	"[things 1]\n" +
	"thing Hero false 0 1\n" +
	"field pos Fixed =0\n" +
	"[behaviors 1]\n" +
	"behavior advance on:Hero stage:control contract:Update 0 1 1 1\n" +
	"param self Hero\n" +
	"emit Hero\n" +
	"node return 1\n" +
	"node with 1 2\n" +
	"node name self 0\n" +
	"node recfield pos 1\n" +
	"node binary add 2\n" +
	"node field pos 1\n" +
	"node name self 0\n" +
	"node fixed 4294967296 0\n" +
	"[pipeline_flattened 1]\n" +
	"step 0 stage:control behavior:advance\n" +
	"[setup 1]\n" +
	"spawn Hero 0\n" +
	"[entrypoint 1]\n" +
	"entrypoint main pipeline:Ctl tick_hz:60 logical:160x120 bindings:bindings\n"

// CONTROL_FIXTURE_B is the recompiled build: identical schema (no migration
// delta), advance body changed to 2.0/tick — so a post-reload branch tick
// proves the behavior re-resolved to the NEW body.
@(private = "file")
CONTROL_FIXTURE_B :: "funpack-artifact 17\n" +
	"[meta 2]\n" +
	"project ctl\n" +
	"version L5:0.2.0\n" +
	"[things 1]\n" +
	"thing Hero false 0 1\n" +
	"field pos Fixed =0\n" +
	"[behaviors 1]\n" +
	"behavior advance on:Hero stage:control contract:Update 0 1 1 1\n" +
	"param self Hero\n" +
	"emit Hero\n" +
	"node return 1\n" +
	"node with 1 2\n" +
	"node name self 0\n" +
	"node recfield pos 1\n" +
	"node binary add 2\n" +
	"node field pos 1\n" +
	"node name self 0\n" +
	"node fixed 8589934592 0\n" +
	"[pipeline_flattened 1]\n" +
	"step 0 stage:control behavior:advance\n" +
	"[setup 1]\n" +
	"spawn Hero 0\n" +
	"[entrypoint 1]\n" +
	"entrypoint main pipeline:Ctl tick_hz:60 logical:160x120 bindings:bindings\n"

// pong_control_session opens a control-test session over `ticks` empty-input
// pong ticks — short canonical runs the branch perturbations diverge from.
@(private = "file")
pong_control_session :: proc(
	t: ^testing.T,
	ticks: int,
	allocator := context.allocator,
) -> (
	program: ^Program,
	session: Debug_Session,
) {
	program = new(Program, allocator)
	loaded, err := load_program(GOLDEN_ARTIFACT, allocator)
	testing.expect(t, err == .None, "golden pong artifact must load")
	program^ = loaded
	inputs := make([]Input, ticks, allocator)
	for i in 0 ..< ticks {
		inputs[i] = empty()
	}
	session = open_debug_session(program, inputs, NO_SEED, allocator)
	return program, session
}

// branch_row reads one row's blackboard off the branch head — the branch-side
// assertion surface (the tests read the package struct directly; the wire
// surface for branch state is a later observe extension).
@(private = "file")
branch_row :: proc(s: ^Debug_Session, thing: string, raw: Thing_Id) -> (row: Row, ok: bool) {
	head := s.branch.head
	table := version_find_table(&head, thing)
	if table == nil {
		return {}, false
	}
	idx, found := find_row_by_id(table.rows, Id{raw = raw})
	if !found {
		return {}, false
	}
	return table.rows[idx], true
}

// canonical_row reads one row's blackboard off the canonical head, for the
// branch-vs-trunk divergence assertions.
@(private = "file")
canonical_row :: proc(s: ^Debug_Session, thing: string, raw: Thing_Id) -> (row: Row, ok: bool) {
	head := s.versions[len(s.versions) - 1]
	table := version_find_table(&head, thing)
	if table == nil {
		return {}, false
	}
	idx, found := find_row_by_id(table.rows, Id{raw = raw})
	if !found {
		return {}, false
	}
	return table.rows[idx], true
}

// inject_input feeds the §23 action-snapshot path on the branch: P2 steering
// down for three branch ticks moves the right paddle exactly as a live device
// would have, while the canonical (idle) paddle never moves.
@(test)
test_control_inject_input_feeds_snapshot_path :: proc(t: ^testing.T) {
	_, session := pong_control_session(t, 5)
	s := session
	response := session_request(
		&s,
		`{"id":1,"cmd":"inject_input","args":{"ticks":3,"values":[{"player":"P2","action":"Steer::Move","value":"4294967296"}]}}`,
	)
	testing.expect(t, strings.contains(response, `"ok":true`), "inject_input must succeed")
	testing.expect(t, strings.contains(response, `"warranted":false`), "a control response is non-warranted")
	testing.expect(t, s.has_branch, "a control command must fork a branch")
	testing.expect_value(t, s.branch.base_tick, 4)
	testing.expect_value(t, s.branch.ticks, 3)

	branch_paddle, branch_ok := branch_row(&s, "Paddle", 1)
	canonical_paddle, canonical_ok := canonical_row(&s, "Paddle", 1)
	testing.expect(t, branch_ok && canonical_ok, "both paddles must resolve")
	branch_y, _ := row_field(branch_paddle, "y")
	canonical_y, _ := row_field(canonical_paddle, "y")
	testing.expect(
		t,
		!field_values_equal(branch_y, canonical_y),
		"the injected steer must move the branch paddle off the idle canonical one",
	)
}

// set forces a blackboard column on the branch through the ordinary boundary
// transaction; the canonical row keeps its committed value.
@(test)
test_control_set_forces_branch_field :: proc(t: ^testing.T) {
	_, session := pong_control_session(t, 3)
	s := session
	response := session_request(
		&s,
		`{"id":2,"cmd":"set","args":{"thing":"Ball","instance":0,"field":"pos","value":"Vec2(x=0,y=0)"}}`,
	)
	testing.expect(t, strings.contains(response, `"ok":true`), "set must succeed")

	ball, ok := branch_row(&s, "Ball", 0)
	testing.expect(t, ok, "the branch ball must resolve")
	pos, _ := row_field(ball, "pos")
	vec, is_vec := pos.(Vec2)
	testing.expect(t, is_vec, "pos must stay a Vec2 column")
	testing.expect_value(t, i64(vec.x), 0)
	testing.expect_value(t, i64(vec.y), 0)

	canonical_ball, _ := canonical_row(&s, "Ball", 0)
	canonical_pos, _ := row_field(canonical_ball, "pos")
	testing.expect(
		t,
		!field_values_equal(pos, canonical_pos),
		"the canonical ball must keep its committed position",
	)
}

// spawn mints a new instance on the branch through the ordinary tick-boundary
// batch — the canonical population is untouched, and the minted Id is answered.
@(test)
test_control_spawn_adds_branch_row :: proc(t: ^testing.T) {
	_, session := pong_control_session(t, 3)
	s := session
	response := session_request(
		&s,
		`{"id":3,"cmd":"spawn","args":{"thing":"Ball","fields":{"pos":"Vec2(x=0,y=0)","vel":"Vec2(x=4294967296,y=0)"}}}`,
	)
	testing.expect(t, strings.contains(response, `"ok":true`), "spawn must succeed")
	testing.expect(t, strings.contains(response, `"instance":1`), "the minted Id must be answered")

	head := s.branch.head
	branch_table := version_find_table(&head, "Ball")
	testing.expect_value(t, len(branch_table.rows), 2)
	canonical := s.versions[len(s.versions) - 1]
	canonical_table := version_find_table(&canonical, "Ball")
	testing.expect_value(t, len(canonical_table.rows), 1)
}

// emit injects a Goal on the branch and folds a pipeline tick over it: pong's
// tally consumer reads the injected signal exactly as a produced one, so the
// branch Scoreboard counts a goal the canonical run never saw.
@(test)
test_control_emit_routes_to_consumer :: proc(t: ^testing.T) {
	_, session := pong_control_session(t, 3)
	s := session
	response := session_request(
		&s,
		`{"id":4,"cmd":"emit","args":{"signal":"Goal","value":"Goal(side=Side::Left)"}}`,
	)
	testing.expect(t, strings.contains(response, `"ok":true`), "emit must succeed")

	board, ok := branch_row(&s, "Scoreboard", 0)
	testing.expect(t, ok, "the branch scoreboard must resolve")
	left, _ := row_field(board, "left")
	right, _ := row_field(board, "right")
	total := left.(i64) + right.(i64)
	testing.expect_value(t, total, 1)

	canonical_board, _ := canonical_row(&s, "Scoreboard", 0)
	canonical_left, _ := row_field(canonical_board, "left")
	canonical_right, _ := row_field(canonical_board, "right")
	testing.expect_value(t, canonical_left.(i64) + canonical_right.(i64), 0)
}

// reload swaps the BRANCH onto a recompiled artifact through hot_reload_swap:
// the post-reload branch tick advances by build B's 2.0 (the behavior
// re-resolved), a refused reload keeps the last-good branch untouched, and the
// canonical chain stays on build A throughout.
@(test)
test_control_reload_swaps_branch_program :: proc(t: ^testing.T) {
	program := new(Program)
	loaded, err := load_program(CONTROL_FIXTURE_A)
	testing.expect(t, err == .None, "fixture A must load")
	program^ = loaded
	inputs := make([]Input, 2)
	for i in 0 ..< 2 {
		inputs[i] = empty()
	}
	s := open_debug_session(program, inputs, NO_SEED)

	// A refused reload (garbage artifact) keeps the branch untouched.
	refused := session_request(&s, `{"id":5,"cmd":"reload","args":{"artifact":"not an artifact"}}`)
	testing.expect(t, strings.contains(refused, `"ok":false`), "a garbage artifact must refuse")
	testing.expect(t, strings.contains(refused, "reload refused"), "the refusal names the gate")
	head_before := s.branch.head

	// Build the reload request with the artifact JSON-escaped through the same
	// writer the envelope uses.
	b := strings.builder_make()
	strings.write_string(&b, `{"id":6,"cmd":"reload","args":{"artifact":`)
	write_json_string(&b, CONTROL_FIXTURE_B)
	strings.write_string(&b, `}}`)
	response := session_request(&s, strings.to_string(b))
	testing.expect(t, strings.contains(response, `"ok":true`), "the recompiled artifact must swap")
	testing.expect(t, strings.contains(response, `"swapped":true`), "the swap is answered")
	testing.expect(
		t,
		world_versions_equal(s.branch.head, head_before),
		"a no-delta migration keeps the branch state value-identical",
	)

	// One post-swap branch tick advances by build B's 2.0, from the canonical
	// head's pos of 2.0 (two A-folded ticks) to 4.0.
	stepped := session_request(&s, `{"id":7,"cmd":"inject_input","args":{"ticks":1}}`)
	testing.expect(t, strings.contains(stepped, `"ok":true`), "the post-swap tick must fold")
	hero, ok := branch_row(&s, "Hero", 0)
	testing.expect(t, ok, "the branch hero must resolve")
	pos, _ := row_field(hero, "pos")
	testing.expect_value(t, i64(pos.(Fixed)), i64(4) << 32)

	// The canonical chain stayed on build A: pos after 2 ticks is 2.0.
	canonical_hero, _ := canonical_row(&s, "Hero", 0)
	canonical_pos, _ := row_field(canonical_hero, "pos")
	testing.expect_value(t, i64(canonical_pos.(Fixed)), i64(2) << 32)
}

// Control refusals answer ok:false and leave the branch exactly where it was.
@(test)
test_control_refusals_leave_branch_untouched :: proc(t: ^testing.T) {
	_, session := pong_control_session(t, 3)
	s := session
	opened := session_request(&s, `{"id":8,"cmd":"branch"}`)
	testing.expect(t, strings.contains(opened, `"ok":true`), "the explicit fork must succeed")
	head_before := s.branch.head
	ticks_before := s.branch.ticks

	cases := [?]string {
		`{"id":9,"cmd":"set","args":{"thing":"Nope","instance":0,"field":"pos","value":"0"}}`,
		`{"id":10,"cmd":"set","args":{"thing":"Ball","instance":0,"field":"nope","value":"0"}}`,
		`{"id":11,"cmd":"set","args":{"thing":"Ball","instance":7,"field":"pos","value":"Vec2(x=0,y=0)"}}`,
		`{"id":12,"cmd":"spawn","args":{"thing":"Nope"}}`,
		`{"id":13,"cmd":"emit","args":{"signal":"Goal","value":"12"}}`,
		`{"id":14,"cmd":"inject_input","args":{"values":[{"player":"P9","action":"Steer::Move","value":"0"}]}}`,
		`{"id":15,"cmd":"inject_input","args":{"values":[{"player":"P1","action":"Nope::Nope","value":"0"}]}}`,
		`{"id":16,"cmd":"branch","args":{"tick":99}}`,
	}
	for request in cases {
		response := session_request(&s, request)
		testing.expect(t, strings.contains(response, `"ok":false`), "a refused control answers ok:false")
	}
	testing.expect(
		t,
		world_versions_equal(s.branch.head, head_before),
		"a refused control must leave the branch head untouched",
	)
	testing.expect_value(t, s.branch.ticks, ticks_before)
}

// control_reference_capture folds the golden run untouched — the canonical
// ground truth the digest pin compares the controlled session against.
@(private = "file")
control_reference_capture :: proc(
	program: ^Program,
	inputs: []Input,
	allocator := context.allocator,
) -> (
	capture: Frame_Capture,
	final: World_Version,
) {
	world := new_world(program^, allocator)
	version := run_startup(program, initial_version(world, allocator), allocator)
	tick_hz := program.entrypoint.tick_hz
	per_tick := make([dynamic]Frame_Digest, 0, len(inputs), allocator)
	for snapshot, i in inputs {
		time := time_resource_at(tick_hz, i, allocator)
		version = step_tick(program, version, snapshot, time, allocator)
		draw := render_version(program, version, snapshot, time, allocator)
		append(&per_tick, capture_frame(version, draw, allocator))
	}
	return finish_capture(per_tick[:], allocator), version
}

// THE STORY ACCEPTANCE — control forks, the canonical run is untouched: a full
// control battery (explicit branch, inject_input, set, spawn, emit) over the
// golden pong session leaves the canonical chain digest-pinned bit-identical to
// an untouched reference fold (per-tick digests, session digest,
// world_versions_equal on the final commit), while the branch head demonstrably
// diverged. §28 §2: the trunk recording is never mutated; "what if?" is a
// git-like fork.
@(test)
test_control_fork_canonical_digest_pinned :: proc(t: ^testing.T) {
	program := new(Program)
	loaded, err := load_program(GOLDEN_ARTIFACT)
	testing.expect(t, err == .None, "golden pong artifact must load")
	program^ = loaded
	inputs := golden_session_inputs()
	s := open_debug_session(program, inputs, NO_SEED)
	baseline, baseline_final := control_reference_capture(program, inputs)

	battery := [?]string {
		`{"id":1,"cmd":"branch","args":{"tick":100}}`,
		`{"id":2,"cmd":"inject_input","args":{"ticks":5,"values":[{"player":"P2","action":"Steer::Move","value":"4294967296"}]}}`,
		`{"id":3,"cmd":"set","args":{"thing":"Ball","instance":0,"field":"pos","value":"Vec2(x=0,y=0)"}}`,
		`{"id":4,"cmd":"spawn","args":{"thing":"Paddle","fields":{"player":"PlayerId::P3","side":"Side::Left","x":"0","y":"0","speed":"0"}}}`,
		`{"id":5,"cmd":"emit","args":{"signal":"Goal","value":"Goal(side=Side::Right)"}}`,
	}
	for request in battery {
		response := session_request(&s, request)
		testing.expect(t, strings.contains(response, `"ok":true`), "every control in the battery must succeed")
		testing.expect(t, strings.contains(response, `"warranted":false`), "every control lineage is non-warranted")
	}
	testing.expect_value(t, s.branch.base_tick, 100)
	testing.expect(
		t,
		!world_versions_equal(s.branch.head, s.versions[len(s.versions) - 1]),
		"the control battery must have perturbed the branch",
	)

	controlled := session_capture(&s)
	testing.expect_value(t, len(controlled.per_tick), len(baseline.per_tick))
	for frame, i in controlled.per_tick {
		testing.expect_value(t, frame.tick, baseline.per_tick[i].tick)
		testing.expect_value(t, frame.digest, baseline.per_tick[i].digest)
	}
	testing.expect_value(t, controlled.session, baseline.session)
	testing.expect(
		t,
		world_versions_equal(s.versions[len(s.versions) - 1], baseline_final),
		"the controlled session's canonical final world must equal the untouched run's",
	)
}
