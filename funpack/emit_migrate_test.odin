package funpack

import "core:strings"
import "core:testing"

emit_data_section :: proc(t: ^testing.T, source: string) -> string {
	ast, parse_err := stage_parse(stage_lex(source))
	testing.expect_value(t, parse_err, Parse_Error.None)
	if parse_err != .None {
		return ""
	}
	b := strings.builder_make(context.temp_allocator)
	emit_data(&b, ast, Imported_Decls{})
	return strings.to_string(b)
}

@(test)
test_emit_data_migrate_lines_carry_all_three_forms :: proc(t: ^testing.T) {
	section := emit_data_section(t,
		"data Player {\n" +
		"  @migrate(from: \"old_pos\")\n" +
		"  pos: Int\n" +
		"  @migrate(with: lift)\n" +
		"  hp: Int\n" +
		"  @migrate(from: \"speed\", with: to_velocity)\n" +
		"  vel: Int\n" +
		"  score: Int = 0\n" +
		"}\n" +
		"@migrate(from: \"OldBoard\")\n" +
		"data Board { w: Int }\n")
	expected :=
		"[data 2]\n" +
		"data Player 4 false\n" +
		"field pos Int -\n" +
		"migrate old_pos -\n" +
		"field hp Int -\n" +
		"migrate - lift\n" +
		"field vel Int -\n" +
		"migrate speed to_velocity\n" +
		"field score Int =0\n" +
		"data Board 1 false\n" +
		"migrate OldBoard -\n" +
		"field w Int -\n"
	testing.expect_value(t, section, expected)
}

@(test)
test_emit_data_without_migrations_is_v7_shape :: proc(t: ^testing.T) {
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
test_migrate_sub_record_frames_under_lead_line_reader :: proc(t: ^testing.T) {
	testing.expect(t, is_sub_record_line("migrate old_pos -"))
	testing.expect(t, is_sub_record_line("migrate - lift"))
	doc_text :=
		"funpack-artifact 19\n" +
		"[data 2]\n" +
		"data Player 1 false\n" +
		"field pos Int -\n" +
		"migrate old_pos -\n" +
		"data Board 1 false\n" +
		"migrate OldBoard -\n" +
		"field w Int -\n"
	doc, err := parse_artifact(doc_text)
	testing.expect_value(t, err, Artifact_Parse_Error.None)
	testing.expect_value(t, doc.schema_version, ARTIFACT_SCHEMA_VERSION)
	section, found := artifact_find_section(doc, "data")
	testing.expect(t, found)
	testing.expect_value(t, section.count, 2)
}

@(test)
test_emit_migrated_artifact_deterministic :: proc(t: ^testing.T) {
	source := "data Player {\n" +
		"  @migrate(from: \"old_hp\", with: lift)\n" +
		"  hp: Int\n" +
		"}\n"
	first := emit_data_section(t, source)
	second := emit_data_section(t, source)
	testing.expect(t, first == second)
	testing.expect(t, len(first) > 0)
}
