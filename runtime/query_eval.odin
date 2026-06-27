package funpack_runtime

import "core:slice"

eval_query_call :: proc(
	interp: ^Interp,
	query: ^Query_Decl,
	node: ^Node,
	env: ^Env,
) -> (
	value: Value,
	ok: bool,
) {
	arg_count := len(node.children) - 1
	if arg_count != len(query.params) {
		return nil, false
	}
	args := make([]Value, arg_count, interp.allocator)
	for i in 0 ..< arg_count {
		arg, arg_ok := eval(interp, &node.children[i + 1], env)
		if !arg_ok {
			return nil, false
		}
		args[i] = arg
	}
	return eval_query_values(interp, query, args)
}

eval_query_values :: proc(
	interp: ^Interp,
	query: ^Query_Decl,
	args: []Value,
) -> (
	value: Value,
	ok: bool,
) {
	if len(args) != len(query.params) {
		return nil, false
	}
	scope := Env {
		names = make(map[string]Value, interp.allocator),
	}
	for param, i in query.params {
		scope.names[param.name] = args[i]
	}
	enclosing := interp.query_indexes
	interp.query_indexes = query.indexes
	value, ok = eval_body(interp, query.body, &scope)
	interp.query_indexes = enclosing
	return value, ok
}

builtin_within :: proc(interp: ^Interp, node: ^Node, env: ^Env) -> (value: Value, ok: bool) {
	if len(node.children) != 4 {
		return nil, false
	}
	source, source_ok := eval(interp, &node.children[1], env)
	if !source_ok {
		return nil, false
	}
	list, is_list := source.(List_Value)
	if !is_list {
		return nil, false
	}
	origin, origin_ok := eval(interp, &node.children[2], env)
	if !origin_ok {
		return nil, false
	}
	radius_value, radius_ok := eval(interp, &node.children[3], env)
	if !radius_ok {
		return nil, false
	}
	radius, is_fixed := radius_value.(Fixed)
	if !is_fixed {
		return nil, false
	}
	out := make([dynamic]Value, 0, len(list.elements), interp.allocator)
	for element in list.elements {
		distance, measurable := query_spatial_distance(interp, element, origin)
		if !measurable {
			return nil, false
		}
		if distance <= radius {
			append(&out, element)
		}
	}
	return List_Value{elements = out[:]}, true
}

builtin_nearest_first :: proc(interp: ^Interp, node: ^Node, env: ^Env) -> (value: Value, ok: bool) {
	if len(node.children) != 3 {
		return nil, false
	}
	source, source_ok := eval(interp, &node.children[1], env)
	if !source_ok {
		return nil, false
	}
	list, is_list := source.(List_Value)
	if !is_list {
		return nil, false
	}
	origin, origin_ok := eval(interp, &node.children[2], env)
	if !origin_ok {
		return nil, false
	}
	keyed := make([]Query_Keyed_Row, len(list.elements), context.temp_allocator)
	for element, i in list.elements {
		distance, measurable := query_spatial_distance(interp, element, origin)
		if !measurable {
			return nil, false
		}
		keyed[i] = Query_Keyed_Row{row = element, distance = distance}
	}
	slice.stable_sort_by(keyed, query_keyed_row_less)
	out := make([]Value, len(keyed), interp.allocator)
	for entry, i in keyed {
		out[i] = entry.row
	}
	return List_Value{elements = out}, true
}

Query_Keyed_Row :: struct {
	row:      Value,
	distance: Fixed,
}

query_keyed_row_less :: proc(a, b: Query_Keyed_Row) -> bool {
	return a.distance < b.distance
}

query_spatial_distance :: proc(interp: ^Interp, element: Value, origin: Value) -> (distance: Fixed, ok: bool) {
	record, is_record := element.(Record_Value)
	if !is_record {
		return 0, false
	}
	field, resolved := query_spatial_field(interp.query_indexes, record.type_name)
	if !resolved {
		return 0, false
	}
	at, has_field := record.fields[field]
	if !has_field {
		return 0, false
	}
	#partial switch from in origin {
	case Vec2:
		at2, is_vec2 := at.(Vec2)
		if !is_vec2 {
			return 0, false
		}
		return vec2_length(vec2_sub(at2, from)), true
	case Vec3:
		at3, is_vec3 := at.(Vec3)
		if !is_vec3 {
			return 0, false
		}
		return vec3_length(vec3_sub(at3, from)), true
	}
	return 0, false
}

query_spatial_field :: proc(indexes: []Index_Req, thing: string) -> (field: string, ok: bool) {
	found := false
	for req in indexes {
		if req.kind != .Spatial || req.thing != thing {
			continue
		}
		if found {
			return "", false
		}
		field = req.field
		found = true
	}
	return field, found
}
