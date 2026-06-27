package funpack

import "core:strings"
import "core:testing"

emit_queries_section :: proc(t: ^testing.T, source: string) -> string {
	ast, parse_err := stage_parse(stage_lex(source))
	testing.expect_value(t, parse_err, Parse_Error.None)
	if parse_err != .None {
		return ""
	}
	b := strings.builder_make(context.temp_allocator)
	emit_queries(&b, ast, "scratch")
	return strings.to_string(b)
}

@(test)
test_emit_queries_record_carries_signature_indexes_and_body :: proc(t: ^testing.T) {
	section := emit_queries_section(t,
		"@index(Enemy.cell)\n" +
		"@spatial(Enemy.pos)\n" +
		"query nearest_cell(origin: Vec2, r: Fixed) -> Vec2 {\n" +
		"  return origin\n" +
		"}\n")
	expected :=
		"[queries 1]\n" +
		"query nearest_cell 2 return:Vec2 2 1 span:scratch:3\n" +
		"param origin Vec2\n" +
		"param r Fixed\n" +
		"index index Enemy cell\n" +
		"index spatial Enemy pos\n" +
		"node return 1\n" +
		"node name origin 0\n"
	testing.expect_value(t, section, expected)
}

@(test)
test_emit_queries_empty_section_for_query_free_source :: proc(t: ^testing.T) {
	section := emit_queries_section(t, "data Board { w: Int }\n")
	testing.expect_value(t, section, "[queries 0]\n")
}

@(test)
test_index_sub_record_frames_under_lead_line_reader :: proc(t: ^testing.T) {
	testing.expect(t, is_sub_record_line("index index Enemy cell"))
	testing.expect(t, is_sub_record_line("index spatial Enemy pos"))
	doc_text :=
		"funpack-artifact 19\n" +
		"[queries 2]\n" +
		"query near 1 return:Vec2 1 1 span:scratch:2\n" +
		"param origin Vec2\n" +
		"index spatial Enemy pos\n" +
		"node return 1\n" +
		"node name origin 0\n" +
		"query keyed 1 return:Int 1 1 span:scratch:6\n" +
		"param side Side\n" +
		"index index Paddle side\n" +
		"node return 1\n" +
		"node int 0 0\n"
	doc, err := parse_artifact(doc_text)
	testing.expect_value(t, err, Artifact_Parse_Error.None)
	testing.expect_value(t, doc.schema_version, ARTIFACT_SCHEMA_VERSION)
	section, found := artifact_find_section(doc, "queries")
	testing.expect(t, found)
	testing.expect_value(t, section.count, 2)
}

@(test)
test_emit_queries_deterministic :: proc(t: ^testing.T) {
	source := "@spatial(Ball.pos)\n" +
		"query balls_within(origin: Vec2, r: Fixed) -> Fixed {\n" +
		"  return r\n" +
		"}\n"
	first := emit_queries_section(t, source)
	second := emit_queries_section(t, source)
	testing.expect(t, first == second)
	testing.expect(t, len(first) > 0)
}
