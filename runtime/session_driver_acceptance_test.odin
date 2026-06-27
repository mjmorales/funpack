package funpack_runtime

import "core:os"
import "core:strings"
import "core:testing"

@(private = "file")
PROBED_DRIVER_FIXTURE :: "funpack-artifact 19\n" +
	"[meta 2]\n" +
	"project probed_driver\n" +
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
	"entrypoint main pipeline:Probed tick_hz:60 logical:160x120 bindings:bindings\n" +
	"[probes 2]\n" +
	"probe break tick_counter 1\n" +
	"node binary gt 2\n" +
	"node field n 1\n" +
	"node name self 0\n" +
	"node int 2 0\n" +
	"probe watch tick_counter 1\n" +
	"node field n 1\n" +
	"node name self 0\n"

@(private = "file")
driver_snake_session :: proc(t: ^testing.T, allocator := context.allocator) -> Debug_Session {
	program := new(Program, allocator)
	loaded, err := load_program(GOLDEN_SNAKE_ARTIFACT, allocator)
	testing.expect(t, err == .None, "golden snake artifact must load")
	program^ = loaded
	inputs := make([]Input, 16, allocator)
	for i in 0 ..< 16 {
		inputs[i] = i == 6 ? with_pressed(empty(), .P1, ActionId(1)) : empty()
	}
	return open_debug_session(program, inputs, seeded_run(42), allocator)
}

@(private = "file")
driver_probed_session :: proc(t: ^testing.T, ticks: int, allocator := context.allocator) -> Debug_Session {
	program := new(Program, allocator)
	loaded, err := load_program(PROBED_DRIVER_FIXTURE, allocator)
	testing.expect(t, err == .None, "probed driver fixture must load")
	program^ = loaded
	inputs := make([]Input, ticks, allocator)
	for i in 0 ..< ticks {
		inputs[i] = empty()
	}
	return open_debug_session(program, inputs, NO_SEED, allocator)
}

@(test)
test_driver_snake_eat_loop_closes :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	s := driver_snake_session(t)

	predicate := Live_Predicate {
		until = 9,
		has_state = true,
		state = State_Assertion {
			thing = "Snake",
			instance = 0,
			field = "grow",
			type_name = "Bool",
			expected_encoded = "true",
		},
	}
	capture := Capture_Spec {
		behavior = "detect_eat",
	}

	result := drive_verification(&s, predicate, capture)

	testing.expect(t, result.passed, "the snake-ate-at-tick-9 predicate must hold")
	testing.expect_value(t, result.reason, "pass")

	testing.expect(t, result.captured, "a passing gate must export a capture_test regression")

	committed, read_err := os.read_entire_file_from_path("testdata/capture_snake_eat.fun", context.temp_allocator)
	if !testing.expect(t, read_err == nil, "the committed capture copy must read") {
		return
	}
	testing.expect_value(t, result.test_src, string(committed))
}

@(test)
test_driver_passing_gate_uncapturable_boundary :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	s := driver_snake_session(t)

	predicate := Live_Predicate {
		until = 9,
		has_state = true,
		state = State_Assertion{thing = "Snake", instance = 0, field = "grow", type_name = "Bool", expected_encoded = "true"},
	}
	result := drive_verification(&s, predicate, Capture_Spec{behavior = "replenish"})

	testing.expect(t, result.passed, "the live predicate held, so the gate passes")
	testing.expect(t, !result.captured, "an unconstructible capture boundary exports no regression")
	testing.expect(t, strings.contains(result.reason, "regression not captured"), "the reason marks the missing capture")
	testing.expect(t, strings.contains(result.reason, "rng: Rng"), "the reason carries capture_test's typed refusal")
}

@(test)
test_driver_state_assertion_record_field :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	s := driver_snake_session(t)

	predicate := Live_Predicate {
		until = 9,
		has_state = true,
		state = State_Assertion {
			thing = "Snake",
			instance = 0,
			field = "head",
			type_name = "Cell",
			expected_encoded = "Cell(x=16,y=14)",
		},
	}
	result := drive_verification(&s, predicate, Capture_Spec{behavior = "detect_eat"})
	testing.expect(t, result.passed, "the committed-head predicate must hold")
	testing.expect(t, result.captured, "the passing gate exports the regression")
}

@(test)
test_driver_state_assertion_deliberate_fail :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	s := driver_snake_session(t)

	predicate := Live_Predicate {
		until = 9,
		has_state = true,
		state = State_Assertion {
			thing = "Snake",
			instance = 0,
			field = "grow",
			type_name = "Bool",
			expected_encoded = "false",
		},
	}
	result := drive_verification(&s, predicate, Capture_Spec{behavior = "detect_eat"})

	testing.expect(t, !result.passed, "a wrong expected value must fail the gate")
	testing.expect(t, !result.captured, "a failing gate exports no regression")
	testing.expect(t, result.test_src == "", "a failing gate carries no test source")
	testing.expect(
		t,
		strings.contains(result.reason, "Snake#0.grow is true, expected false"),
		"the fail reason must name the observed-vs-expected divergence",
	)
}

@(test)
test_driver_probe_firing_predicate :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	s := driver_probed_session(t, 6)

	watch_pred := Live_Predicate {
		until = 5,
		has_probe = true,
		probe = Probe_Assertion{target = "tick_counter", kind = .Watch, min_fires = 1},
	}
	watch_result := drive_verification(&s, watch_pred, Capture_Spec{behavior = "tick_counter"})
	testing.expect(t, watch_result.passed, "the @watch-fired predicate must hold")

	s2 := driver_probed_session(t, 6)
	break_pred := Live_Predicate {
		until = 5,
		has_probe = true,
		probe = Probe_Assertion{target = "tick_counter", kind = .Break, min_fires = 1},
	}
	break_result := drive_verification(&s2, break_pred, Capture_Spec{behavior = "tick_counter"})
	testing.expect(t, break_result.passed, "the @break-fired predicate must hold")
}

@(test)
test_driver_probe_assertion_unmet_fails :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	s := driver_probed_session(t, 3)

	predicate := Live_Predicate {
		until = 2,
		has_probe = true,
		probe = Probe_Assertion{target = "tick_counter", kind = .Watch, min_fires = 5},
	}
	result := drive_verification(&s, predicate, Capture_Spec{behavior = "tick_counter"})
	testing.expect(t, !result.passed, "an unmet probe threshold must fail")
	testing.expect(t, strings.contains(result.reason, "watch_fired"), "the reason names the probe event")
	testing.expect(t, strings.contains(result.reason, "expected >= 5"), "the reason names the shortfall")
}

@(test)
test_driver_state_and_probe_combined :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	s := driver_probed_session(t, 6)

	predicate := Live_Predicate {
		until = 5,
		has_state = true,
		state = State_Assertion {
			thing = "Counter",
			instance = 0,
			field = "n",
			type_name = "Int",
			expected_encoded = "6",
		},
		has_probe = true,
		probe = Probe_Assertion{target = "tick_counter", kind = .Watch, min_fires = 1},
	}
	result := drive_verification(&s, predicate, Capture_Spec{behavior = "tick_counter"})
	testing.expect(t, result.passed, "both arms hold, so the combined gate passes")
	testing.expect(t, result.captured, "the passing combined gate exports the regression")
}

@(test)
test_driver_vacuous_predicate_refused :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	s := driver_probed_session(t, 3)
	result := drive_verification(&s, Live_Predicate{until = 2}, Capture_Spec{behavior = "tick_counter"})
	testing.expect(t, !result.passed, "a predicate asserting nothing must be refused")
	testing.expect(t, strings.contains(result.reason, "vacuous"), "the reason names the vacuous gate")
}

@(test)
test_driver_run_target_out_of_range :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	s := driver_snake_session(t)
	predicate := Live_Predicate {
		until = 999,
		has_state = true,
		state = State_Assertion{thing = "Snake", instance = 0, field = "grow", type_name = "Bool", expected_encoded = "true"},
	}
	result := drive_verification(&s, predicate, Capture_Spec{behavior = "detect_eat"})
	testing.expect(t, !result.passed, "a run past the recording must fail")
	testing.expect(t, strings.contains(result.reason, "out of range"), "the reason surfaces the session's run refusal")
}

@(test)
test_driver_is_non_perturbing :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator

	reference := driver_snake_session(t)
	baseline := session_capture(&reference)

	driven := driver_snake_session(t)
	predicate := Live_Predicate {
		until = 9,
		has_state = true,
		state = State_Assertion{thing = "Snake", instance = 0, field = "grow", type_name = "Bool", expected_encoded = "true"},
	}
	result := drive_verification(&driven, predicate, Capture_Spec{behavior = "detect_eat"})
	testing.expect(t, result.passed, "the drive used for the pin must pass (so it exercises the on-pass capture)")

	driven_capture := session_capture(&driven)
	if !testing.expect_value(t, len(driven_capture.per_tick), len(baseline.per_tick)) {
		return
	}
	for frame, i in driven_capture.per_tick {
		testing.expect_value(t, frame.tick, baseline.per_tick[i].tick)
		testing.expect_value(t, frame.digest, baseline.per_tick[i].digest)
	}
	testing.expect_value(t, driven_capture.session, baseline.session)
	testing.expect(
		t,
		world_versions_equal(driven.versions[len(driven.versions) - 1], reference.versions[len(reference.versions) - 1]),
		"the driven session's final committed world must equal the undriven reference's — driving is non-perturbing",
	)
}
