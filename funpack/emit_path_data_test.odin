package funpack

import "core:strings"
import "core:testing"

emit_data_section_imported :: proc(t: ^testing.T, source: string, schema_source: string) -> string {
	ast, parse_err := stage_parse(stage_lex(source))
	testing.expect_value(t, parse_err, Parse_Error.None)
	schema_ast, schema_parse_err := stage_parse(stage_lex(schema_source))
	testing.expect_value(t, schema_parse_err, Parse_Error.None)
	if parse_err != .None || schema_parse_err != .None {
		return ""
	}
	b := strings.builder_make(context.temp_allocator)
	emit_data(&b, ast, Imported_Decls{things = schema_ast.things[:]})
	return strings.to_string(b)
}

@(test)
test_emit_path_projection_from_own_thing_field :: proc(t: ^testing.T) {
	section := emit_data_section(t,
		"thing Hunter {\n" +
		"  pos:  Vec2\n" +
		"  path: Path = Path{steps: [], cost: 0.0}\n" +
		"}\n")
	expected :=
		"[data 1]\n" +
		"data Path 2 false\n" +
		"field steps [Vec2] -\n" +
		"field cost Fixed -\n"
	testing.expect_value(t, section, expected)
}

@(test)
test_emit_path_projection_from_imported_thing_field :: proc(t: ^testing.T) {
	section := emit_data_section_imported(t,
		"data Score { points: Int }\n",
		"thing Rabbit {\n" +
		"  pos:    Vec2\n" +
		"  path:   Path = Path{steps: [], cost: 0.0}\n" +
		"  hidden: Bool = false\n" +
		"}\n")
	expected :=
		"[data 2]\n" +
		"data Score 1 false\n" +
		"field points Int -\n" +
		"data Path 2 false\n" +
		"field steps [Vec2] -\n" +
		"field cost Fixed -\n"
	testing.expect_value(t, section, expected)
}

@(test)
test_emit_no_path_field_no_projection :: proc(t: ^testing.T) {
	section := emit_data_section(t,
		"data Board {\n" +
		"  w: Int\n" +
		"  h: Int\n" +
		"}\n")
	expected :=
		"[data 1]\n" +
		"data Board 2 false\n" +
		"field w Int -\n" +
		"field h Int -\n"
	testing.expect_value(t, section, expected)
}

@(test)
test_emit_settings_and_path_projection_fixed_order :: proc(t: ^testing.T) {
	section := emit_data_section(t,
		"thing Menu {\n" +
		"  settings: Settings\n" +
		"}\n" +
		"thing Hunter {\n" +
		"  path: Path = Path{steps: [], cost: 0.0}\n" +
		"}\n")
	expected :=
		"[data 3]\n" +
		"data Settings 3 false\n" +
		"field volume Int -\n" +
		"field fullscreen Bool -\n" +
		"field access AccessOpts -\n" +
		"data AccessOpts 1 false\n" +
		"field reduce_motion Bool -\n" +
		"data Path 2 false\n" +
		"field steps [Vec2] -\n" +
		"field cost Fixed -\n"
	testing.expect_value(t, section, expected)
}
