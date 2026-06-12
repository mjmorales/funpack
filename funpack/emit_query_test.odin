// The §08 §3 state-query artifact carry (schema v9, docs/artifact-format.md
// §16): the [queries] section — one record per `query` declaration carrying
// its fn-mold signature, its §05 §3 @index/@spatial requirement `index KIND
// THING FIELD` sub-records, and its §2.7 body node run — and the byte
// disciplines the bump rides on: a query-free project emits the constant
// `[queries 0]` tail (every section emits its header, §3), and the new
// `index` sub-record keyword frames under the funpack reader's lead-line
// discipline so every section count still reconciles.
package funpack

import "core:strings"
import "core:testing"

// emit_queries_section parses a source and renders its [queries] section
// bytes — the one section the v9 carry adds — so each fixture pins the exact
// emitted lines without a full project tree.
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
	// AC (artifact carries queries): the §08 §3 exemplar shape — a @spatial and
	// an @index requirement prefixing a query — emits the fn-mold lead line
	// (param/index/body counts + span), the `param` lines, one `index KIND
	// THING FIELD` line per declared requirement in authored order, and the
	// §2.7 body node run. Byte-exact, the golden-emission discipline.
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
	// AC (constant tail for query-free projects): a source declaring no query
	// emits the bare `[queries 0]` header — every section emits its header
	// even at N = 0 (§3), so a v9 reader always sees the fixed section run.
	section := emit_queries_section(t, "data Board { w: Int }\n")
	testing.expect_value(t, section, "[queries 0]\n")
}

@(test)
test_index_sub_record_frames_under_lead_line_reader :: proc(t: ^testing.T) {
	// AC (reader discipline): `index` is a sub-record keyword (§2.1), so a
	// [queries] section carrying requirement lines still reconciles its
	// declared top-level count under the funpack reader — the same lead-line
	// discipline every other sub-record frames by.
	testing.expect(t, is_sub_record_line("index index Enemy cell"))
	testing.expect(t, is_sub_record_line("index spatial Enemy pos"))
	doc_text :=
		"funpack-artifact 15\n" +
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
	// AC (deterministic emission, spec §29): two renders of a [queries] section
	// are byte-identical — the carry adds no field whose value depends on when
	// or where it was emitted.
	source := "@spatial(Ball.pos)\n" +
		"query balls_within(origin: Vec2, r: Fixed) -> Fixed {\n" +
		"  return r\n" +
		"}\n"
	first := emit_queries_section(t, source)
	second := emit_queries_section(t, source)
	testing.expect(t, first == second)
	testing.expect(t, len(first) > 0)
}
