package funpack_runtime

import "core:slice"
import "core:strings"

Tick_Table :: struct {
	thing:     string,
	singleton: bool,
	rows:      [dynamic]Row,
	next_id:   Thing_Id,
}

Signal_Mailbox :: struct {
	by_type:     map[string][]Value,
	by_instance: map[string]map[Id][]Value,
}

Tick_State :: struct {
	tables:          []Tick_Table,
	mailbox:         Signal_Mailbox,
	spawns:          [dynamic]Pending_Spawn,
	despawns:        [dynamic]Ref,
	persist_commands: [dynamic]Record_Value,
	terrain_commands: [dynamic]Terrain_Command,
	tile_refusals:    [dynamic]Tile_Command_Refusal,
	rng:             Rng,
	superseded:      [dynamic]map[string]Field_Value,
	allocator:       Runtime_Allocator,
	commit_allocator: Runtime_Allocator,
	observe:          ^Tick_Observe,
	honor:            ^Probe_Honor,
	honor_tick:       int,
}

Pending_Spawn :: struct {
	thing:  string,
	fields: map[string]Field_Value,
}

run_startup :: proc(
	program: ^Program,
	base: World_Version,
	allocator := context.allocator,
) -> World_Version {
	if len(program.setup) == 0 {
		if setup_fn := program_startup(program); setup_fn != nil && len(setup_fn.body) > 0 && is_command_list_type(setup_fn.return_type) {
			if populated, ran := run_startup_body(program, base, setup_fn, allocator); ran {
				return populated
			}
		}
	}

	tables := new_tick_tables(base, allocator)

	spawn_engine_singletons(program, tables, allocator)

	for command in program.setup {
		table := find_tick_table(tables, command.thing)
		if table == nil {
			continue
		}
		fields := build_spawn_blackboard(program, command, allocator)
		id := Id{raw = table.next_id}
		table.next_id += 1
		append(&table.rows, Row{id = id, fields = fields})
	}

	return commit_tick_tables(base, tables, allocator)
}

run_startup_body :: proc(
	program: ^Program,
	base: World_Version,
	setup_fn: ^Function_Decl,
	allocator := context.allocator,
) -> (
	populated: World_Version,
	ran: bool,
) {
	state := new_tick_state(base, allocator, allocator)
	base_version := base
	interp := new_interp(program, &base_version, &state, empty(), Record_Value{}, allocator)

	env := Env{names = make(map[string]Value, allocator)}
	result, result_ok := eval_behavior_body(&interp, setup_fn.body, &env)
	if !result_ok {
		return {}, false
	}
	if _, is_list := result.(List_Value); !is_list {
		return {}, false
	}
	dispatch_emit_component(&interp, &state, nil, Row{}, setup_fn.return_type, result)
	spawn_engine_singletons(program, state.tables, allocator)
	apply_spawn_batch(&state)
	return commit_tick_tables(base, state.tables, allocator), true
}

spawn_engine_singletons :: proc(
	program: ^Program,
	tables: []Tick_Table,
	allocator := context.allocator,
) {
	for thing in program.things {
		if !thing.singleton {
			continue
		}
		table := find_tick_table(tables, thing.name)
		if table == nil {
			continue
		}
		fields := build_singleton_blackboard(program, thing, allocator)
		id := Id{raw = table.next_id}
		table.next_id += 1
		append(&table.rows, Row{id = id, fields = fields})
	}
}

build_singleton_blackboard :: proc(
	program: ^Program,
	thing: Thing_Decl,
	allocator := context.allocator,
) -> map[string]Field_Value {
	fields := make(map[string]Field_Value, allocator)
	for fd in thing.fields {
		if !fd.has_default {
			continue
		}
		if v, ok := decode_default(program, fd, allocator); ok {
			fields[fd.name] = own_committed_column(v, allocator)
		}
	}
	return fields
}

own_committed_column :: proc(fv: Field_Value, allocator := context.allocator) -> Field_Value {
	if owned, ok := deep_clone_field_value(fv, allocator); ok {
		return owned
	}
	return fv
}

run_startup_seeded :: proc(
	program: ^Program,
	base: World_Version,
	seed: Rng,
	allocator := context.allocator,
) -> (
	populated: World_Version,
	advanced: Rng,
) {
	setup_fn := program_startup(program)
	if setup_fn == nil || len(setup_fn.body) == 0 {
		return run_startup(program, base, allocator), seed
	}

	state := new_tick_state(base, allocator, allocator)
	state.rng = seed
	base_version := base
	interp := new_interp(program, &base_version, &state, empty(), Record_Value{}, allocator)

	env := Env{names = make(map[string]Value, allocator)}
	for param in setup_fn.params {
		if param.type == "Rng" {
			env.names[param.name] = state.rng
		}
	}
	result, result_ok := eval_behavior_body(&interp, setup_fn.body, &env)
	if !result_ok {
		return run_startup(program, base, allocator), seed
	}
	tuple, is_tuple := result.(Tuple_Value)
	if !is_tuple {
		return run_startup(program, base, allocator), seed
	}
	fold_tuple_emit(&interp, &state, nil, Row{}, setup_fn.return_type, tuple)
	spawn_engine_singletons(program, state.tables, allocator)
	apply_spawn_batch(&state)
	return commit_tick_tables(base, state.tables, allocator), state.rng
}

program_startup :: proc(program: ^Program) -> ^Function_Decl {
	for &fn in program.functions {
		if fn.kind == .Startup {
			return &fn
		}
	}
	return nil
}

program_is_seeded :: proc(program: ^Program) -> bool {
	setup_fn := program_startup(program)
	if setup_fn == nil {
		return false
	}
	for param in setup_fn.params {
		if param.type == "Rng" {
			return true
		}
	}
	return false
}

program_uses_rng :: proc(program: ^Program) -> bool {
	for behavior in program.behaviors {
		for param in behavior.params {
			if param.type == "Rng" {
				return true
			}
		}
	}
	for fn in program.functions {
		for param in fn.params {
			if param.type == "Rng" {
				return true
			}
		}
	}
	return false
}

RUNTIME_DEFAULT_SEED :: i64(0x5EED)

resolve_root_seed :: proc(override: Maybe(i64), entrypoint: Entrypoint) -> i64 {
	if seed, ok := override.?; ok {
		return seed
	}
	if entrypoint.has_seed {
		return entrypoint.seed
	}
	return RUNTIME_DEFAULT_SEED
}

run_startup_rooted :: proc(
	program: ^Program,
	base: World_Version,
	seed: i64,
	allocator := context.allocator,
) -> (
	version: World_Version,
	rng: Rng,
) {
	if program_is_seeded(program) {
		return run_startup_seeded(program, base, rand_seed(seed), allocator)
	}
	return run_startup(program, base, allocator), rand_seed(seed)
}

build_spawn_blackboard :: proc(
	program: ^Program,
	command: Spawn_Command,
	allocator := context.allocator,
) -> map[string]Field_Value {
	fields := make(map[string]Field_Value, allocator)
	decl := program_thing(program, command.thing)

	for field in command.fields {
		fields[field.name] = own_committed_column(
			spawn_field_to_value(program, decl, field.name, field, allocator),
			allocator,
		)
	}
	if decl != nil {
		for fd in decl.fields {
			if _, present := fields[fd.name]; present {
				continue
			}
			if fd.has_default {
				if v, ok := decode_default(program, fd, allocator); ok {
					fields[fd.name] = own_committed_column(v, allocator)
				}
			}
		}
	}
	return fields
}

spawn_field_to_value :: proc(
	program: ^Program,
	decl: ^Thing_Decl,
	name: string,
	field: Spawn_Field,
	allocator := context.allocator,
) -> Field_Value {
	switch field.kind {
	case .Vec2:
		return Vec2{field.vec2_x, field.vec2_y}
	case .Variant:
		return field.variant
	case .Int:
		return field.int_val
	case .Fixed:
		if field_is_int(decl, name) {
			return field.int_val
		}
		return field.fixed
	case .Record, .List:
		if v, ok := decode_default_value(
			program,
			thing_field_type(decl, name),
			field.encoded,
			allocator,
		); ok {
			return v
		}
		return nil
	}
	return field.fixed
}

thing_field_type :: proc(decl: ^Thing_Decl, name: string) -> string {
	if decl == nil {
		return ""
	}
	for fd in decl.fields {
		if fd.name == name {
			return fd.type
		}
	}
	return ""
}

decode_default :: proc(
	program: ^Program,
	fd: Field_Decl,
	allocator := context.allocator,
) -> (
	value: Field_Value,
	ok: bool,
) {
	return decode_default_value(program, fd.type, fd.default_encoded, allocator)
}

decode_default_value :: proc(
	program: ^Program,
	type_name: string,
	encoded: string,
	allocator := context.allocator,
	human := false,
) -> (
	value: Field_Value,
	ok: bool,
) {
	switch type_name {
	case "Int":
		return decode_int(encoded)
	case "Fixed":
		return decode_fixed(encoded, human)
	case "Bool":
		return decode_bool(encoded)
	}
	if strings.has_prefix(type_name, "[") || strings.has_prefix(encoded, "[") {
		return decode_list_default(program, type_name, encoded, allocator, human)
	}
	if strings.contains(encoded, "(") {
		return decode_record_default(program, type_name, encoded, allocator, human)
	}
	if strings.contains(encoded, "::") {
		return strings.clone(encoded, allocator), true
	}
	if encoded == "true" || encoded == "false" {
		return decode_bool(encoded)
	}
	if is_signed_decimal(encoded) {
		return decode_fixed(encoded, human)
	}
	if human {
		if fixed_value, fixed_ok := decode_fixed_source(encoded); fixed_ok {
			return fixed_value, true
		}
	}
	return strings.clone(encoded, allocator), true
}

decode_record_default :: proc(
	program: ^Program,
	type_name: string,
	encoded: string,
	allocator := context.allocator,
	human := false,
) -> (
	value: Field_Value,
	ok: bool,
) {
	open := strings.index_byte(encoded, '(')
	if open < 0 || !strings.has_suffix(encoded, ")") {
		return nil, false
	}
	ctor := encoded[:open]
	body := encoded[open + 1:len(encoded) - 1]

	vec2_fields := ctor == "Vec2"
	vec3_fields := ctor == "Vec3"
	decl := program_data(program, ctor)
	fields := make(map[string]Value, allocator)
	if len(body) > 0 {
		for pair in split_top_level(body, ',', allocator) {
			eq := strings.index_byte(pair, '=')
			if eq < 0 {
				return nil, false
			}
			name := pair[:eq]
			field_enc := pair[eq + 1:]
			field_type := (vec2_fields || vec3_fields) ? "Fixed" : data_field_type(decl, name)
			fv, fv_ok := decode_default_to_value(program, field_type, field_enc, allocator, human)
			if !fv_ok {
				return nil, false
			}
			fields[strings.clone(name, allocator)] = fv
		}
	}
	if vec2_fields {
		if v, vec_ok := record_to_vec2(fields); vec_ok {
			if vec, is_vec := v.(Vec2); is_vec {
				return vec, true
			}
		}
		return nil, false
	}
	if vec3_fields {
		if v, vec_ok := record_to_vec3(fields); vec_ok {
			if vec, is_vec := v.(Vec3); is_vec {
				return vec, true
			}
		}
		return nil, false
	}
	return Record_Value{type_name = strings.clone(ctor, allocator), fields = fields}, true
}

decode_default_to_value :: proc(
	program: ^Program,
	type_name: string,
	encoded: string,
	allocator := context.allocator,
	human := false,
) -> (
	value: Value,
	ok: bool,
) {
	if open := strings.index_byte(encoded, '('); open > 0 {
		ctor := encoded[:open]
		if strings.contains(ctor, "::") && strings.has_suffix(encoded, ")") {
			return decode_struct_variant_value(program, encoded, allocator, human)
		}
	}
	fv, fv_ok := decode_default_value(program, type_name, encoded, allocator, human)
	if !fv_ok {
		return nil, false
	}
	return field_value_to_value(fv), true
}

decode_struct_variant_value :: proc(
	program: ^Program,
	encoded: string,
	allocator := context.allocator,
	human := false,
) -> (
	value: Value,
	ok: bool,
) {
	open := strings.index_byte(encoded, '(')
	if open < 0 || !strings.has_suffix(encoded, ")") {
		return nil, false
	}
	ctor := encoded[:open]
	sep := strings.index(ctor, "::")
	if sep < 0 {
		return nil, false
	}
	enum_type := strings.clone(ctor[:sep], allocator)
	case_name := strings.clone(ctor[sep + 2:], allocator)
	body := encoded[open + 1:len(encoded) - 1]

	payload_fields := make(map[string]Value, allocator)
	if len(body) > 0 {
		for pair in split_top_level(body, ',', allocator) {
			eq := strings.index_byte(pair, '=')
			if eq < 0 {
				return nil, false
			}
			name := pair[:eq]
			pv, pv_ok := decode_default_to_value(program, "", pair[eq + 1:], allocator, human)
			if !pv_ok {
				return nil, false
			}
			payload_fields[strings.clone(name, allocator)] = pv
		}
	}
	boxed := new(Value, allocator)
	boxed^ = Record_Value{type_name = "", fields = payload_fields}
	return Variant_Value{enum_type = enum_type, case_name = case_name, payload = boxed}, true
}

decode_list_default :: proc(
	program: ^Program,
	type_name: string,
	encoded: string,
	allocator := context.allocator,
	human := false,
) -> (
	value: Field_Value,
	ok: bool,
) {
	if !strings.has_prefix(encoded, "[") || !strings.has_suffix(encoded, "]") {
		return nil, false
	}
	elem_type := strings.trim_suffix(strings.trim_prefix(type_name, "["), "]")
	body := encoded[1:len(encoded) - 1]
	if len(body) == 0 {
		return List_Value{elements = make([]Value, 0, allocator)}, true
	}
	pieces := split_top_level(body, ',', allocator)
	elements := make([]Value, len(pieces), allocator)
	for piece, i in pieces {
		ev, ev_ok := decode_default_to_value(program, elem_type, piece, allocator, human)
		if !ev_ok {
			return nil, false
		}
		elements[i] = ev
	}
	return List_Value{elements = elements}, true
}

split_top_level :: proc(s: string, sep: byte, allocator := context.allocator) -> []string {
	pieces := make([dynamic]string, allocator)
	depth := 0
	start := 0
	for i in 0 ..< len(s) {
		switch s[i] {
		case '(', '[':
			depth += 1
		case ')', ']':
			depth -= 1
		case:
			if s[i] == sep && depth == 0 {
				append(&pieces, s[start:i])
				start = i + 1
			}
		}
	}
	append(&pieces, s[start:])
	return pieces[:]
}

program_data :: proc(program: ^Program, name: string) -> ^Data_Decl {
	for &decl in program.data {
		if decl.name == name {
			return &decl
		}
	}
	return nil
}

data_field_type :: proc(decl: ^Data_Decl, name: string) -> string {
	if decl == nil {
		return ""
	}
	for fd in decl.fields {
		if fd.name == name {
			return fd.type
		}
	}
	return ""
}

field_is_int :: proc(decl: ^Thing_Decl, name: string) -> bool {
	if decl == nil {
		return false
	}
	for fd in decl.fields {
		if fd.name == name {
			return fd.type == "Int"
		}
	}
	return false
}

step_tick :: proc(
	program: ^Program,
	prior: World_Version,
	input: Input,
	time: Record_Value,
	allocator := context.allocator,
	rng: ^Rng = nil,
	indices: ^Index_State = nil,
	observe: ^Tick_Observe = nil,
	honor: ^Probe_Honor = nil,
	honor_tick: int = 0,
) -> World_Version {
	state := new_tick_state(prior, allocator, allocator)
	if rng != nil {
		state.rng = rng^
	}
	state.observe = observe
	state.honor = honor
	state.honor_tick = honor_tick
	prior_version := prior
	interp := new_interp(program, &prior_version, &state, input, time, allocator)

	run_pipeline_fold(&interp, &state, program)

	apply_spawn_batch(&state)
	if rng != nil {
		rng^ = state.rng
	}
	next := commit_tick_state(prior, &state, allocator)
	if indices != nil {
		indices^ = fold_index_state(indices^, &prior_version, &next, allocator)
	}
	return next
}

run_pipeline_fold :: proc(interp: ^Interp, state: ^Tick_State, program: ^Program) {
	for step in program.pipeline {
		if step.stage == "startup" || step.stage == "render" || step.stage == "audio" {
			continue
		}
		if is_physics_solve_step(step) {
			run_solve(interp, state)
			continue
		}
		behavior := program_behavior(program, step.behavior)
		if behavior == nil {
			continue
		}
		run_behavior_over_instances(interp, state, step, behavior)
	}
}

run_behavior_over_instances :: proc(
	interp: ^Interp,
	state: ^Tick_State,
	step: Pipeline_Step,
	behavior: ^Behavior_Decl,
) {
	table := find_tick_table(state.tables, behavior.on_thing)
	if table == nil {
		return
	}
	for i in 0 ..< len(table.rows) {
		self_row := table.rows[i]
		env := bind_behavior_env(interp, state, step, behavior, self_row)
		result, ok := eval_behavior_body(interp, behavior.body, &env)
		if state.observe != nil {
			observe_behavior_step(state.observe, step, behavior, self_row, env, result, ok)
		}
		if state.honor != nil {
			honor_behavior_step(state.honor, interp, state.honor_tick, behavior, self_row, &env, result, ok)
		}
		if !ok {
			continue
		}
		fold_behavior_result(interp, state, step, behavior, self_row, result)
	}
}

bind_behavior_env :: proc(
	interp: ^Interp,
	state: ^Tick_State,
	step: Pipeline_Step,
	behavior: ^Behavior_Decl,
	self_row: Row,
) -> Env {
	env := Env{names = make(map[string]Value, interp.allocator)}
	for param in behavior.params {
		env.names[param.name] = bind_param(interp, state, param, self_row)
	}
	return env
}

bind_param :: proc(
	interp: ^Interp,
	state: ^Tick_State,
	param: Param_Decl,
	self_row: Row,
) -> Value {
	type := param.type
	switch {
	case type == "Input":
		return input_marker(interp)
	case type == "Time":
		return interp.time
	case type == "Nav":
		return nav_marker(interp)
	case type == "Rng":
		return state.rng
	case is_signal_list_type(type):
		return inbound_signal_list(interp, state, signal_type_of(type), self_row)
	case is_view_type(type):
		return view_rows_as_list(interp, view_thing_of(type))
	case param.name == "self":
		return row_to_record(interp, self_row)
	}
	return row_to_record(interp, self_row)
}

fold_behavior_result :: proc(
	interp: ^Interp,
	state: ^Tick_State,
	step: Pipeline_Step,
	behavior: ^Behavior_Decl,
	self_row: Row,
	result: Value,
) {
	emit := primary_emit(behavior)
	if tuple, is_tuple := result.(Tuple_Value); is_tuple {
		fold_tuple_emit(interp, state, behavior, self_row, emit, tuple)
		return
	}
	dispatch_emit_component(interp, state, behavior, self_row, emit, result)
}

dispatch_emit_component :: proc(
	interp: ^Interp,
	state: ^Tick_State,
	behavior: ^Behavior_Decl,
	self_row: Row,
	emit: string,
	value: Value,
) {
	switch {
	case emit == "Rng":
		if rng, is_rng := value.(Rng); is_rng {
			state.rng = rng
		}
	case is_signal_list_type(emit):
		route_signals(state, signal_type_of(emit), value)
	case emit == "[Draw]":
	case emit == "[Despawn]":
		if behavior != nil {
			fold_despawn_emit(state, behavior.on_thing, self_row, value)
		}
	case is_persist_command_list_type(emit):
		queue_persist_commands(interp, state, value)
	case is_settile_command_list_type(emit):
		queue_settile_commands(interp, state, value)
	case is_buildlayer_command_list_type(emit):
		queue_buildlayer_commands(interp, state, value)
	case is_command_list_type(emit):
		queue_commands(interp, state, value)
	case behavior != nil:
		write_blackboard(interp, state, behavior.on_thing, self_row.id, value)
	}
}

fold_despawn_emit :: proc(state: ^Tick_State, on_thing: string, self_row: Row, result: Value) {
	list, is_list := result.(List_Value)
	if !is_list || len(list.elements) == 0 {
		return
	}
	queue_despawn(state, Ref{thing = on_thing, id = self_row.id})
}

fold_tuple_emit :: proc(
	interp: ^Interp,
	state: ^Tick_State,
	behavior: ^Behavior_Decl,
	self_row: Row,
	emit_type: string,
	tuple: Tuple_Value,
) {
	component_types := split_tuple_type(emit_type, state.allocator)
	if len(component_types) == len(tuple.elements) {
		for elem, i in tuple.elements {
			dispatch_emit_component(interp, state, behavior, self_row, component_types[i], elem)
		}
		return
	}
	for elem in tuple.elements {
		switch v in elem {
		case Rng:
			state.rng = v
		case List_Value:
			queue_commands(interp, state, elem)
		case i64, Fixed, bool, Vec2, Ref, Record_Value, Variant_Value, Lambda_Value, String_Value, Tuple_Value, Vec3, Transform_Value, Pose_Value, Handle_Value, Nav_Value, Map_Value:
		}
	}
}

split_tuple_type :: proc(type: string, allocator := context.allocator) -> []string {
	if len(type) < 2 || type[0] != '(' || type[len(type) - 1] != ')' {
		return nil
	}
	pieces := split_top_level(type[1:len(type) - 1], ',', allocator)
	for piece, i in pieces {
		pieces[i] = strings.trim_space(piece)
	}
	return pieces
}

new_signal_mailbox :: proc(allocator := context.allocator) -> Signal_Mailbox {
	return Signal_Mailbox {
		by_type = make(map[string][]Value, allocator),
		by_instance = make(map[string]map[Id][]Value, allocator),
	}
}

is_per_instance_signal :: proc(signal_type: string) -> bool {
	return signal_type == SOLVER_TRIGGER_SIGNAL || signal_type == "Contact"
}

route_signals :: proc(state: ^Tick_State, signal_type: string, result: Value) {
	list, is_list := result.(List_Value)
	if !is_list || len(list.elements) == 0 {
		return
	}
	if state.observe != nil {
		observe_broadcast_signals(state.observe, signal_type, list.elements)
	}
	existing := state.mailbox.by_type[signal_type]
	combined := make([]Value, len(existing) + len(list.elements), state.allocator)
	copy(combined, existing)
	copy(combined[len(existing):], list.elements)
	state.mailbox.by_type[signal_type] = combined
}

route_instance_signal :: proc(state: ^Tick_State, signal_type: string, target: Id, signal: Value) {
	if state.observe != nil {
		observe_instance_signal(state.observe, signal_type, target, signal)
	}
	per_type, has := state.mailbox.by_instance[signal_type]
	if !has {
		per_type = make(map[Id][]Value, state.allocator)
	}
	existing := per_type[target]
	combined := make([]Value, len(existing) + 1, state.allocator)
	copy(combined, existing)
	combined[len(existing)] = signal
	per_type[target] = combined
	state.mailbox.by_instance[signal_type] = per_type
}

inbound_signal_list :: proc(
	interp: ^Interp,
	state: ^Tick_State,
	signal_type: string,
	self_row: Row,
) -> Value {
	existing: []Value
	if is_per_instance_signal(signal_type) {
		if per_type, has := state.mailbox.by_instance[signal_type]; has {
			existing = per_type[self_row.id]
		}
	} else {
		existing = state.mailbox.by_type[signal_type]
	}
	elements := make([]Value, len(existing), interp.allocator)
	copy(elements, existing)
	return List_Value{elements = elements}
}

write_blackboard :: proc(
	interp: ^Interp,
	state: ^Tick_State,
	thing: string,
	id: Id,
	result: Value,
) {
	record, is_record := result.(Record_Value)
	if !is_record {
		return
	}
	table := find_tick_table(state.tables, thing)
	if table == nil {
		return
	}
	i, found := find_row_by_id(table.rows[:], id)
	if !found {
		return
	}
	next := make(map[string]Field_Value, state.commit_allocator)
	for k, v in record.fields {
		if fv, ok := value_to_field_value(v, state.commit_allocator); ok {
			next[k] = fv
		}
	}
	if table.rows[i].fields != nil {
		append(&state.superseded, table.rows[i].fields)
	}
	table.rows[i].fields = next
}

queue_commands :: proc(interp: ^Interp, state: ^Tick_State, result: Value) {
	list, is_list := result.(List_Value)
	if !is_list {
		return
	}
	for elem in list.elements {
		record, is_record := elem.(Record_Value)
		if !is_record {
			continue
		}
		fields := make(map[string]Field_Value, state.commit_allocator)
		for k, v in record.fields {
			if fv, ok := value_to_field_value(v, state.commit_allocator); ok {
				fields[k] = fv
			}
		}
		append(&state.spawns, Pending_Spawn{thing = record.type_name, fields = fields})
	}
}

queue_persist_commands :: proc(interp: ^Interp, state: ^Tick_State, result: Value) {
	list, is_list := result.(List_Value)
	if !is_list {
		return
	}
	for elem in list.elements {
		if record, is_record := elem.(Record_Value); is_record {
			append(&state.persist_commands, record)
		}
	}
}

queue_settile_commands :: proc(interp: ^Interp, state: ^Tick_State, result: Value) {
	queue_terrain_commands(state, result, .Set_Tile)
}

queue_buildlayer_commands :: proc(interp: ^Interp, state: ^Tick_State, result: Value) {
	queue_terrain_commands(state, result, .Build_Layer)
}

queue_terrain_commands :: proc(state: ^Tick_State, result: Value, kind: Terrain_Command_Kind) {
	list, is_list := result.(List_Value)
	if !is_list {
		return
	}
	for elem in list.elements {
		if record, is_record := elem.(Record_Value); is_record {
			append(&state.terrain_commands, Terrain_Command{kind = kind, record = record})
		} else {
			append(&state.tile_refusals, Tile_Command_Refusal{command = kind, kind = .Malformed_Command})
		}
	}
}

queue_spawn :: proc(state: ^Tick_State, thing: string, fields: map[string]Field_Value) {
	append(&state.spawns, Pending_Spawn{thing = thing, fields = fields})
}

queue_despawn :: proc(state: ^Tick_State, ref: Ref) {
	append(&state.despawns, ref)
}

apply_spawn_batch :: proc(state: ^Tick_State) {
	for ref in state.despawns {
		table := find_tick_table(state.tables, ref.thing)
		if table == nil {
			continue
		}
		if dropped, removed := remove_row_by_id(table, ref.id); removed && dropped != nil {
			append(&state.superseded, dropped)
		}
	}
	for spawn in state.spawns {
		table := find_tick_table(state.tables, spawn.thing)
		if table == nil {
			continue
		}
		id := Id{raw = table.next_id}
		table.next_id += 1
		append(&table.rows, Row{id = id, fields = spawn.fields})
	}
}

remove_row_by_id :: proc(table: ^Tick_Table, id: Id) -> (dropped: map[string]Field_Value, removed: bool) {
	for i in 0 ..< len(table.rows) {
		if table.rows[i].id == id {
			dropped = table.rows[i].fields
			ordered_remove(&table.rows, i)
			return dropped, true
		}
	}
	return nil, false
}

new_tick_state :: proc(
	prior: World_Version,
	allocator := context.allocator,
	commit_allocator := context.allocator,
) -> Tick_State {
	return Tick_State {
		tables = new_tick_tables(prior, allocator),
		mailbox = new_signal_mailbox(allocator),
		spawns = make([dynamic]Pending_Spawn, allocator),
		despawns = make([dynamic]Ref, allocator),
		persist_commands = make([dynamic]Record_Value, allocator),
		terrain_commands = make([dynamic]Terrain_Command, allocator),
		tile_refusals = make([dynamic]Tile_Command_Refusal, allocator),
		superseded = make([dynamic]map[string]Field_Value, allocator),
		allocator = allocator,
		commit_allocator = commit_allocator,
	}
}

new_tick_tables :: proc(prior: World_Version, allocator := context.allocator) -> []Tick_Table {
	tables := make([]Tick_Table, len(prior.tables), allocator)
	for table, i in prior.tables {
		rows := make([dynamic]Row, allocator)
		for row in table.rows {
			append(&rows, row)
		}
		tables[i] = Tick_Table {
			thing     = table.thing,
			singleton = table.singleton,
			rows      = rows,
			next_id   = table.next_id,
		}
	}
	return tables
}

commit_tick_state :: proc(
	prior: World_Version,
	state: ^Tick_State,
	allocator := context.allocator,
) -> World_Version {
	version := commit_tick_tables(prior, state.tables, allocator)
	version.tilemaps = fold_tile_layers(prior, state)
	return version
}

commit_tick_tables :: proc(
	prior: World_Version,
	tables: []Tick_Table,
	allocator := context.allocator,
) -> World_Version {
	changed := make(map[string]Version_Table, allocator)
	for &table in tables {
		rows := make([]Row, len(table.rows), allocator)
		copy(rows, table.rows[:])
		slice.sort_by(rows, proc(a, b: Row) -> bool {
			return a.id.raw < b.id.raw
		})
		changed[table.thing] = Version_Table {
			thing     = table.thing,
			singleton = table.singleton,
			rows      = rows,
			next_id   = table.next_id,
		}
	}
	version := commit_version(prior, changed, allocator)
	delete(changed)
	return version
}

find_tick_table :: proc(tables: []Tick_Table, thing: string) -> ^Tick_Table {
	for &table in tables {
		if table.thing == thing {
			return &table
		}
	}
	return nil
}

row_to_record :: proc(interp: ^Interp, row: Row, thing := "") -> Value {
	fields := make(map[string]Value, interp.allocator)
	for k, v in row.fields {
		fields[k] = field_value_to_value(v)
	}
	return Record_Value{type_name = thing, fields = fields}
}

view_rows_as_list :: proc(interp: ^Interp, thing: string) -> Value {
	view := interp_view_of_type(interp, thing)
	elements := make([]Value, view_count(view), interp.allocator)
	for i in 0 ..< view_count(view) {
		row, _ := view_at(view, i)
		elements[i] = row_to_record(interp, row, thing)
	}
	return List_Value{elements = elements}
}

interp_view_of_type :: proc(interp: ^Interp, thing: string) -> View {
	if interp.tick != nil {
		if table := find_tick_table(interp.tick.tables, thing); table != nil {
			return View{thing = thing, rows = table.rows[:]}
		}
	}
	return view_of_type(interp.version, thing)
}

interp_resolve_ref :: proc(interp: ^Interp, ref: Ref) -> (row: Row, some: bool) {
	if interp.tick != nil {
		if table := find_tick_table(interp.tick.tables, ref.thing); table != nil {
			idx, found := find_row_by_id(table.rows[:], ref.id)
			if !found {
				return {}, false
			}
			return table.rows[idx], true
		}
	}
	return resolve_ref(interp.version, ref)
}

input_marker :: proc(interp: ^Interp) -> Value {
	fields := make(map[string]Value, interp.allocator)
	return Record_Value{type_name = "Input", fields = fields}
}

is_physics_solve_step :: proc(step: Pipeline_Step) -> bool {
	return step.stage == "physics" && step.behavior == "solve"
}

is_signal_list_type :: proc(type: string) -> bool {
	if !is_bracket_list(type) {
		return false
	}
	if is_persist_command_list_type(type) {
		return false
	}
	if is_settile_command_list_type(type) || is_buildlayer_command_list_type(type) {
		return false
	}
	inner := signal_type_of(type)
	return inner != "Draw" && inner != "Spawn" && inner != "Despawn"
}

is_command_list_type :: proc(type: string) -> bool {
	return type == "[Spawn]"
}

is_persist_command_list_type :: proc(type: string) -> bool {
	return type == "[Save]" || type == "[Restore]" || type == "[ApplySettings]"
}

is_settile_command_list_type :: proc(type: string) -> bool {
	return type == "[SetTile]"
}

is_buildlayer_command_list_type :: proc(type: string) -> bool {
	return type == "[BuildLayer]"
}

is_view_type :: proc(type: string) -> bool {
	return len(type) > 6 && type[:5] == "View[" && type[len(type) - 1] == ']'
}

is_bracket_list :: proc(type: string) -> bool {
	return len(type) >= 3 && type[0] == '[' && type[len(type) - 1] == ']'
}

signal_type_of :: proc(type: string) -> string {
	if is_bracket_list(type) {
		return type[1:len(type) - 1]
	}
	return type
}

view_thing_of :: proc(type: string) -> string {
	if is_view_type(type) {
		return type[5:len(type) - 1]
	}
	return type
}

primary_emit :: proc(behavior: ^Behavior_Decl) -> string {
	if len(behavior.emits) == 0 {
		return ""
	}
	return behavior.emits[0]
}

program_thing :: proc(program: ^Program, name: string) -> ^Thing_Decl {
	for &thing in program.things {
		if thing.name == name {
			return &thing
		}
	}
	return nil
}

program_behavior :: proc(program: ^Program, name: string) -> ^Behavior_Decl {
	for &behavior in program.behaviors {
		if behavior.name == name {
			return &behavior
		}
	}
	return nil
}

program_pipeline_step :: proc(program: ^Program, behavior_name: string) -> ^Pipeline_Step {
	for &step in program.pipeline {
		if step.behavior == behavior_name {
			return &step
		}
	}
	return nil
}
