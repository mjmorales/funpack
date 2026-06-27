package funpack_runtime

import "core:fmt"
import "core:strings"

Probe_Honor :: struct {
	program:     ^Program,
	breaks:      [dynamic]Break_Hit,
	watches:     [dynamic]Watch_Fire,
	logs:        [dynamic]Log_Emit,
	traces:      [dynamic]Trace_Record,
	watch_state: map[Watch_Key]Value,
	live:        []Live_Probe,
	allocator:   Runtime_Allocator,
}

Watch_Key :: struct {
	probe:    int,
	instance: Id,
}

Break_Hit :: struct {
	behavior: string,
	target:   string,
	instance: Id,
	tick:     int,
	self_enc: string,
}

Watch_Fire :: struct {
	target:   string,
	instance: Id,
	tick:     int,
	old_enc:  string,
	new_enc:  string,
}

Log_Emit :: struct {
	behavior: string,
	target:   string,
	instance: Id,
	tick:     int,
	value_enc: string,
}

Trace_Record :: struct {
	behavior:    string,
	target:      string,
	instance:    Id,
	tick:        int,
	self_before: string,
	result_enc:  string,
	ok:          bool,
}

new_probe_honor :: proc(program: ^Program, allocator := context.allocator) -> Probe_Honor {
	return Probe_Honor {
		program     = program,
		breaks      = make([dynamic]Break_Hit, allocator),
		watches     = make([dynamic]Watch_Fire, allocator),
		logs        = make([dynamic]Log_Emit, allocator),
		traces      = make([dynamic]Trace_Record, allocator),
		watch_state = make(map[Watch_Key]Value, allocator),
		live        = nil,
		allocator   = allocator,
	}
}

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
		if !probe_honored_at(honor.program, probe, behavior) {
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
	for live, live_idx in honor.live {
		if live.on_signal != "" {
			continue
		}
		if !probe_honored_at(honor.program, live.probe, behavior) {
			continue
		}
		#partial switch live.probe.kind {
		case .Break:
			honor_break(honor, interp, live.probe, behavior, self_row, env, tick)
		case .Watch:
			honor_watch(honor, interp, live.probe, live_watch_key(honor, live_idx), behavior, self_row, env, tick)
		}
	}
}

live_watch_key :: proc(honor: ^Probe_Honor, live_idx: int) -> int {
	return len(honor.program.probes) + live_idx
}

probe_honored_at :: proc(program: ^Program, probe: Probe_Decl, behavior: ^Behavior_Decl) -> bool {
	if probe.target == behavior.name {
		return true
	}
	if probe.kind == .Trace && qualified_target_is_stage(program, probe.target, behavior.stage) {
		return true
	}
	return false
}

@(private = "file")
qualified_target_is_stage :: proc(program: ^Program, target: string, stage: string) -> bool {
	owner, member, qualified := split_qualified_target(target)
	if !qualified {
		return false
	}
	return owner == program.entrypoint.pipeline && member == stage
}

split_qualified_target :: proc(target: string) -> (owner: string, member: string, qualified: bool) {
	dot := strings.index_byte(target, '.')
	if dot < 0 {
		return "", "", false
	}
	return target[:dot], target[dot + 1:], true
}

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
		return
	}
	if values_equal(prior, value) {
		return
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

@(private = "file")
eval_probe_body :: proc(interp: ^Interp, probe: Probe_Decl, env: ^Env) -> (value: Value, ok: bool) {
	if len(probe.body) != 1 {
		return nil, false
	}
	return eval(interp, &probe.body[0], env)
}

@(private)
encode_value_text :: proc(value: Value, allocator := context.allocator) -> string {
	b := strings.builder_make(allocator)
	render_value_text(&b, value)
	return strings.to_string(b)
}

@(private)
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

session_honor_probes :: proc(
	s: ^Debug_Session,
	allocator := context.allocator,
) -> (
	honor: Probe_Honor,
	final: World_Version,
) {
	honor = new_probe_honor(s.program, allocator)
	honor.live = s.live_probes[:]
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
