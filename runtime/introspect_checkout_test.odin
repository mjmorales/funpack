package funpack_runtime

import "core:strings"
import "core:testing"

@(private = "file")
checkout_reference_capture :: proc(
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

@(private = "file")
checkout_pong_session :: proc(
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

@(test)
test_checkout_makes_branch_the_active_observe_lineage :: proc(t: ^testing.T) {
	_, session := checkout_pong_session(t, 3)
	s := session

	forked := session_request(&s, `{"id":1,"cmd":"branch"}`)
	testing.expect(t, strings.contains(forked, `"ok":true`), "the fork must succeed")
	testing.expect_value(t, s.branch.base_tick, 2)
	set := session_request(
		&s,
		`{"id":2,"cmd":"set","args":{"thing":"Ball","instance":0,"field":"pos","value":"Vec2(x=0,y=0)"}}`,
	)
	testing.expect(t, strings.contains(set, `"ok":true`), "the branch set must succeed")
	testing.expect_value(t, s.branch.ticks, 1)

	pre := session_request(&s, `{"id":3,"cmd":"diff","args":{"from":2,"to":3}}`)
	testing.expect(t, strings.contains(pre, `"ok":false`), "the canonical default has no tick 3")
	testing.expect(t, strings.contains(pre, "tick out of range"), "the canonical chain fails closed past its head")

	checked := session_request(&s, `{"id":4,"cmd":"checkout"}`)
	testing.expect(t, strings.contains(checked, `"ok":true`), "checkout of the live branch must succeed")
	testing.expect(t, strings.contains(checked, `"active":"branch"`), "checkout names the branch active")
	testing.expect(t, strings.contains(checked, `"warranted":false`), "a forked active lineage is non-warranted")
	testing.expect(t, s.active_branch, "checkout flips the session active-lineage selector")

	post := session_request(&s, `{"id":5,"cmd":"diff","args":{"from":2,"to":3}}`)
	testing.expect(t, strings.contains(post, `"ok":true`), "the branch tip is addressable once checked out")
	testing.expect(t, strings.contains(post, `"thing":"Ball"`), "the diff reads the branch's forced Ball")
	testing.expect(t, strings.contains(post, `"field":"pos"`), "the forced pos column is the branch divergence")
}

@(test)
test_checkout_unknown_branch_fails_closed :: proc(t: ^testing.T) {
	_, session := checkout_pong_session(t, 3)
	s := session

	checked := session_request(&s, `{"id":1,"cmd":"checkout"}`)
	testing.expect(t, strings.contains(checked, `"ok":false`), "checkout with no live branch fails closed")
	testing.expect(t, strings.contains(checked, "no branch to checkout"), "the refusal names the missing lineage")
	testing.expect(t, !s.active_branch, "a failed checkout leaves the session on canonical")

	bad := session_request(&s, `{"id":2,"cmd":"checkout","args":{"target":"trunk"}}`)
	testing.expect(t, strings.contains(bad, `"ok":false`), "an unknown checkout target fails closed")
	testing.expect(t, strings.contains(bad, "unknown checkout target"), "the refusal names the closed target set")

	diff := session_request(&s, `{"id":3,"cmd":"diff","args":{"from":0,"to":1}}`)
	testing.expect(t, strings.contains(diff, `"ok":true`), "the canonical default stays readable after a failed checkout")
}

@(test)
test_checkout_canonical_is_default_and_arg_overrides :: proc(t: ^testing.T) {
	_, session := checkout_pong_session(t, 3)
	s := session

	session_request(&s, `{"id":1,"cmd":"branch"}`)
	session_request(&s, `{"id":2,"cmd":"set","args":{"thing":"Ball","instance":0,"field":"pos","value":"Vec2(x=0,y=0)"}}`)
	session_request(&s, `{"id":3,"cmd":"checkout"}`)
	testing.expect(t, s.active_branch, "the branch is the active default after checkout")

	override_canon := session_request(&s, `{"id":4,"cmd":"diff","args":{"from":2,"to":3,"branch":"canonical"}}`)
	testing.expect(t, strings.contains(override_canon, `"ok":false`), "the per-call canonical override reads the trunk, which has no tick 3")
	testing.expect(t, s.active_branch, "a per-call override never mutates the session default")

	back := session_request(&s, `{"id":5,"cmd":"checkout","args":{"target":"canonical"}}`)
	testing.expect(t, strings.contains(back, `"ok":true`), "checkout{canonical} must succeed")
	testing.expect(t, strings.contains(back, `"active":"canonical"`), "the session is back on canonical")
	testing.expect(t, strings.contains(back, `"warranted":true`), "the canonical trunk is warranted")
	testing.expect(t, !s.active_branch, "checkout{canonical} clears the active-branch selector")

	override_branch := session_request(&s, `{"id":6,"cmd":"diff","args":{"from":2,"to":3,"branch":"branch"}}`)
	testing.expect(t, strings.contains(override_branch, `"ok":true`), "the per-call branch override reads the fork tip")
	testing.expect(t, strings.contains(override_branch, `"field":"pos"`), "the override surfaces the branch divergence")

	_, fresh := checkout_pong_session(t, 3)
	f := fresh
	miss := session_request(&f, `{"id":7,"cmd":"diff","args":{"from":0,"to":1,"branch":"branch"}}`)
	testing.expect(t, strings.contains(miss, `"ok":false`), "a branch arg with no live branch fails closed")
	testing.expect(t, strings.contains(miss, "unknown branch"), "the refusal names the missing lineage")
}

@(test)
test_checkout_refold_observes_reject_branch :: proc(t: ^testing.T) {
	_, session := checkout_pong_session(t, 3)
	s := session
	session_request(&s, `{"id":1,"cmd":"branch"}`)
	session_request(&s, `{"id":2,"cmd":"set","args":{"thing":"Ball","instance":0,"field":"pos","value":"Vec2(x=0,y=0)"}}`)
	session_request(&s, `{"id":3,"cmd":"checkout"}`)

	refold_cmds := [?]string{"signals", "trace", "replay_behavior"}
	for cmd in refold_cmds {
		req := strings.concatenate({`{"id":4,"cmd":"`, cmd, `","args":{"tick":0,"behavior":"paddle_move","branch":"branch"}}`})
		response := session_request(&s, req)
		testing.expect(t, strings.contains(response, `"ok":false`), "a re-fold observe rejects a branch address")
		testing.expect(t, strings.contains(response, "branch refold unsupported"), "the refusal names the canonical-only re-fold")

		canon_req := strings.concatenate({`{"id":5,"cmd":"`, cmd, `","args":{"tick":0,"behavior":"paddle_move","branch":"canonical"}}`})
		canon := session_request(&s, canon_req)
		testing.expect(t, strings.contains(canon, `"ok":true`), "the canonical override re-folds the recorded tick")
	}
}

@(test)
test_checkout_canonical_digest_pinned :: proc(t: ^testing.T) {
	program, session := checkout_pong_session(t, 8)
	s := session
	inputs := make([]Input, 8)
	for i in 0 ..< 8 {
		inputs[i] = empty()
	}
	baseline, baseline_final := checkout_reference_capture(program, inputs)

	dance := [?]string {
		`{"id":1,"cmd":"branch"}`,
		`{"id":2,"cmd":"set","args":{"thing":"Ball","instance":0,"field":"pos","value":"Vec2(x=0,y=0)"}}`,
		`{"id":3,"cmd":"checkout"}`,
		`{"id":4,"cmd":"diff","args":{"from":7,"to":8}}`,
		`{"id":5,"cmd":"draw_list","args":{"tick":8}}`,
		`{"id":6,"cmd":"checkout","args":{"target":"canonical"}}`,
		`{"id":7,"cmd":"diff","args":{"from":0,"to":7}}`,
	}
	for request in dance {
		session_request(&s, request)
	}

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
		"the canonical final world must equal the untouched run's across a checkout dance",
	)
}
