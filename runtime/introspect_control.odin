package funpack_runtime

import "core:encoding/json"
import "core:fmt"
import "core:strings"

Session_Branch :: struct {
	base_tick:       int,
	program_storage: Program,
	program:         ^Program,
	head:            World_Version,
	ticks:           int,
	rng:             Rng,
	has_rng:         bool,
}

control_request :: proc(
	s: ^Debug_Session,
	id: i64,
	cmd: string,
	args: json.Object,
	allocator := context.allocator,
) -> string {
	switch cmd {
	case "branch":
		return control_branch(s, id, args, allocator)
	case "checkout":
		return control_checkout(s, id, args, allocator)
	case "inject_input":
		return control_inject_input(s, id, args, allocator)
	case "set":
		return control_set(s, id, args, allocator)
	case "spawn":
		return control_spawn(s, id, args, allocator)
	case "despawn":
		return control_despawn(s, id, args, allocator)
	case "emit":
		return control_emit(s, id, args, allocator)
	case "reload":
		return control_reload(s, id, args, allocator)
	}
	return error_response(id, cmd, "unknown control command", allocator)
}

@(private = "file")
fork_branch :: proc(s: ^Debug_Session, tick: int) -> bool {
	head, ok := session_version_at(s, tick)
	if !ok {
		return false
	}
	branch := Session_Branch {
		base_tick = tick,
		program   = s.program,
		head      = head,
	}
	if s.seed.has_seed {
		branch.rng = s.rngs[tick + 1]
		branch.has_rng = true
	}
	s.branch = branch
	s.has_branch = true
	return true
}

@(private = "file")
ensure_branch :: proc(s: ^Debug_Session) {
	if s.has_branch {
		return
	}
	anchor := s.cursor.loaded ? s.cursor.tick : len(s.versions) - 1
	fork_branch(s, anchor)
}

@(private = "file")
branch_logical_tick :: proc(s: ^Debug_Session) -> int {
	return s.branch.base_tick + 1 + s.branch.ticks
}

@(private = "file")
control_ok_response :: proc(
	s: ^Debug_Session,
	id: i64,
	cmd: string,
	extras: string,
	allocator := context.allocator,
) -> string {
	b := strings.builder_make(allocator)
	ok_response_open(&b, id, cmd)
	fmt.sbprintf(
		&b,
		"{{\"branch\":{{\"base_tick\":%d,\"ticks\":%d}},\"warranted\":false%s}}}}",
		s.branch.base_tick,
		s.branch.ticks,
		extras,
	)
	return strings.to_string(b)
}

@(private = "file")
control_branch :: proc(
	s: ^Debug_Session,
	id: i64,
	args: json.Object,
	allocator := context.allocator,
) -> string {
	tick := i64(len(s.versions) - 1)
	if requested, has_tick := json_int_field(args, "tick"); has_tick {
		tick = requested
	}
	if !fork_branch(s, int(tick)) {
		return error_response(id, "branch", "tick out of range", allocator)
	}
	return control_ok_response(s, id, "branch", "", allocator)
}

@(private = "file")
control_checkout :: proc(
	s: ^Debug_Session,
	id: i64,
	args: json.Object,
	allocator := context.allocator,
) -> string {
	target := "branch"
	if requested, has_target := json_string_field(args, "target"); has_target {
		target = requested
	}
	switch target {
	case "canonical":
		s.active_branch = false
		return checkout_ok_response(s, id, allocator)
	case "branch":
		if !s.has_branch {
			return error_response(id, "checkout", "no branch to checkout — branch first", allocator)
		}
		s.active_branch = true
		return checkout_ok_response(s, id, allocator)
	}
	return error_response(id, "checkout", "unknown checkout target (branch|canonical)", allocator)
}

@(private = "file")
checkout_ok_response :: proc(
	s: ^Debug_Session,
	id: i64,
	allocator := context.allocator,
) -> string {
	b := strings.builder_make(allocator)
	ok_response_open(&b, id, "checkout")
	strings.write_string(&b, "{\"active\":")
	if s.active_branch {
		fmt.sbprintf(&b, "\"branch\",\"warranted\":false,\"branch\":{{\"base_tick\":%d,\"ticks\":%d}}}}}}", s.branch.base_tick, s.branch.ticks)
	} else {
		strings.write_string(&b, "\"canonical\",\"warranted\":true}}")
	}
	return strings.to_string(b)
}

@(private = "file")
control_inject_input :: proc(
	s: ^Debug_Session,
	id: i64,
	args: json.Object,
	allocator := context.allocator,
) -> string {
	ensure_branch(s)
	branch := &s.branch
	snapshot, build_err := build_input_snapshot(branch.program, args, allocator)
	if build_err != "" {
		return error_response(id, "inject_input", build_err, allocator)
	}
	ticks := i64(1)
	if requested, has_ticks := json_int_field(args, "ticks"); has_ticks {
		ticks = requested
	}
	if ticks < 1 {
		return error_response(id, "inject_input", "ticks must be >= 1", allocator)
	}
	tick_hz := branch.program.entrypoint.tick_hz
	for _ in 0 ..< ticks {
		time := time_resource_at(tick_hz, branch_logical_tick(s), allocator)
		if branch.has_rng {
			branch.head = step_tick(branch.program, branch.head, snapshot, time, allocator, &branch.rng)
		} else {
			branch.head = step_tick(branch.program, branch.head, snapshot, time, allocator)
		}
		branch.ticks += 1
	}
	return control_ok_response(s, id, "inject_input", "", allocator)
}

build_input_snapshot :: proc(
	program: ^Program,
	args: json.Object,
	allocator := context.allocator,
) -> (
	snapshot: Input,
	err: string,
) {
	registry := build_action_registry(program^, allocator)
	snapshot = empty()

	if entries, has := json_array_field(args, "pressed"); has {
		for entry in entries {
			player, action, _, _, entry_err := injected_entry(registry, entry)
			if entry_err != "" {
				return snapshot, entry_err
			}
			snapshot = with_pressed(snapshot, player, action)
		}
	}
	if entries, has := json_array_field(args, "held"); has {
		for entry in entries {
			player, action, _, _, entry_err := injected_entry(registry, entry)
			if entry_err != "" {
				return snapshot, entry_err
			}
			snapshot = with_held(snapshot, player, action)
		}
	}
	if entries, has := json_array_field(args, "values"); has {
		for entry in entries {
			player, action, value, _, entry_err := injected_entry(registry, entry, "value")
			if entry_err != "" {
				return snapshot, entry_err
			}
			snapshot = with_value(snapshot, player, action, value)
		}
	}
	if entries, has := json_array_field(args, "axes"); has {
		for entry in entries {
			player, action, x, y, entry_err := injected_entry(registry, entry, "x", "y")
			if entry_err != "" {
				return snapshot, entry_err
			}
			snapshot = with_axis(snapshot, player, action, Vec2{x = x, y = y})
		}
	}
	return snapshot, ""
}

@(private = "file")
injected_entry :: proc(
	registry: Action_Registry,
	entry: json.Value,
	analog_keys: ..string,
) -> (
	player: PlayerId,
	action: ActionId,
	first: Fixed,
	second: Fixed,
	err: string,
) {
	object, is_object := entry.(json.Object)
	if !is_object {
		return .P1, ActionId(0), 0, 0, "input record must be an object"
	}
	player_name, has_player := json_string_field(object, "player")
	if !has_player {
		return .P1, ActionId(0), 0, 0, "input record missing player"
	}
	resolved_player, player_ok := parse_player(player_name)
	if !player_ok {
		return .P1, ActionId(0), 0, 0, "unknown player (P1..P4)"
	}
	action_name, has_action := json_string_field(object, "action")
	if !has_action {
		return resolved_player, ActionId(0), 0, 0, "input record missing action"
	}
	def, has_def := registry_find_token(registry, action_name)
	if !has_def {
		return resolved_player, ActionId(0), 0, 0, "unknown action"
	}
	analog := [2]Fixed{0, 0}
	for key, i in analog_keys {
		encoded, has_value := json_string_field(object, key)
		if !has_value {
			return resolved_player, def.id, 0, 0, "input record missing analog field"
		}
		decoded, decode_ok := decode_fixed(encoded)
		if !decode_ok {
			return resolved_player, def.id, 0, 0, "analog value must be Fixed raw bits"
		}
		analog[i] = decoded
	}
	return resolved_player, def.id, analog[0], analog[1], ""
}

@(private = "file")
parse_player :: proc(name: string) -> (player: PlayerId, ok: bool) {
	switch name {
	case "P1":
		return .P1, true
	case "P2":
		return .P2, true
	case "P3":
		return .P3, true
	case "P4":
		return .P4, true
	}
	return .P1, false
}

@(private = "file")
control_value_matches_type :: proc(program: ^Program, type_name: string, value: Field_Value) -> bool {
	switch type_name {
	case "Int":
		_, ok := value.(i64)
		return ok
	case "Fixed":
		_, ok := value.(Fixed)
		return ok
	case "Bool":
		_, ok := value.(bool)
		return ok
	case "Vec2":
		_, ok := value.(Vec2)
		return ok
	case "Vec3":
		_, ok := value.(Vec3)
		return ok
	case "String":
		_, ok := value.(String_Value)
		return ok
	}
	if strings.has_prefix(type_name, "[") {
		_, ok := value.(List_Value)
		return ok
	}
	if program_data(program, type_name) != nil {
		record, ok := value.(Record_Value)
		return ok && record.type_name == type_name
	}
	return true
}

@(private = "file")
value_decode_error :: proc(field: string, field_type: string, allocator := context.allocator) -> string {
	return fmt.aprintf(
		"value does not decode for field %s (declared type %s) — expected a source literal like %s",
		field,
		field_type,
		field_type_sample_literal(field_type),
		allocator = allocator,
	)
}

@(private = "file")
field_type_sample_literal :: proc(field_type: string) -> string {
	switch field_type {
	case "Int":
		return "42"
	case "Fixed":
		return "110.0"
	case "Bool":
		return "true"
	case "Vec2":
		return "Vec2(x=2.0,y=104.0)"
	case "Vec3":
		return "Vec3(x=2.0,y=104.0,z=0.0)"
	}
	if strings.has_prefix(field_type, "[") {
		return "[] (an empty list, or comma-joined element literals)"
	}
	return "110.0"
}

@(private = "file")
control_set :: proc(
	s: ^Debug_Session,
	id: i64,
	args: json.Object,
	allocator := context.allocator,
) -> string {
	ensure_branch(s)
	branch := &s.branch
	thing, has_thing := json_string_field(args, "thing")
	field, has_field := json_string_field(args, "field")
	encoded, has_value := json_string_field(args, "value")
	if !has_thing || !has_field || !has_value {
		return error_response(id, "set", "missing args.thing, args.field, or args.value", allocator)
	}
	instance, _ := json_int_field(args, "instance")

	decl := program_thing(branch.program, thing)
	if decl == nil {
		return error_response(id, "set", "unknown thing", allocator)
	}
	field_type := thing_field_type(decl, field)
	if field_type == "" {
		return error_response(id, "set", "unknown field", allocator)
	}
	decoded, decode_ok := decode_default_value(branch.program, field_type, encoded, allocator, true)
	if !decode_ok || !control_value_matches_type(branch.program, field_type, decoded) {
		return error_response(id, "set", value_decode_error(field, field_type, allocator), allocator)
	}

	state := new_tick_state(branch.head, allocator, allocator)
	table := find_tick_table(state.tables, thing)
	if table == nil {
		return error_response(id, "set", "unknown thing", allocator)
	}
	row_idx, found := find_row_by_id(table.rows[:], Id{raw = Thing_Id(instance)})
	if !found {
		return error_response(id, "set", "no instance with that id", allocator)
	}
	next := make(map[string]Field_Value, allocator)
	for name, value in table.rows[row_idx].fields {
		next[name] = value
	}
	next[field] = decoded
	table.rows[row_idx].fields = next
	branch.head = commit_tick_state(branch.head, &state, allocator)
	branch.ticks += 1
	return control_ok_response(s, id, "set", "", allocator)
}

@(private = "file")
control_spawn :: proc(
	s: ^Debug_Session,
	id: i64,
	args: json.Object,
	allocator := context.allocator,
) -> string {
	ensure_branch(s)
	branch := &s.branch
	thing, has_thing := json_string_field(args, "thing")
	if !has_thing {
		return error_response(id, "spawn", "missing args.thing", allocator)
	}
	decl := program_thing(branch.program, thing)
	if decl == nil {
		return error_response(id, "spawn", "unknown thing", allocator)
	}

	overrides: json.Object
	if nested, has_fields := args["fields"]; has_fields {
		if object, fields_ok := nested.(json.Object); fields_ok {
			overrides = object
		}
	}
	fields := make(map[string]Field_Value, allocator)
	for fd in decl.fields {
		if supplied, has_override := overrides[fd.name]; has_override {
			encoded, is_string := supplied.(json.String)
			if !is_string {
				return error_response(id, "spawn", "field overrides must be encoded strings", allocator)
			}
			decoded, decode_ok := decode_default_value(branch.program, fd.type, encoded, allocator, true)
			if !decode_ok || !control_value_matches_type(branch.program, fd.type, decoded) {
				return error_response(id, "spawn", value_decode_error(fd.name, fd.type, allocator), allocator)
			}
			fields[fd.name] = decoded
			continue
		}
		if decoded, decode_ok := decode_default(branch.program, fd, allocator); decode_ok {
			fields[fd.name] = decoded
		}
	}

	state := new_tick_state(branch.head, allocator, allocator)
	table := find_tick_table(state.tables, thing)
	if table == nil {
		return error_response(id, "spawn", "unknown thing", allocator)
	}
	minted := table.next_id
	queue_spawn(&state, thing, fields)
	apply_spawn_batch(&state)
	branch.head = commit_tick_state(branch.head, &state, allocator)
	branch.ticks += 1
	extras := fmt.aprintf(",\"instance\":%d", minted, allocator = allocator)
	return control_ok_response(s, id, "spawn", extras, allocator)
}

@(private = "file")
control_despawn :: proc(
	s: ^Debug_Session,
	id: i64,
	args: json.Object,
	allocator := context.allocator,
) -> string {
	ensure_branch(s)
	branch := &s.branch
	thing, has_thing := json_string_field(args, "thing")
	if !has_thing {
		return error_response(id, "despawn", "missing args.thing", allocator)
	}
	instance, has_instance := json_int_field(args, "instance")
	if !has_instance {
		return error_response(id, "despawn", "missing args.instance", allocator)
	}
	if program_thing(branch.program, thing) == nil {
		return error_response(id, "despawn", "unknown thing", allocator)
	}

	target := Id{raw = Thing_Id(instance)}
	state := new_tick_state(branch.head, allocator, allocator)
	table := find_tick_table(state.tables, thing)
	if table == nil {
		return error_response(id, "despawn", "unknown thing", allocator)
	}
	if _, found := find_row_by_id(table.rows[:], target); !found {
		return error_response(id, "despawn", "no instance with that id", allocator)
	}

	queue_despawn(&state, Ref{thing = thing, id = target})
	apply_spawn_batch(&state)
	branch.head = commit_tick_state(branch.head, &state, allocator)
	branch.ticks += 1
	extras := fmt.aprintf(",\"instance\":%d", instance, allocator = allocator)
	return control_ok_response(s, id, "despawn", extras, allocator)
}

@(private = "file")
control_emit :: proc(
	s: ^Debug_Session,
	id: i64,
	args: json.Object,
	allocator := context.allocator,
) -> string {
	ensure_branch(s)
	branch := &s.branch
	signal, has_signal := json_string_field(args, "signal")
	encoded, has_value := json_string_field(args, "value")
	if !has_signal || !has_value {
		return error_response(id, "emit", "missing args.signal or args.value", allocator)
	}
	decoded, decode_ok := decode_default_value(branch.program, signal, encoded, allocator, true)
	if !decode_ok {
		return error_response(id, "emit", value_decode_error(signal, signal, allocator), allocator)
	}
	record, is_record := decoded.(Record_Value)
	if !is_record || record.type_name != signal {
		return error_response(id, "emit", "signal value must be a record of the signal type", allocator)
	}

	prior := branch.head
	state := new_tick_state(prior, allocator, allocator)
	if branch.has_rng {
		state.rng = branch.rng
	}
	elements := make([]Value, 1, allocator)
	elements[0] = decoded_record_as_value(record)
	route_signals(&state, signal, List_Value{elements = elements})

	time := time_resource_at(branch.program.entrypoint.tick_hz, branch_logical_tick(s), allocator)
	interp := new_interp(branch.program, &prior, &state, empty(), time, allocator)
	run_pipeline_fold(&interp, &state, branch.program)
	apply_spawn_batch(&state)
	if branch.has_rng {
		branch.rng = state.rng
	}
	branch.head = commit_tick_state(branch.head, &state, allocator)
	branch.ticks += 1
	return control_ok_response(s, id, "emit", "", allocator)
}

@(private = "file")
decoded_record_as_value :: proc(record: Record_Value) -> Value {
	return field_value_to_value(record)
}

@(private = "file")
control_reload :: proc(
	s: ^Debug_Session,
	id: i64,
	args: json.Object,
	allocator := context.allocator,
) -> string {
	ensure_branch(s)
	branch := &s.branch
	artifact, has_artifact := json_string_field(args, "artifact")
	if !has_artifact {
		return error_response(id, "reload", "missing args.artifact", allocator)
	}
	new_program, migrated, result := hot_reload_swap(branch.program, branch.head, artifact, allocator)
	if !result.ok {
		b := strings.builder_make(allocator)
		if result.load_err != .None {
			fmt.sbprintf(&b, "reload refused: artifact load error %v", result.load_err)
		} else {
			fmt.sbprintf(&b, "reload refused: migration refusal %v", result.refusal.kind)
		}
		return error_response(id, "reload", strings.to_string(b), allocator)
	}
	branch.program_storage = new_program
	branch.program = &branch.program_storage
	branch.head = migrated
	branch.ticks += 1
	return control_ok_response(s, id, "reload", ",\"swapped\":true", allocator)
}
