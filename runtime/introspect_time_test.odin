// §28 §3 time-command acceptance: load / run / pause / step / rewind / reset /
// status navigate a cursor over the recorded timeline, with rewind restoring
// the nearest fixed-cadence ring snapshot at-or-before the target and
// re-folding recorded inputs to the exact tick. The bit-exactness oracle is
// the session's independently retained canonical chain (open_debug_session
// folds it once at open): every cursor position must compare
// world_versions_equal — and digest-equal — to the canonical version of that
// tick, seedless (golden pong) and seeded (golden snake, whose eat tick draws
// the replacement food from the threaded Rng, so a wrong re-threaded Rng
// diverges visibly). The time battery is observe-class: a digest pin proves it
// leaves the canonical chain bit-identical.
package funpack_runtime

import "core:fmt"
import "core:strings"
import "core:testing"

// time_pong_session opens the seedless time-travel fixture: the golden pong
// artifact over its 600-tick scripted session — long enough that the cadence
// ring (16-tick cadence, 32 slots) overflows and evicts, which the ring tests
// rely on.
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

// frame_digest_at digests one version exactly as the canonical capture does —
// the §20 draw-list projection over the same per-tick Time, then capture_frame.
// The digest comparison surface for the rewind bit-exactness pins.
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

// The load and status envelopes are pinned byte-for-byte: the time group rides
// the same versioned exact-match envelope as every observe command, and status
// reports the session shape (cursor, recording extent, ring constants and
// occupancy, branch liveness) in fixed field order.
@(test)
test_time_load_and_status_envelopes :: proc(t: ^testing.T) {
	_, session := time_pong_session(t)
	s := session

	unloaded := session_request(&s, `{"id":1,"cmd":"status"}`)
	expected_unloaded :=
		`{"v":1,"id":1,"ok":true,"cmd":"status","result":{"loaded":false,"tick":null,` +
		`"ticks_recorded":600,"seeded":false,"cadence":16,` +
		`"ring":{"slots":32,"occupied":0,"oldest":null,"newest":null},"branch":{"live":false,"active":"canonical"}}}`
	testing.expect_value(t, unloaded, expected_unloaded)

	loaded := session_request(&s, `{"id":2,"cmd":"load"}`)
	testing.expect_value(t, loaded, `{"v":1,"id":2,"ok":true,"cmd":"load","result":{"tick":-1}}`)

	armed := session_request(&s, `{"id":3,"cmd":"status"}`)
	expected_armed :=
		`{"v":1,"id":3,"ok":true,"cmd":"status","result":{"loaded":true,"tick":-1,` +
		`"ticks_recorded":600,"seeded":false,"cadence":16,` +
		`"ring":{"slots":32,"occupied":0,"oldest":null,"newest":null},"branch":{"live":false,"active":"canonical"}}}`
	testing.expect_value(t, armed, expected_armed)
}

// run / step / pause walk the cursor through the production fold: every
// position compares bit-exact (world_versions_equal) against the canonical
// retained chain, pause acks the position without moving it, and the cadence
// ring fills on the fixed 16-tick boundaries.
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
	// Cadence snapshots at ticks 0,16,…,96 — seven entries, none evicted yet.
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

// THE REWIND ACCEPTANCE (seedless) — rewind restores the nearest ring snapshot
// at-or-before the target and re-folds to the exact tick, bit-exact and
// digest-pinned against the canonical chain; the bounded ring evicts its
// oldest insertions on a long run, and a target below the oldest retained
// entry restores from the permanent post-startup floor.
@(test)
test_time_rewind_ring_bit_exact :: proc(t: ^testing.T) {
	_, session := time_pong_session(t)
	s := session
	session_request(&s, `{"id":1,"cmd":"load"}`)
	session_request(&s, `{"id":2,"cmd":"run"}`)

	// 600 ticks push cadence snapshots 0,16,…,592 (38) through 32 slots: the six
	// oldest insertions (0..80) are evicted — oldest retained 96, newest 592.
	status := session_request(&s, `{"id":3,"cmd":"status"}`)
	testing.expect(
		t,
		strings.contains(status, `"ring":{"slots":32,"occupied":32,"oldest":96,"newest":592}`),
		"the full run must leave the ring at capacity with the six oldest insertions evicted",
	)

	// Rewind into ring coverage: base 288, two ticks re-folded — bit-exact and
	// digest-equal to the canonical tick 290.
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

	// Rewind below the oldest retained entry (96): the permanent post-startup
	// floor is the base — a longer re-fold, never a refusal.
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

	// Rewind forward again: ring entries ahead of the cursor snapshot the same
	// deterministic canonical timeline, so they remain valid restore bases.
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

// reset returns to tick zero's fold base — the post-startup version — and a
// step from there reproduces canonical tick 0; rewind to -1 is the same floor.
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

// THE SEEDED ACCEPTANCE — the cursor threads the recorded Rng: run/rewind/step
// across the snake eat tick (whose commit carries an RNG-drawn replacement
// food) stay bit-exact against the canonical seeded chain, and the cursor's
// Rng sits at the canonical entering state of every boundary it visits.
@(test)
test_time_seeded_rewind_rethreads_rng :: proc(t: ^testing.T) {
	program := new(Program, context.allocator)
	loaded, err := load_program(GOLDEN_SNAKE_ARTIFACT, context.allocator)
	testing.expect(t, err == .None, "golden snake artifact must load")
	program^ = loaded
	inputs := make([]Input, 16, context.allocator)
	for i in 0 ..< 16 {
		// The golden scripted session: one Down press at tick 6 steers the snake
		// onto the seed-spawned food (the same script the seeded observe tests pin).
		inputs[i] = i == 6 ? with_pressed(empty(), .P1, ActionId(1)) : empty()
	}
	session := open_debug_session(program, inputs, seeded_run(42), context.allocator)
	s := session

	// The eat tick: the first boundary whose entering Rng differs from the next —
	// the replenish draw. Derived from the session's retained chain.
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

	// Rewind to the eat tick: the re-fold crosses the draw, so a wrong
	// re-threaded Rng would place the replacement food in a different cell.
	session_request(&s, fmt.tprintf(`{{"id":3,"cmd":"rewind","args":{{"tick":%d}}}}`, eat_tick))
	testing.expect(
		t,
		world_versions_equal(s.cursor.head, s.versions[eat_tick]),
		"the seeded rewind must reproduce the canonical eat tick — RNG-drawn food included",
	)
	testing.expect_value(t, s.cursor.rng.state, s.rngs[eat_tick + 1].state)

	// One step off the rewound position continues the canonical thread.
	session_request(&s, `{"id":4,"cmd":"step"}`)
	testing.expect(
		t,
		world_versions_equal(s.cursor.head, s.versions[eat_tick + 1]),
		"a step off the rewound eat tick must continue the canonical seeded chain",
	)
}

// The time battery is observe-class: a full walk (load, runs, steps, rewinds,
// reset) leaves the session's canonical chain digest-pinned bit-identical —
// the cursor folds into its own lineage and never writes the retained chain.
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

// Every unservable time request is refused with a well-formed envelope: the
// navigation commands demand a loaded timeline, step refuses the end of the
// recording, and run/rewind refuse out-of-range or backward targets.
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
