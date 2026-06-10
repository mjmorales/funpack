// The §28 introspection session — the observe side of the fourth structured
// contract (runtime → agent). The session layer is a PURE request/response fold
// over (session_state, request) → (session_state, response): one NDJSON line in,
// one NDJSON line out, no socket — the duplex transport is a thin adapter a
// live host wires over this seam later (deliberately deferred; the fold is the
// contract and is harness-testable without it).
//
// THE ENVELOPE (§28 §2): a JSON envelope with funpack payloads — every funpack
// value crossing the wire is a STRING in the artifact's own literal encoding
// (§16: Int decimal, Fixed raw Q32.32 bits, `Type(f=enc,…)` records, `[enc,…]`
// lists, `Enum::Case` tokens, `Lk:bytes` strings), the one value codec the
// runtime already owns (decode_default_value is its inverse, so a control
// payload round-trips through the same encoding). The protocol is versioned
// exact-match (§28 §2): every response carries `"v"`, and a request declaring a
// different version is refused.
//
// OBSERVE IS NON-PERTURBING BY CONSTRUCTION (§28 §2): every observe command is
// a pure read of the session's RETAINED COMMITTED COW chain — `pipeline` reads
// the artifact, `diff`/`draw_list` read committed versions, and
// `signals`/`trace`/`replay_behavior` re-fold ONE tick from its prior committed
// version into a scratch result with the Tick_Observe tap copying values out
// (the tap never writes tick state). The canonical chain is never touched, so
// an observed run digests bit-identical to an unobserved one — the digest-pin
// acceptance test (introspect_test.odin) holds the warranty, and §28's "an
// observe-only session is safe to run in CI" follows.
//
// The COW chain makes retention cheap (§28 §1: snapshots ≈ retaining a root
// pointer): open_debug_session folds the recorded run once through the SAME
// run_startup/step_tick seam every driver uses and keeps every committed
// version — the §28 §3 time-travel substrate.
package funpack_runtime

import "core:encoding/json"
import "core:fmt"
import "core:slice"
import "core:strings"

// INTROSPECT_PROTOCOL_VERSION is the §28 §2 exact-match envelope version. Every
// response carries it as `"v"`; a request declaring a different `"v"` is refused
// (a request with no `"v"` speaks the current version). A change to the envelope
// shape or the value encoding bumps it.
INTROSPECT_PROTOCOL_VERSION :: 1

// Debug_Session is the introspection session state: the loaded program, the
// recorded determinism inputs (per-tick snapshots + the tick-0 seed, exactly the
// replay record's inputs), and the RETAINED committed COW chain the observe
// commands read. `rngs` retains the Rng state ENTERING each tick (seeded runs
// only) so a single tick re-folds bit-identically in isolation — the same
// fold-forward threading step_tick does, snapshotted per boundary.
//
// The canonical chain is never written after open — observe reads it; the
// control side (§28 §2: control perturbs, so it forks) forks a branch off it
// and never mutates the trunk.
Debug_Session :: struct {
	program:   ^Program,
	seed:      Run_Seed,
	snapshots: []Input, // the recorded per-tick action snapshots (tick i read snapshots[i])
	startup:   World_Version, // the committed post-startup version tick 0 folds from
	versions:  []World_Version, // versions[i] = the committed version tick i produced
	rngs:      []Rng, // seeded runs: rngs[i] = Rng entering tick i; rngs[n] = final. Empty when seedless.
	allocator: Runtime_Allocator,
}

// open_debug_session folds a recorded run once through the production seam
// (run_startup / run_startup_seeded + step_tick — the identical fold replay_refold
// drives) and retains the whole committed chain plus the per-boundary Rng states.
// The retained chain is the observe surface: structural sharing makes each version
// a near-free root pointer (§08 §4), so a session over an M-tick run holds M+1
// roots, not M copies. The caller owns the program and the snapshots; the session
// allocates its retained state on `allocator`.
open_debug_session :: proc(
	program: ^Program,
	snapshots: []Input,
	run_seed: Run_Seed = NO_SEED,
	allocator := context.allocator,
) -> Debug_Session {
	world := new_world(program^, allocator)
	base := initial_version(world, allocator)
	tick_hz := program.entrypoint.tick_hz
	versions := make([]World_Version, len(snapshots), allocator)
	session := Debug_Session {
		program   = program,
		seed      = run_seed,
		snapshots = snapshots,
		versions  = versions,
		allocator = allocator,
	}

	if run_seed.has_seed {
		rngs := make([]Rng, len(snapshots) + 1, allocator)
		startup, advanced := run_startup_seeded(program, base, rand_seed(run_seed.seed), allocator)
		current := advanced
		prior := startup
		for snapshot, i in snapshots {
			rngs[i] = current
			time := time_resource_at(tick_hz, i, allocator)
			versions[i] = step_tick(program, prior, snapshot, time, allocator, &current)
			prior = versions[i]
		}
		rngs[len(snapshots)] = current
		session.startup = startup
		session.rngs = rngs
		return session
	}

	startup := run_startup(program, base, allocator)
	prior := startup
	for snapshot, i in snapshots {
		time := time_resource_at(tick_hz, i, allocator)
		versions[i] = step_tick(program, prior, snapshot, time, allocator)
		prior = versions[i]
	}
	session.startup = startup
	return session
}

// session_version_at resolves a tick ordinal onto the retained committed chain:
// -1 is the post-startup version (the state tick 0 folds from), 0..n-1 the
// committed result of that tick. Out-of-range is ok=false — the request layer
// turns it into a refusal, never a crash.
session_version_at :: proc(s: ^Debug_Session, tick: int) -> (version: World_Version, ok: bool) {
	if tick == -1 {
		return s.startup, true
	}
	if tick < 0 || tick >= len(s.versions) {
		return {}, false
	}
	return s.versions[tick], true
}

// session_capture digests the session's retained canonical chain exactly as the
// production capture drivers do — per committed tick, render_version's §20
// draw-list projection over the SAME per-tick Time derivation, capture_frame,
// then the session fold. It is the comparison surface the non-perturbation and
// canonical-untouched acceptance tests pin against an unobserved reference run:
// equal captures prove the observed/controlled session's canonical chain is
// bit-identical to a run nobody touched.
session_capture :: proc(s: ^Debug_Session, allocator := context.allocator) -> Frame_Capture {
	tick_hz := s.program.entrypoint.tick_hz
	per_tick := make([dynamic]Frame_Digest, 0, len(s.versions), allocator)
	for version, i in s.versions {
		time := time_resource_at(tick_hz, i, allocator)
		draw := render_version(s.program, version, s.snapshots[i], time, allocator)
		append(&per_tick, capture_frame(version, draw, allocator))
	}
	return finish_capture(per_tick[:], allocator)
}

// --- The Tick_Observe tap (the capture seam the tick fold carries) ---------

// Tick_Observe is the §28 observe-class capture buffer a re-fold threads through
// step_tick: the per-behavior-step (in → out) transitions and the routed signals,
// in fold order (flattened pipeline order, stable Id order within a step — the
// deterministic order the fold itself runs in, so the capture order is replayable).
// The tap sites (tick.odin) only APPEND copies here; they never read it back into
// the fold, which is what makes observation non-perturbing by construction.
Tick_Observe :: struct {
	steps:     [dynamic]Step_Capture,
	signals:   [dynamic]Signal_Capture,
	allocator: Runtime_Allocator,
}

// new_tick_observe builds an empty capture buffer on `allocator` — the request
// scratch, so a capture's values (which alias the re-fold's tick-allocated
// values) stay live exactly as long as the response is being rendered.
new_tick_observe :: proc(allocator := context.allocator) -> Tick_Observe {
	return Tick_Observe {
		steps     = make([dynamic]Step_Capture, allocator),
		signals   = make([dynamic]Signal_Capture, allocator),
		allocator = allocator,
	}
}

// Step_Capture is one behavior instance's (in → out) at one pipeline step: the
// step ordinal, the instance, the pre-eval blackboard (the working map the fold
// later REPLACES, never mutates — so the alias stays the before-state), the bound
// param environment (the behavior's declared reads, copied shallowly), and the
// returned value. `ok` is false for a body that produced no return.
Step_Capture :: struct {
	ordinal:     int,
	behavior:    string,
	instance:    Id,
	self_before: map[string]Field_Value, // aliases the pre-eval working map (replaced, not mutated)
	env:         map[string]Value, // the bound reads, copied at capture (values aliased)
	result:      Value,
	ok:          bool,
}

// Signal_Capture is one routed signal delivery: the signal type, the routed
// values, and — for a §11 §4 engine per-instance signal — the target instance
// the engine routed it to. Broadcast routes carry per_instance=false.
Signal_Capture :: struct {
	signal:       string,
	per_instance: bool,
	target:       Id, // meaningful only when per_instance
	values:       []Value,
}

// observe_behavior_step copies one behavior instance's transition into the
// capture buffer — called from the tick fold (run_behavior_over_instances) when
// the tap is armed. The env map is copied (the fold's env is scratch the next
// instance rebinds); the values inside it are aliased, safe because the capture
// and the re-fold share one request-scoped allocator.
observe_behavior_step :: proc(
	obs: ^Tick_Observe,
	step: Pipeline_Step,
	behavior: ^Behavior_Decl,
	self_row: Row,
	env: Env,
	result: Value,
	ok: bool,
) {
	captured := make(map[string]Value, obs.allocator)
	for name, value in env.names {
		captured[name] = value
	}
	append(
		&obs.steps,
		Step_Capture {
			ordinal     = step.ordinal,
			behavior    = behavior.name,
			instance    = self_row.id,
			self_before = self_row.fields,
			env         = captured,
			result      = result,
			ok          = ok,
		},
	)
}

// observe_broadcast_signals copies one broadcast route (route_signals) into the
// capture buffer — the elements slice is copied so the capture survives the
// mailbox's own combining.
observe_broadcast_signals :: proc(obs: ^Tick_Observe, signal_type: string, values: []Value) {
	copied := make([]Value, len(values), obs.allocator)
	copy(copied, values)
	append(&obs.signals, Signal_Capture{signal = signal_type, values = copied})
}

// observe_instance_signal copies one engine per-instance route
// (route_instance_signal) with its target Id into the capture buffer.
observe_instance_signal :: proc(obs: ^Tick_Observe, signal_type: string, target: Id, signal: Value) {
	values := make([]Value, 1, obs.allocator)
	values[0] = signal
	append(
		&obs.signals,
		Signal_Capture{signal = signal_type, per_instance = true, target = target, values = values},
	)
}

// session_refold_tick re-folds ONE recorded tick from its prior committed version
// with the observe tap armed — the bounded re-fold `signals`/`trace`/
// `replay_behavior` read (§28 §3: causality is recomputed, not stored). It re-runs
// the EXACT production fold (same step_tick, same recorded snapshot, same per-tick
// Time, the retained entering-Rng for a seeded run) into request-scoped scratch:
// the canonical chain is read, never written, so the re-fold is observe-class by
// construction. Returns the re-committed version (the tick's after-state the
// trace's self_after reads) — bit-identical to the retained versions[tick], since
// the inputs are identical and the fold is deterministic.
session_refold_tick :: proc(
	s: ^Debug_Session,
	tick: int,
	observe: ^Tick_Observe,
	allocator := context.allocator,
) -> (
	committed: World_Version,
	ok: bool,
) {
	if tick < 0 || tick >= len(s.snapshots) {
		return {}, false
	}
	prior := tick == 0 ? s.startup : s.versions[tick - 1]
	time := time_resource_at(s.program.entrypoint.tick_hz, tick, allocator)
	if s.seed.has_seed {
		rng := s.rngs[tick]
		return step_tick(s.program, prior, s.snapshots[tick], time, allocator, &rng, observe), true
	}
	return step_tick(s.program, prior, s.snapshots[tick], time, allocator, nil, observe), true
}

// --- The request fold: one NDJSON line in, one NDJSON line out -------------

// session_request is the duplex seam's pure fold: parse one request line
// (`{"id":N,"cmd":"…","args":{…}`), dispatch it, and render one response line
// (no trailing newline — the transport adapter owns framing). Observe commands
// leave the session untouched; control commands (introspect_control.odin) write
// only the branch. Every refusal is a well-formed `"ok":false` envelope carrying
// the request id (0 when the line was too malformed to carry one), so the
// command stream stays loggable and replayable (§28 §3: sessions are themselves
// replayable).
session_request :: proc(
	s: ^Debug_Session,
	line: string,
	allocator := context.allocator,
) -> string {
	parsed, parse_err := json.parse(transmute([]u8)line, json.DEFAULT_SPECIFICATION, true, allocator)
	if parse_err != .None {
		return error_response(0, "", "malformed request: not valid JSON", allocator)
	}
	request, is_object := parsed.(json.Object)
	if !is_object {
		return error_response(0, "", "malformed request: not a JSON object", allocator)
	}
	id, _ := json_int_field(request, "id")
	if declared, has_version := json_int_field(request, "v"); has_version {
		if declared != INTROSPECT_PROTOCOL_VERSION {
			return error_response(id, "", "protocol version mismatch: exact-match v1 required", allocator)
		}
	}
	cmd, has_cmd := json_string_field(request, "cmd")
	if !has_cmd {
		return error_response(id, "", "malformed request: missing cmd", allocator)
	}
	args: json.Object
	if nested, has_args := request["args"]; has_args {
		if object, args_ok := nested.(json.Object); args_ok {
			args = object
		}
	}

	switch cmd {
	case "pipeline":
		return observe_pipeline(s, id, allocator)
	case "signals":
		return observe_signals(s, id, args, allocator)
	case "trace":
		return observe_trace(s, id, args, allocator)
	case "diff":
		return observe_diff(s, id, args, allocator)
	case "replay_behavior":
		return observe_replay_behavior(s, id, args, allocator)
	case "draw_list":
		return observe_draw_list(s, id, args, allocator)
	}
	return error_response(id, cmd, "unknown command", allocator)
}

// --- Observe commands -------------------------------------------------------

// observe_pipeline answers the flattened §11 total order — every Pipeline_Step's
// ordinal, stage, and behavior, exactly as the artifact carries them. A pure read
// of the loaded program; stepping granularity IS this schedule (§28 §1).
@(private = "file")
observe_pipeline :: proc(s: ^Debug_Session, id: i64, allocator := context.allocator) -> string {
	b := strings.builder_make(allocator)
	ok_response_open(&b, id, "pipeline")
	strings.write_string(&b, "{\"steps\":[")
	for step, i in s.program.pipeline {
		if i > 0 {
			strings.write_byte(&b, ',')
		}
		fmt.sbprintf(&b, "{{\"ordinal\":%d,\"stage\":", step.ordinal)
		write_json_string(&b, step.stage)
		strings.write_string(&b, ",\"behavior\":")
		write_json_string(&b, step.behavior)
		strings.write_byte(&b, '}')
	}
	strings.write_string(&b, "]}}")
	return strings.to_string(b)
}

// observe_signals answers the signals routed during one recorded tick — the live
// dataflow as data (§28 §1). It re-folds the tick with the tap armed and renders
// every route in fold order: broadcast routes with their value lists, engine
// per-instance routes with their target Id.
@(private = "file")
observe_signals :: proc(
	s: ^Debug_Session,
	id: i64,
	args: json.Object,
	allocator := context.allocator,
) -> string {
	tick, has_tick := json_int_field(args, "tick")
	if !has_tick {
		return error_response(id, "signals", "missing args.tick", allocator)
	}
	obs := new_tick_observe(allocator)
	if _, ok := session_refold_tick(s, int(tick), &obs, allocator); !ok {
		return error_response(id, "signals", "tick out of range", allocator)
	}
	b := strings.builder_make(allocator)
	ok_response_open(&b, id, "signals")
	fmt.sbprintf(&b, "{{\"tick\":%d,\"routes\":[", tick)
	for capture, i in obs.signals {
		if i > 0 {
			strings.write_byte(&b, ',')
		}
		strings.write_string(&b, "{\"signal\":")
		write_json_string(&b, capture.signal)
		if capture.per_instance {
			fmt.sbprintf(&b, ",\"target\":%d", capture.target.raw)
		} else {
			strings.write_string(&b, ",\"target\":null")
		}
		strings.write_string(&b, ",\"values\":[")
		for value, j in capture.values {
			if j > 0 {
				strings.write_byte(&b, ',')
			}
			write_encoded_value(&b, value, allocator)
		}
		strings.write_string(&b, "]}")
	}
	strings.write_string(&b, "]}}")
	return strings.to_string(b)
}

// observe_trace answers one behavior's per-instance (in → out) for one recorded
// tick — the §28 §3 bounded re-fold ("causality is recomputed, not stored"). Per
// instance it renders the pre-eval blackboard, the bound reads (the declared
// params, in declaration order), the returned value, and the post-tick committed
// blackboard (null when the tick despawned the instance).
@(private = "file")
observe_trace :: proc(
	s: ^Debug_Session,
	id: i64,
	args: json.Object,
	allocator := context.allocator,
) -> string {
	tick, has_tick := json_int_field(args, "tick")
	behavior_name, has_behavior := json_string_field(args, "behavior")
	if !has_tick || !has_behavior {
		return error_response(id, "trace", "missing args.tick or args.behavior", allocator)
	}
	behavior := program_behavior(s.program, behavior_name)
	if behavior == nil {
		return error_response(id, "trace", "unknown behavior", allocator)
	}
	obs := new_tick_observe(allocator)
	committed, ok := session_refold_tick(s, int(tick), &obs, allocator)
	if !ok {
		return error_response(id, "trace", "tick out of range", allocator)
	}
	b := strings.builder_make(allocator)
	ok_response_open(&b, id, "trace")
	fmt.sbprintf(&b, "{{\"tick\":%d,\"behavior\":", tick)
	write_json_string(&b, behavior_name)
	strings.write_string(&b, ",\"steps\":[")
	wrote := 0
	for capture in obs.steps {
		if capture.behavior != behavior_name {
			continue
		}
		if wrote > 0 {
			strings.write_byte(&b, ',')
		}
		wrote += 1
		fmt.sbprintf(&b, "{{\"ordinal\":%d,\"instance\":%d,\"self_before\":", capture.ordinal, capture.instance.raw)
		write_encoded_blackboard(&b, behavior.on_thing, capture.self_before, allocator)
		strings.write_string(&b, ",\"reads\":{")
		for param, i in behavior.params {
			if i > 0 {
				strings.write_byte(&b, ',')
			}
			write_json_string(&b, param.name)
			strings.write_byte(&b, ':')
			write_encoded_value(&b, capture.env[param.name], allocator)
		}
		fmt.sbprintf(&b, "}},\"ok\":%s,\"result\":", capture.ok ? "true" : "false")
		write_encoded_value(&b, capture.result, allocator)
		strings.write_string(&b, ",\"self_after\":")
		write_committed_row(&b, committed, behavior.on_thing, capture.instance, allocator)
		strings.write_byte(&b, '}')
	}
	strings.write_string(&b, "]}}")
	return strings.to_string(b)
}

// write_committed_row renders one committed row's blackboard (the trace's
// self_after) — null when the Id is absent from the committed version (the tick
// despawned it; the dangling case is a value, never a crash).
@(private = "file")
write_committed_row :: proc(
	b: ^strings.Builder,
	version: World_Version,
	thing: string,
	id: Id,
	allocator := context.allocator,
) {
	committed := version
	if table := version_find_table(&committed, thing); table != nil {
		if idx, found := find_row_by_id(table.rows, id); found {
			write_encoded_blackboard(b, thing, table.rows[idx].fields, allocator)
			return
		}
	}
	strings.write_string(b, "null")
}

// observe_diff answers the committed-state delta between two retained ticks — a
// pure read of two COW versions (serialization closure: any tick, no
// instrumentation). Per table (declaration order) it names the rows added,
// removed, and — per surviving row in Id order — each changed field with its
// from/to encodings (sorted field names). Tables with no delta are omitted.
@(private = "file")
observe_diff :: proc(
	s: ^Debug_Session,
	id: i64,
	args: json.Object,
	allocator := context.allocator,
) -> string {
	from_tick, has_from := json_int_field(args, "from")
	to_tick, has_to := json_int_field(args, "to")
	if !has_from || !has_to {
		return error_response(id, "diff", "missing args.from or args.to", allocator)
	}
	from_version, from_ok := session_version_at(s, int(from_tick))
	to_version, to_ok := session_version_at(s, int(to_tick))
	if !from_ok || !to_ok {
		return error_response(id, "diff", "tick out of range", allocator)
	}
	b := strings.builder_make(allocator)
	ok_response_open(&b, id, "diff")
	fmt.sbprintf(&b, "{{\"from\":%d,\"to\":%d,\"tables\":[", from_tick, to_tick)
	wrote := 0
	for to_table in to_version.tables {
		from_rows: []Row
		from_mutable := from_version
		if from_table := version_find_table(&from_mutable, to_table.thing); from_table != nil {
			from_rows = from_table.rows
		}
		table_json := diff_table_json(to_table.thing, from_rows, to_table.rows, allocator)
		if table_json == "" {
			continue
		}
		if wrote > 0 {
			strings.write_byte(&b, ',')
		}
		wrote += 1
		strings.write_string(&b, table_json)
	}
	strings.write_string(&b, "]}}")
	return strings.to_string(b)
}

// diff_table_json renders one table's delta between two committed row sets, or ""
// when the table is unchanged. Both row slices are ascending by Id (the committed
// invariant), so the walk is a linear merge: an Id only in `to` was added, only in
// `from` removed, and a shared Id compares field-by-field in sorted name order.
@(private = "file")
diff_table_json :: proc(
	thing: string,
	from_rows: []Row,
	to_rows: []Row,
	allocator := context.allocator,
) -> string {
	b := strings.builder_make(allocator)
	strings.write_string(&b, "{\"thing\":")
	write_json_string(&b, thing)
	strings.write_string(&b, ",\"added\":[")
	changed := false

	added := 0
	for to_row in to_rows {
		if _, found := find_row_by_id(from_rows, to_row.id); found {
			continue
		}
		if added > 0 {
			strings.write_byte(&b, ',')
		}
		added += 1
		changed = true
		fmt.sbprintf(&b, "{{\"id\":%d,\"row\":", to_row.id.raw)
		write_encoded_blackboard(&b, thing, to_row.fields, allocator)
		strings.write_byte(&b, '}')
	}
	strings.write_string(&b, "],\"removed\":[")
	removed := 0
	for from_row in from_rows {
		if _, found := find_row_by_id(to_rows, from_row.id); found {
			continue
		}
		if removed > 0 {
			strings.write_byte(&b, ',')
		}
		removed += 1
		changed = true
		fmt.sbprintf(&b, "%d", from_row.id.raw)
	}
	strings.write_string(&b, "],\"changed\":[")
	rows_changed := 0
	for to_row in to_rows {
		from_idx, found := find_row_by_id(from_rows, to_row.id)
		if !found {
			continue
		}
		fields_json := diff_fields_json(from_rows[from_idx].fields, to_row.fields, allocator)
		if fields_json == "" {
			continue
		}
		if rows_changed > 0 {
			strings.write_byte(&b, ',')
		}
		rows_changed += 1
		changed = true
		fmt.sbprintf(&b, "{{\"id\":%d,\"fields\":%s}}", to_row.id.raw, fields_json)
	}
	strings.write_string(&b, "]}")
	if !changed {
		return ""
	}
	return strings.to_string(b)
}

// diff_fields_json renders one row's changed columns in sorted field-name order,
// or "" when every column compares equal (field_values_equal — the same
// structural equality the determinism comparisons use).
@(private = "file")
diff_fields_json :: proc(
	from_fields: map[string]Field_Value,
	to_fields: map[string]Field_Value,
	allocator := context.allocator,
) -> string {
	names := sorted_blackboard_names(to_fields, allocator)
	b := strings.builder_make(allocator)
	strings.write_byte(&b, '[')
	wrote := 0
	for name in names {
		from_value, had := from_fields[name]
		if had && field_values_equal(from_value, to_fields[name]) {
			continue
		}
		if wrote > 0 {
			strings.write_byte(&b, ',')
		}
		wrote += 1
		strings.write_string(&b, "{\"field\":")
		write_json_string(&b, name)
		strings.write_string(&b, ",\"from\":")
		if had {
			write_encoded_field_value(&b, from_value, allocator)
		} else {
			strings.write_string(&b, "null")
		}
		strings.write_string(&b, ",\"to\":")
		write_encoded_field_value(&b, to_fields[name], allocator)
		strings.write_byte(&b, '}')
	}
	strings.write_byte(&b, ']')
	if wrote == 0 {
		return ""
	}
	return strings.to_string(b)
}

// observe_replay_behavior re-runs one behavior in isolation from its captured
// inputs (§28 §1: pure behaviors → replay one behavior from captured inputs). The
// tick re-fold captures each instance's bound environment and in-fold result;
// then the behavior body is evaluated a SECOND time over the captured env against
// the prior COMMITTED version (no tick in flight — true isolation), and the two
// results are compared with values_equal. refold_matches=true is the purity
// theorem holding for that instance; a false is a runtime bug to file (a behavior
// read something outside its declared inputs).
@(private = "file")
observe_replay_behavior :: proc(
	s: ^Debug_Session,
	id: i64,
	args: json.Object,
	allocator := context.allocator,
) -> string {
	tick, has_tick := json_int_field(args, "tick")
	behavior_name, has_behavior := json_string_field(args, "behavior")
	if !has_tick || !has_behavior {
		return error_response(id, "replay_behavior", "missing args.tick or args.behavior", allocator)
	}
	behavior := program_behavior(s.program, behavior_name)
	if behavior == nil {
		return error_response(id, "replay_behavior", "unknown behavior", allocator)
	}
	obs := new_tick_observe(allocator)
	if _, ok := session_refold_tick(s, int(tick), &obs, allocator); !ok {
		return error_response(id, "replay_behavior", "tick out of range", allocator)
	}

	// The isolated re-run reads the prior COMMITTED version (tick = nil): the
	// captured env carries every declared read, so the only fallback surface is a
	// committed-version Ref resolve — the §08 population-fixity guarantee.
	prior := new(World_Version, allocator)
	prior^ = int(tick) == 0 ? s.startup : s.versions[int(tick) - 1]
	time := time_resource_at(s.program.entrypoint.tick_hz, int(tick), allocator)
	interp := new_interp(s.program, prior, nil, s.snapshots[int(tick)], time, allocator)

	b := strings.builder_make(allocator)
	ok_response_open(&b, id, "replay_behavior")
	fmt.sbprintf(&b, "{{\"tick\":%d,\"behavior\":", tick)
	write_json_string(&b, behavior_name)
	strings.write_string(&b, ",\"instances\":[")
	wrote := 0
	for capture in obs.steps {
		if capture.behavior != behavior_name {
			continue
		}
		env := Env {
			names = make(map[string]Value, allocator),
		}
		for name, value in capture.env {
			env.names[name] = value
		}
		replayed, replay_ok := eval_behavior_body(&interp, behavior.body, &env)
		matches := capture.ok == replay_ok && (!capture.ok || values_equal(capture.result, replayed))
		if wrote > 0 {
			strings.write_byte(&b, ',')
		}
		wrote += 1
		fmt.sbprintf(&b, "{{\"instance\":%d,\"ok\":%s,\"result\":", capture.instance.raw, capture.ok ? "true" : "false")
		write_encoded_value(&b, capture.result, allocator)
		fmt.sbprintf(&b, ",\"refold_matches\":%s}}", matches ? "true" : "false")
	}
	strings.write_string(&b, "]}}")
	return strings.to_string(b)
}

// observe_draw_list dumps one committed tick's §20 draw-list — the render
// projection re-run post-hoc over the retained version (render is a post-commit
// projection, so re-projecting commits nothing). This is §28's
// screenshot{include_drawlist} surface scoped to the deterministic half: the
// draw-list IS the determinism-path render output; the pixel surface is a
// present-boundary concern the session does not serve.
@(private = "file")
observe_draw_list :: proc(
	s: ^Debug_Session,
	id: i64,
	args: json.Object,
	allocator := context.allocator,
) -> string {
	tick, has_tick := json_int_field(args, "tick")
	if !has_tick {
		return error_response(id, "draw_list", "missing args.tick", allocator)
	}
	version, ok := session_version_at(s, int(tick))
	if !ok || int(tick) < 0 {
		return error_response(id, "draw_list", "tick out of range", allocator)
	}
	time := time_resource_at(s.program.entrypoint.tick_hz, int(tick), allocator)
	draw := render_version(s.program, version, s.snapshots[int(tick)], time, allocator)
	b := strings.builder_make(allocator)
	ok_response_open(&b, id, "draw_list")
	fmt.sbprintf(&b, "{{\"tick\":%d,\"commands\":[", tick)
	for cmd, i in draw.cmds {
		if i > 0 {
			strings.write_byte(&b, ',')
		}
		encoded := strings.builder_make(allocator)
		render_draw_cmd_text(&encoded, cmd)
		write_json_string(&b, strings.to_string(encoded))
	}
	strings.write_string(&b, "]}}")
	return strings.to_string(b)
}

// --- The envelope builders ---------------------------------------------------

// ok_response_open writes the success envelope up to the `result` value — the
// caller writes the result object and the closing brace. Field order is fixed
// (v, id, ok, cmd, result), so a response line is byte-stable for the session
// log (§28 §3: a debug session re-runs bit-identically).
@(private = "file")
ok_response_open :: proc(b: ^strings.Builder, id: i64, cmd: string) {
	fmt.sbprintf(b, "{{\"v\":%d,\"id\":%d,\"ok\":true,\"cmd\":", INTROSPECT_PROTOCOL_VERSION, id)
	write_json_string(b, cmd)
	strings.write_string(b, ",\"result\":")
}

// error_response renders the refusal envelope: same fixed field order, an
// `"error"` string instead of a result. Every malformed or refused request gets
// one — the fold never panics on wire input.
error_response :: proc(
	id: i64,
	cmd: string,
	message: string,
	allocator := context.allocator,
) -> string {
	b := strings.builder_make(allocator)
	fmt.sbprintf(&b, "{{\"v\":%d,\"id\":%d,\"ok\":false,\"cmd\":", INTROSPECT_PROTOCOL_VERSION, id)
	write_json_string(&b, cmd)
	strings.write_string(&b, ",\"error\":")
	write_json_string(&b, message)
	strings.write_byte(&b, '}')
	return strings.to_string(b)
}

// write_json_string writes one JSON string literal with the mandatory escapes
// (quote, backslash, control bytes); UTF-8 payload bytes pass through verbatim.
write_json_string :: proc(b: ^strings.Builder, s: string) {
	strings.write_byte(b, '"')
	for i in 0 ..< len(s) {
		c := s[i]
		switch c {
		case '"':
			strings.write_string(b, "\\\"")
		case '\\':
			strings.write_string(b, "\\\\")
		case '\n':
			strings.write_string(b, "\\n")
		case '\r':
			strings.write_string(b, "\\r")
		case '\t':
			strings.write_string(b, "\\t")
		case:
			if c < 0x20 {
				fmt.sbprintf(b, "\\u%04x", c)
			} else {
				strings.write_byte(b, c)
			}
		}
	}
	strings.write_byte(b, '"')
}

// json_int_field reads one integer field off a parsed request object. Requests
// are parsed with parse_integers=true, so a JSON integer arrives as i64 — no
// float ever enters the envelope (§10).
@(private = "file")
json_int_field :: proc(object: json.Object, key: string) -> (value: i64, ok: bool) {
	field, has := object[key]
	if !has {
		return 0, false
	}
	integer, is_integer := field.(json.Integer)
	if !is_integer {
		return 0, false
	}
	return integer, true
}

// json_string_field reads one string field off a parsed request object.
@(private = "file")
json_string_field :: proc(object: json.Object, key: string) -> (value: string, ok: bool) {
	field, has := object[key]
	if !has {
		return "", false
	}
	text, is_string := field.(json.String)
	if !is_string {
		return "", false
	}
	return text, true
}

// --- The funpack value encoding (the §28 §2 "funpack values as strings") ----

// write_encoded_value JSON-quotes one interpreter Value rendered in the artifact
// literal encoding.
write_encoded_value :: proc(b: ^strings.Builder, value: Value, allocator := context.allocator) {
	encoded := strings.builder_make(allocator)
	render_value_text(&encoded, value)
	write_json_string(b, strings.to_string(encoded))
}

// write_encoded_field_value JSON-quotes one blackboard column rendered in the
// artifact literal encoding.
write_encoded_field_value :: proc(
	b: ^strings.Builder,
	value: Field_Value,
	allocator := context.allocator,
) {
	encoded := strings.builder_make(allocator)
	render_field_value_text(&encoded, value)
	write_json_string(b, strings.to_string(encoded))
}

// write_encoded_blackboard JSON-quotes one row's whole blackboard as a
// `Thing(field=enc,…)` record literal in sorted field-name order — the
// serialization-closure dump (§28 §1: dump any blackboard at any tick).
write_encoded_blackboard :: proc(
	b: ^strings.Builder,
	thing: string,
	fields: map[string]Field_Value,
	allocator := context.allocator,
) {
	encoded := strings.builder_make(allocator)
	strings.write_string(&encoded, thing)
	strings.write_byte(&encoded, '(')
	names := sorted_blackboard_names(fields, allocator)
	for name, i in names {
		if i > 0 {
			strings.write_byte(&encoded, ',')
		}
		strings.write_string(&encoded, name)
		strings.write_byte(&encoded, '=')
		render_field_value_text(&encoded, fields[name])
	}
	strings.write_byte(&encoded, ')')
	write_json_string(b, strings.to_string(encoded))
}

// sorted_blackboard_names returns a blackboard's field names in sorted order —
// the deterministic render order (map iteration order is not).
@(private = "file")
sorted_blackboard_names :: proc(
	fields: map[string]Field_Value,
	allocator := context.allocator,
) -> []string {
	names := make([dynamic]string, 0, len(fields), allocator)
	for name in fields {
		append(&names, name)
	}
	slice.sort(names[:])
	return names[:]
}

// render_field_value_text renders one blackboard column in the artifact literal
// encoding — the inverse of decode_default_value, so an observe output pastes
// back as a control `set`/`spawn` payload. Fixed renders as its raw Q32.32 bits
// in decimal (§16 §2.3 — the only float-free encoding), Vec2/Vec3 as their
// component constructors, a record as `Type(f=enc,…)` sorted, a list as
// `[enc,…]`, a unit-variant token verbatim, a String as `Lk:bytes`.
render_field_value_text :: proc(b: ^strings.Builder, value: Field_Value) {
	switch v in value {
	case i64:
		fmt.sbprintf(b, "%d", v)
	case Fixed:
		fmt.sbprintf(b, "%d", i64(v))
	case bool:
		strings.write_string(b, v ? "true" : "false")
	case string:
		strings.write_string(b, v)
	case Vec2:
		fmt.sbprintf(b, "Vec2(x=%d,y=%d)", i64(v.x), i64(v.y))
	case Vec3:
		fmt.sbprintf(b, "Vec3(x=%d,y=%d,z=%d)", i64(v.x), i64(v.y), i64(v.z))
	case Ref:
		fmt.sbprintf(b, "Ref(thing=%s,id=%d)", v.thing, v.id.raw)
	case Record_Value:
		render_record_text(b, v)
	case List_Value:
		render_list_text(b, v)
	case Variant_Value:
		render_variant_text(b, v)
	case String_Value:
		fmt.sbprintf(b, "L%d:%s", len(v.text), v.text)
	}
}

// render_value_text renders one interpreter Value in the artifact literal
// encoding. The transient arms a blackboard never carries (lambda, tuple, Rng,
// the anim values) render as readable opaque forms — they appear only in trace
// results, never in a control payload.
render_value_text :: proc(b: ^strings.Builder, value: Value) {
	switch v in value {
	case i64:
		fmt.sbprintf(b, "%d", v)
	case Fixed:
		fmt.sbprintf(b, "%d", i64(v))
	case bool:
		strings.write_string(b, v ? "true" : "false")
	case Vec2:
		fmt.sbprintf(b, "Vec2(x=%d,y=%d)", i64(v.x), i64(v.y))
	case Vec3:
		fmt.sbprintf(b, "Vec3(x=%d,y=%d,z=%d)", i64(v.x), i64(v.y), i64(v.z))
	case Ref:
		fmt.sbprintf(b, "Ref(thing=%s,id=%d)", v.thing, v.id.raw)
	case Record_Value:
		render_record_text(b, v)
	case List_Value:
		render_list_text(b, v)
	case Variant_Value:
		render_variant_text(b, v)
	case Lambda_Value:
		fmt.sbprintf(b, "<lambda/%d>", len(v.params))
	case String_Value:
		fmt.sbprintf(b, "L%d:%s", len(v.text), v.text)
	case Tuple_Value:
		strings.write_byte(b, '(')
		for element, i in v.elements {
			if i > 0 {
				strings.write_byte(b, ',')
			}
			render_value_text(b, element)
		}
		strings.write_byte(b, ')')
	case Rng:
		fmt.sbprintf(b, "Rng(state=%d)", v.state)
	case Transform_Value:
		render_transform_text(b, v)
	case Pose_Value:
		render_pose_text(b, v)
	case Handle_Value:
		render_handle_text(b, v)
	case:
		// A nil Value (an unbound read) renders as the explicit absence token.
		strings.write_string(b, "<none>")
	}
}

// render_record_text renders a record literal `Type(f=enc,…)` in sorted
// field-name order; an anonymous record (a boxed variant payload) renders with
// an empty constructor name.
@(private = "file")
render_record_text :: proc(b: ^strings.Builder, record: Record_Value) {
	strings.write_string(b, record.type_name)
	strings.write_byte(b, '(')
	names := make([dynamic]string, 0, len(record.fields), context.temp_allocator)
	for name in record.fields {
		append(&names, name)
	}
	slice.sort(names[:])
	for name, i in names {
		if i > 0 {
			strings.write_byte(b, ',')
		}
		strings.write_string(b, name)
		strings.write_byte(b, '=')
		render_value_text(b, record.fields[name])
	}
	strings.write_byte(b, ')')
}

// render_list_text renders a `[enc,…]` list literal in element order.
@(private = "file")
render_list_text :: proc(b: ^strings.Builder, list: List_Value) {
	strings.write_byte(b, '[')
	for element, i in list.elements {
		if i > 0 {
			strings.write_byte(b, ',')
		}
		render_value_text(b, element)
	}
	strings.write_byte(b, ']')
}

// render_variant_text renders an enum value: the bare `Enum::Case` token for a
// unit variant, `Enum::Case(payload)` for a payload-carrying one (a boxed record
// payload renders its parenthesized fields, matching the §16 struct-variant form).
@(private = "file")
render_variant_text :: proc(b: ^strings.Builder, variant: Variant_Value) {
	strings.write_string(b, variant.enum_type)
	strings.write_string(b, "::")
	strings.write_string(b, variant.case_name)
	if variant.payload == nil {
		return
	}
	if record, is_record := variant.payload^.(Record_Value); is_record && record.type_name == "" {
		render_record_text(b, record)
		return
	}
	strings.write_byte(b, '(')
	render_value_text(b, variant.payload^)
	strings.write_byte(b, ')')
}

// render_transform_text renders a §16 §7 bone transform with raw-bit lanes.
@(private = "file")
render_transform_text :: proc(b: ^strings.Builder, t: Transform_Value) {
	fmt.sbprintf(
		b,
		"Transform(pos=Vec3(x=%d,y=%d,z=%d),rot=Quat(x=%d,y=%d,z=%d,w=%d),scale=Vec3(x=%d,y=%d,z=%d))",
		i64(t.pos.x),
		i64(t.pos.y),
		i64(t.pos.z),
		i64(t.rot.x),
		i64(t.rot.y),
		i64(t.rot.z),
		i64(t.rot.w),
		i64(t.scale.x),
		i64(t.scale.y),
		i64(t.scale.z),
	)
}

// render_pose_text renders the sparse Bone→Transform pose in its deterministic
// driven-bone order.
@(private = "file")
render_pose_text :: proc(b: ^strings.Builder, pose: Pose_Value) {
	strings.write_string(b, "Pose(")
	for bone, i in pose.bones {
		if i > 0 {
			strings.write_byte(b, ',')
		}
		strings.write_string(b, bone.bone)
		strings.write_byte(b, '=')
		render_transform_text(b, bone.transform)
	}
	strings.write_byte(b, ')')
}

// render_handle_text renders an opaque anim handle as its builder log —
// `Skeleton.humanoid.bind(…)…` — the §03 identity the handle compares by.
@(private = "file")
render_handle_text :: proc(b: ^strings.Builder, handle: Handle_Value) {
	strings.write_string(b, handle.kind)
	strings.write_byte(b, '.')
	strings.write_string(b, handle.factory)
	for op in handle.ops {
		strings.write_byte(b, '.')
		strings.write_string(b, op.method)
		strings.write_byte(b, '(')
		for arg, i in op.args {
			if i > 0 {
				strings.write_byte(b, ',')
			}
			strings.write_string(b, arg)
		}
		strings.write_byte(b, ')')
	}
}

// render_draw_cmd_text renders one §20 draw command in the same constructor
// style the value encoding uses — the draw-list dump's line items.
render_draw_cmd_text :: proc(b: ^strings.Builder, cmd: Draw_Cmd) {
	switch c in cmd {
	case Draw_Rect:
		fmt.sbprintf(
			b,
			"Rect(at=Vec2(x=%d,y=%d),size=Vec2(x=%d,y=%d),color=Color::%v)",
			i64(c.at.x),
			i64(c.at.y),
			i64(c.size.x),
			i64(c.size.y),
			c.color,
		)
	case Draw_Text:
		fmt.sbprintf(b, "Text(at=Vec2(x=%d,y=%d),text=L%d:%s,color=Color::%v)", i64(c.at.x), i64(c.at.y), len(c.text), c.text, c.color)
	case Draw_Camera:
		fmt.sbprintf(b, "Camera(at=Vec2(x=%d,y=%d),zoom=%d,rotation=%d)", i64(c.at.x), i64(c.at.y), i64(c.zoom), i64(c.rotation))
	case Draw3_Camera:
		fmt.sbprintf(
			b,
			"Camera3(eye=Vec3(x=%d,y=%d,z=%d),at=Vec3(x=%d,y=%d,z=%d),fov=%d)",
			i64(c.eye.x),
			i64(c.eye.y),
			i64(c.eye.z),
			i64(c.at.x),
			i64(c.at.y),
			i64(c.at.z),
			i64(c.fov),
		)
	case Draw3_Light:
		fmt.sbprintf(b, "Light(dir=Vec3(x=%d,y=%d,z=%d),color=Color::%v)", i64(c.dir.x), i64(c.dir.y), i64(c.dir.z), c.color)
	case Draw3_Plane:
		fmt.sbprintf(
			b,
			"Plane(at=Vec3(x=%d,y=%d,z=%d),size=Vec2(x=%d,y=%d),color=Color::%v)",
			i64(c.at.x),
			i64(c.at.y),
			i64(c.at.z),
			i64(c.size.x),
			i64(c.size.y),
			c.color,
		)
	case Draw3_Rigged:
		strings.write_string(b, "Rigged(skeleton=")
		render_handle_text(b, c.skeleton)
		strings.write_string(b, ",parts=")
		render_handle_text(b, c.parts)
		strings.write_string(b, ",pose=")
		render_pose_text(b, c.pose)
		fmt.sbprintf(b, ",at=Vec3(x=%d,y=%d,z=%d))", i64(c.at.x), i64(c.at.y), i64(c.at.z))
	}
}
