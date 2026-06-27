package funpack_runtime

import "core:strings"
import "core:testing"

@(private = "file")
LIVE_BREAK_FIXTURE :: "funpack-artifact 19\n" +
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

@(test)
test_live_break_when_pauses_on_predicate :: proc(t: ^testing.T) {
	_, session, ok := live_break_session(t, 8)
	if !ok {
		return
	}
	s := session
	response := session_request(
		&s,
		`{"id":1,"cmd":"break","args":{"target":"tick_counter","body":["node binary gt 2","node field n 1","node name self 0","node int 2 0"]}}`,
	)
	testing.expect(t, strings.contains(response, `"ok":true`), "a well-formed break{when} must register")
	testing.expect(t, strings.contains(response, `"cmd":"break"`), "the response names the break command")
	testing.expect(t, strings.contains(response, `"handle":0`), "the first live probe mints handle 0")
	testing.expect(t, strings.contains(response, `"live":1`), "the registry holds one live probe")
	testing.expect(t, strings.contains(response, `"event":"breakpoint_hit"`), "the break must emit breakpoint_hit")
	testing.expect(t, strings.contains(response, `"target":"tick_counter"`), "the hit names the probed behavior")
	testing.expect(t, strings.contains(response, `"tick":3`), "the predicate first holds at tick 3")
	testing.expect(t, strings.contains(response, "Counter(n=3,"), "the hit carries the self blackboard at the pause")
}

@(test)
test_live_watch_fires_on_change :: proc(t: ^testing.T) {
	_, session, ok := live_break_session(t, 5)
	if !ok {
		return
	}
	s := session
	response := session_request(
		&s,
		`{"id":2,"cmd":"watch","args":{"target":"tick_counter","body":["node field n 1","node name self 0"]}}`,
	)
	testing.expect(t, strings.contains(response, `"ok":true`), "a well-formed watch must register")
	testing.expect(t, strings.contains(response, `"cmd":"watch"`), "the response names the watch command")
	testing.expect(t, strings.contains(response, `"handle":0`), "the first live probe mints handle 0")
	testing.expect(t, strings.contains(response, `"event":"watch_fired"`), "the watch must emit watch_fired")
	testing.expect(t, strings.contains(response, `"target":"tick_counter"`), "the fire names the watched behavior")
	testing.expect(t, strings.contains(response, `"old":"0"`), "the first change is 0 → ...")
	testing.expect(t, strings.contains(response, `"new":"1"`), "... → 1 at tick 1")
}

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

	cleared := session_request(&s, `{"id":2,"cmd":"clear","args":{"handle":0}}`)
	testing.expect(t, strings.contains(cleared, `"ok":true`), "clear must succeed for a live handle")
	testing.expect(t, strings.contains(cleared, `"cleared":0`), "the response names the cleared handle")
	testing.expect(t, strings.contains(cleared, `"live":0`), "the registry is now empty")
	testing.expect_value(t, len(s.live_probes), 0)

	reset := session_request(
		&s,
		`{"id":3,"cmd":"watch","args":{"target":"tick_counter","body":["node field n 1","node name self 0"]}}`,
	)
	testing.expect(t, strings.contains(reset, `"handle":1`), "the next live probe mints handle 1, the cleared one freed")
	testing.expect_value(t, len(s.live_probes), 1)

	miss := session_request(&s, `{"id":4,"cmd":"clear","args":{"handle":99}}`)
	testing.expect(t, strings.contains(miss, `"ok":false`), "an unknown handle is refused")
	testing.expect(t, strings.contains(miss, "no live probe with that handle"), "the refusal names the missing handle")
}

@(test)
test_live_break_node_forest_predicate_folds :: proc(t: ^testing.T) {
	_, session, ok := live_break_session(t, 8)
	if !ok {
		return
	}
	s := session
	response := session_request(
		&s,
		`{"id":1,"cmd":"break","args":{"target":"tick_counter","body":[`+
		`"node binary and 2",`+
		`"node binary gt 2","node field n 1","node name self 0","node int 2 0",`+
		`"node binary gt 2","node field pos 1","node name self 0","node fixed 0 0"]}}`,
	)
	testing.expect(t, strings.contains(response, `"ok":true`), "a multi-node predicate must register")
	testing.expect(t, strings.contains(response, `"event":"breakpoint_hit"`), "the conjunction must fire when it holds")
	testing.expect(t, strings.contains(response, `"tick":3`), "the conjunction first holds at tick 3")
}

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
	testing.expect(t, strings.contains(response, `"event":"breakpoint_hit"`), "a routed Goal must fire breakpoint_hit")
	testing.expect(t, strings.contains(response, `"target":"Goal"`), "the hit names the routed signal type")
}

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
		{`{"id":1,"cmd":"break","args":{"target":"tick_counter"}}`, "missing or malformed args.body"},
		{`{"id":2,"cmd":"break","args":{"on_signal":"Goal","body":["node int 1 0"]}}`, "either {on_signal} or {when"},
		{`{"id":3,"cmd":"break","args":{"target":"ghost","body":["node int 1 0"]}}`, "unknown behavior"},
		{`{"id":4,"cmd":"break","args":{"on_signal":"Nope"}}`, "unknown signal"},
		{`{"id":5,"cmd":"watch","args":{"target":"ghost","body":["node int 1 0"]}}`, "unknown behavior"},
		{`{"id":6,"cmd":"watch","args":{"target":"tick_counter","body":["node int 1 0","node int 2 0"]}}`, "missing or malformed args.body"},
		{`{"id":7,"cmd":"watch","args":{"target":"tick_counter","body":[42]}}`, "missing or malformed args.body"},
		{`{"id":8,"cmd":"clear","args":{}}`, "missing args.handle"},
	}
	for entry in cases {
		response := session_request(&s, entry.request)
		testing.expect(t, strings.contains(response, `"ok":false`), "a refused break-group command must answer ok:false")
		testing.expect(t, strings.contains(response, entry.fragment), entry.fragment)
	}
	testing.expect_value(t, len(s.live_probes), 0)
}

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

@(test)
test_live_break_group_non_perturbing_digest_pin :: proc(t: ^testing.T) {
	program, session, ok := live_break_session(t, 16)
	if !ok {
		return
	}
	s := session
	baseline, baseline_final := reference_unprobed_capture(program, s.snapshots)

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
