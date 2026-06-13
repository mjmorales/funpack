// §28 §2 checkout acceptance — the active-lineage SWITCH paired with `branch`'s
// fork. `branch` creates a forked recording lineage off a snapshot; `checkout`
// makes it the session's ACTIVE lineage, so subsequent observe commands read the
// branch WITHOUT a per-call `branch` arg (§28 §2: canonical chain by default, or
// the active branch once checked out). These tests pin the contract corners:
//
//   - checkout to a forked branch makes a subsequent observe read that lineage
//     with NO branch arg (the fork's divergence is visible by default);
//   - checkout fails closed when no branch is live (nothing to navigate to);
//   - the canonical chain is the DEFAULT — observe reads it until checkout, and a
//     `checkout{canonical}` returns to it; an explicit per-call `branch` arg
//     overrides the session default either way (§28 §2's optional argument);
//   - checkout is NON-PERTURBING — it mutates no recorded state, so the canonical
//     session digest is bit-identical across a checkout (the §28 warranty: observe,
//     even branch-addressed, never changes behavior).
package funpack_runtime

import "core:strings"
import "core:testing"

// checkout_reference_capture folds the golden run untouched — the canonical
// ground truth the non-perturbation pin compares the checkout dance against
// (self-contained per the test discipline; the twin of the control test's
// reference fold).
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

// checkout_pong_session opens a control-test session over `ticks` empty-input
// pong ticks — the same short-canonical opener the control battery folds from.
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

// THE CHECKOUT ACCEPTANCE — checkout makes a forked branch the active lineage:
// fork at the canonical head, force a field on the branch (the divergence), then
// `checkout` and read it back with a NO-ARG diff. The diff over the branch's
// fork-point→tip range reports the forced column; the SAME no-arg diff before
// checkout (canonical default) fails closed at the out-of-range branch tip — so
// the active-lineage switch is what redirects the read, not the diff args.
@(test)
test_checkout_makes_branch_the_active_observe_lineage :: proc(t: ^testing.T) {
	_, session := checkout_pong_session(t, 3)
	s := session

	// Fork at the canonical head (tick 2) and force the branch ball's position —
	// the branch tip lands at base_tick + 1 = tick 3.
	forked := session_request(&s, `{"id":1,"cmd":"branch"}`)
	testing.expect(t, strings.contains(forked, `"ok":true`), "the fork must succeed")
	testing.expect_value(t, s.branch.base_tick, 2)
	set := session_request(
		&s,
		`{"id":2,"cmd":"set","args":{"thing":"Ball","instance":0,"field":"pos","value":"Vec2(x=0,y=0)"}}`,
	)
	testing.expect(t, strings.contains(set, `"ok":true`), "the branch set must succeed")
	testing.expect_value(t, s.branch.ticks, 1)

	// Before checkout the session reads canonical: a diff to the branch tip (tick
	// 3) is out of range on the 3-tick canonical chain — the default is canonical.
	pre := session_request(&s, `{"id":3,"cmd":"diff","args":{"from":2,"to":3}}`)
	testing.expect(t, strings.contains(pre, `"ok":false`), "the canonical default has no tick 3")
	testing.expect(t, strings.contains(pre, "tick out of range"), "the canonical chain fails closed past its head")

	// Checkout the branch — now the SAME no-arg diff reads the branch lineage: the
	// fork-point (shared canonical tick 2) → branch tip (the forced state).
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

// Checkout fails closed when no branch is live — there is no forked lineage to
// navigate to. The session stays on canonical, and observe keeps its default.
@(test)
test_checkout_unknown_branch_fails_closed :: proc(t: ^testing.T) {
	_, session := checkout_pong_session(t, 3)
	s := session

	checked := session_request(&s, `{"id":1,"cmd":"checkout"}`)
	testing.expect(t, strings.contains(checked, `"ok":false`), "checkout with no live branch fails closed")
	testing.expect(t, strings.contains(checked, "no branch to checkout"), "the refusal names the missing lineage")
	testing.expect(t, !s.active_branch, "a failed checkout leaves the session on canonical")

	// A bad target name fails closed too — the target set is closed (branch|canonical).
	bad := session_request(&s, `{"id":2,"cmd":"checkout","args":{"target":"trunk"}}`)
	testing.expect(t, strings.contains(bad, `"ok":false`), "an unknown checkout target fails closed")
	testing.expect(t, strings.contains(bad, "unknown checkout target"), "the refusal names the closed target set")

	// The canonical chain stays the default and readable.
	diff := session_request(&s, `{"id":3,"cmd":"diff","args":{"from":0,"to":1}}`)
	testing.expect(t, strings.contains(diff, `"ok":true`), "the canonical default stays readable after a failed checkout")
}

// The canonical chain is the default, and checkout{canonical} returns to it; an
// explicit per-call `branch` arg (§28 §2) overrides the active default either way.
@(test)
test_checkout_canonical_is_default_and_arg_overrides :: proc(t: ^testing.T) {
	_, session := checkout_pong_session(t, 3)
	s := session

	session_request(&s, `{"id":1,"cmd":"branch"}`)
	session_request(&s, `{"id":2,"cmd":"set","args":{"thing":"Ball","instance":0,"field":"pos","value":"Vec2(x=0,y=0)"}}`)
	session_request(&s, `{"id":3,"cmd":"checkout"}`)
	testing.expect(t, s.active_branch, "the branch is the active default after checkout")

	// `branch:"canonical"` forces the trunk for one call EVEN while checked out:
	// the canonical chain has no tick 3, so the override fails closed there.
	override_canon := session_request(&s, `{"id":4,"cmd":"diff","args":{"from":2,"to":3,"branch":"canonical"}}`)
	testing.expect(t, strings.contains(override_canon, `"ok":false`), "the per-call canonical override reads the trunk, which has no tick 3")
	testing.expect(t, s.active_branch, "a per-call override never mutates the session default")

	// Return to canonical, then `branch:"branch"` forces the fork for one call.
	back := session_request(&s, `{"id":5,"cmd":"checkout","args":{"target":"canonical"}}`)
	testing.expect(t, strings.contains(back, `"ok":true`), "checkout{canonical} must succeed")
	testing.expect(t, strings.contains(back, `"active":"canonical"`), "the session is back on canonical")
	testing.expect(t, strings.contains(back, `"warranted":true`), "the canonical trunk is warranted")
	testing.expect(t, !s.active_branch, "checkout{canonical} clears the active-branch selector")

	override_branch := session_request(&s, `{"id":6,"cmd":"diff","args":{"from":2,"to":3,"branch":"branch"}}`)
	testing.expect(t, strings.contains(override_branch, `"ok":true`), "the per-call branch override reads the fork tip")
	testing.expect(t, strings.contains(override_branch, `"field":"pos"`), "the override surfaces the branch divergence")

	// Naming a branch when none is live fails closed even as a per-call arg.
	_, fresh := checkout_pong_session(t, 3)
	f := fresh
	miss := session_request(&f, `{"id":7,"cmd":"diff","args":{"from":0,"to":1,"branch":"branch"}}`)
	testing.expect(t, strings.contains(miss, `"ok":false`), "a branch arg with no live branch fails closed")
	testing.expect(t, strings.contains(miss, "unknown branch"), "the refusal names the missing lineage")
}

// Re-fold observe commands stay canonical-only: signals/trace/replay_behavior
// replay a RECORDED tick, which only the canonical chain has — a branch address
// fails closed rather than silently re-folding the trunk.
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

		// The same command on the explicit canonical override re-folds the recorded
		// tick 0 on the trunk and succeeds (paddle_move is a real pong behavior).
		canon_req := strings.concatenate({`{"id":5,"cmd":"`, cmd, `","args":{"tick":0,"behavior":"paddle_move","branch":"canonical"}}`})
		canon := session_request(&s, canon_req)
		testing.expect(t, strings.contains(canon, `"ok":true`), "the canonical override re-folds the recorded tick")
	}
}

// THE CHECKOUT WARRANTY — checkout is non-perturbing: it mutates no recorded
// state, only which already-committed lineage observe reads. A full checkout
// dance (fork, set on the branch, checkout to branch, branch-addressed reads,
// checkout back to canonical) leaves the canonical session capture bit-identical
// to an untouched reference fold — observe, even branch-addressed, is a theorem.
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
