package funpack_runtime

import "core:encoding/json"
import "core:fmt"
import "core:slice"
import "core:strings"

capture_test_request :: proc(
	s: ^Debug_Session,
	id: i64,
	args: json.Object,
	allocator := context.allocator,
) -> string {
	tick, has_tick := json_int_field(args, "tick")
	behavior_name, has_behavior := json_string_field(args, "behavior")
	if !has_tick || !has_behavior {
		return error_response(id, "capture_test", "missing args.tick or args.behavior", allocator)
	}
	behavior := program_behavior(s.program, behavior_name)
	if behavior == nil {
		return error_response(id, "capture_test", "unknown behavior", allocator)
	}
	obs, _, refusal, ok := refold_tick_obs(s, id, "capture_test", int(tick), allocator)
	if !ok {
		return refusal
	}

	instance, instance_given := json_int_field(args, "instance")
	capture: Step_Capture
	found := false
	for step in obs.steps {
		if step.behavior != behavior_name {
			continue
		}
		if instance_given && step.instance.raw != Thing_Id(instance) {
			continue
		}
		capture = step
		found = true
		break
	}
	if !found {
		return error_response(id, "capture_test", "no captured step for that behavior and instance", allocator)
	}
	if !capture.ok {
		return error_response(id, "capture_test", "the captured step produced no result to assert", allocator)
	}

	source, render_err := render_captured_test(s, behavior, capture, int(tick), allocator)
	if render_err != "" {
		return error_response(id, "capture_test", render_err, allocator)
	}

	b := strings.builder_make(allocator)
	ok_response_open(&b, id, "capture_test")
	fmt.sbprintf(&b, "{{\"tick\":%d,\"behavior\":", tick)
	write_json_string(&b, behavior_name)
	fmt.sbprintf(&b, ",\"instance\":%d,\"test\":", capture.instance.raw)
	write_json_string(&b, source)
	strings.write_string(&b, "}}")
	return strings.to_string(b)
}

@(private = "file")
render_captured_test :: proc(
	s: ^Debug_Session,
	behavior: ^Behavior_Decl,
	capture: Step_Capture,
	tick: int,
	allocator := context.allocator,
) -> (
	source: string,
	err: string,
) {
	b := strings.builder_make(allocator)
	fmt.sbprintf(
		&b,
		"@doc(\"Captured by capture_test: %s on %s#%d at tick %d of a recorded session.\")\n",
		behavior.name,
		behavior.on_thing,
		capture.instance.raw,
		tick,
	)
	fmt.sbprintf(&b, "test \"captured %s tick %d instance %d\" {{\n", behavior.name, tick, capture.instance.raw)
	fmt.sbprintf(&b, "  assert %s.step(", behavior.name)
	for param, i in behavior.params {
		if i > 0 {
			strings.write_string(&b, ", ")
		}
		if param_err := write_param_fixture(&b, s, behavior, capture, param, tick, allocator); param_err != "" {
			return "", param_err
		}
	}
	strings.write_string(&b, ") == ")
	if result_err := write_source_value(&b, s.program, capture.result, primary_emit(behavior), allocator); result_err != "" {
		return "", result_err
	}
	strings.write_string(&b, "\n}\n")
	return strings.to_string(b), ""
}

capture_tick_request :: proc(
	s: ^Debug_Session,
	id: i64,
	args: json.Object,
	allocator := context.allocator,
) -> string {
	tick, has_tick := json_int_field(args, "tick")
	thing, has_thing := json_string_field(args, "thing")
	twin_name, has_twin := json_string_field(args, "twin")
	if !has_tick || !has_thing || !has_twin {
		return error_response(id, "capture_tick", "missing args.tick, args.thing, or args.twin", allocator)
	}
	twin := program_function(s.program, twin_name)
	if twin == nil {
		return error_response(id, "capture_tick", "unknown twin function", allocator)
	}
	pre_version, _, pre_refusal, pre_ok := resolve_observe_version(s, id, "capture_tick", args, int(tick) - 1)
	if !pre_ok {
		return pre_refusal
	}
	post_version, _, post_refusal, post_ok := resolve_observe_version(s, id, "capture_tick", args, int(tick))
	if !post_ok {
		return post_refusal
	}
	pre_mut := pre_version
	post_mut := post_version
	pre_table := version_find_table(&pre_mut, thing)
	post_table := version_find_table(&post_mut, thing)
	if pre_table == nil || post_table == nil {
		return error_response(id, "capture_tick", "unknown thing", allocator)
	}
	takes_view, twin_err := capture_tick_twin_shape(twin, thing, allocator)
	if twin_err != "" {
		return error_response(id, "capture_tick", twin_err, allocator)
	}

	source, render_err := render_captured_tick(
		s.program,
		thing,
		twin_name,
		takes_view,
		pre_table.rows,
		post_table.rows,
		int(tick),
		allocator,
	)
	if render_err != "" {
		return error_response(id, "capture_tick", render_err, allocator)
	}

	b := strings.builder_make(allocator)
	ok_response_open(&b, id, "capture_tick")
	fmt.sbprintf(&b, "{{\"tick\":%d,\"thing\":", tick)
	write_json_string(&b, thing)
	strings.write_string(&b, ",\"twin\":")
	write_json_string(&b, twin_name)
	strings.write_string(&b, ",\"test\":")
	write_json_string(&b, source)
	strings.write_string(&b, "}}")
	return strings.to_string(b)
}

@(private = "file")
capture_tick_twin_shape :: proc(
	twin: ^Function_Decl,
	thing: string,
	allocator := context.allocator,
) -> (
	takes_view: bool,
	err: string,
) {
	list_type := fmt.aprintf("[%s]", thing, allocator = allocator)
	if len(twin.params) != 1 {
		return false, fmt.aprintf(
			"twin %s must take exactly one param (%s or View[%s])",
			twin.name,
			list_type,
			thing,
			allocator = allocator,
		)
	}
	if !is_bracket_list(twin.return_type) || signal_type_of(twin.return_type) != thing {
		return false, fmt.aprintf("twin %s must return %s", twin.name, list_type, allocator = allocator)
	}
	param_type := twin.params[0].type
	switch {
	case is_view_type(param_type) && view_thing_of(param_type) == thing:
		return true, ""
	case is_bracket_list(param_type) && signal_type_of(param_type) == thing:
		return false, ""
	}
	return false, fmt.aprintf(
		"twin %s param must be %s or View[%s], not %s",
		twin.name,
		list_type,
		thing,
		param_type,
		allocator = allocator,
	)
}

@(private = "file")
render_captured_tick :: proc(
	program: ^Program,
	thing: string,
	twin_name: string,
	takes_view: bool,
	pre_rows: []Row,
	post_rows: []Row,
	tick: int,
	allocator := context.allocator,
) -> (
	source: string,
	err: string,
) {
	b := strings.builder_make(allocator)
	fmt.sbprintf(
		&b,
		"@doc(\"Captured by capture_tick: %s vs the live schedule for %s over tick %d of a recorded session.\")\n",
		twin_name,
		thing,
		tick,
	)
	fmt.sbprintf(&b, "test \"captured tick %d %s twin %s\" {{\n", tick, thing, twin_name)
	fmt.sbprintf(&b, "  assert %s(", twin_name)
	list_hint := fmt.aprintf("[%s]", thing, allocator = allocator)
	if takes_view {
		strings.write_string(&b, "View.of(")
	}
	if pre_err := write_rows_source_list(&b, program, thing, pre_rows, list_hint, allocator); pre_err != "" {
		return "", pre_err
	}
	if takes_view {
		strings.write_string(&b, ")")
	}
	strings.write_string(&b, ") == ")
	if post_err := write_rows_source_list(&b, program, thing, post_rows, list_hint, allocator); post_err != "" {
		return "", post_err
	}
	strings.write_string(&b, "\n}\n")
	return strings.to_string(b), ""
}

@(private = "file")
write_rows_source_list :: proc(
	b: ^strings.Builder,
	program: ^Program,
	thing: string,
	rows: []Row,
	list_hint: string,
	allocator := context.allocator,
) -> (
	err: string,
) {
	elements := make([]Value, len(rows), allocator)
	for row, i in rows {
		fields := make(map[string]Value, allocator)
		for k, v in row.fields {
			fields[k] = field_value_to_value(v)
		}
		elements[i] = Record_Value{type_name = thing, fields = fields}
	}
	return write_source_value(b, program, List_Value{elements = elements}, list_hint, allocator)
}

@(private = "file")
write_param_fixture :: proc(
	b: ^strings.Builder,
	s: ^Debug_Session,
	behavior: ^Behavior_Decl,
	capture: Step_Capture,
	param: Param_Decl,
	tick: int,
	allocator := context.allocator,
) -> (
	err: string,
) {
	switch {
	case param.type == "Input":
		return write_input_fixture(b, s, tick, allocator)
	case param.type == "Rng" || param.type == "Time":
		return fmt.aprintf(
			"param %s: %s has no deterministic source constructor — capture at a constructible boundary",
			param.name,
			param.type,
			allocator = allocator,
		)
	case is_view_type(param.type):
		strings.write_string(b, "View.of(")
		if list_err := write_source_value(b, s.program, capture.env[param.name], param.type[4:], allocator); list_err != "" {
			return list_err
		}
		strings.write_string(b, ")")
		return ""
	}
	return write_source_value(b, s.program, capture.env[param.name], param.type, allocator)
}

@(private = "file")
write_input_fixture :: proc(
	b: ^strings.Builder,
	s: ^Debug_Session,
	tick: int,
	allocator := context.allocator,
) -> (
	err: string,
) {
	registry := build_action_registry(s.program^, allocator)
	snapshot := s.snapshots[tick]
	strings.write_string(b, "Input.empty()")

	buttons := make([dynamic]Player_Action, 0, len(snapshot.buttons), allocator)
	for key in snapshot.buttons {
		append(&buttons, key)
	}
	sort_player_actions(buttons[:])
	for key in buttons {
		state := snapshot.buttons[key]
		action_name, action_ok := registry_action_name(registry, key.action)
		if !action_ok {
			return "recorded snapshot carries an action outside the program's registry"
		}
		switch {
		case state.pressed:
			fmt.sbprintf(b, ".with_pressed(PlayerId::%v, %s)", key.player, action_name)
		case state.held:
			fmt.sbprintf(b, ".with_held(PlayerId::%v, %s)", key.player, action_name)
		case:
			return "recorded snapshot carries a released-only edge — no producer constructs it"
		}
	}

	axes := make([dynamic]Player_Action, 0, len(snapshot.axes), allocator)
	for key in snapshot.axes {
		append(&axes, key)
	}
	sort_player_actions(axes[:])
	for key in axes {
		vec := snapshot.axes[key]
		action_name, action_ok := registry_action_name(registry, key.action)
		if !action_ok {
			return "recorded snapshot carries an action outside the program's registry"
		}
		if vec.y == 0 {
			fmt.sbprintf(b, ".with_value(PlayerId::%v, %s, ", key.player, action_name)
			write_source_fixed(b, vec.x)
			strings.write_string(b, ")")
		} else {
			fmt.sbprintf(b, ".with_axis(PlayerId::%v, %s, Vec2{{x: ", key.player, action_name)
			write_source_fixed(b, vec.x)
			strings.write_string(b, ", y: ")
			write_source_fixed(b, vec.y)
			strings.write_string(b, "})")
		}
	}
	return ""
}

@(private = "file")
sort_player_actions :: proc(keys: []Player_Action) {
	slice.sort_by(keys, proc(a, b: Player_Action) -> bool {
		if a.player != b.player {
			return a.player < b.player
		}
		return a.action < b.action
	})
}

@(private = "file")
registry_action_name :: proc(registry: Action_Registry, action: ActionId) -> (name: string, ok: bool) {
	for def in registry.defs {
		if def.id == action {
			return def.name, true
		}
	}
	return "", false
}

@(private = "file")
write_source_value :: proc(
	b: ^strings.Builder,
	program: ^Program,
	value: Value,
	type_hint: string,
	allocator := context.allocator,
) -> (
	err: string,
) {
	switch v in value {
	case i64:
		fmt.sbprintf(b, "%d", v)
		return ""
	case Fixed:
		write_source_fixed(b, v)
		return ""
	case bool:
		strings.write_string(b, v ? "true" : "false")
		return ""
	case Vec2:
		strings.write_string(b, "Vec2{x: ")
		write_source_fixed(b, v.x)
		strings.write_string(b, ", y: ")
		write_source_fixed(b, v.y)
		strings.write_string(b, "}")
		return ""
	case Vec3:
		strings.write_string(b, "Vec3{x: ")
		write_source_fixed(b, v.x)
		strings.write_string(b, ", y: ")
		write_source_fixed(b, v.y)
		strings.write_string(b, ", z: ")
		write_source_fixed(b, v.z)
		strings.write_string(b, "}")
		return ""
	case String_Value:
		write_source_string(b, v.text)
		return ""
	case Record_Value:
		return write_source_record(b, program, v, type_hint, allocator)
	case List_Value:
		strings.write_string(b, "[")
		element_hint := is_bracket_list(type_hint) ? signal_type_of(type_hint) : ""
		for element, i in v.elements {
			if i > 0 {
				strings.write_string(b, ", ")
			}
			if element_err := write_source_value(b, program, element, element_hint, allocator); element_err != "" {
				return element_err
			}
		}
		strings.write_string(b, "]")
		return ""
	case Variant_Value:
		strings.write_string(b, v.enum_type)
		strings.write_string(b, "::")
		strings.write_string(b, v.case_name)
		if v.payload == nil {
			return ""
		}
		if record, is_record := v.payload^.(Record_Value); is_record && record.type_name == "" {
			return write_source_record_body(b, program, record, allocator)
		}
		strings.write_string(b, "(")
		if payload_err := write_source_value(b, program, v.payload^, "", allocator); payload_err != "" {
			return payload_err
		}
		strings.write_string(b, ")")
		return ""
	case Ref, Lambda_Value, Tuple_Value, Rng, Transform_Value, Pose_Value, Handle_Value, Nav_Value, Map_Value:
		return fmt.aprintf("captured value has no funpack source literal: %v", value, allocator = allocator)
	}
	return "captured value has no funpack source literal: nil"
}

@(private = "file")
write_source_record :: proc(
	b: ^strings.Builder,
	program: ^Program,
	record: Record_Value,
	type_hint: string,
	allocator := context.allocator,
) -> (
	err: string,
) {
	name := record.type_name != "" ? record.type_name : type_hint
	if name == "" {
		return "captured record has no constructor name and no declared type at its position"
	}
	strings.write_string(b, name)
	decl_fields, has_decl := source_decl_fields(program, name)
	if !has_decl {
		return write_source_record_body(b, program, record, allocator)
	}
	strings.write_string(b, "{")
	wrote := 0
	for field in decl_fields {
		value, has_value := record.fields[field.name]
		if !has_value {
			continue
		}
		if wrote > 0 {
			strings.write_string(b, ", ")
		}
		wrote += 1
		strings.write_string(b, field.name)
		strings.write_string(b, ": ")
		if field_err := write_source_value(b, program, value, field.type, allocator); field_err != "" {
			return field_err
		}
	}
	strings.write_string(b, "}")
	return ""
}

@(private = "file")
write_source_record_body :: proc(
	b: ^strings.Builder,
	program: ^Program,
	record: Record_Value,
	allocator := context.allocator,
) -> (
	err: string,
) {
	strings.write_string(b, "{")
	names := make([dynamic]string, 0, len(record.fields), allocator)
	for field_name in record.fields {
		append(&names, field_name)
	}
	slice.sort(names[:])
	for field_name, i in names {
		if i > 0 {
			strings.write_string(b, ", ")
		}
		strings.write_string(b, field_name)
		strings.write_string(b, ": ")
		if field_err := write_source_value(b, program, record.fields[field_name], "", allocator); field_err != "" {
			return field_err
		}
	}
	strings.write_string(b, "}")
	return ""
}

@(private = "file")
source_decl_fields :: proc(program: ^Program, name: string) -> (fields: []Field_Decl, ok: bool) {
	if thing := program_thing(program, name); thing != nil {
		return thing.fields, true
	}
	if data := program_data(program, name); data != nil {
		return data.fields, true
	}
	for &signal in program.signals {
		if signal.name == name {
			return signal.fields, true
		}
	}
	return nil, false
}

write_source_fixed :: proc(b: ^strings.Builder, value: Fixed) {
	bits := i64(value)
	magnitude: u64
	if bits < 0 {
		strings.write_string(b, "-")
		magnitude = u64(~bits) + 1
	} else {
		magnitude = u64(bits)
	}
	fmt.sbprintf(b, "%d.", magnitude >> FIXED_FRACTION_BITS)
	fraction := magnitude & 0xFFFFFFFF
	if fraction == 0 {
		strings.write_string(b, "0")
		return
	}
	for fraction != 0 {
		fraction *= 10
		fmt.sbprintf(b, "%d", fraction >> FIXED_FRACTION_BITS)
		fraction &= 0xFFFFFFFF
	}
}

@(private = "file")
write_source_string :: proc(b: ^strings.Builder, text: string) {
	strings.write_string(b, "\"")
	for i in 0 ..< len(text) {
		c := text[i]
		switch c {
		case '"':
			strings.write_string(b, "\\\"")
		case '\\':
			strings.write_string(b, "\\\\")
		case '\n':
			strings.write_string(b, "\\n")
		case '\t':
			strings.write_string(b, "\\t")
		case:
			strings.write_byte(b, c)
		}
	}
	strings.write_string(b, "\"")
}
