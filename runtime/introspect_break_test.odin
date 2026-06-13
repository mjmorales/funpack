// §28 §3 BREAK-GROUP acceptance: the LIVE, dynamically-set break/watch/clear
// commands — the runtime counterpart to the in-code @break/@watch directives. A
// session-set break{when:<pred>} pauses when a node-forest predicate holds (the
// breakpoint_hit async event); a break{on_signal} pauses on a routed signal; a watch
// fires watch_fired on a value change; clear removes a live probe by handle. The
// predicate/expression bodies are NODE FORESTS supplied OVER THE WIRE (§28 §2: the
// runtime never compiles funpack source live), folded through the EXISTING interpreter
// exactly as the honored in-code probes are. The battery proves the wire-set honor AND
// the determinism warranty: a session with live probes set digests its canonical chain
// bit-identical to one with none (the break group is OBSERVE-class — it pauses and
// reports, it does not mutate the recorded fold).
//
// FIXTURE TECHNIQUE (Lore #8/#14, mirroring probes_test.odin): a hand-built
// node-forest artifact carrying a behavior with NO in-code probes ([probes 0] tail),
// so the honor surface under test is purely the SESSION-SET live probes — set over the
// wire as the SAME `node KIND … child_count` line run the [probes] section carries. The
// break{on_signal} path is proven over the real golden pong run, which routes a Goal
// signal (the same dataflow the `signals` observe reads).
package funpack_runtime

import "core:strings"
import "core:testing"

// LIVE_BREAK_FIXTURE is a minimal one-behavior artifact carrying NO in-code probes —
// the [probes 0] tail — so every probe honored in these tests is SESSION-SET over the
// wire. The Counter thing's `n: Int` advances n+1 every step (so a wire watch{self.n}
// sees a change every tick and a wire break{self.n > 2} crosses its threshold
// mid-run); `pos: Fixed` advances 1.0/tick (a second evolving column for a distinct
// per-tick digest). Identical behavior to probes_test.odin's PROBED_FIXTURE minus the
// in-code [probes] records — the live group adds them at session time instead.
@(private = "file")
LIVE_BREAK_FIXTURE :: "funpack-artifact 18\n" +
	"[meta 2]\n" +
	"project livebreak\n" +
	"version L5:0.1.0\n" +
	"[things 1]\n" +
	"thing Counter false 0 2\n" +
	"field n Int =0\n" +
	"field pos Fixed =0\n" +
	"[behaviors 1]\n" +
	"behavior tick_counter on:Counter stage:control contract:Update 0 1 1 1\n" +
	"param self Counter\n" +
	"emit Counter\n" +
	"node return 1\n" +
	"node with 2 3\n" +
	"node name self 0\n" +
	"node recfield n 1\n" +
	"node binary add 2\n" +
	"node field n 1\n" +
	"node name self 0\n" +
	"node int 1 0\n" +
	"node recfield pos 1\n" +
	"node binary add 2\n" +
	"node field pos 1\n" +
	"node name self 0\n" +
	"node fixed 4294967296 0\n" +
	"[pipeline_flattened 1]\n" +
	"step 0 stage:control behavior:tick_counter\n" +
	"[setup 1]\n" +
	"spawn Counter 0\n" +
	"[entrypoint 1]\n" +
	"entrypoint main pipeline:Live tick_hz:60 logical:160x120 bindings:bindings\n" +
	"[probes 0]\n"

// live_break_session loads the probe-free fixture and opens a session over `ticks`
// empty input snapshots — the shared opener the live break/watch battery drives wire
// commands against.
@(private = "file")
live_break_session :: proc(
	t: ^testing.T,
	ticks: int,
	allocator := context.allocator,
) -> (
	program: ^Program,
	session: Debug_Session,
	ok: bool,
) {
	program = new(Program, allocator)
	loaded, err := load_program(LIVE_BREAK_FIXTURE, allocator)
	if !testing.expectf(t, err == .None, "live-break fixture must load, got %v", err) {
		return nil, {}, false
	}
	program^ = loaded
	inputs := make([]Input, ticks, allocator)
	for i in 0 ..< ticks {
		inputs[i] = empty()
	}
	session = open_debug_session(program, inputs, NO_SEED, allocator)
	return program, session, true
}

// A wire break{when:<pred>} pauses + emits breakpoint_hit: a session-set break whose
// predicate `self.n > 2` is supplied as a NODE FOREST over the wire (the SAME line run
// the [probes] section carries) fires at the exact tick the predicate first holds —
// proving the live break is honored through the same seam an in-code @break is, just
// session-set. The response carries the breakpoint_hit firings the new break produced.
@(test)
test_live_break_when_pauses_on_predicate :: proc(t: ^testing.T) {
	_, session, ok := live_break_session(t, 8)
	if !ok {
		return
	}
	s := session
	// break{when: self.n > 2}, the predicate as a wire node forest — the SAME
	// `binary gt` over a field access and an int the artifact emits.
	response := session_request(
		&s,
		`{"id":1,"cmd":"break","args":{"target":"tick_counter","body":["node binary gt 2","node field n 1","node name self 0","node int 2 0"]}}`,
	)
	testing.expect(t, strings.contains(response, `"ok":true`), "a well-formed break{when} must register")
	testing.expect(t, strings.contains(response, `"cmd":"break"`), "the response names the break command")
	testing.expect(t, strings.contains(response, `"handle":0`), "the first live probe mints handle 0")
	testing.expect(t, strings.contains(response, `"live":1`), "the registry holds one live probe")
	// The predicate `self.n > 2` first holds when the bound self.n entering the tick
	// is 3 (tick i commits n=i+1, so self.n entering tick 3 is 3) — a breakpoint_hit
	// stamped at tick 3, carrying the target and the self blackboard (§28 §2).
	testing.expect(t, strings.contains(response, `"event":"breakpoint_hit"`), "the break must emit breakpoint_hit")
	testing.expect(t, strings.contains(response, `"target":"tick_counter"`), "the hit names the probed behavior")
	testing.expect(t, strings.contains(response, `"tick":3`), "the predicate first holds at tick 3")
	testing.expect(t, strings.contains(response, "Counter(n=3,"), "the hit carries the self blackboard at the pause")
}

// A wire watch{<expr>} emits watch_fired on a value CHANGE: a session-set watch whose
// expression `self.n` is supplied as a node forest over the wire fires watch_fired
// every tick AFTER the first observation (which establishes the baseline) — the value
// changes every step, so the stream carries the old → new value each tick.
@(test)
test_live_watch_fires_on_change :: proc(t: ^testing.T) {
	_, session, ok := live_break_session(t, 5)
	if !ok {
		return
	}
	s := session
	// watch{self.n}, the watched expression as a wire node forest.
	response := session_request(
		&s,
		`{"id":2,"cmd":"watch","args":{"target":"tick_counter","body":["node field n 1","node name self 0"]}}`,
	)
	testing.expect(t, strings.contains(response, `"ok":true`), "a well-formed watch must register")
	testing.expect(t, strings.contains(response, `"cmd":"watch"`), "the response names the watch command")
	testing.expect(t, strings.contains(response, `"handle":0`), "the first live probe mints handle 0")
	// 5 ticks: bound self.n is 0,1,2,3,4. Tick 0 establishes the baseline (0), ticks
	// 1..4 each differ from the prior → 4 fires, the first at tick 1 (0 → 1).
	testing.expect(t, strings.contains(response, `"event":"watch_fired"`), "the watch must emit watch_fired")
	testing.expect(t, strings.contains(response, `"target":"tick_counter"`), "the fire names the watched behavior")
	testing.expect(t, strings.contains(response, `"old":"0"`), "the first change is 0 → ...")
	testing.expect(t, strings.contains(response, `"new":"1"`), "... → 1 at tick 1")
}

// clear removes a live probe by handle: after a clear the probe is gone from the
// registry (its firings no longer ride a subsequent re-fold). An unknown handle is a
// well-formed refusal, never a silent no-op (a stale clear surfaces).
@(test)
test_live_clear_removes_probe :: proc(t: ^testing.T) {
	_, session, ok := live_break_session(t, 5)
	if !ok {
		return
	}
	s := session
	set := session_request(
		&s,
		`{"id":1,"cmd":"watch","args":{"target":"tick_counter","body":["node field n 1","node name self 0"]}}`,
	)
	testing.expect(t, strings.contains(set, `"handle":0`), "the watch mints handle 0")
	testing.expect_value(t, len(s.live_probes), 1)

	// Clearing the live probe by handle removes it — the registry shrinks to empty.
	cleared := session_request(&s, `{"id":2,"cmd":"clear","args":{"handle":0}}`)
	testing.expect(t, strings.contains(cleared, `"ok":true`), "clear must succeed for a live handle")
	testing.expect(t, strings.contains(cleared, `"cleared":0`), "the response names the cleared handle")
	testing.expect(t, strings.contains(cleared, `"live":0`), "the registry is now empty")
	testing.expect_value(t, len(s.live_probes), 0)

	// A re-set watch + re-fold now sees only the new probe — the cleared one is gone.
	reset := session_request(
		&s,
		`{"id":3,"cmd":"watch","args":{"target":"tick_counter","body":["node field n 1","node name self 0"]}}`,
	)
	testing.expect(t, strings.contains(reset, `"handle":1`), "the next live probe mints handle 1, the cleared one freed")
	testing.expect_value(t, len(s.live_probes), 1)

	// Clearing an unknown handle is refused, not a silent no-op.
	miss := session_request(&s, `{"id":4,"cmd":"clear","args":{"handle":99}}`)
	testing.expect(t, strings.contains(miss, `"ok":false`), "an unknown handle is refused")
	testing.expect(t, strings.contains(miss, "no live probe with that handle"), "the refusal names the missing handle")
}

// A NODE-FOREST PREDICATE over self folds correctly: a richer wire predicate
// `self.n > 2 and self.pos > 0` (a `binary and` over two comparisons, the SAME
// multi-node forest funpack emits) folds through the existing interpreter against the
// bound self exactly as an in-code probe would — proving the live break interprets an
// arbitrary client-supplied node forest, not just a trivial leaf. self.pos advances
// 1.0/tick, so it exceeds 0 from tick 1 on; the conjunction first holds when self.n
// also exceeds 2, i.e. tick 3.
@(test)
test_live_break_node_forest_predicate_folds :: proc(t: ^testing.T) {
	_, session, ok := live_break_session(t, 8)
	if !ok {
		return
	}
	s := session
	// break{when: self.n > 2 and self.pos > 0} — a two-comparison conjunction over
	// self, supplied as the flat pre-order node forest. pos is Fixed: `self.pos > 0`
	// compares the Fixed lane against a fixed-0 literal (raw bits 0).
	response := session_request(
		&s,
		`{"id":1,"cmd":"break","args":{"target":"tick_counter","body":[`+
		`"node binary and 2",`+
		`"node binary gt 2","node field n 1","node name self 0","node int 2 0",`+
		`"node binary gt 2","node field pos 1","node name self 0","node fixed 0 0"]}}`,
	)
	testing.expect(t, strings.contains(response, `"ok":true`), "a multi-node predicate must register")
	testing.expect(t, strings.contains(response, `"event":"breakpoint_hit"`), "the conjunction must fire when it holds")
	// The conjunction first holds at tick 3 (self.n entering tick 3 is 3 > 2, and
	// self.pos entering tick 3 is 3.0 > 0).
	testing.expect(t, strings.contains(response, `"tick":3`), "the conjunction first holds at tick 3")
}

// break{on_signal} pauses on a ROUTED signal: over the golden pong run a
// break{on_signal:Goal} fires breakpoint_hit at the tick the score behavior routes a
// Goal broadcast — the live twin of a signal-triggered pause, honored over the SAME
// signal dataflow the `signals` observe reads (§28 §1). The hit names the signal as
// its target (addressing reuses index identity, §28 §2).
@(test)
test_live_break_on_signal_pauses_on_route :: proc(t: ^testing.T) {
	program := new(Program, context.allocator)
	loaded, err := load_program(GOLDEN_ARTIFACT, context.allocator)
	if !testing.expect(t, err == .None, "golden pong artifact must load") {
		return
	}
	program^ = loaded
	session := open_debug_session(program, golden_session_inputs(context.allocator), NO_SEED, context.allocator)
	s := session

	response := session_request(&s, `{"id":1,"cmd":"break","args":{"on_signal":"Goal"}}`)
	testing.expect(t, strings.contains(response, `"ok":true`), "break{on_signal:Goal} must register")
	testing.expect(t, strings.contains(response, `"handle":0`), "the signal break mints handle 0")
	// The golden run routes at least one Goal (the signals observe pins this), so the
	// signal break fires breakpoint_hit naming Goal as the target.
	testing.expect(t, strings.contains(response, `"event":"breakpoint_hit"`), "a routed Goal must fire breakpoint_hit")
	testing.expect(t, strings.contains(response, `"target":"Goal"`), "the hit names the routed signal type")
}

// break{on_signal} on an UNKNOWN signal is refused (addressing reuses index identity,
// §28 §2: the named signal must be a declared type), and a break/watch with a
// malformed or missing node-forest body is refused — every reject a well-formed
// envelope, never a crash and never a partial probe.
@(test)
test_live_break_arg_refusals :: proc(t: ^testing.T) {
	_, session, ok := live_break_session(t, 4)
	if !ok {
		return
	}
	s := session

	cases := [?]struct {
		request:  string,
		fragment: string,
	} {
		// A break with neither {when:body} nor {on_signal}.
		{`{"id":1,"cmd":"break","args":{"target":"tick_counter"}}`, "missing or malformed args.body"},
		// A break with both forms at once.
		{`{"id":2,"cmd":"break","args":{"on_signal":"Goal","body":["node int 1 0"]}}`, "either {on_signal} or {when"},
		// A break{when} on an unknown behavior.
		{`{"id":3,"cmd":"break","args":{"target":"ghost","body":["node int 1 0"]}}`, "unknown behavior"},
		// A break{on_signal} on an unknown signal type.
		{`{"id":4,"cmd":"break","args":{"on_signal":"Nope"}}`, "unknown signal"},
		// A watch on an unknown behavior.
		{`{"id":5,"cmd":"watch","args":{"target":"ghost","body":["node int 1 0"]}}`, "unknown behavior"},
		// A watch with a body that does not fold to exactly one subtree (two top-level
		// nodes — an over-shaped forest the wire parse refuses).
		{`{"id":6,"cmd":"watch","args":{"target":"tick_counter","body":["node int 1 0","node int 2 0"]}}`, "missing or malformed args.body"},
		// A watch with a non-string body element.
		{`{"id":7,"cmd":"watch","args":{"target":"tick_counter","body":[42]}}`, "missing or malformed args.body"},
		// A clear with no handle.
		{`{"id":8,"cmd":"clear","args":{}}`, "missing args.handle"},
	}
	for entry in cases {
		response := session_request(&s, entry.request)
		testing.expect(t, strings.contains(response, `"ok":false`), "a refused break-group command must answer ok:false")
		testing.expect(t, strings.contains(response, entry.fragment), entry.fragment)
	}
	// Every refusal left the registry empty — a refused command registers nothing.
	testing.expect_value(t, len(s.live_probes), 0)
}

// reference_unprobed_capture folds the live-break fixture's run with NO honor tap —
// the production seam verbatim — capturing per-tick digests and the final committed
// version. It is the ground truth the non-perturbation pin compares the live-probed
// session against.
@(private = "file")
reference_unprobed_capture :: proc(
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

// THE NON-PERTURBATION PIN (§28 §2: the break group is OBSERVE-class). A session that
// SETS a live break AND a live watch over the wire — both firing over the recording —
// digests its canonical chain bit-identical to a run nobody probed: per-tick digests,
// session digest, and the final committed world. Setting and honoring a live probe is
// a pure read of the recorded fold (the predicate/expression folds against the bound
// scope, the re-fold builds its own scratch chain), so a live break/watch pauses and
// reports without changing the recorded fold — exactly the in-code probe warranty,
// now for session-set probes. This is why break/watch/clear sit in the OBSERVE column.
@(test)
test_live_break_group_non_perturbing_digest_pin :: proc(t: ^testing.T) {
	program, session, ok := live_break_session(t, 16)
	if !ok {
		return
	}
	s := session
	baseline, baseline_final := reference_unprobed_capture(program, s.snapshots)

	// Set a live break AND a live watch — both fire over the recording (the responses
	// carry their firings), so the pin proves non-perturbation DESPITE active firings.
	break_resp := session_request(
		&s,
		`{"id":1,"cmd":"break","args":{"target":"tick_counter","body":["node binary gt 2","node field n 1","node name self 0","node int 2 0"]}}`,
	)
	testing.expect(t, strings.contains(break_resp, `"event":"breakpoint_hit"`), "the live break fired during the re-fold")
	watch_resp := session_request(
		&s,
		`{"id":2,"cmd":"watch","args":{"target":"tick_counter","body":["node field n 1","node name self 0"]}}`,
	)
	testing.expect(t, strings.contains(watch_resp, `"event":"watch_fired"`), "the live watch fired during the re-fold")
	testing.expect_value(t, len(s.live_probes), 2)

	// THE WARRANTY: the session's canonical chain (built at open, never touched by
	// setting or honoring a live probe) still digests bit-identical to the unprobed
	// run — the live break/watch re-folds into scratch, leaving the trunk untouched.
	probed := session_capture(&s)
	testing.expect_value(t, len(probed.per_tick), len(baseline.per_tick))
	for frame, i in probed.per_tick {
		testing.expect_value(t, frame.tick, baseline.per_tick[i].tick)
		testing.expect_value(t, frame.digest, baseline.per_tick[i].digest)
	}
	testing.expect_value(t, probed.session, baseline.session)
	testing.expect(
		t,
		world_versions_equal(s.versions[len(s.versions) - 1], baseline_final),
		"the session's canonical chain must equal the unprobed run's — setting a live break/watch touches no trunk version",
	)
}
