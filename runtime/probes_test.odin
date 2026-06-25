// §28 §4 PROBE-honor acceptance: the runtime LOADS the artifact's [probes]
// section (schema v18) and HONORS every in-code @break/@watch/@log/@trace in a
// live debug session — @break pauses on its predicate (the breakpoint_hit async
// event), @watch fires watch_fired on a value change, @log emits its structured
// value each step, @trace records the per-step (in → out) transition — folding each
// predicate/expression body as a NODE FOREST through the existing interpreter,
// NEVER compiling source (§28 §2). The battery proves the loader decode AND the
// honor seam, plus the determinism warranty: a probed session's canonical chain
// digests bit-identical to the unprobed run (honoring is observe-class — no
// heisenbugs, §28 §2).
//
// FIXTURE TECHNIQUE (Lore #8/#14): a hand-built node-forest artifact carrying a
// behavior plus all four directives. The cross-pinned games (dungeon/warren/krognid/
// statequery) carry NO in-code probes (their [probes 0] tails), so the honor surface
// is proven on a hand-built fixture exactly as every other engine arm is proven
// before/independent of a real emitted artifact. The probe bodies are the same §2.7
// `node` runs funpack emits (verified against the funpack emit golden's byte shape:
// `probe break TARGET 1\nnode binary gt 2\nnode name X 0\nnode int N 0`).
package funpack_runtime

import "core:strings"
import "core:testing"

// PROBED_FIXTURE is a minimal one-behavior artifact carrying all four §28 §4
// directives on the behavior `tick_counter`. The Counter thing's `n: Int` advances
// n+1 every step (so @watch sees a change every tick and @break crosses its
// threshold mid-run), and `pos: Fixed` advances 1.0/tick (a second evolving column
// so the per-tick frame digest is distinct). The [probes 4] section carries:
//   @break(self.n > 2)  — pauses once n exceeds 2 (breakpoint_hit)
//   @watch(self.n)      — fires watch_fired each tick (n changes every step)
//   @log(self.n)        — emits the structured value each step
//   @trace              — records the per-step (in → out) transition (body-less)
// Each body is a §2.7 node forest, never funpack source (§28 §2). The probe records
// are top-level `probe` lead lines; the `node` lines are their sub-record bodies, so
// the section reconciles under the same lead-line discipline a [functions] record
// does.
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

// probed_session loads the fixture and opens a session over `ticks` empty input
// snapshots — the shared opener the honor battery folds from.
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

// The loader decodes the [probes] section into the Probe_Decl slice: four probes in
// source order, each with its closed kind, its target (the behavior name), and a
// node-forest body of the declared shape (one statement subtree for break/log/watch,
// empty for trace) — never funpack source.
@(test)
test_load_probes_section :: proc(t: ^testing.T) {
	program, err := load_program(PROBED_FIXTURE, context.temp_allocator)
	if !testing.expectf(t, err == .None, "probed fixture must load, got %v", err) {
		return
	}
	testing.expect_value(t, len(program.probes), 4)

	testing.expect_value(t, program.probes[0].kind, Probe_Kind.Break)
	testing.expect_value(t, program.probes[0].target, "tick_counter")
	testing.expect_value(t, len(program.probes[0].body), 1) // the predicate subtree
	// The predicate body is a node forest: `binary gt` over a field access and an int.
	testing.expect_value(t, program.probes[0].body[0].kind, Node_Kind.Binary)

	testing.expect_value(t, program.probes[1].kind, Probe_Kind.Watch)
	testing.expect_value(t, len(program.probes[1].body), 1)
	testing.expect_value(t, program.probes[1].body[0].kind, Node_Kind.Field)

	testing.expect_value(t, program.probes[2].kind, Probe_Kind.Log)
	testing.expect_value(t, len(program.probes[2].body), 1)

	// @trace carries no argument — body_count 0, an empty forest.
	testing.expect_value(t, program.probes[3].kind, Probe_Kind.Trace)
	testing.expect_value(t, len(program.probes[3].body), 0)
}

// A malformed [probes] record is fail-closed: an unknown KIND token, a body run that
// over- or under-shapes the declared body_count, and a non-`probe` lead line are all
// refused before producing a partial Program (the load is total or it fails, §1).
@(test)
test_load_probes_malformed_refused :: proc(t: ^testing.T) {
	// An unknown probe KIND is a schema mismatch.
	unknown_kind := "funpack-artifact 19\n[probes 1]\nprobe poke tick_counter 0\n"
	_, kind_err := load_program(unknown_kind, context.temp_allocator)
	testing.expect_value(t, kind_err, Artifact_Error.Bad_Field)

	// A body run that under-shapes the declared body_count (declares 1, carries 0).
	short_body := "funpack-artifact 19\n[probes 1]\nprobe break tick_counter 1\n"
	_, body_err := load_program(short_body, context.temp_allocator)
	testing.expect_value(t, body_err, Artifact_Error.Body_Count_Mismatch)

	// A body run that over-shapes it (declares 0, carries a node) — the @trace shape
	// with a stray body subtree.
	long_body := "funpack-artifact 19\n[probes 1]\nprobe trace tick_counter 0\nnode int 1 0\n"
	_, long_err := load_program(long_body, context.temp_allocator)
	testing.expect_value(t, long_err, Artifact_Error.Body_Count_Mismatch)
}

// @break HONOR: a live session honoring the recorded run fires breakpoint_hit at the
// exact tick the predicate (`self.n > 2`) first holds. n is the PRE-eval value at
// each step (the behavior reads self.n BEFORE writing n+1), so over ticks 0..N the
// bound self.n is the committed n entering the tick: 0,1,2,3,… The predicate
// `self.n > 2` first holds when the bound self.n is 3 — the step at tick 3 (n
// entering tick 3 is 3, since tick i commits n=i+1). The breakpoint_hit event
// carries the firing probe's target and the self blackboard (§28 §2).
@(test)
test_honor_break_pauses_on_predicate :: proc(t: ^testing.T) {
	_, session, ok := probed_session(t, 8)
	if !ok {
		return
	}
	s := session
	honor, _ := session_honor_probes(&s)

	// The predicate `self.n > 2` holds at every step whose bound self.n exceeds 2.
	// self.n entering tick i is i (tick i-1 committed n=i). So it holds at ticks
	// 3,4,5,6,7 — five hits, the FIRST at tick 3.
	if !testing.expect(t, len(honor.breaks) >= 1, "a @break must fire when its predicate holds") {
		return
	}
	first := honor.breaks[0]
	testing.expect_value(t, first.target, "tick_counter")
	testing.expect_value(t, first.behavior, "tick_counter")
	testing.expect_value(t, first.tick, 3) // self.n entering tick 3 is 3 (> 2 first holds)
	testing.expect_value(t, len(honor.breaks), 5) // ticks 3,4,5,6,7

	// The breakpoint_hit async event is a well-formed {v, event, …} envelope carrying
	// the target and the self blackboard at the pausing step (n=3, pos=3.0 raw bits).
	event := render_breakpoint_hit_event(first)
	testing.expect(t, strings.contains(event, `"v":1`))
	testing.expect(t, strings.contains(event, `"event":"breakpoint_hit"`))
	testing.expect(t, strings.contains(event, `"target":"tick_counter"`))
	testing.expect(t, strings.contains(event, `"tick":3`))
	// The self blackboard dump carries n=3 in the artifact literal encoding.
	testing.expect(t, strings.contains(event, "Counter(n=3,"))
}

// @watch HONOR: a @watch fires watch_fired on each value CHANGE — n advances every
// tick, so the watch fires every tick AFTER the first observation (which establishes
// the baseline, no prior to differ from). The event carries the old → new value.
@(test)
test_honor_watch_fires_on_change :: proc(t: ^testing.T) {
	_, session, ok := probed_session(t, 5)
	if !ok {
		return
	}
	s := session
	honor, _ := session_honor_probes(&s)

	// 5 ticks: the bound self.n is 0,1,2,3,4. Tick 0 establishes the baseline (0),
	// ticks 1..4 each differ from the prior → 4 fires.
	testing.expect_value(t, len(honor.watches), 4)

	first := honor.watches[0]
	testing.expect_value(t, first.target, "tick_counter")
	testing.expect_value(t, first.tick, 1) // first CHANGE is at tick 1 (0 → 1)
	testing.expect_value(t, first.old_enc, "0")
	testing.expect_value(t, first.new_enc, "1")

	// The watch_fired async event carries the target and the old → new value (§28 §2).
	event := render_watch_fired_event(first)
	testing.expect(t, strings.contains(event, `"event":"watch_fired"`))
	testing.expect(t, strings.contains(event, `"target":"tick_counter"`))
	testing.expect(t, strings.contains(event, `"old":"0"`))
	testing.expect(t, strings.contains(event, `"new":"1"`))
}

// @log HONOR: a @log emits its structured value EVERY step (unconditional), with
// tick/thing context — the printf-debugging killer (typed, queryable, never a raw
// print). Over N ticks the run produces N log emits, the bound self.n at each.
@(test)
test_honor_log_emits_each_step :: proc(t: ^testing.T) {
	_, session, ok := probed_session(t, 5)
	if !ok {
		return
	}
	s := session
	honor, _ := session_honor_probes(&s)

	// One emit per tick (a @log is unconditional): 5 ticks → 5 emits.
	testing.expect_value(t, len(honor.logs), 5)
	// The values are the bound self.n at each step: 0,1,2,3,4 in the artifact literal
	// encoding (an Int renders as plain decimal).
	expected := [?]string{"0", "1", "2", "3", "4"}
	for emit, i in honor.logs {
		testing.expect_value(t, emit.tick, i)
		testing.expect_value(t, emit.behavior, "tick_counter")
		testing.expect_value(t, emit.value_enc, expected[i])
	}
}

// @trace HONOR: a @trace records the full per-step (in → out) transition every step —
// the bound self before and the returned value after. Over N ticks it records N
// transitions, each carrying the pre-eval self and the step's return.
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
	testing.expect(t, first.ok) // the step returned a value
	// The pre-eval self (n=0, pos=0) and the returned Counter (n=1, pos=1.0) — the
	// (in → out) transition in the artifact literal encoding.
	testing.expect(t, strings.contains(first.self_before, "Counter(n=0,"))
	testing.expect(t, strings.contains(first.result_enc, "n=1"))
}

// reference_unprobed_capture folds the probed fixture's run with NO honor tap — the
// production seam verbatim — capturing per-tick digests and the final committed
// version. It is the ground truth the non-perturbation pin compares the probed
// session against (the introspect digest-pin mold).
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

// THE DETERMINISM WARRANTY — honoring a probe is NON-PERTURBING, proven with a
// digest pin: a session that HONORS the four probes over the recorded run (firing
// breaks/watches/logs/traces) digests its canonical chain bit-identical to a run
// nobody probed — per-tick digests, session digest, and the final committed world
// (world_versions_equal). §28 §2: a predicate/expression body is a pure interpreter
// fold of the artifact's node forest — it reads the bound scope, never writes tick
// state — so "observation can never change behavior — no heisenbugs."
@(test)
test_honor_non_perturbing_digest_pin :: proc(t: ^testing.T) {
	program, session, ok := probed_session(t, 16)
	if !ok {
		return
	}
	s := session
	baseline, baseline_final := reference_unprobed_capture(program, s.snapshots)

	// Drive the honor seam over the WHOLE run — every probe fires as it folds — and
	// keep the FINAL committed version the honored fold produced (the fold that ran
	// step_tick WITH the honor tap armed at every behavior step).
	honor, honored_final := session_honor_probes(&s)
	// The probes did fire (the run is non-trivial), so the pin proves honoring is
	// non-perturbing DESPITE active firings, not merely when no probe triggers.
	testing.expect(t, len(honor.breaks) > 0, "the @break fired during the honored run")
	testing.expect(t, len(honor.watches) > 0, "the @watch fired during the honored run")
	testing.expect(t, len(honor.logs) > 0, "the @log emitted during the honored run")
	testing.expect(t, len(honor.traces) > 0, "the @trace recorded during the honored run")

	// THE WARRANTY: the honored fold (step_tick WITH the honor tap firing every step)
	// commits a final world bit-identical to the unprobed reference fold — honoring
	// perturbs no committed state (§28 §2: the predicate/expression bodies read the
	// bound scope, never write tick state).
	testing.expect(
		t,
		world_versions_equal(honored_final, baseline_final),
		"the honored fold's final committed world must equal the unprobed run's — honoring is non-perturbing",
	)

	// And the session's OWN canonical chain (built at open, never touched by honoring)
	// still digests bit-identical to the unprobed run — honoring re-folds into scratch,
	// leaving the trunk untouched (the observe-class invariant).
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

// An artifact with the constant [probes 0] tail (a release artifact, or an in-code-
// probe-free dev build — the dungeon/warren/krognid/statequery shape) decodes to the
// empty probe slice and honors nothing — the tail is always present, always empty
// (§28 §4 "release artifacts hold no introspection machinery").
@(test)
test_load_empty_probes_tail :: proc(t: ^testing.T) {
	probe_free := "funpack-artifact 19\n[meta 2]\nproject bare\nversion L5:0.1.0\n[probes 0]\n"
	program, err := load_program(probe_free, context.temp_allocator)
	testing.expect_value(t, err, Artifact_Error.None)
	testing.expect_value(t, len(program.probes), 0)
}
