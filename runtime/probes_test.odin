package funpack_runtime

import "core:strings"
import "core:testing"

@(private = "file")
PROBED_FIXTURE :: "funpack-artifact 19\n" +
	"[meta 2]\n" +
	"project probed\n" +
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
	"entrypoint main pipeline:Probed tick_hz:60 logical:160x120 bindings:bindings\n" +
	"[probes 4]\n" +
	"probe break tick_counter 1\n" +
	"node binary gt 2\n" +
	"node field n 1\n" +
	"node name self 0\n" +
	"node int 2 0\n" +
	"probe watch tick_counter 1\n" +
	"node field n 1\n" +
	"node name self 0\n" +
	"probe log tick_counter 1\n" +
	"node field n 1\n" +
	"node name self 0\n" +
	"probe trace tick_counter 0\n"

@(private = "file")
probed_session :: proc(
	t: ^testing.T,
	ticks: int,
	allocator := context.allocator,
) -> (
	program: ^Program,
	session: Debug_Session,
	ok: bool,
) {
	program = new(Program, allocator)
	loaded, err := load_program(PROBED_FIXTURE, allocator)
	if !testing.expectf(t, err == .None, "probed fixture must load, got %v", err) {
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
test_load_probes_section :: proc(t: ^testing.T) {
	program, err := load_program(PROBED_FIXTURE, context.temp_allocator)
	if !testing.expectf(t, err == .None, "probed fixture must load, got %v", err) {
		return
	}
	testing.expect_value(t, len(program.probes), 4)

	testing.expect_value(t, program.probes[0].kind, Probe_Kind.Break)
	testing.expect_value(t, program.probes[0].target, "tick_counter")
	testing.expect_value(t, len(program.probes[0].body), 1)
	testing.expect_value(t, program.probes[0].body[0].kind, Node_Kind.Binary)

	testing.expect_value(t, program.probes[1].kind, Probe_Kind.Watch)
	testing.expect_value(t, len(program.probes[1].body), 1)
	testing.expect_value(t, program.probes[1].body[0].kind, Node_Kind.Field)

	testing.expect_value(t, program.probes[2].kind, Probe_Kind.Log)
	testing.expect_value(t, len(program.probes[2].body), 1)

	testing.expect_value(t, program.probes[3].kind, Probe_Kind.Trace)
	testing.expect_value(t, len(program.probes[3].body), 0)
}

@(test)
test_load_probes_malformed_refused :: proc(t: ^testing.T) {
	unknown_kind := "funpack-artifact 19\n[probes 1]\nprobe poke tick_counter 0\n"
	_, kind_err := load_program(unknown_kind, context.temp_allocator)
	testing.expect_value(t, kind_err, Artifact_Error.Bad_Field)

	short_body := "funpack-artifact 19\n[probes 1]\nprobe break tick_counter 1\n"
	_, body_err := load_program(short_body, context.temp_allocator)
	testing.expect_value(t, body_err, Artifact_Error.Body_Count_Mismatch)

	long_body := "funpack-artifact 19\n[probes 1]\nprobe trace tick_counter 0\nnode int 1 0\n"
	_, long_err := load_program(long_body, context.temp_allocator)
	testing.expect_value(t, long_err, Artifact_Error.Body_Count_Mismatch)
}

@(test)
test_honor_break_pauses_on_predicate :: proc(t: ^testing.T) {
	_, session, ok := probed_session(t, 8)
	if !ok {
		return
	}
	s := session
	honor, _ := session_honor_probes(&s)

	if !testing.expect(t, len(honor.breaks) >= 1, "a @break must fire when its predicate holds") {
		return
	}
	first := honor.breaks[0]
	testing.expect_value(t, first.target, "tick_counter")
	testing.expect_value(t, first.behavior, "tick_counter")
	testing.expect_value(t, first.tick, 3)
	testing.expect_value(t, len(honor.breaks), 5)

	event := render_breakpoint_hit_event(first)
	testing.expect(t, strings.contains(event, `"v":1`))
	testing.expect(t, strings.contains(event, `"event":"breakpoint_hit"`))
	testing.expect(t, strings.contains(event, `"target":"tick_counter"`))
	testing.expect(t, strings.contains(event, `"tick":3`))
	testing.expect(t, strings.contains(event, "Counter(n=3,"))
}

@(test)
test_honor_watch_fires_on_change :: proc(t: ^testing.T) {
	_, session, ok := probed_session(t, 5)
	if !ok {
		return
	}
	s := session
	honor, _ := session_honor_probes(&s)

	testing.expect_value(t, len(honor.watches), 4)

	first := honor.watches[0]
	testing.expect_value(t, first.target, "tick_counter")
	testing.expect_value(t, first.tick, 1)
	testing.expect_value(t, first.old_enc, "0")
	testing.expect_value(t, first.new_enc, "1")

	event := render_watch_fired_event(first)
	testing.expect(t, strings.contains(event, `"event":"watch_fired"`))
	testing.expect(t, strings.contains(event, `"target":"tick_counter"`))
	testing.expect(t, strings.contains(event, `"old":"0"`))
	testing.expect(t, strings.contains(event, `"new":"1"`))
}

@(test)
test_honor_log_emits_each_step :: proc(t: ^testing.T) {
	_, session, ok := probed_session(t, 5)
	if !ok {
		return
	}
	s := session
	honor, _ := session_honor_probes(&s)

	testing.expect_value(t, len(honor.logs), 5)
	expected := [?]string{"0", "1", "2", "3", "4"}
	for emit, i in honor.logs {
		testing.expect_value(t, emit.tick, i)
		testing.expect_value(t, emit.behavior, "tick_counter")
		testing.expect_value(t, emit.value_enc, expected[i])
	}
}

@(test)
test_honor_trace_records_transitions :: proc(t: ^testing.T) {
	_, session, ok := probed_session(t, 4)
	if !ok {
		return
	}
	s := session
	honor, _ := session_honor_probes(&s)

	testing.expect_value(t, len(honor.traces), 4)
	first := honor.traces[0]
	testing.expect_value(t, first.behavior, "tick_counter")
	testing.expect_value(t, first.tick, 0)
	testing.expect(t, first.ok)
	testing.expect(t, strings.contains(first.self_before, "Counter(n=0,"))
	testing.expect(t, strings.contains(first.result_enc, "n=1"))
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
test_honor_non_perturbing_digest_pin :: proc(t: ^testing.T) {
	program, session, ok := probed_session(t, 16)
	if !ok {
		return
	}
	s := session
	baseline, baseline_final := reference_unprobed_capture(program, s.snapshots)

	honor, honored_final := session_honor_probes(&s)
	testing.expect(t, len(honor.breaks) > 0, "the @break fired during the honored run")
	testing.expect(t, len(honor.watches) > 0, "the @watch fired during the honored run")
	testing.expect(t, len(honor.logs) > 0, "the @log emitted during the honored run")
	testing.expect(t, len(honor.traces) > 0, "the @trace recorded during the honored run")

	testing.expect(
		t,
		world_versions_equal(honored_final, baseline_final),
		"the honored fold's final committed world must equal the unprobed run's — honoring is non-perturbing",
	)

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
		"the session's canonical chain must equal the unprobed run's — honoring touches no trunk version",
	)
}

@(test)
test_load_empty_probes_tail :: proc(t: ^testing.T) {
	probe_free := "funpack-artifact 19\n[meta 2]\nproject bare\nversion L5:0.1.0\n[probes 0]\n"
	program, err := load_program(probe_free, context.temp_allocator)
	testing.expect_value(t, err, Artifact_Error.None)
	testing.expect_value(t, len(program.probes), 0)
}
