package funpack_runtime

import "core:encoding/json"
import "core:fmt"
import "core:strings"

INTROSPECT_PROTOCOL_VERSION :: 1

Debug_Session :: struct {
	program:   ^Program,
	seed:      Run_Seed,
	snapshots: []Input,
	startup:   World_Version,
	versions:  []World_Version,
	rngs:      []Rng,
	allocator: Runtime_Allocator,
	has_branch: bool,
	branch:     Session_Branch,
	active_branch: bool,
	cursor:     Time_Cursor,
	live_probes:  [dynamic]Live_Probe,
	next_handle:  int,
}

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
		startup, advanced := run_startup_rooted(program, base, run_seed.seed, allocator)
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

Read_Lineage :: enum {
	Canonical,
	Branch,
}

session_read_lineage :: proc(
	s: ^Debug_Session,
	args: json.Object,
) -> (
	lineage: Read_Lineage,
	ok: bool,
) {
	if name, has := json_string_field(args, "branch"); has {
		switch name {
		case "canonical":
			return .Canonical, true
		case "branch":
			if !s.has_branch {
				return .Canonical, false
			}
			return .Branch, true
		}
		return .Canonical, false
	}
	if s.active_branch && s.has_branch {
		return .Branch, true
	}
	return .Canonical, true
}

observe_refold_on_canonical :: proc(s: ^Debug_Session, args: json.Object) -> bool {
	lineage, ok := session_read_lineage(s, args)
	return ok && lineage == .Canonical
}

session_version_at :: proc(s: ^Debug_Session, tick: int) -> (version: World_Version, ok: bool) {
	default := s.active_branch && s.has_branch ? Read_Lineage.Branch : Read_Lineage.Canonical
	return session_version_on(s, default, tick)
}

session_version_on :: proc(
	s: ^Debug_Session,
	lineage: Read_Lineage,
	tick: int,
) -> (
	version: World_Version,
	ok: bool,
) {
	if lineage == .Branch && s.has_branch {
		if tick <= s.branch.base_tick {
			return session_version_on(s, .Canonical, tick)
		}
		if tick == branch_tip_tick(s) {
			return s.branch.head, true
		}
		return {}, false
	}
	if tick == -1 {
		return s.startup, true
	}
	if tick < 0 || tick >= len(s.versions) {
		return {}, false
	}
	return s.versions[tick], true
}

branch_tip_tick :: proc(s: ^Debug_Session) -> int {
	return s.branch.base_tick + s.branch.ticks
}

session_lineage_input :: proc(s: ^Debug_Session, lineage: Read_Lineage, tick: int) -> Input {
	if lineage == .Branch && tick > s.branch.base_tick {
		return empty()
	}
	return s.snapshots[tick]
}

resolve_observe_version :: proc(
	s: ^Debug_Session,
	id: i64,
	cmd: string,
	args: json.Object,
	tick: int,
	allocator := context.allocator,
) -> (
	version: World_Version,
	lineage: Read_Lineage,
	refusal: string,
	ok: bool,
) {
	lin, lineage_ok := session_read_lineage(s, args)
	if !lineage_ok {
		return {}, lin, err_unknown_branch(id, cmd, allocator), false
	}
	ver, ver_ok := session_version_on(s, lin, tick)
	if !ver_ok {
		return {}, lin, err_tick_out_of_range(id, cmd, allocator), false
	}
	return ver, lin, "", true
}

refold_tick_obs :: proc(
	s: ^Debug_Session,
	id: i64,
	cmd: string,
	tick: int,
	allocator := context.allocator,
) -> (
	obs: Tick_Observe,
	committed: World_Version,
	refusal: string,
	ok: bool,
) {
	obs = new_tick_observe(allocator)
	refolded, refold_ok := session_refold_tick(s, tick, &obs, allocator)
	if !refold_ok {
		return obs, {}, err_tick_out_of_range(id, cmd, allocator), false
	}
	return obs, refolded, "", true
}

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

Tick_Observe :: struct {
	steps:     [dynamic]Step_Capture,
	signals:   [dynamic]Signal_Capture,
	allocator: Runtime_Allocator,
}

new_tick_observe :: proc(allocator := context.allocator) -> Tick_Observe {
	return Tick_Observe {
		steps     = make([dynamic]Step_Capture, allocator),
		signals   = make([dynamic]Signal_Capture, allocator),
		allocator = allocator,
	}
}

Step_Capture :: struct {
	ordinal:     int,
	behavior:    string,
	instance:    Id,
	self_before: map[string]Field_Value,
	env:         map[string]Value,
	result:      Value,
	ok:          bool,
}

Signal_Capture :: struct {
	signal:       string,
	per_instance: bool,
	target:       Id,
	values:       []Value,
}

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

observe_broadcast_signals :: proc(obs: ^Tick_Observe, signal_type: string, values: []Value) {
	copied := make([]Value, len(values), obs.allocator)
	copy(copied, values)
	append(&obs.signals, Signal_Capture{signal = signal_type, values = copied})
}

observe_instance_signal :: proc(obs: ^Tick_Observe, signal_type: string, target: Id, signal: Value) {
	values := make([]Value, 1, obs.allocator)
	values[0] = signal
	append(
		&obs.signals,
		Signal_Capture{signal = signal_type, per_instance = true, target = target, values = values},
	)
}

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
		return step_tick(s.program, prior, s.snapshots[tick], time, allocator, &rng, observe = observe), true
	}
	return step_tick(s.program, prior, s.snapshots[tick], time, allocator, nil, observe = observe), true
}

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
	case "state":
		return observe_state(s, id, args, allocator)
	case "screenshot":
		return observe_screenshot(s, id, args, allocator)
	case "load", "run", "pause", "step", "rewind", "reset", "status":
		return time_request(s, id, cmd, args, allocator)
	case "break", "watch", "clear":
		return break_request(s, id, cmd, args, allocator)
	case "capture_test":
		return capture_test_request(s, id, args, allocator)
	case "capture_tick":
		return capture_tick_request(s, id, args, allocator)
	case "audit":
		return audit_request(s, id, args, allocator)
	case "branch", "checkout", "inject_input", "set", "spawn", "despawn", "emit", "reload":
		return control_request(s, id, cmd, args, allocator)
	}
	return error_response(id, cmd, "unknown command", allocator)
}

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
	if !observe_refold_on_canonical(s, args) {
		return err_refold_canonical_only(id, "signals", allocator)
	}
	obs, _, refusal, ok := refold_tick_obs(s, id, "signals", int(tick), allocator)
	if !ok {
		return refusal
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
		if step := program_pipeline_step(s.program, behavior_name); step != nil {
			return trace_unsupported_stage(id, behavior_name, step.stage, int(tick), allocator)
		}
		return error_response(id, "trace", "unknown behavior", allocator)
	}
	obs := new_tick_observe(allocator)
	committed: World_Version
	switch behavior.stage {
	case "render":
		version, lineage, refusal, ok := resolve_observe_version(s, id, "trace", args, int(tick))
		if !ok {
			return refusal
		}
		if int(tick) < 0 {
			return err_tick_out_of_range(id, "trace", allocator)
		}
		input := session_lineage_input(s, lineage, int(tick))
		time := time_resource_at(s.program.entrypoint.tick_hz, int(tick), allocator)
		render_version(s.program, version, input, time, allocator, &obs)
		committed = version
	case "audio", "startup":
		return trace_unsupported_stage(id, behavior_name, behavior.stage, int(tick), allocator)
	case:
		if !observe_refold_on_canonical(s, args) {
			return err_refold_canonical_only(id, "trace", allocator)
		}
		refolded_obs, refolded, refusal, refold_ok := refold_tick_obs(s, id, "trace", int(tick), allocator)
		if !refold_ok {
			return refusal
		}
		obs = refolded_obs
		committed = refolded
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

@(private = "file")
trace_unsupported_stage :: proc(
	id: i64,
	behavior_name: string,
	stage: string,
	tick: int,
	allocator := context.allocator,
) -> string {
	b := strings.builder_make(allocator)
	ok_response_open(&b, id, "trace")
	fmt.sbprintf(&b, "{{\"tick\":%d,\"behavior\":", tick)
	write_json_string(&b, behavior_name)
	strings.write_string(&b, ",\"stage\":")
	write_json_string(&b, stage)
	strings.write_string(&b, ",\"steps\":[],\"note\":")
	note: string
	switch stage {
	case "audio":
		note = "the audio stage is a deferred slot, not folded into the interior tick; observe its routed output via inspect_signals"
	case "startup":
		note = "the startup stage runs once before tick 0, not per-tick; it is not part of a per-tick re-fold"
	case:
		note = "this stage is run by an engine battery with no per-instance user behavior body; it is not part of a per-tick re-fold"
	}
	write_json_string(&b, note)
	strings.write_string(&b, "}}")
	return strings.to_string(b)
}

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
	from_version, _, from_refusal, from_ok := resolve_observe_version(s, id, "diff", args, int(from_tick))
	if !from_ok {
		return from_refusal
	}
	to_version, _, to_refusal, to_ok := resolve_observe_version(s, id, "diff", args, int(to_tick))
	if !to_ok {
		return to_refusal
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

session_head_tick :: proc(s: ^Debug_Session, lineage: Read_Lineage) -> int {
	if lineage == .Branch && s.has_branch {
		return branch_tip_tick(s)
	}
	return len(s.versions) - 1
}

@(private = "file")
observe_state :: proc(
	s: ^Debug_Session,
	id: i64,
	args: json.Object,
	allocator := context.allocator,
) -> string {
	thing, has_thing := json_string_field(args, "thing")
	if !has_thing {
		return error_response(id, "state", "missing args.thing", allocator)
	}
	lineage, lineage_ok := session_read_lineage(s, args)
	if !lineage_ok {
		return err_unknown_branch(id, "state", allocator)
	}
	tick, has_tick := json_int_field(args, "tick")
	target_tick := has_tick ? int(tick) : session_head_tick(s, lineage)
	version, ver_ok := session_version_on(s, lineage, target_tick)
	if !ver_ok {
		return err_tick_out_of_range(id, "state", allocator)
	}
	mutable := version
	table := version_find_table(&mutable, thing)
	if table == nil {
		return error_response(id, "state", "unknown thing", allocator)
	}
	instance, has_instance := json_int_field(args, "instance")
	b := strings.builder_make(allocator)
	ok_response_open(&b, id, "state")
	fmt.sbprintf(&b, "{{\"tick\":%d,\"thing\":", target_tick)
	write_json_string(&b, thing)
	strings.write_string(&b, ",\"instances\":[")
	wrote := 0
	for row in table.rows {
		if has_instance && row.id.raw != Thing_Id(instance) {
			continue
		}
		if wrote > 0 {
			strings.write_byte(&b, ',')
		}
		wrote += 1
		fmt.sbprintf(&b, "{{\"id\":%d,\"fields\":", row.id.raw)
		write_state_fields(&b, row.fields, allocator)
		strings.write_byte(&b, '}')
	}
	strings.write_string(&b, "]}}")
	return strings.to_string(b)
}

@(private = "file")
write_state_fields :: proc(
	b: ^strings.Builder,
	fields: map[string]Field_Value,
	allocator := context.allocator,
) {
	strings.write_byte(b, '{')
	names := sorted_blackboard_names(fields, allocator)
	for name, i in names {
		if i > 0 {
			strings.write_byte(b, ',')
		}
		write_json_string(b, name)
		strings.write_byte(b, ':')
		write_encoded_field_value(b, fields[name], allocator)
	}
	strings.write_byte(b, '}')
}

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
	if !observe_refold_on_canonical(s, args) {
		return err_refold_canonical_only(id, "replay_behavior", allocator)
	}
	behavior := program_behavior(s.program, behavior_name)
	if behavior == nil {
		return error_response(id, "replay_behavior", "unknown behavior", allocator)
	}
	obs, _, refusal, ok := refold_tick_obs(s, id, "replay_behavior", int(tick), allocator)
	if !ok {
		return refusal
	}

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
	version, lineage, refusal, ok := resolve_observe_version(s, id, "draw_list", args, int(tick))
	if !ok {
		return refusal
	}
	if int(tick) < 0 {
		return err_tick_out_of_range(id, "draw_list", allocator)
	}
	input := session_lineage_input(s, lineage, int(tick))
	time := time_resource_at(s.program.entrypoint.tick_hz, int(tick), allocator)
	overlay, _ := json_bool_field(args, "overlay")
	draw := render_version(s.program, version, input, time, allocator, nil, overlay)
	b := strings.builder_make(allocator)
	ok_response_open(&b, id, "draw_list")
	fmt.sbprintf(&b, "{{\"tick\":%d,\"commands\":[", tick)
	write_draw_commands_json(&b, draw.cmds, allocator)
	strings.write_string(&b, "]}}")
	return strings.to_string(b)
}

@(private = "file")
observe_screenshot :: proc(
	s: ^Debug_Session,
	id: i64,
	args: json.Object,
	allocator := context.allocator,
) -> string {
	tick, has_tick := json_int_field(args, "tick")
	if !has_tick {
		return error_response(id, "screenshot", "missing args.tick", allocator)
	}
	version, lineage, refusal, ok := resolve_observe_version(s, id, "screenshot", args, int(tick))
	if !ok {
		return refusal
	}
	if int(tick) < 0 {
		return err_tick_out_of_range(id, "screenshot", allocator)
	}
	input := session_lineage_input(s, lineage, int(tick))
	time := time_resource_at(s.program.entrypoint.tick_hz, int(tick), allocator)
	overlay, _ := json_bool_field(args, "overlay")
	draw := render_version(s.program, version, input, time, allocator, nil, overlay)

	encoded, width, height, captured := session_capture_frame(s.program, draw, allocator)
	if !captured {
		return error_response(
			id,
			"screenshot",
			"screenshot crosses the render/present boundary — requires a FUNPACK_LIVE build with a display (use draw_list for the sim-pure, headless draw-list dump)",
			allocator,
		)
	}

	b := strings.builder_make(allocator)
	ok_response_open(&b, id, "screenshot")
	fmt.sbprintf(&b, "{{\"tick\":%d,\"width\":%d,\"height\":%d,\"format\":\"qoi\",\"pixels\":", tick, width, height)
	write_json_string(&b, encoded)
	if include, _ := json_bool_field(args, "include_drawlist"); include {
		strings.write_string(&b, ",\"commands\":[")
		write_draw_commands_json(&b, draw.cmds, allocator)
		strings.write_byte(&b, ']')
	}
	strings.write_string(&b, "}}")
	return strings.to_string(b)
}

write_draw_commands_json :: proc(b: ^strings.Builder, cmds: []Draw_Cmd, allocator := context.allocator) {
	for cmd, i in cmds {
		if i > 0 {
			strings.write_byte(b, ',')
		}
		encoded := strings.builder_make(allocator)
		render_draw_cmd_text(&encoded, cmd)
		write_json_string(b, strings.to_string(encoded))
	}
}

ok_response_open :: proc(b: ^strings.Builder, id: i64, cmd: string) {
	fmt.sbprintf(b, "{{\"v\":%d,\"id\":%d,\"ok\":true,\"cmd\":", INTROSPECT_PROTOCOL_VERSION, id)
	write_json_string(b, cmd)
	strings.write_string(b, ",\"result\":")
}

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

err_tick_out_of_range :: proc(id: i64, cmd: string, allocator := context.allocator) -> string {
	return error_response(id, cmd, "tick out of range", allocator)
}

err_unknown_branch :: proc(id: i64, cmd: string, allocator := context.allocator) -> string {
	return error_response(id, cmd, "unknown branch — checkout an existing lineage", allocator)
}

err_refold_canonical_only :: proc(id: i64, cmd: string, allocator := context.allocator) -> string {
	message := fmt.aprintf(
		"branch refold unsupported — %s re-folds a recorded tick (canonical only)",
		cmd,
		allocator = allocator,
	)
	return error_response(id, cmd, message, allocator)
}

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

json_int_field :: proc(object: json.Object, key: string) -> (value: i64, ok: bool) {
	field, has := object[key]
	if !has {
		return 0, false
	}
	#partial switch v in field {
	case json.Integer:
		return i64(v), true
	case json.Float:
		if v == f64(i64(v)) {
			return i64(v), true
		}
	}
	return 0, false
}

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

json_bool_field :: proc(object: json.Object, key: string) -> (value: bool, ok: bool) {
	field, has := object[key]
	if !has {
		return false, false
	}
	flag, is_bool := field.(json.Boolean)
	if !is_bool {
		return false, false
	}
	return flag, true
}

json_array_field :: proc(object: json.Object, key: string) -> (values: json.Array, ok: bool) {
	field, has := object[key]
	if !has {
		return nil, false
	}
	entries, is_array := field.(json.Array)
	if !is_array {
		return nil, false
	}
	return entries, true
}
