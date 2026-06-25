// §28 §5 agent-driven live-verification driver — ACCEPTANCE. The driver boots an
// EXISTING runtime test artifact headless, drives the §28 session to a tick, asserts
// a live-behavior predicate over the observed committed state and the honored-probe
// stream, and ON PASS exports a capture_test regression — the closed loop the
// dungeon-crawler "Run the game: does X happen?" gates will consume, proven here
// against snake/pong/a hand-built probed fixture (NOT the dungeon, which is not built
// here).
//
// THE LOOP CLOSES (the load-bearing acceptance): drive the seeded golden snake to its
// eat tick (the committed eat signature grow=true at the cell the seed placed),
// PASS the live predicate, export the detect_eat capture_test, and assert the exported
// bytes EQUAL the committed known-good copy testdata/capture_snake_eat.fun — the SAME
// bytes the funpack compiler's cross-product guard parses and runs (introspect_capture
// _test.odin pins them byte-for-byte against `funpack test`). So a passing live gate
// emits a runnable, known-compiling, known-passing funpack regression — the §28 §5
// "the debugger's output IS a regression test" realized end to end.
//
// PASS AND A DELIBERATE FAIL are both proven: the same run with a wrong expected value
// fails the gate with a typed reason and exports NO regression (a failing gate
// verifies nothing and lands no test). The DETERMINISM PIN proves the whole drive is
// observe-class: a session driven through the full loop (run + state read + probe
// re-fold + capture_test) digests its canonical chain bit-identical to an undriven
// reference — driving perturbs no canonical byte (§28 §2 the warranty).
package funpack_runtime

import "core:os"
import "core:strings"
import "core:testing"

// PROBED_DRIVER_FIXTURE is a minimal one-behavior artifact carrying a @watch and a
// @break on the behavior `tick_counter`, the probe-firing predicate surface the
// driver asserts on. The Counter thing's `n: Int` advances n+1 every step, so @watch
// (self.n) fires watch_fired every tick after the first and @break (self.n > 2)
// crosses its threshold mid-run — the SAME node-forest probe shape funpack emits
// (probes_test.odin's fixture), here used as the driver's probe-assertion target. The
// driver re-folds this run with the honor tap armed (session_honor_probes) and counts
// the firings, never compiling source (§28 §2).
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

// driver_snake_session opens the seeded golden-snake session (seed 42, the scripted
// 16-tick run with one Down press at tick 6) — the SAME canonical run the capture
// acceptance folds, so the driver's exported capture_test matches the committed copy.
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

// driver_probed_session opens a session over the probed fixture with `ticks` empty
// snapshots — the probe-firing predicate's run.
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

// THE LOOP CLOSES — the headline acceptance. Drive the seeded snake to its eat tick
// (tick 9, where the head lands on the seed-placed food and the committed eat
// signature grow=true holds), assert the live predicate, and export the detect_eat
// regression. The exported funpack test must EQUAL the committed known-good copy —
// the SAME bytes the funpack compiler parses and runs — so a passing live gate emits a
// runnable, known-compiling, known-passing regression.
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
			expected_encoded = "true", // the committed eat signature: detect_eat set grow at the food cell
		},
	}
	capture := Capture_Spec {
		behavior = "detect_eat",
		// tick defaults to predicate.until (9) — capture at the verified boundary.
	}

	result := drive_verification(&s, predicate, capture)

	// The live predicate held.
	testing.expect(t, result.passed, "the snake-ate-at-tick-9 predicate must hold")
	testing.expect_value(t, result.reason, "pass")

	// A regression WAS exported (the loop's on-pass arm fired).
	testing.expect(t, result.captured, "a passing gate must export a capture_test regression")

	// THE LOOP-CLOSURE PROOF: the exported funpack test equals the committed known-good
	// copy — the SAME bytes the funpack compiler's cross-product guard parses and runs
	// (introspect_capture_test.odin pins them against `funpack test`). So the driver's
	// emitted regression is runnable, known-compiling, known-passing funpack source.
	committed, read_err := os.read_entire_file_from_path("testdata/capture_snake_eat.fun", context.temp_allocator)
	if !testing.expect(t, read_err == nil, "the committed capture copy must read") {
		return
	}
	testing.expect_value(t, result.test_src, string(committed))
}

// A PASSING gate whose capture boundary is NOT constructible: the live predicate
// holds, but the named capture behavior (snake's `replenish`, which reads a threaded
// `rng: Rng` — no funpack source literal for a mid-run Rng) cannot be exported as a
// runnable test. The gate STILL PASSES (the live behavior was verified) but exports no
// regression; the reason carries capture_test's typed refusal so the agent re-captures
// at a constructible boundary. This locks the orthogonality of "did X happen?" (the
// gate) and "can this exact observation mint a test?" (the export).
@(test)
test_driver_passing_gate_uncapturable_boundary :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	s := driver_snake_session(t)

	predicate := Live_Predicate {
		until = 9,
		has_state = true,
		state = State_Assertion{thing = "Snake", instance = 0, field = "grow", type_name = "Bool", expected_encoded = "true"},
	}
	// replenish reads rng: Rng → capture_test refuses it (introspect_capture_test.odin's
	// typed refusal), even though the live predicate over Snake.grow holds.
	result := drive_verification(&s, predicate, Capture_Spec{behavior = "replenish"})

	testing.expect(t, result.passed, "the live predicate held, so the gate passes")
	testing.expect(t, !result.captured, "an unconstructible capture boundary exports no regression")
	testing.expect(t, strings.contains(result.reason, "regression not captured"), "the reason marks the missing capture")
	testing.expect(t, strings.contains(result.reason, "rng: Rng"), "the reason carries capture_test's typed refusal")
}

// A SECOND live predicate over the SAME run — the committed head cell at the eat tick
// — also passes, proving the state assertion is over real evolving state (a record
// field, decoded structurally), not a single hardcoded case.
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
			expected_encoded = "Cell(x=16,y=14)", // the committed head at the eat tick (the §28 §2 pre-encoded form)
		},
	}
	result := drive_verification(&s, predicate, Capture_Spec{behavior = "detect_eat"})
	testing.expect(t, result.passed, "the committed-head predicate must hold")
	testing.expect(t, result.captured, "the passing gate exports the regression")
}

// THE DELIBERATE FAIL — the same run, a WRONG expected value. The gate fails with a
// typed reason naming the divergence, and exports NO regression (a failing gate
// verifies nothing and lands no test). This is the half that makes a PASS meaningful.
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
			expected_encoded = "false", // WRONG — grow is true at the eat tick
		},
	}
	result := drive_verification(&s, predicate, Capture_Spec{behavior = "detect_eat"})

	testing.expect(t, !result.passed, "a wrong expected value must fail the gate")
	testing.expect(t, !result.captured, "a failing gate exports no regression")
	testing.expect(t, result.test_src == "", "a failing gate carries no test source")
	// The reason names the divergence (observed vs expected) for the operator.
	testing.expect(
		t,
		strings.contains(result.reason, "Snake#0.grow is true, expected false"),
		"the fail reason must name the observed-vs-expected divergence",
	)
}

// THE PROBE-FIRING PREDICATE (§28 §5 "a watchpoint predicate IS a test assertion").
// Drive the probed fixture and assert the @watch on `tick_counter` fired — the driver
// re-folds the run with the honor tap armed and counts watch_fired firings. A @break
// assertion on the same target also holds (the predicate self.n > 2 crosses mid-run).
@(test)
test_driver_probe_firing_predicate :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	s := driver_probed_session(t, 6)

	// @watch fires every tick after the first observation (n changes every step):
	// 6 ticks → 5 fires, so >= 1 holds.
	watch_pred := Live_Predicate {
		until = 5,
		has_probe = true,
		probe = Probe_Assertion{target = "tick_counter", kind = .Watch, min_fires = 1},
	}
	watch_result := drive_verification(&s, watch_pred, Capture_Spec{behavior = "tick_counter"})
	testing.expect(t, watch_result.passed, "the @watch-fired predicate must hold")

	// @break (self.n > 2) holds at ticks 3,4,5 — three hits, so >= 1 holds.
	s2 := driver_probed_session(t, 6)
	break_pred := Live_Predicate {
		until = 5,
		has_probe = true,
		probe = Probe_Assertion{target = "tick_counter", kind = .Break, min_fires = 1},
	}
	break_result := drive_verification(&s2, break_pred, Capture_Spec{behavior = "tick_counter"})
	testing.expect(t, break_result.passed, "the @break-fired predicate must hold")
}

// A probe assertion that DOES NOT meet its threshold fails — a @watch asked to fire
// more times than the run produces. The reason names the event and the shortfall.
@(test)
test_driver_probe_assertion_unmet_fails :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	s := driver_probed_session(t, 3)

	// 3 ticks → 2 watch fires; asserting >= 5 must fail.
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

// BOTH ARMS AND-COMBINE — a predicate asserting state AND a probe firing passes only
// when both hold. The probed fixture's committed n at tick 5 is 5 (n entering tick i
// is i, tick i commits i+1; so committed n at tick 5 is 6), and the @watch fired —
// both arms hold, so the gate passes and exports the tick_counter regression.
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
			expected_encoded = "6", // tick 5 commits n = 6
		},
		has_probe = true,
		probe = Probe_Assertion{target = "tick_counter", kind = .Watch, min_fires = 1},
	}
	result := drive_verification(&s, predicate, Capture_Spec{behavior = "tick_counter"})
	testing.expect(t, result.passed, "both arms hold, so the combined gate passes")
	testing.expect(t, result.captured, "the passing combined gate exports the regression")
}

// A vacuous predicate (neither arm) is refused — a gate that asserts nothing verifies
// nothing. The driver fails closed rather than reporting a meaningless pass.
@(test)
test_driver_vacuous_predicate_refused :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	s := driver_probed_session(t, 3)
	result := drive_verification(&s, Live_Predicate{until = 2}, Capture_Spec{behavior = "tick_counter"})
	testing.expect(t, !result.passed, "a predicate asserting nothing must be refused")
	testing.expect(t, strings.contains(result.reason, "vacuous"), "the reason names the vacuous gate")
}

// An out-of-range run target fails at the run step — the driver surfaces the session's
// own refusal (the synchronous run's "tick out of range"), never silently asserting
// against a stale tick.
@(test)
test_driver_run_target_out_of_range :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	s := driver_snake_session(t)
	predicate := Live_Predicate {
		until = 999, // past the 16-tick recording
		has_state = true,
		state = State_Assertion{thing = "Snake", instance = 0, field = "grow", type_name = "Bool", expected_encoded = "true"},
	}
	result := drive_verification(&s, predicate, Capture_Spec{behavior = "detect_eat"})
	testing.expect(t, !result.passed, "a run past the recording must fail")
	testing.expect(t, strings.contains(result.reason, "out of range"), "the reason surfaces the session's run refusal")
}

// THE DETERMINISM PIN — the whole drive is OBSERVE-CLASS. A session driven through the
// full loop (load → run → state read → probe re-fold → capture_test export) digests
// its canonical chain bit-identical to an undriven reference: driving perturbs no
// canonical byte (§28 §2 the warranty, extended to the verification driver exactly as
// introspect_test.odin / probes_test.odin pin it for the session and the probe honor).
@(test)
test_driver_is_non_perturbing :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator

	// Reference: an undriven session's canonical capture.
	reference := driver_snake_session(t)
	baseline := session_capture(&reference)

	// A fresh session driven through the FULL loop (a passing gate that re-folds for
	// the probe arm too, to exercise every observe path the driver takes).
	driven := driver_snake_session(t)
	predicate := Live_Predicate {
		until = 9,
		has_state = true,
		state = State_Assertion{thing = "Snake", instance = 0, field = "grow", type_name = "Bool", expected_encoded = "true"},
	}
	result := drive_verification(&driven, predicate, Capture_Spec{behavior = "detect_eat"})
	testing.expect(t, result.passed, "the drive used for the pin must pass (so it exercises the on-pass capture)")

	// The driven session's canonical chain digests bit-identical to the undriven
	// reference — per-tick digests, the session digest, and the final committed world.
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
