// The §28 §4 probe-honor side of the introspection contract — the runtime half
// of the probe spine. funpack EMITS the in-code @break/@watch/@log/@trace
// directives into the executable artifact's [probes] section (the funpack-side
// emit, schema v18); THIS file LOADS them via load_probes (artifact_load.odin) and
// HONORS every one in a live debug session: @break pauses on its predicate, @watch
// fires the `watch_fired` async event on a value change, @log emits its structured
// value, @trace records the per-step (in → out) transition. The §29 §2 index
// contract is the funpack-side record of every probe (operator review) and never
// reaches the runtime — for a LIVE session to honor a probe the directive must ride
// the thing the runtime executes, which the [probes] section is (§28 §4 "Probes
// ride the executable artifact").
//
// NODE-FOREST-ONLY, NEVER SOURCE (§28 §2). A probe's predicate/expression body is a
// §2.7 node forest compiled funpack-side and carried in the artifact (Probe_Decl.
// body); this file evaluates it through the EXISTING interpreter (`eval`, interp.odin
// — the §09 ground truth) against the behavior's bound scope. The runtime owns no
// funpack compiler and never compiles source live; the only evaluable form is the
// node forest the artifact supplied.
//
// OBSERVE-CLASS / NON-PERTURBING (§28 §2, the determinism warranty). Honoring a
// probe is a PURE READ: a predicate/expression body folds against the behavior's
// already-bound env and reads it, never writing tick state, and a @watch's prior
// value lives in the Probe_Honor buffer (request/session scratch), never in the
// committed COW chain — exactly the Tick_Observe discipline. So a probed session's
// canonical chain digests bit-identical to the unprobed run: "observation can never
// change behavior — no heisenbugs." The honor tap rides the SAME tick fold every
// driver runs (set on Tick_State, read at the behavior-step seam), nil off a fold.
//
// HONOR TARGET MAP (spec §28 §4 On-table + §05 §5). The live honor surface is
// behavior-step-centric: a probe whose TARGET is a behavior folds its body against
// that behavior's bound env at every step; a @watch whose TARGET is a `data`/thing
// FIELD is honored at each behavior step whose on_thing owns the field (the field's
// value diffed across the step). A probe targeting a fn/let/query/enum/signal/
// pipeline — the broader §05 §5 parse breadth — rides the artifact for the §29 §2
// index review but has no per-tick behavior step to fold against, so it is loaded
// but not honored live here (see the run reasoning log, runtime-2.2-honor-target-
// resolution).
package funpack_runtime

import "core:fmt"
import "core:strings"

// Probe_Honor is the §28 §4 honor buffer the tick fold threads through step_tick —
// the probe-side twin of Tick_Observe. When non-nil, the behavior-step seam folds
// every behavior-targeted probe against the bound env and APPENDS its firings here
// (breakpoint hits, watch fires, log emits, trace records), in fold order
// (flattened pipeline order, stable Id order within a step — the deterministic order
// the fold runs in, so the firing order is replayable). The tap only reads the
// fold's values and appends; it never writes tick state, which is what keeps
// honoring non-perturbing. The `program` and `watch_state` are read to resolve
// targets and diff @watch values across steps WITHOUT touching the committed chain.
Probe_Honor :: struct {
	program:     ^Program,
	breaks:      [dynamic]Break_Hit,
	watches:     [dynamic]Watch_Fire,
	logs:        [dynamic]Log_Emit,
	traces:      [dynamic]Trace_Record,
	// watch_state retains the LAST value each @watch saw, keyed by (probe index,
	// instance) — the prior the next step diffs against to detect a change. It lives
	// in this request/session scratch, never in tick state (the non-perturbation
	// invariant): a @watch fires only on a value that DIFFERS from the previous step
	// the same instance ran, so the first observation of an instance never fires
	// (there is no prior to differ from).
	watch_state: map[Watch_Key]Value,
	allocator:   Runtime_Allocator,
}

// Watch_Key identifies one @watch's running value for one instance: the probe's
// index in program.probes (a stable per-program identity) and the instance Id. Two
// instances of the same on-Thing each track their own prior, so a change on one
// never spuriously fires the other.
Watch_Key :: struct {
	probe:    int,
	instance: Id,
}

// Break_Hit is one §28 §4 @break firing: the probed behavior, the instance whose
// step satisfied the predicate, the tick, and the bound `self` blackboard rendered
// in the artifact literal encoding (the §28 §2 breakpoint_hit payload — the firing
// probe's target and the value/context). It becomes a `breakpoint_hit` async event.
Break_Hit :: struct {
	behavior: string,
	target:   string, // the probe's §28 §2 index-identity target (the behavior name)
	instance: Id,
	tick:     int,
	self_enc: string, // the bound self blackboard, artifact literal encoding
}

// Watch_Fire is one §28 §4 @watch firing: the watched target, the instance, the
// tick, and the value's old → new encodings (the §28 §2 watch_fired payload — the
// firing probe's target and value). It is appended only when the watched
// expression's value DIFFERS from the prior step's, so the stream carries changes,
// never every step.
Watch_Fire :: struct {
	target:   string, // the watched behavior or `data` field's §28 §2 identity
	instance: Id,
	tick:     int,
	old_enc:  string, // the prior value, artifact literal encoding
	new_enc:  string, // the changed-to value, artifact literal encoding
}

// Log_Emit is one §28 §4 @log firing: the probed behavior, the instance, the tick,
// and the structured value rendered in the artifact literal encoding (the §28 §4
// "structured, serialized value each step, with tick/thing context" — the
// printf-debugging killer: typed, queryable, never a raw print). One per behavior
// step (a @log emits every step, unconditionally).
Log_Emit :: struct {
	behavior: string,
	target:   string,
	instance: Id,
	tick:     int,
	value_enc: string, // the logged value, artifact literal encoding
}

// Trace_Record is one §28 §4 @trace firing: the full per-step (in → out)
// transition — the behavior, the instance, the tick, the bound `self` before, and
// the returned value after, both in the artifact literal encoding. It mirrors the
// observe trace's (self_before, result) shape; @trace records every step (no
// predicate).
Trace_Record :: struct {
	behavior:    string,
	target:      string,
	instance:    Id,
	tick:        int,
	self_before: string, // the bound self blackboard before the step, artifact literal encoding
	result_enc:  string, // the step's returned value, artifact literal encoding
	ok:          bool,   // false for a body that produced no return
}

// new_probe_honor builds an empty honor buffer over a program on `allocator` (the
// request/session scratch) — the buffer the tick fold appends firings into. The
// program is retained read-only so the seam resolves a probe's target against the
// loaded [probes]/[things] without re-reading the artifact.
new_probe_honor :: proc(program: ^Program, allocator := context.allocator) -> Probe_Honor {
	return Probe_Honor {
		program     = program,
		breaks      = make([dynamic]Break_Hit, allocator),
		watches     = make([dynamic]Watch_Fire, allocator),
		logs        = make([dynamic]Log_Emit, allocator),
		traces      = make([dynamic]Trace_Record, allocator),
		watch_state = make(map[Watch_Key]Value, allocator),
		allocator   = allocator,
	}
}

// honor_behavior_step folds every probe that targets this behavior step against the
// bound env and appends its firing(s) to the honor buffer — called from the tick
// fold (run_behavior_over_instances) when the honor tap is armed, at the SAME seam
// the observe tap fires. It is a pure read of the fold's already-computed values:
// it evaluates predicate/expression bodies against `env` (never writing tick state)
// and records firings, so an honored fold commits bit-identical state to an
// un-honored one (the §28 §2 non-perturbation warranty). `tick` is the 0-based tick
// ordinal the firing is stamped with (the §28 §2 tick/thing context).
honor_behavior_step :: proc(
	honor: ^Probe_Honor,
	interp: ^Interp,
	tick: int,
	behavior: ^Behavior_Decl,
	self_row: Row,
	env: ^Env,
	result: Value,
	ok: bool,
) {
	for &probe, idx in honor.program.probes {
		if !probe_honored_at(probe, behavior) {
			continue
		}
		switch probe.kind {
		case .Break:
			honor_break(honor, interp, probe, behavior, self_row, env, tick)
		case .Log:
			honor_log(honor, interp, probe, behavior, self_row, env, tick)
		case .Watch:
			honor_watch(honor, interp, probe, idx, behavior, self_row, env, tick)
		case .Trace:
			honor_trace(honor, interp, probe, behavior, self_row, env, result, ok, tick)
		}
	}
}

// probe_honored_at reports whether a probe fires at THIS behavior step (spec §28 §4
// On-table). A probe whose target is the behavior's NAME is honored against the
// behavior's bound env every step. A @watch whose target is a `data`/thing FIELD is
// honored at every step of a behavior writing that field's owning thing — resolved
// by matching the watched field's thing to the behavior's on_thing. Every other
// target (a fn/let/query/etc. name with no per-tick step) is not honored here.
probe_honored_at :: proc(probe: Probe_Decl, behavior: ^Behavior_Decl) -> bool {
	if probe.target == behavior.name {
		return true
	}
	// A @watch may prefix a `data` field (§05 §5); its target is the field's owning
	// thing, honored at each step of a behavior writing that thing.
	if probe.kind == .Watch && probe.target == behavior.on_thing {
		return true
	}
	return false
}

// honor_break evaluates a @break predicate against the behavior's bound env; when it
// holds, it appends a Break_Hit (the §28 §2 breakpoint_hit event the live host
// pushes, pausing the session). The predicate is a pure fold of the node forest the
// artifact carried — no source, no write. A predicate that does not evaluate to a
// bool (a malformed body the loader would not have emitted) does not fire.
@(private = "file")
honor_break :: proc(
	honor: ^Probe_Honor,
	interp: ^Interp,
	probe: Probe_Decl,
	behavior: ^Behavior_Decl,
	self_row: Row,
	env: ^Env,
	tick: int,
) {
	value, eval_ok := eval_probe_body(interp, probe, env)
	if !eval_ok {
		return
	}
	if !as_bool(value) {
		return
	}
	append(
		&honor.breaks,
		Break_Hit {
			behavior = behavior.name,
			target = probe.target,
			instance = self_row.id,
			tick = tick,
			self_enc = encode_blackboard_text(behavior.on_thing, self_row.fields, honor.allocator),
		},
	)
}

// honor_log evaluates a @log expression against the bound env and appends a Log_Emit
// EVERY step (a @log is unconditional — the structured value each step, §28 §4). The
// value is rendered in the artifact literal encoding, so the emitted log is typed
// and queryable, never a raw print.
@(private = "file")
honor_log :: proc(
	honor: ^Probe_Honor,
	interp: ^Interp,
	probe: Probe_Decl,
	behavior: ^Behavior_Decl,
	self_row: Row,
	env: ^Env,
	tick: int,
) {
	value, eval_ok := eval_probe_body(interp, probe, env)
	if !eval_ok {
		return
	}
	append(
		&honor.logs,
		Log_Emit {
			behavior = behavior.name,
			target = probe.target,
			instance = self_row.id,
			tick = tick,
			value_enc = encode_value_text(value, honor.allocator),
		},
	)
}

// honor_watch evaluates a @watch expression against the bound env and appends a
// Watch_Fire ONLY when the value DIFFERS from the prior step the same instance ran
// (§28 §4 "fire watch_fired when the value changes"). The running prior lives in the
// honor buffer keyed by (probe, instance) — never in tick state, so the watch is
// non-perturbing. The first observation of an instance establishes the baseline and
// does not fire (no prior to differ from).
@(private = "file")
honor_watch :: proc(
	honor: ^Probe_Honor,
	interp: ^Interp,
	probe: Probe_Decl,
	probe_index: int,
	behavior: ^Behavior_Decl,
	self_row: Row,
	env: ^Env,
	tick: int,
) {
	value, eval_ok := eval_probe_body(interp, probe, env)
	if !eval_ok {
		return
	}
	key := Watch_Key{probe = probe_index, instance = self_row.id}
	prior, seen := honor.watch_state[key]
	honor.watch_state[key] = value
	if !seen {
		return // first observation: establish the baseline, never fire
	}
	if values_equal(prior, value) {
		return // unchanged: no fire
	}
	append(
		&honor.watches,
		Watch_Fire {
			target = probe.target,
			instance = self_row.id,
			tick = tick,
			old_enc = encode_value_text(prior, honor.allocator),
			new_enc = encode_value_text(value, honor.allocator),
		},
	)
}

// honor_trace appends a Trace_Record for EVERY step (a @trace records the full
// per-step (in → out) transition, §28 §4 — no predicate). It mirrors the observe
// trace's (self_before, result) shape: the bound self before the step and the
// returned value after, both in the artifact literal encoding. self_row.fields still
// aliases the pre-eval working map here (a blackboard write REPLACES the map, never
// mutates it), so it is the before-state.
@(private = "file")
honor_trace :: proc(
	honor: ^Probe_Honor,
	interp: ^Interp,
	probe: Probe_Decl,
	behavior: ^Behavior_Decl,
	self_row: Row,
	env: ^Env,
	result: Value,
	ok: bool,
	tick: int,
) {
	append(
		&honor.traces,
		Trace_Record {
			behavior = behavior.name,
			target = probe.target,
			instance = self_row.id,
			tick = tick,
			self_before = encode_blackboard_text(behavior.on_thing, self_row.fields, honor.allocator),
			result_enc = encode_value_text(result, honor.allocator),
			ok = ok,
		},
	)
}

// eval_probe_body folds a probe's predicate/expression node forest against the
// behavior's bound env through the EXISTING interpreter's EXPRESSION evaluator (`eval`,
// §09 ground truth). A probe body is a bare EXPRESSION the funpack emitter wrote with
// emit_expr (a predicate `self.n > 2`, a watched/logged `self.n`) — NOT a statement
// body, so it is evaluated with `eval` directly, never the statement fold
// (eval_statement/eval_body reject a bare expression at statement position). The body
// is exactly one expression subtree (body_count 1 for @break/@log/@watch); a @trace
// body is empty (body_count 0) and never reaches here. ok is false for an empty or
// malformed body (a body the loader would not have emitted for a value-bearing probe),
// so a degenerate body never fires.
@(private = "file")
eval_probe_body :: proc(interp: ^Interp, probe: Probe_Decl, env: ^Env) -> (value: Value, ok: bool) {
	if len(probe.body) != 1 {
		return nil, false
	}
	return eval(interp, &probe.body[0], env)
}

// encode_value_text renders one interpreter Value in the artifact literal encoding
// (the §28 §2 wire form — Int decimal, Fixed raw Q32.32 bits, records/lists/variants
// in their inline forms), the same render_value_text the observe trace uses. Kept as
// a plain string (not JSON-quoted) here; the event renderer JSON-quotes it.
@(private = "file")
encode_value_text :: proc(value: Value, allocator := context.allocator) -> string {
	b := strings.builder_make(allocator)
	render_value_text(&b, value)
	return strings.to_string(b)
}

// encode_blackboard_text renders one row's whole blackboard as a `Thing(field=enc,…)`
// record literal in sorted field-name order — the serialization-closure dump (§28 §1)
// the breakpoint_hit/trace payloads carry. It mirrors write_encoded_blackboard's body
// without the JSON quoting (the event renderer quotes it).
@(private = "file")
encode_blackboard_text :: proc(
	thing: string,
	fields: map[string]Field_Value,
	allocator := context.allocator,
) -> string {
	b := strings.builder_make(allocator)
	strings.write_string(&b, thing)
	strings.write_byte(&b, '(')
	names := sorted_blackboard_names(fields, allocator)
	for name, i in names {
		if i > 0 {
			strings.write_byte(&b, ',')
		}
		strings.write_string(&b, name)
		strings.write_byte(&b, '=')
		render_field_value_text(&b, fields[name])
	}
	strings.write_byte(&b, ')')
	return strings.to_string(b)
}

// --- The async-event renderers (§28 §2/§3 the closed async-event set) --------

// render_breakpoint_hit_event renders one Break_Hit as a §28 §2 async-event NDJSON
// line: `{v, event, …}`, correlated by `event` name (not `id`), carrying the firing
// probe's target and value (the §28 §2 "two that carry probe payloads"). The field
// order is fixed (v, event, target, behavior, instance, tick, self), so the line is
// byte-stable for the session log (§28 §3: a debug session re-runs bit-identically).
// `breakpoint_hit` is the §28 §3 closed-set event a @break pause pushes.
render_breakpoint_hit_event :: proc(hit: Break_Hit, allocator := context.allocator) -> string {
	b := strings.builder_make(allocator)
	fmt.sbprintf(&b, "{{\"v\":%d,\"event\":\"breakpoint_hit\",\"target\":", INTROSPECT_PROTOCOL_VERSION)
	write_json_string(&b, hit.target)
	strings.write_string(&b, ",\"behavior\":")
	write_json_string(&b, hit.behavior)
	fmt.sbprintf(&b, ",\"instance\":%d,\"tick\":%d,\"self\":", hit.instance.raw, hit.tick)
	write_json_string(&b, hit.self_enc)
	strings.write_byte(&b, '}')
	return strings.to_string(b)
}

// render_watch_fired_event renders one Watch_Fire as a §28 §2 async-event NDJSON
// line: `{v, event, …}` carrying the firing probe's target and the old → new value
// (the §28 §2 watch_fired payload). Fixed field order (v, event, target, instance,
// tick, old, new). `watch_fired` is the §28 §3 closed-set event a @watch value change
// pushes.
render_watch_fired_event :: proc(fire: Watch_Fire, allocator := context.allocator) -> string {
	b := strings.builder_make(allocator)
	fmt.sbprintf(&b, "{{\"v\":%d,\"event\":\"watch_fired\",\"target\":", INTROSPECT_PROTOCOL_VERSION)
	write_json_string(&b, fire.target)
	fmt.sbprintf(&b, ",\"instance\":%d,\"tick\":%d,\"old\":", fire.instance.raw, fire.tick)
	write_json_string(&b, fire.old_enc)
	strings.write_string(&b, ",\"new\":")
	write_json_string(&b, fire.new_enc)
	strings.write_byte(&b, '}')
	return strings.to_string(b)
}

// --- The session honor seam (the foundation the live break/watch group builds on) -

// session_honor_probes re-folds the WHOLE recorded run with the probe-honor tap
// armed and returns the populated buffer — every @break hit, @watch fire, @log emit,
// and @trace record the run's in-code probes produced, in fold order across ticks —
// plus the FINAL committed version the honored fold produced. It re-runs the EXACT
// production fold (the same step_tick + recorded snapshots + per-tick Time + retained
// entering-Rng a seeded run uses) into request-scoped scratch: the SESSION'S
// canonical chain (s.versions) is never touched — this fold builds its own scratch
// chain — so honoring is observe-class by construction (§28 §2). The returned
// `final` is the comparison surface the non-perturbation pin holds against an
// unprobed reference fold: a honored step_tick commits bit-identical state to an
// un-honored one (the determinism warranty). It is the bounded re-fold the live
// break/watch/clear command group will drive incrementally; here it drains the whole
// timeline at once so the honor battery can assert the firings against a recorded
// session. The @watch running-prior threads ACROSS ticks for an instance (the
// buffer's watch_state outlives a single tick), so a watch fires on a real cross-step
// change, not a per-tick reset.
session_honor_probes :: proc(
	s: ^Debug_Session,
	allocator := context.allocator,
) -> (
	honor: Probe_Honor,
	final: World_Version,
) {
	honor = new_probe_honor(s.program, allocator)
	prior := s.startup
	tick_hz := s.program.entrypoint.tick_hz
	for snapshot, i in s.snapshots {
		time := time_resource_at(tick_hz, i, allocator)
		if s.seed.has_seed {
			rng := s.rngs[i]
			prior = step_tick(s.program, prior, snapshot, time, allocator, &rng, honor = &honor, honor_tick = i)
		} else {
			prior = step_tick(s.program, prior, snapshot, time, allocator, nil, honor = &honor, honor_tick = i)
		}
	}
	return honor, prior
}
