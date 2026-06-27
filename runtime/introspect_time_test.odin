package funpack_runtime

import "core:fmt"
import "core:strings"
import "core:testing"

@(private = "file")
time_pong_session :: proc(
	t: ^testing.T,
	allocator := context.allocator,
) -> (
	program: ^Program,
	session: Debug_Session,
) {
	program = new(Program, allocator)
	loaded, err := load_program(GOLDEN_ARTIFACT, allocator)
	testing.expect(t, err == .None, "golden pong artifact must load")
	program^ = loaded
	session = open_debug_session(program, golden_session_inputs(allocator), NO_SEED, allocator)
	return program, session
}

@(private = "file")
frame_digest_at :: proc(
	s: ^Debug_Session,
	version: World_Version,
	tick: int,
	allocator := context.allocator,
) -> Frame_Digest {
	time := time_resource_at(s.program.entrypoint.tick_hz, tick, allocator)
	draw := render_version(s.program, version, s.snapshots[tick], time, allocator)
	return capture_frame(version, draw, allocator)
}

@(test)
test_time_load_and_status_envelopes :: proc(t: ^testing.T) {
	_, session := time_pong_session(t)
	s := session

	unloaded := session_request(&s, `{"id":1,"cmd":"status"}`)
	expected_unloaded :=
		`{"v":1,"id":1,"ok":true,"cmd":"status","result":{"loaded":false,"tick":null,` +
		`"ticks_recorded":600,"seeded":false,"uses_rng":false,"cadence":16,` +
		`"ring":{"slots":32,"occupied":0,"oldest":null,"newest":null},"branch":{"live":false,"active":"canonical"}}}`
	testing.expect_value(t, unloaded, expected_unloaded)

	loaded := session_request(&s, `{"id":2,"cmd":"load"}`)
	testing.expect_value(t, loaded, `{"v":1,"id":2,"ok":true,"cmd":"load","result":{"tick":-1}}`)

	armed := session_request(&s, `{"id":3,"cmd":"status"}`)
	expected_armed :=
		`{"v":1,"id":3,"ok":true,"cmd":"status","result":{"loaded":true,"tick":-1,` +
		`"ticks_recorded":600,"seeded":false,"uses_rng":false,"cadence":16,` +
		`"ring":{"slots":32,"occupied":0,"oldest":null,"newest":null},"branch":{"live":false,"active":"canonical"}}}`
	testing.expect_value(t, armed, expected_armed)
}

@(test)
test_time_run_step_pause_track_canonical :: proc(t: ^testing.T) {
	_, session := time_pong_session(t)
	s := session
	session_request(&s, `{"id":1,"cmd":"load"}`)

	stepped := session_request(&s, `{"id":2,"cmd":"step"}`)
	testing.expect_value(t, stepped, `{"v":1,"id":2,"ok":true,"cmd":"step","result":{"tick":0}}`)
	testing.expect(
		t,
		world_versions_equal(s.cursor.head, s.versions[0]),
		"one step must land bit-exact on canonical tick 0",
	)

	ran := session_request(&s, `{"id":3,"cmd":"run","args":{"until":99}}`)
	testing.expect_value(t, ran, `{"v":1,"id":3,"ok":true,"cmd":"run","result":{"tick":99}}`)
	testing.expect(
		t,
		world_versions_equal(s.cursor.head, s.versions[99]),
		"run must land bit-exact on canonical tick 99",
	)
	testing.expect_value(t, s.cursor.ring_len, 7)

	paused := session_request(&s, `{"id":4,"cmd":"pause"}`)
	testing.expect_value(t, paused, `{"v":1,"id":4,"ok":true,"cmd":"pause","result":{"tick":99}}`)

	to_end := session_request(&s, `{"id":5,"cmd":"run"}`)
	testing.expect_value(t, to_end, `{"v":1,"id":5,"ok":true,"cmd":"run","result":{"tick":599}}`)
	testing.expect(
		t,
		world_versions_equal(s.cursor.head, s.versions[599]),
		"run-to-end must land bit-exact on the canonical final tick",
	)
}

@(test)
test_time_rewind_ring_bit_exact :: proc(t: ^testing.T) {
	_, session := time_pong_session(t)
	s := session
	session_request(&s, `{"id":1,"cmd":"load"}`)
	session_request(&s, `{"id":2,"cmd":"run"}`)

	status := session_request(&s, `{"id":3,"cmd":"status"}`)
	testing.expect(
		t,
		strings.contains(status, `"ring":{"slots":32,"occupied":32,"oldest":96,"newest":592}`),
		"the full run must leave the ring at capacity with the six oldest insertions evicted",
	)

	rewound := session_request(&s, `{"id":4,"cmd":"rewind","args":{"tick":290}}`)
	testing.expect_value(
		t,
		rewound,
		`{"v":1,"id":4,"ok":true,"cmd":"rewind","result":{"tick":290,"restored_from":288,"refolded":2}}`,
	)
	testing.expect(
		t,
		world_versions_equal(s.cursor.head, s.versions[290]),
		"rewind must restore canonical tick 290 bit-exact",
	)
	testing.expect_value(
		t,
		frame_digest_at(&s, s.cursor.head, 290).digest,
		frame_digest_at(&s, s.versions[290], 290).digest,
	)

	floored := session_request(&s, `{"id":5,"cmd":"rewind","args":{"tick":5}}`)
	testing.expect_value(
		t,
		floored,
		`{"v":1,"id":5,"ok":true,"cmd":"rewind","result":{"tick":5,"restored_from":-1,"refolded":6}}`,
	)
	testing.expect(
		t,
		world_versions_equal(s.cursor.head, s.versions[5]),
		"a below-ring rewind must re-fold from the startup floor bit-exact",
	)

	forward := session_request(&s, `{"id":6,"cmd":"rewind","args":{"tick":593}}`)
	testing.expect_value(
		t,
		forward,
		`{"v":1,"id":6,"ok":true,"cmd":"rewind","result":{"tick":593,"restored_from":592,"refolded":1}}`,
	)
	testing.expect(
		t,
		world_versions_equal(s.cursor.head, s.versions[593]),
		"a forward rewind must reuse the still-valid ring entry ahead of the cursor",
	)
}

@(test)
test_time_reset_returns_to_startup :: proc(t: ^testing.T) {
	_, session := time_pong_session(t)
	s := session
	session_request(&s, `{"id":1,"cmd":"load"}`)
	session_request(&s, `{"id":2,"cmd":"run","args":{"until":50}}`)

	reset := session_request(&s, `{"id":3,"cmd":"reset"}`)
	testing.expect_value(t, reset, `{"v":1,"id":3,"ok":true,"cmd":"reset","result":{"tick":-1}}`)
	testing.expect(
		t,
		world_versions_equal(s.cursor.head, s.startup),
		"reset must restore the post-startup version",
	)

	session_request(&s, `{"id":4,"cmd":"step"}`)
	testing.expect(
		t,
		world_versions_equal(s.cursor.head, s.versions[0]),
		"the first step after reset must reproduce canonical tick 0",
	)
}

@(test)
test_time_seeded_rewind_rethreads_rng :: proc(t: ^testing.T) {
	program := new(Program, context.allocator)
	loaded, err := load_program(GOLDEN_SNAKE_ARTIFACT, context.allocator)
	testing.expect(t, err == .None, "golden snake artifact must load")
	program^ = loaded
	inputs := make([]Input, 16, context.allocator)
	for i in 0 ..< 16 {
		inputs[i] = i == 6 ? with_pressed(empty(), .P1, ActionId(1)) : empty()
	}
	session := open_debug_session(program, inputs, seeded_run(42), context.allocator)
	s := session

	seeded_status := session_request(&s, `{"id":0,"cmd":"status"}`)
	testing.expect(t, strings.contains(seeded_status, `"seeded":true`), seeded_status)
	testing.expect(t, strings.contains(seeded_status, `"uses_rng":true`), seeded_status)

	eat_tick := -1
	for i in 0 ..< len(s.rngs) - 1 {
		if s.rngs[i + 1].state != s.rngs[i].state {
			eat_tick = i
			break
		}
	}
	if !testing.expect(t, eat_tick > 0, "the seeded run must have an RNG-drawing tick") {
		return
	}

	session_request(&s, `{"id":1,"cmd":"load"}`)
	session_request(&s, `{"id":2,"cmd":"run"}`)
	testing.expect(
		t,
		world_versions_equal(s.cursor.head, s.versions[len(inputs) - 1]),
		"the seeded run must land bit-exact on the canonical final tick",
	)
	testing.expect_value(t, s.cursor.rng.state, s.rngs[len(inputs)].state)

	session_request(&s, fmt.tprintf(`{{"id":3,"cmd":"rewind","args":{{"tick":%d}}}}`, eat_tick))
	testing.expect(
		t,
		world_versions_equal(s.cursor.head, s.versions[eat_tick]),
		"the seeded rewind must reproduce the canonical eat tick — RNG-drawn food included",
	)
	testing.expect_value(t, s.cursor.rng.state, s.rngs[eat_tick + 1].state)

	session_request(&s, `{"id":4,"cmd":"step"}`)
	testing.expect(
		t,
		world_versions_equal(s.cursor.head, s.versions[eat_tick + 1]),
		"a step off the rewound eat tick must continue the canonical seeded chain",
	)
}

@(test)
test_time_battery_non_perturbing_digest_pin :: proc(t: ^testing.T) {
	_, session := time_pong_session(t)
	s := session
	baseline := session_capture(&s)

	battery := [?]string {
		`{"id":1,"cmd":"load"}`,
		`{"id":2,"cmd":"run","args":{"until":99}}`,
		`{"id":3,"cmd":"step"}`,
		`{"id":4,"cmd":"rewind","args":{"tick":40}}`,
		`{"id":5,"cmd":"reset"}`,
		`{"id":6,"cmd":"run"}`,
		`{"id":7,"cmd":"status"}`,
	}
	for request in battery {
		response := session_request(&s, request)
		testing.expect(t, strings.contains(response, `"ok":true`), "every time command in the battery must succeed")
	}

	walked := session_capture(&s)
	if !testing.expect_value(t, len(walked.per_tick), len(baseline.per_tick)) {
		return
	}
	for frame, i in walked.per_tick {
		testing.expect_value(t, frame.digest, baseline.per_tick[i].digest)
	}
	testing.expect_value(t, walked.session, baseline.session)
}

@(test)
test_time_request_refusals :: proc(t: ^testing.T) {
	_, session := time_pong_session(t)
	s := session

	cases_unloaded := [?]struct {
		request:  string,
		fragment: string,
	} {
		{`{"id":1,"cmd":"run"}`, `no timeline loaded`},
		{`{"id":2,"cmd":"pause"}`, `no timeline loaded`},
		{`{"id":3,"cmd":"step"}`, `no timeline loaded`},
		{`{"id":4,"cmd":"rewind","args":{"tick":0}}`, `no timeline loaded`},
		{`{"id":5,"cmd":"reset"}`, `no timeline loaded`},
	}
	for entry in cases_unloaded {
		response := session_request(&s, entry.request)
		testing.expect(t, strings.contains(response, `"ok":false`), "an unloaded navigation must answer ok:false")
		testing.expect(t, strings.contains(response, entry.fragment), entry.fragment)
	}

	session_request(&s, `{"id":6,"cmd":"load"}`)
	cases_loaded := [?]struct {
		request:  string,
		fragment: string,
	} {
		{`{"id":7,"cmd":"rewind"}`, `missing args.tick`},
		{`{"id":8,"cmd":"rewind","args":{"tick":-2}}`, `tick out of range`},
		{`{"id":9,"cmd":"rewind","args":{"tick":600}}`, `tick out of range`},
		{`{"id":10,"cmd":"run","args":{"until":600}}`, `tick out of range`},
	}
	for entry in cases_loaded {
		response := session_request(&s, entry.request)
		testing.expect(t, strings.contains(response, `"ok":false`), "an unservable time request must answer ok:false")
		testing.expect(t, strings.contains(response, entry.fragment), entry.fragment)
	}

	session_request(&s, `{"id":11,"cmd":"run","args":{"until":10}}`)
	behind := session_request(&s, `{"id":12,"cmd":"run","args":{"until":3}}`)
	testing.expect(t, strings.contains(behind, `rewind instead`), "a backward run target must point at rewind")

	session_request(&s, `{"id":13,"cmd":"run"}`)
	at_end := session_request(&s, `{"id":14,"cmd":"step"}`)
	testing.expect(t, strings.contains(at_end, `end of recording`), "a step past the recording must be refused")
}

TIME_BRANCH_SELECTOR_ARTIFACT := #load("testdata/seedless_startup_spawn.artifact", string)

@(private = "file")
time_branch_session :: proc(
	t: ^testing.T,
	ticks: int,
	allocator := context.allocator,
) -> (
	program: ^Program,
	session: Debug_Session,
) {
	program = new(Program, allocator)
	loaded, err := load_program(TIME_BRANCH_SELECTOR_ARTIFACT, allocator)
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
test_time_advance_branch_selector_must_match_active_lineage :: proc(t: ^testing.T) {
	_, session := time_branch_session(t, 12)
	s := session

	session_request(&s, `{"id":1,"cmd":"load"}`)
	session_request(&s, `{"id":2,"cmd":"run"}`)
	cursor_at_end := s.cursor.tick

	forked := session_request(&s, `{"id":3,"cmd":"branch","args":{"tick":4}}`)
	testing.expect(t, strings.contains(forked, `"ok":true`), forked)
	testing.expect(t, s.has_branch && !s.active_branch, "the branch must exist but not be checked out")

	stepped := session_request(&s, `{"id":4,"cmd":"step","args":{"branch":"branch"}}`)
	testing.expect(t, strings.contains(stepped, `"ok":false`), stepped)
	testing.expectf(t, strings.contains(stepped, `control_checkout`), "the refusal must name control_checkout: %s", stepped)
	testing.expect(t, strings.contains(stepped, `not checked out`), stepped)
	testing.expect(t, !strings.contains(stepped, `end of recording`), "the selector must be honored, not fall through to the active lineage")

	ran := session_request(&s, `{"id":5,"cmd":"run","args":{"branch":"branch"}}`)
	testing.expect(t, strings.contains(ran, `"ok":false`), ran)
	testing.expect(t, strings.contains(ran, `control_checkout`), ran)

	testing.expect_value(t, s.cursor.tick, cursor_at_end)
	testing.expect_value(t, s.branch.ticks, 0)

	bogus := session_request(&s, `{"id":6,"cmd":"step","args":{"branch":"trunk"}}`)
	testing.expect(t, strings.contains(bogus, `"ok":false`), bogus)
	testing.expect(t, strings.contains(bogus, `control_checkout`), bogus)

	canon := session_request(&s, `{"id":7,"cmd":"step","args":{"branch":"canonical"}}`)
	testing.expectf(t, strings.contains(canon, `end of recording`), "a canonical selector with canonical active proceeds: %s", canon)
	testing.expect(t, !strings.contains(canon, `control_checkout`), "the active-lineage selector is not a refusal")

	session_request(&s, `{"id":8,"cmd":"checkout","args":{"target":"branch"}}`)
	tip_before := branch_tip_tick(&s)
	on_branch := session_request(&s, `{"id":9,"cmd":"step","args":{"branch":"branch"}}`)
	testing.expect(t, strings.contains(on_branch, `"ok":true`), on_branch)
	testing.expect_value(t, branch_tip_tick(&s), tip_before + 1)

	unselected := session_request(&s, `{"id":10,"cmd":"step"}`)
	testing.expect(t, strings.contains(unselected, `"ok":true`), unselected)
	testing.expect_value(t, branch_tip_tick(&s), tip_before + 2)
}
