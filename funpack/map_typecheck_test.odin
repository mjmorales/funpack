package funpack

import "core:testing"

check_map_expr :: proc(import_header, expr_source: string) -> (type: Type, err: Type_Error) {
	ast, _ := stage_parse(stage_lex(import_header))
	bindings, _ := resolve_imports(ast)
	p := Parser{tokens = stage_lex(expr_source)}
	expr, parse_err := parse_expression(&p)
	if parse_err != .None {
		return nil, .Unsupported_Expr
	}
	ctx := Check_Ctx {
		bindings = bindings,
		scope    = make(Scope, context.temp_allocator),
	}
	return expr_check(ctx, expr)
}

MAP_HEADER :: "import engine.map.{Map, empty, len, get, has, set, remove, keys, values}\n"

@(test)
test_engine_map_full_import_resolves :: proc(t: ^testing.T) {
	ast, parse_err := stage_parse(stage_lex(MAP_HEADER))
	testing.expect_value(t, parse_err, Parse_Error.None)
	bindings, err := resolve_imports(ast)
	testing.expect_value(t, err, Type_Error.None)
	for name in ([]string{"Map", "empty", "len", "get", "has", "set", "remove", "keys", "values"}) {
		_, bound := bindings.names[name]
		testing.expectf(t, bound, "name %q binds from engine.map", name)
	}
	get_binding := bindings.names["get"]
	testing.expect_value(t, get_binding.module, "engine.list")
}

@(test)
test_map_empty_constructor_types_undetermined :: proc(t: ^testing.T) {
	for form in ([]string{"empty()", "Map.empty()"}) {
		type, err := check_map_expr(MAP_HEADER, form)
		testing.expect_value(t, err, Type_Error.None)
		node, is_map := type.(^Map_Type)
		testing.expectf(t, is_map, "%q types as a Map", form)
		if is_map {
			testing.expect(t, node.key == nil)
			testing.expect(t, node.value == nil)
		}
	}
}

@(test)
test_map_set_infers_kv_from_args :: proc(t: ^testing.T) {
	type, err := check_map_expr(MAP_HEADER, "empty().set(1, true)")
	testing.expect_value(t, err, Type_Error.None)
	node, is_map := type.(^Map_Type)
	testing.expect(t, is_map)
	if is_map {
		testing.expect(t, is_ground(node.key, .Int))
		testing.expect(t, is_ground(node.value, .Bool))
	}
}

@(test)
test_map_get_returns_option_of_value :: proc(t: ^testing.T) {
	type, err := check_map_expr(MAP_HEADER, "empty().set(1, true).get(1)")
	testing.expect_value(t, err, Type_Error.None)
	option, is_option := type.(^Option_Type)
	testing.expect(t, is_option)
	if is_option {
		testing.expect(t, is_ground(option.elem, .Bool))
	}
}

@(test)
test_map_get_wrong_key_type_rejected :: proc(t: ^testing.T) {
	_, err := check_map_expr(MAP_HEADER, "empty().set(1, true).get(2.0)")
	testing.expect_value(t, err, Type_Error.Type_Mismatch)
}

@(test)
test_map_has_returns_bool :: proc(t: ^testing.T) {
	type, err := check_map_expr(MAP_HEADER, "empty().set(1, true).has(1)")
	testing.expect_value(t, err, Type_Error.None)
	testing.expect(t, is_ground(type, .Bool))
}

@(test)
test_map_remove_preserves_map_type :: proc(t: ^testing.T) {
	type, err := check_map_expr(MAP_HEADER, "empty().set(1, true).remove(1)")
	testing.expect_value(t, err, Type_Error.None)
	node, is_map := type.(^Map_Type)
	testing.expect(t, is_map)
	if is_map {
		testing.expect(t, is_ground(node.key, .Int))
		testing.expect(t, is_ground(node.value, .Bool))
	}
}

@(test)
test_map_keys_and_values_project_lists :: proc(t: ^testing.T) {
	keys_type, keys_err := check_map_expr(MAP_HEADER, "empty().set(1, true).keys()")
	testing.expect_value(t, keys_err, Type_Error.None)
	keys_list, keys_is_list := keys_type.(^List_Type)
	testing.expect(t, keys_is_list)
	if keys_is_list {
		testing.expect(t, is_ground(keys_list.elem, .Int))
	}

	values_type, values_err := check_map_expr(MAP_HEADER, "empty().set(1, true).values()")
	testing.expect_value(t, values_err, Type_Error.None)
	values_list, values_is_list := values_type.(^List_Type)
	testing.expect(t, values_is_list)
	if values_is_list {
		testing.expect(t, is_ground(values_list.elem, .Bool))
	}
}

@(test)
test_map_len_returns_int :: proc(t: ^testing.T) {
	type, err := check_map_expr(MAP_HEADER, "empty().set(1, true).len()")
	testing.expect_value(t, err, Type_Error.None)
	testing.expect(t, is_ground(type, .Int))
}

@(test)
test_surface_methods_for_receiver_lists_map_methods :: proc(t: ^testing.T) {
	hint := surface_methods_for_receiver(map_of(Ground_Type.Int, Ground_Type.Bool))
	testing.expect_value(t, hint, "available methods: get, has, keys, len, remove, set, values")
}
