package funpack_runtime

import "core:strings"
import "core:testing"

@(private = "file")
QUALIFIED_FIXTURE :: "funpack-artifact 19\n" +
	"[meta 2]\n" +
	"project qualified\n" +
	"version L5:0.1.0\n" +
	"[data 1]\n" +
	"data DriftLog 1 false\n" +
	"field bias Fixed -\n" +
	"[things 1]\n" +
	"thing Counter false 0 1\n" +
	"field n Int =0\n" +
	"[behaviors 1]\n" +
	"behavior tick_counter on:Counter stage:control contract:Update 0 1 1 1\n" +
	"param self Counter\n" +
	"emit Counter\n" +
	"node return 1\n" +
	"node with 1 2\n" +
	"node name self 0\n" +
	"node recfield n 1\n" +
	"node binary add 2\n" +
	"node field n 1\n" +
	"node name self 0\n" +
	"node int 1 0\n" +
	"[pipeline_flattened 1]\n" +
	"step 0 stage:control behavior:tick_counter\n" +
	"[setup 1]\n" +
	"spawn Counter 0\n" +
	"[entrypoint 1]\n" +
	"entrypoint main pipeline:Loop tick_hz:60 logical:160x120 bindings:bindings\n" +
	"[probes 3]\n" +
	"probe watch DriftLog.bias 1\n" +
	"node field bias 1\n" +
	"node name self 0\n" +
	"probe trace Loop.control 0\n" +
	"probe trace tick_counter 0\n"

@(private = "file")
qualified_session :: proc(
	t: ^testing.T,
	ticks: int,
	allocator := context.allocator,
) -> (
	program: ^Program,
	session: Debug_Session,
	ok: bool,
) {
	program = new(Program, allocator)
	loaded, err := load_program(QUALIFIED_FIXTURE, allocator)
	if !testing.expectf(t, err == .None, "qualified fixture must load, got %v", err) {
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
test_split_qualified_target :: proc(t: ^testing.T) {
	owner, member, qualified := split_qualified_target("Loop.control")
	testing.expect(t, qualified)
	testing.expect_value(t, owner, "Loop")
	testing.expect_value(t, member, "control")

	d_owner, d_member, d_qualified := split_qualified_target("DriftLog.bias")
	testing.expect(t, d_qualified)
	testing.expect_value(t, d_owner, "DriftLog")
	testing.expect_value(t, d_member, "bias")

	_, _, bare := split_qualified_target("tick_counter")
	testing.expect(t, !bare)
}

@(test)
test_honor_stage_trace_records_transitions :: proc(t: ^testing.T) {
	_, session, ok := qualified_session(t, 4)
	if !ok {
		return
	}
	s := session
	honor, _ := session_honor_probes(&s)

	stage_traces := make([dynamic]Trace_Record, context.temp_allocator)
	for rec in honor.traces {
		if rec.target == "Loop.control" {
			append(&stage_traces, rec)
		}
	}
	testing.expect_value(t, len(stage_traces), 4)

	first := stage_traces[0]
	testing.expect_value(t, first.behavior, "tick_counter")
	testing.expect_value(t, first.target, "Loop.control")
	testing.expect_value(t, first.tick, 0)
	testing.expect(t, first.ok)
	testing.expect(t, strings.contains(first.self_before, "Counter(n=0"))
	testing.expect(t, strings.contains(first.result_enc, "n=1"))

	third := stage_traces[2]
	testing.expect_value(t, third.tick, 2)
	testing.expect(t, strings.contains(third.self_before, "Counter(n=2"))
	testing.expect(t, strings.contains(third.result_enc, "n=3"))
}

@(test)
test_honor_field_watch_data_fails_closed :: proc(t: ^testing.T) {
	_, session, ok := qualified_session(t, 8)
	if !ok {
		return
	}
	s := session
	honor, _ := session_honor_probes(&s)

	testing.expect_value(t, len(honor.watches), 0)
	for fire in honor.watches {
		testing.expect(t, fire.target != "DriftLog.bias", "a data-field @watch has no live honor site")
	}
}

@(test)
test_honor_unknown_stage_target_fails_closed :: proc(t: ^testing.T) {
	unknown_stage := "funpack-artifact 19\n" +
		"[meta 2]\n" +
		"project unknownstage\n" +
		"version L5:0.1.0\n" +
		"[things 1]\n" +
		"thing Counter false 0 1\n" +
		"field n Int =0\n" +
		"[behaviors 1]\n" +
		"behavior tick_counter on:Counter stage:control contract:Update 0 1 1 1\n" +
		"param self Counter\n" +
		"emit Counter\n" +
		"node return 1\n" +
		"node with 1 2\n" +
		"node name self 0\n" +
		"node recfield n 1\n" +
		"node binary add 2\n" +
		"node field n 1\n" +
		"node name self 0\n" +
		"node int 1 0\n" +
		"[pipeline_flattened 1]\n" +
		"step 0 stage:control behavior:tick_counter\n" +
		"[setup 1]\n" +
		"spawn Counter 0\n" +
		"[entrypoint 1]\n" +
		"entrypoint main pipeline:Loop tick_hz:60 logical:160x120 bindings:bindings\n" +
		"[probes 2]\n" +
		"probe trace Loop.collision 0\n" +
		"probe trace Other.control 0\n"

	program := new(Program, context.temp_allocator)
	loaded, err := load_program(unknown_stage, context.temp_allocator)
	if !testing.expectf(t, err == .None, "unknown-stage fixture must load, got %v", err) {
		return
	}
	program^ = loaded
	inputs := make([]Input, 4, context.temp_allocator)
	for i in 0 ..< 4 {
		inputs[i] = empty()
	}
	s := open_debug_session(program, inputs, NO_SEED, context.temp_allocator)
	honor, _ := session_honor_probes(&s)

	testing.expect_value(t, len(honor.traces), 0)
}

@(test)
test_honor_qualified_non_perturbing_digest_pin :: proc(t: ^testing.T) {
	program, session, ok := qualified_session(t, 12)
	if !ok {
		return
	}
	s := session

	baseline := new_world(program^, context.temp_allocator)
	baseline_version := run_startup(program, initial_version(baseline, context.temp_allocator), context.temp_allocator)
	tick_hz := program.entrypoint.tick_hz
	for snapshot, i in s.snapshots {
		time := time_resource_at(tick_hz, i, context.temp_allocator)
		baseline_version = step_tick(program, baseline_version, snapshot, time, context.temp_allocator)
	}

	honor, honored_final := session_honor_probes(&s)
	testing.expect(t, len(honor.traces) > 0, "the qualified stage @trace fired during the honored run")

	testing.expect(
		t,
		world_versions_equal(honored_final, baseline_version),
		"the honored fold's final committed world must equal the unprobed run's — qualified honoring is non-perturbing",
	)
}
