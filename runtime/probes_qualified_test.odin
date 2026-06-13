// §28 §4 QUALIFIED-target probe honor: the runtime resolves the §28 §2 `Owner.member`
// addressing the funpack emitter writes for a SUB-DECLARATION probe — a stage @trace
// (TARGET `<pipeline>.<stage>`) and a field @watch (TARGET `<data>.<field>`) — beyond
// the bare-name behavior probes the base battery (probes_test.odin) proves. The emit
// half writes these qualified TARGETs with NO schema bump (TARGET is a free-string
// name field; `Owner.member` is one space-free token at the same parse position), so
// the loader already decodes them into Probe_Decl.target; this battery proves the
// HONOR-side RESOLUTION of the two qualified shapes:
//
//   - a stage @trace `<pipeline>.<stage>` records the per-step (in → out) transition
//     for EVERY behavior the stage schedules — resolved by matching the pipeline
//     prefix to the entrypoint's one pipeline and the stage member to a step's stage;
//   - a field @watch `<data>.<field>` is loaded and resolvable but has NO live
//     behavior-step honor site (a `data` is a §03 §1 value record with no rows / no
//     runtime identity, and the @watch body binds `self` to the data VALUE, never a
//     thing row a behavior step binds) — so the resolution FAILS CLOSED here. This is
//     the field-@watch honor-site limitation surfaced for the driver
//     (runtime-field-stage-probe-honor): the spec gives `<data>.<field>` as addressing
//     but does not define which embedding of a value type a live watch diffs.
//
// FIXTURE TECHNIQUE (Lore #8/#14): a hand-built node-forest artifact, exactly as the
// base honor battery — the cross-pinned games carry no in-code probes ([probes 0]),
// so the qualified honor surface is proven on a hand-built fixture independent of a
// real emitted artifact. The probe bodies are the same §2.7 `node` runs funpack emits
// (the field @watch body `self.bias` = `node field bias 1\nnode name self 0`, the
// golden's `DriftLog.bias` shape).
package funpack_runtime

import "core:strings"
import "core:testing"

// QUALIFIED_FIXTURE carries BOTH qualified-target shapes plus a bare-name behavior
// trace as the contrast. The `Counter` thing's `n: Int` advances n+1 every step (a
// changing column the stage trace records distinct in → out for). The pipeline is
// `Loop` (the entrypoint's), its `control` stage schedules the one behavior, so a
// stage @trace `Loop.control` resolves to that step. The free-standing `DriftLog`
// data (a watched `bias` field, the §28 §4 field-probe position — never embedded in a
// thing, exactly as the funpack emit golden's `DriftLog`) is the no-live-site case.
// [probes 3]:
//   probe watch DriftLog.bias 1  — QUALIFIED `<data>.<field>`: loaded, NOT honored
//   probe trace Loop.control 0   — QUALIFIED `<pipeline>.<stage>`: honored at the step
//   probe trace tick_counter 0   — bare behavior name: honored (the base shape)
@(private = "file")
QUALIFIED_FIXTURE :: "funpack-artifact 18\n" +
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

// qualified_session loads QUALIFIED_FIXTURE and opens a session over `ticks` empty
// input snapshots — the shared opener this battery folds from (the probed_session
// mold, on the qualified fixture).
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

// split_qualified_target is the inverse of the emitter's `<owner>.<member>` join: a
// qualified target splits at the first `.`, a bare name does not. The two TARGET
// shapes the [probes] section carries are distinguished by `qualified`.
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

	// A bare declaration name is NOT qualified (a behavior-prefix probe's target).
	_, _, bare := split_qualified_target("tick_counter")
	testing.expect(t, !bare)
}

// STAGE @trace HONOR: a @trace whose TARGET is the QUALIFIED `<pipeline>.<stage>` site
// records the per-step (in → out) transition for the behavior the stage schedules. The
// `Loop.control` stage runs `tick_counter`, so over N ticks the stage trace records N
// transitions — each the bound self before (n entering the tick) and the returned
// Counter after (n+1). Resolved by matching the pipeline prefix (`Loop`, the
// entrypoint's) and the stage member (`control`, the step's stage).
@(test)
test_honor_stage_trace_records_transitions :: proc(t: ^testing.T) {
	_, session, ok := qualified_session(t, 4)
	if !ok {
		return
	}
	s := session
	honor, _ := session_honor_probes(&s)

	// TWO traces fire per step: the bare-name `tick_counter` @trace AND the qualified
	// `Loop.control` stage @trace (both honor at the one behavior step). 4 ticks → 8
	// trace records. Filter to the stage trace's QUALIFIED target.
	stage_traces := make([dynamic]Trace_Record, context.temp_allocator)
	for rec in honor.traces {
		if rec.target == "Loop.control" {
			append(&stage_traces, rec)
		}
	}
	testing.expect_value(t, len(stage_traces), 4) // one per tick, the stage's one behavior

	first := stage_traces[0]
	testing.expect_value(t, first.behavior, "tick_counter") // the behavior the stage scheduled
	testing.expect_value(t, first.target, "Loop.control") // the qualified stage site
	testing.expect_value(t, first.tick, 0)
	testing.expect(t, first.ok)
	// The (in → out) transition: self entering tick 0 is n=0, the step returns n=1.
	testing.expect(t, strings.contains(first.self_before, "Counter(n=0"))
	testing.expect(t, strings.contains(first.result_enc, "n=1"))

	// The stage trace tracks the changing column across ticks — tick 2's transition is
	// n=2 → n=3 (the stage records each step's real in → out, not a per-tick reset).
	third := stage_traces[2]
	testing.expect_value(t, third.tick, 2)
	testing.expect(t, strings.contains(third.self_before, "Counter(n=2"))
	testing.expect(t, strings.contains(third.result_enc, "n=3"))
}

// FIELD @watch FAILS CLOSED: a @watch whose TARGET is the QUALIFIED `<data>.<field>`
// site is loaded and resolvable, but a `data` is a §03 §1 value record with no rows
// and no runtime identity (it lives only embedded on a thing's blackboard, and the
// @watch body binds `self` to the data VALUE, never a thing row a behavior step
// binds). So it has NO live behavior-step honor site and fires NOTHING — the
// fail-closed default for the field-@watch honor-site limitation
// (runtime-field-stage-probe-honor). No `watch_fired` carries the `DriftLog.bias`
// target.
@(test)
test_honor_field_watch_data_fails_closed :: proc(t: ^testing.T) {
	_, session, ok := qualified_session(t, 8)
	if !ok {
		return
	}
	s := session
	honor, _ := session_honor_probes(&s)

	// The fixture has NO @watch on a thing/behavior, only the data-field @watch — so
	// the watch buffer is empty: the data-field @watch found no live honor site.
	testing.expect_value(t, len(honor.watches), 0)
	for fire in honor.watches {
		testing.expect(t, fire.target != "DriftLog.bias", "a data-field @watch has no live honor site")
	}
}

// UNKNOWN QUALIFIED STAGE FAILS CLOSED: a @trace whose `<pipeline>.<stage>` names a
// stage no step runs in (or a pipeline that is not the entrypoint's) matches no
// behavior step, so it records nothing — the fail-closed reading for an unknown stage
// target (qualified_target_is_stage returns false on a non-matching owner/member).
@(test)
test_honor_unknown_stage_target_fails_closed :: proc(t: ^testing.T) {
	// `Loop.collision` names a real pipeline but a stage no step in this fixture runs;
	// `Other.control` names a pipeline that is not the entrypoint's. Both fail closed.
	unknown_stage := "funpack-artifact 18\n" +
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

	// Neither qualified @trace resolves to a live stage step → no transitions recorded.
	testing.expect_value(t, len(honor.traces), 0)
}

// THE DETERMINISM WARRANTY for the qualified targets: a session that HONORS the
// qualified stage @trace (and the loaded-but-unhonored data @watch) over the recorded
// run digests its canonical chain bit-identical to a run nobody probed. Honoring is
// observe-class (§28 §2) — the stage @trace is a pure copy-out of the step's already
// computed (self_before, result), writing only into request scratch, and the
// data @watch fires nothing — so the qualified resolution perturbs no committed state.
@(test)
test_honor_qualified_non_perturbing_digest_pin :: proc(t: ^testing.T) {
	program, session, ok := qualified_session(t, 12)
	if !ok {
		return
	}
	s := session

	// The unprobed reference fold (the production seam with NO honor tap).
	baseline := new_world(program^, context.temp_allocator)
	baseline_version := run_startup(program, initial_version(baseline, context.temp_allocator), context.temp_allocator)
	tick_hz := program.entrypoint.tick_hz
	for snapshot, i in s.snapshots {
		time := time_resource_at(tick_hz, i, context.temp_allocator)
		baseline_version = step_tick(program, baseline_version, snapshot, time, context.temp_allocator)
	}

	// Drive the honor seam over the WHOLE run — the stage @trace fires every step.
	honor, honored_final := session_honor_probes(&s)
	testing.expect(t, len(honor.traces) > 0, "the qualified stage @trace fired during the honored run")

	// THE WARRANTY: the honored fold's final committed world equals the unprobed run's.
	testing.expect(
		t,
		world_versions_equal(honored_final, baseline_version),
		"the honored fold's final committed world must equal the unprobed run's — qualified honoring is non-perturbing",
	)
}
