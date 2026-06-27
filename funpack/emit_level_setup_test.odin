package funpack

import "core:strings"
import "core:testing"

level_setup_thing_fixture :: proc() -> []Thing_Node {
	fields := make([]Field_Decl, 5, context.temp_allocator)
	fields[0] = Field_Decl{name = "pos", type = Type_Ref{name = "Vec2"}}
	fields[1] = Field_Decl{name = "hp", type = Type_Ref{name = "Int"}}
	fields[2] = Field_Decl{name = "alert", type = Type_Ref{name = "Bool"}}
	fields[3] = Field_Decl{name = "rate", type = Type_Ref{name = "Fixed"}}
	ref_args := make([]Type_Ref, 1, context.temp_allocator)
	ref_args[0] = Type_Ref{name = "Door"}
	fields[4] = Field_Decl{name = "gate", type = Type_Ref{name = "Ref", args = ref_args}}
	things := make([]Thing_Node, 1, context.temp_allocator)
	things[0] = Thing_Node{name = "Guard", fields = fields}
	return things
}

level_setup_batch_fixture :: proc() -> Level_Spawn_Batch {
	params := make([]Baked_Param, 4, context.temp_allocator)
	params[0] = Baked_Param{field = "hp", value = to_fixed(7)}
	params[1] = Baked_Param{field = "alert", value = to_fixed(1)}
	params[2] = Baked_Param{field = "rate", value = Fixed(10737418240)}
	params[3] = Baked_Param{field = "gate", is_ref = true, ref_id = 42}
	spawns := make([]Baked_Spawn, 2, context.temp_allocator)
	spawns[0] = Baked_Spawn {
		thing_type = "Guard",
		id         = 1,
		has_facing = true,
		pos        = Baked_Coord{dim = .D2, x = to_fixed(24), y = to_fixed(8)},
		facing     = Fixed(6746518852),
		params     = params,
	}
	spawns[1] = Baked_Spawn {
		thing_type = "Guard",
		id         = 0,
		pos        = Baked_Coord{dim = .D2, x = to_fixed(8), y = to_fixed(24)},
	}
	return Level_Spawn_Batch{fn_name = "fort_spawns", spawns = spawns}
}

@(test)
test_emit_level_setup_encodes_rows_by_declared_type :: proc(t: ^testing.T) {
	b := strings.builder_make(context.temp_allocator)
	emit_level_setup(&b, level_setup_batch_fixture(), level_setup_thing_fixture(), nil)
	expected :=
		"[setup 2]\n" +
		"spawn Guard 5\n" +
		"set pos =vec2 103079215104 34359738368\n" +
		"set facing =6746518852\n" +
		"set hp =7\n" +
		"set alert =true\n" +
		"set rate =10737418240\n" +
		"spawn Guard 1\n" +
		"set pos =vec2 34359738368 103079215104\n"
	testing.expect_value(t, strings.to_string(b), expected)
}

@(test)
test_emit_level_setup_unresolved_schema_falls_back_to_fixed_bits :: proc(t: ^testing.T) {
	b := strings.builder_make(context.temp_allocator)
	emit_level_setup(&b, level_setup_batch_fixture(), nil, nil)
	testing.expect(t, strings.contains(strings.to_string(b), "set hp =30064771072\n"))
}

@(test)
test_level_setup_batch_detects_lone_extern_call :: proc(t: ^testing.T) {
	source := "fn setup() -> [Spawn] {\n  return fort_spawns()\n}\n"
	ast, parse_err := stage_parse(stage_lex(source))
	testing.expect_value(t, parse_err, Parse_Error.None)
	batches := make([]Level_Spawn_Batch, 1, context.temp_allocator)
	batches[0] = level_setup_batch_fixture()
	batch, found := level_setup_batch(ast, batches)
	testing.expect(t, found)
	testing.expect_value(t, batch.fn_name, "fort_spawns")
	_, none_found := level_setup_batch(ast, nil)
	testing.expect(t, !none_found)

	literal := "fn setup() -> [Spawn] {\n  return [Spawn(Guard{pos: Vec2{x: 1.0, y: 1.0}})]\n}\n"
	literal_ast, literal_err := stage_parse(stage_lex(literal))
	testing.expect_value(t, literal_err, Parse_Error.None)
	_, literal_found := level_setup_batch(literal_ast, batches)
	testing.expect(t, !literal_found)
}

@(test)
test_emit_level_setup_deterministic :: proc(t: ^testing.T) {
	first := strings.builder_make(context.temp_allocator)
	emit_level_setup(&first, level_setup_batch_fixture(), level_setup_thing_fixture(), nil)
	second := strings.builder_make(context.temp_allocator)
	emit_level_setup(&second, level_setup_batch_fixture(), level_setup_thing_fixture(), nil)
	testing.expect(t, strings.to_string(first) == strings.to_string(second))
}
