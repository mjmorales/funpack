package funpack

import "core:strings"

Setup_Spawn_Value :: struct {
	type_name: string,
	record:    Record_Value,
}

resolve_setup_values :: proc(ctx: Eval_Ctx) -> (spawns: []Setup_Spawn_Value, found: bool, ok: bool) {
	fn, declared := find_user_fn(ctx.ast, "setup")
	if !declared {
		return nil, false, true
	}
	if len(fn.params) != 0 {
		return nil, false, true
	}
	value, eval_ok := eval_user_fn(ctx, fn, {})
	if !eval_ok {
		return nil, true, false
	}
	list, is_list := value.(List_Value)
	if !is_list {
		return nil, true, false
	}
	out := make([dynamic]Setup_Spawn_Value, 0, len(list.elements), context.temp_allocator)
	for element in list.elements {
		record, spawn_ok := spawn_command_record(element)
		if !spawn_ok {
			return nil, true, false
		}
		append(&out, Setup_Spawn_Value{type_name = record.type_name, record = record})
	}
	return out[:], true, true
}

spawn_command_record :: proc(element: Value) -> (record: Record_Value, ok: bool) {
	command, is_record := element.(Record_Value)
	if !is_record || command.type_name != "Spawn" {
		return {}, false
	}
	thing, found := record_field_value(command.fields, "thing")
	if !found {
		return {}, false
	}
	record, ok = thing.(Record_Value)
	return
}

encode_setup_value_field :: proc(v: Value) -> (encoded: string, ok: bool) {
	#partial switch e in v {
	case Vec2_Value:
		return strings.concatenate(
			{
				"vec2 ",
				encode_fixed(e.x, context.temp_allocator),
				" ",
				encode_fixed(e.y, context.temp_allocator),
			},
			context.temp_allocator,
		), true
	}
	return encode_setup_value_token(v)
}

encode_setup_value_token :: proc(v: Value) -> (token: string, ok: bool) {
	switch e in v {
	case i64:
		return encode_int(e, context.temp_allocator), true
	case Fixed:
		return encode_fixed(e, context.temp_allocator), true
	case bool:
		return encode_bool(e), true
	case string:
		return encode_string(e, context.temp_allocator), true
	case Enum_Value:
		if e.payload != nil {
			return "", false
		}
		return strings.concatenate({e.type_name, "::", e.variant}, context.temp_allocator), true
	case Vec2_Value:
		return strings.concatenate(
			{"Vec2(x=", encode_fixed(e.x, context.temp_allocator), ",y=", encode_fixed(e.y, context.temp_allocator), ")"},
			context.temp_allocator,
		), true
	case Vec3_Value:
		return strings.concatenate(
			{
				"Vec3(x=",
				encode_fixed(e.x, context.temp_allocator),
				",y=",
				encode_fixed(e.y, context.temp_allocator),
				",z=",
				encode_fixed(e.z, context.temp_allocator),
				")",
			},
			context.temp_allocator,
		), true
	case Record_Value:
		return encode_value_record_token(e)
	case List_Value:
		return encode_value_list_token(e)
	case Option_Value, Map_Value, Tuple_Value, Lambda_Value, Input_Value, Time_Value, Transform_Value, Pose_Value, Tilemap_Value, Nav_Value, Quat_Value, Rng:
		return "", false
	}
	return "", false
}

encode_value_record_token :: proc(r: Record_Value) -> (token: string, ok: bool) {
	b := strings.builder_make(context.temp_allocator)
	strings.write_string(&b, r.type_name)
	if r.variant != "" {
		strings.write_string(&b, "::")
		strings.write_string(&b, r.variant)
	}
	strings.write_byte(&b, '(')
	for field, i in r.fields {
		if i > 0 {
			strings.write_byte(&b, ',')
		}
		strings.write_string(&b, field.name)
		strings.write_byte(&b, '=')
		inner := encode_setup_value_token(field.value) or_return
		strings.write_string(&b, inner)
	}
	strings.write_byte(&b, ')')
	return strings.to_string(b), true
}

encode_value_list_token :: proc(l: List_Value) -> (token: string, ok: bool) {
	b := strings.builder_make(context.temp_allocator)
	strings.write_byte(&b, '[')
	for element, i in l.elements {
		if i > 0 {
			strings.write_byte(&b, ',')
		}
		inner := encode_setup_value_token(element) or_return
		strings.write_string(&b, inner)
	}
	strings.write_byte(&b, ']')
	return strings.to_string(b), true
}
