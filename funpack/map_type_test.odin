package funpack

import "core:testing"

@(test)
test_map_type_node_in_union :: proc(t: ^testing.T) {
	m := map_of(user_type_of("Cell", .Data), user_type_of("Tile", .Enum))
	node, is_map := m.(^Map_Type)
	testing.expect(t, is_map)
	if is_map {
		key, key_is_user := node.key.(^User_Type)
		value, value_is_user := node.value.(^User_Type)
		testing.expect(t, key_is_user)
		testing.expect(t, value_is_user)
		if key_is_user {
			testing.expect_value(t, key.name, "Cell")
		}
		if value_is_user {
			testing.expect_value(t, value.name, "Tile")
		}
	}
}

@(test)
test_map_compatibility_is_structural :: proc(t: ^testing.T) {
	int_bool := map_of(Ground_Type.Int, Ground_Type.Bool)
	same := map_of(Ground_Type.Int, Ground_Type.Bool)
	other_value := map_of(Ground_Type.Int, Ground_Type.Fixed)
	other_key := map_of(Ground_Type.Fixed, Ground_Type.Bool)
	empty := map_of(nil, nil)
	testing.expect(t, types_compatible(int_bool, same))
	testing.expect(t, !types_compatible(int_bool, other_value))
	testing.expect(t, !types_compatible(int_bool, other_key))
	testing.expect(t, types_compatible(empty, int_bool))
	testing.expect(t, types_compatible(int_bool, empty))
	testing.expect(t, !types_compatible(int_bool, list_of(Ground_Type.Int)))
	testing.expect(t, !types_compatible(int_bool, option_of(Ground_Type.Int)))
	testing.expect(t, !types_compatible(int_bool, tuple_of({Ground_Type.Int, Ground_Type.Bool})))
}

@(test)
test_map_type_ref_resolves_two_params :: proc(t: ^testing.T) {
	ground := Type_Ref {
		name = "Map",
		args = {Type_Ref{name = "Int"}, Type_Ref{name = "Bool"}},
	}
	resolved := resolve_type_ref(Type_Env{}, Bindings{}, ground)
	node, is_map := resolved.(^Map_Type)
	testing.expect(t, is_map)
	if is_map {
		testing.expect(t, is_ground(node.key, .Int))
		testing.expect(t, is_ground(node.value, .Bool))
	}

	type_vars := Type_Ref {
		name = "Map",
		args = {Type_Ref{name = "K"}, Type_Ref{name = "V"}},
	}
	var_resolved := resolve_type_ref(Type_Env{}, Bindings{}, type_vars)
	var_node, var_is_map := var_resolved.(^Map_Type)
	testing.expect(t, var_is_map)
	if var_is_map {
		testing.expect(t, var_node.key == nil)
		testing.expect(t, var_node.value == nil)
	}
}

@(test)
test_map_surface_type_string :: proc(t: ^testing.T) {
	testing.expect_value(
		t,
		surface_type_string(map_of(user_type_of("Cell", .Data), user_type_of("Tile", .Enum))),
		"Map[Cell, Tile]",
	)
	testing.expect_value(t, surface_type_string(map_of(nil, nil)), "Map[_, _]")
}

@(test)
test_engine_map_import_binds_map_type :: proc(t: ^testing.T) {
	ast, parse_err := stage_parse(stage_lex("import engine.map.{Map}\n"))
	testing.expect_value(t, parse_err, Parse_Error.None)
	bindings, err := resolve_imports(ast)
	testing.expect_value(t, err, Type_Error.None)
	map_binding, has_map := bindings.names["Map"]
	testing.expect(t, has_map)
	testing.expect_value(t, map_binding.module, "engine.map")
	testing.expect_value(t, map_binding.kind, Decl_Kind.Type_Name)
}

@(test)
test_map_typed_field_resolves_friction_repro :: proc(t: ^testing.T) {
	source :=
		"import engine.map.{Map}\n" +
		"import engine.grid.{Cell}\n" +
		"enum Tile { Floor, Wall }\n" +
		"data Dungeon { tiles: Map[Cell, Tile] }\n" +
		"test \"map-typed field resolves\" {\n\tassert 1 == 1\n}\n"
	report, err := run_test_pipeline(source)
	testing.expect_value(t, err, Pipeline_Error.None)
	testing.expect_value(t, report.passed, 1)
	testing.expect_value(t, report.failed, 0)
}
