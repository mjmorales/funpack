package funpack_runtime

import "core:fmt"
import "core:strings"
import "core:testing"

@(private = "file")
CONTROL_FIXTURE_A :: "funpack-artifact 19\n" +
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

@(private = "file")
CONTROL_FIXTURE_B :: "funpack-artifact 19\n" +
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

@(test)
test_control_set_accepts_source_literal_vec2 :: proc(t: ^testing.T) {
	_, session := pong_control_session(t, 3)
	s := session
	response := session_request(
		&s,
		`{"id":2,"cmd":"set","args":{"thing":"Ball","instance":0,"field":"pos","value":"Vec2(x=2.0,y=104.0)"}}`,
	)
	testing.expect(t, strings.contains(response, `"ok":true`), response)

	ball, ok := branch_row(&s, "Ball", 0)
	testing.expect(t, ok, "the branch ball must resolve")
	pos, _ := row_field(ball, "pos")
	vec, is_vec := pos.(Vec2)
	testing.expect(t, is_vec, "pos must stay a Vec2 column")
	testing.expect_value(t, i64(vec.x), i64(to_fixed(2)))
	testing.expect_value(t, i64(vec.y), i64(to_fixed(104)))
}

@(test)
test_control_set_accepts_source_literal_scalar :: proc(t: ^testing.T) {
	_, session := pong_control_session(t, 3)
	s := session
	response := session_request(
		&s,
		`{"id":2,"cmd":"set","args":{"thing":"Ball","instance":0,"field":"vel","value":"Vec2(x=-0.5,y=1.5)"}}`,
	)
	testing.expect(t, strings.contains(response, `"ok":true`), response)

	ball, ok := branch_row(&s, "Ball", 0)
	testing.expect(t, ok, "the branch ball must resolve")
	vel, _ := row_field(ball, "vel")
	vec, is_vec := vel.(Vec2)
	testing.expect(t, is_vec, "vel must stay a Vec2 column")
	testing.expect_value(t, i64(vec.x), i64(fixed_neg(fixed_div(FIXED_ONE, to_fixed(2)))))
	testing.expect_value(t, i64(vec.y), i64(fixed_add(FIXED_ONE, fixed_div(FIXED_ONE, to_fixed(2)))))
}

@(test)
test_control_set_rejects_type_mismatch :: proc(t: ^testing.T) {
	_, session := pong_control_session(t, 3)
	s := session
	response := session_request(
		&s,
		`{"id":2,"cmd":"set","args":{"thing":"Ball","instance":0,"field":"pos","value":"not-a-vec"}}`,
	)
	testing.expect(t, strings.contains(response, `"ok":false`), "a type-mismatched value must refuse")
	testing.expect(t, strings.contains(response, "declared type Vec2"), response)
	if ball, ok := branch_row(&s, "Ball", 0); ok {
		pos, _ := row_field(ball, "pos")
		_, is_vec := pos.(Vec2)
		testing.expect(t, is_vec, "pos must remain a Vec2 column, never a bare string token")
	}
}

@(test)
test_control_set_decode_error_names_sample_literal :: proc(t: ^testing.T) {
	_, session := pong_control_session(t, 3)
	s := session
	response := session_request(
		&s,
		`{"id":2,"cmd":"set","args":{"thing":"Ball","instance":0,"field":"pos","value":"Vec2(x=2.0,y=oops)"}}`,
	)
	testing.expect(t, strings.contains(response, `"ok":false`), "an undecodable value must refuse")
	testing.expect(t, strings.contains(response, "field pos"), "the error must name the field")
	testing.expect(t, strings.contains(response, "declared type Vec2"), "the error must name the declared type")
	testing.expect(t, strings.contains(response, "Vec2(x=2.0,y=104.0)"), response)
}

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

@(test)
test_control_despawn_removes_branch_row :: proc(t: ^testing.T) {
	_, session := pong_control_session(t, 3)
	s := session

	spawned := session_request(
		&s,
		`{"id":1,"cmd":"spawn","args":{"thing":"Ball","fields":{"pos":"Vec2(x=0,y=0)","vel":"Vec2(x=4294967296,y=0)"}}}`,
	)
	testing.expect(t, strings.contains(spawned, `"instance":1`), "the spawn must mint Id 1")
	if _, ok := branch_row(&s, "Ball", 1); !ok {
		testing.fail_now(t, "the minted Ball must be live before despawn")
	}

	response := session_request(&s, `{"id":2,"cmd":"despawn","args":{"thing":"Ball","instance":1}}`)
	testing.expect(t, strings.contains(response, `"ok":true`), "despawn must succeed")
	testing.expect(t, strings.contains(response, `"warranted":false`), "a control response is non-warranted")
	testing.expect(t, strings.contains(response, `"instance":1`), "the removed Id must be answered")

	if _, ok := branch_row(&s, "Ball", 1); ok {
		testing.fail_now(t, "the despawned instance must be absent from the branch head")
	}
	head := s.branch.head
	branch_table := version_find_table(&head, "Ball")
	testing.expect_value(t, len(branch_table.rows), 1)
	canonical := s.versions[len(s.versions) - 1]
	canonical_table := version_find_table(&canonical, "Ball")
	testing.expect_value(t, len(canonical_table.rows), 1)
}

@(test)
test_control_despawn_refusals :: proc(t: ^testing.T) {
	_, session := pong_control_session(t, 3)
	s := session
	opened := session_request(&s, `{"id":1,"cmd":"branch"}`)
	testing.expect(t, strings.contains(opened, `"ok":true`), "the explicit fork must succeed")
	head_before := s.branch.head
	ticks_before := s.branch.ticks

	cases := [?]string {
		`{"id":2,"cmd":"despawn","args":{"thing":"Ball"}}`,
		`{"id":3,"cmd":"despawn","args":{"thing":"Nope","instance":0}}`,
		`{"id":4,"cmd":"despawn","args":{"thing":"Ball","instance":7}}`,
	}
	for request in cases {
		response := session_request(&s, request)
		testing.expect(t, strings.contains(response, `"ok":false`), "a refused despawn answers ok:false")
	}
	testing.expect(
		t,
		world_versions_equal(s.branch.head, head_before),
		"a refused despawn must leave the branch head untouched",
	)
	testing.expect_value(t, s.branch.ticks, ticks_before)
}

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

	refused := session_request(&s, `{"id":5,"cmd":"reload","args":{"artifact":"not an artifact"}}`)
	testing.expect(t, strings.contains(refused, `"ok":false`), "a garbage artifact must refuse")
	testing.expect(t, strings.contains(refused, "reload refused"), "the refusal names the gate")
	head_before := s.branch.head

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

	stepped := session_request(&s, `{"id":7,"cmd":"inject_input","args":{"ticks":1}}`)
	testing.expect(t, strings.contains(stepped, `"ok":true`), "the post-swap tick must fold")
	hero, ok := branch_row(&s, "Hero", 0)
	testing.expect(t, ok, "the branch hero must resolve")
	pos, _ := row_field(hero, "pos")
	testing.expect_value(t, i64(pos.(Fixed)), i64(4) << 32)

	canonical_hero, _ := canonical_row(&s, "Hero", 0)
	canonical_pos, _ := row_field(canonical_hero, "pos")
	testing.expect_value(t, i64(canonical_pos.(Fixed)), i64(2) << 32)
}

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

@(private = "file")
SEEDLESS_CONTROL_ARTIFACT := #load("testdata/seedless_startup_spawn.artifact", string)

@(private = "file")
seedless_control_session :: proc(
	t: ^testing.T,
	ticks: int,
	allocator := context.allocator,
) -> (
	program: ^Program,
	session: Debug_Session,
) {
	program = new(Program, allocator)
	loaded, err := load_program(SEEDLESS_CONTROL_ARTIFACT, allocator)
	testing.expect(t, err == .None, "the seedless Mote fixture must load")
	program^ = loaded
	inputs := make([]Input, ticks, allocator)
	for i in 0 ..< ticks {
		inputs[i] = empty()
	}
	session = open_debug_session(program, inputs, NO_SEED, allocator)
	return program, session
}

@(test)
test_introspect_branch_forward_fold_advances_and_runs_behaviors :: proc(t: ^testing.T) {
	_, session := seedless_control_session(t, 2)
	s := session

	session_request(&s, `{"id":1,"cmd":"branch","args":{"tick":-1}}`)
	session_request(&s, `{"id":2,"cmd":"checkout","args":{"target":"branch"}}`)
	session_request(&s, `{"id":3,"cmd":"load"}`)
	spawned := session_request(&s, `{"id":4,"cmd":"spawn","args":{"thing":"Mote","fields":{"x":"100","hp":"5"}}}`)
	testing.expect(t, strings.contains(spawned, `"ok":true`), spawned)

	tip_before := branch_tip_tick(&s)
	staged_before, ok_before := branch_row(&s, "Mote", 4)
	if !testing.expect(t, ok_before, "the staged Mote must be live on the branch before the fold") {
		return
	}
	x_before, _ := staged_before.fields["x"].(i64)
	testing.expect_value(t, x_before, 100)

	run_target := tip_before + 5
	ran := session_request(&s, fmt.tprintf(`{{"id":5,"cmd":"run","args":{{"until":%d}}}}`, run_target))
	testing.expect(t, strings.contains(ran, `"ok":true`), ran)
	testing.expectf(t, strings.contains(ran, fmt.tprintf(`"tick":%d`, run_target)), "run must report the folded tip: %s", ran)

	testing.expect_value(t, branch_tip_tick(&s), run_target)
	staged_after, ok_after := branch_row(&s, "Mote", 4)
	if !testing.expect(t, ok_after, "the staged Mote must persist through the fold") {
		return
	}
	x_after, _ := staged_after.fields["x"].(i64)
	testing.expectf(t, x_after == 105, "the march behavior must run on every folded tick (x 100 -> 105), got x=%d", x_after)

	at_tip := session_request(&s, fmt.tprintf(`{{"id":6,"cmd":"state","args":{{"thing":"Mote","branch":"branch","tick":%d}}}}`, run_target))
	testing.expect(t, strings.contains(at_tip, `"ok":true`), at_tip)
	testing.expect(t, strings.contains(at_tip, `"x":"105"`), at_tip)

	reference := branch_forward_reference(&s, staged_base_head(&s), 5)
	testing.expect(
		t,
		world_versions_equal(s.branch.head, reference),
		"the branch-forward fold must equal a plain step_tick re-fold of the staged base (determinism warranty)",
	)
}

@(test)
test_introspect_control_spawn_honors_rewound_cursor :: proc(t: ^testing.T) {
	_, session := seedless_control_session(t, 12)
	s := session

	session_request(&s, `{"id":1,"cmd":"load"}`)
	session_request(&s, `{"id":2,"cmd":"run"}`)
	rewound := session_request(&s, `{"id":3,"cmd":"rewind","args":{"tick":5}}`)
	testing.expect(t, strings.contains(rewound, `"tick":5`), rewound)
	testing.expect_value(t, s.cursor.tick, 5)

	spawned := session_request(&s, `{"id":4,"cmd":"spawn","args":{"thing":"Mote","fields":{"x":"77","hp":"9"}}}`)
	testing.expect(t, strings.contains(spawned, `"ok":true`), spawned)
	testing.expect(t, strings.contains(spawned, `"base_tick":5`), fmt.tprintf("the implicit fork must anchor at the rewound cursor tick 5, got: %s", spawned))
	testing.expect_value(t, s.branch.base_tick, 5)

	staged, ok := branch_row(&s, "Mote", 4)
	if !testing.expect(t, ok, "the spawned Mote must be observable on the rewound-anchored branch") {
		return
	}
	x, _ := staged.fields["x"].(i64)
	testing.expect_value(t, x, 77)

	session_request(&s, `{"id":5,"cmd":"checkout","args":{"target":"branch"}}`)
	stepped := session_request(&s, `{"id":6,"cmd":"step"}`)
	testing.expect(t, strings.contains(stepped, `"ok":true`), stepped)
	advanced, ok2 := branch_row(&s, "Mote", 4)
	if !testing.expect(t, ok2, "the staged Mote must persist through the forward fold") {
		return
	}
	x2, _ := advanced.fields["x"].(i64)
	testing.expect_value(t, x2, 78)
}

@(test)
test_introspect_control_spawn_anchors_recording_head_when_unloaded :: proc(t: ^testing.T) {
	_, session := seedless_control_session(t, 6)
	s := session
	spawned := session_request(&s, `{"id":1,"cmd":"spawn","args":{"thing":"Mote","fields":{"x":"1","hp":"1"}}}`)
	testing.expect(t, strings.contains(spawned, `"ok":true`), spawned)
	testing.expect_value(t, s.branch.base_tick, 5)
}

@(private = "file")
staged_base_head :: proc(s: ^Debug_Session) -> World_Version {
	ref := s^
	ref.has_branch = false
	ref.active_branch = false
	session_request(&ref, `{"id":1,"cmd":"branch","args":{"tick":-1}}`)
	session_request(&ref, `{"id":2,"cmd":"checkout","args":{"target":"branch"}}`)
	session_request(&ref, `{"id":3,"cmd":"spawn","args":{"thing":"Mote","fields":{"x":"100","hp":"5"}}}`)
	return ref.branch.head
}

@(private = "file")
branch_forward_reference :: proc(s: ^Debug_Session, base: World_Version, n: int, allocator := context.allocator) -> World_Version {
	head := base
	tick_hz := s.program.entrypoint.tick_hz
	next_logical := s.branch.base_tick + 1 + 1
	for _ in 0 ..< n {
		time := time_resource_at(tick_hz, next_logical, allocator)
		head = step_tick(s.program, head, empty(), time, allocator)
		next_logical += 1
	}
	return head
}

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
		`{"id":5,"cmd":"despawn","args":{"thing":"Paddle","instance":2}}`,
		`{"id":6,"cmd":"emit","args":{"signal":"Goal","value":"Goal(side=Side::Right)"}}`,
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
