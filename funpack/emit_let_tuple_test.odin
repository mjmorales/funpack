package funpack

import "core:strings"
import "core:testing"

LET_TUPLE_HEADER :: "import engine.rand.{Rng, range}\n"

emit_fn_body_nodes :: proc(t: ^testing.T, source: string, fn_name: string) -> string {
	ast, parse_err := stage_parse(stage_lex(source))
	testing.expect_value(t, parse_err, Parse_Error.None)
	if parse_err != .None {
		return ""
	}
	fn, found := find_fn(ast, fn_name)
	testing.expect(t, found)
	if !found {
		return ""
	}
	b := strings.builder_make(context.temp_allocator)
	emit_body(&b, fn.body)
	return strings.to_string(b)
}

@(test)
test_emit_let_tuple_node_bytes :: proc(t: ^testing.T) {
	source := strings.concatenate({LET_TUPLE_HEADER,
		"fn probe_tuple_let(rng: Rng) -> Int {\n" +
		"  let (v, r1) = rng.range(0, 10)\n" +
		"  return v\n" +
		"}\n"}, context.temp_allocator)
	nodes := emit_fn_body_nodes(t, source, "probe_tuple_let")
	expected :=
		"node let_tuple 2 v r1 1\n" +
		"node call 3\n" +
		"node field range 1\n" +
		"node name rng 0\n" +
		"node int 0 0\n" +
		"node int 10 0\n" +
		"node return 1\n" +
		"node name v 0\n"
	testing.expect_value(t, nodes, expected)
}

@(test)
test_emit_let_tuple_forest_well_formed_and_deterministic :: proc(t: ^testing.T) {
	source := strings.concatenate({LET_TUPLE_HEADER,
		"fn probe_tuple_let(rng: Rng) -> Int {\n" +
		"  let (v, r1) = rng.range(0, 10)\n" +
		"  return v\n" +
		"}\n"}, context.temp_allocator)
	first := emit_fn_body_nodes(t, source, "probe_tuple_let")
	second := emit_fn_body_nodes(t, source, "probe_tuple_let")
	testing.expect(t, first == second)
	nodes := split_artifact_lines(first)
	testing.expect(t, body_forest_is_well_formed(nodes, 2))
}

@(test)
test_emit_let_tuple_three_binders_bytes :: proc(t: ^testing.T) {
	source := strings.concatenate({LET_TUPLE_HEADER,
		"fn three(rng: Rng) -> Int {\n" +
		"  let (a, b, c) = (1, 2, 3)\n" +
		"  return a + b + c\n" +
		"}\n"}, context.temp_allocator)
	nodes := emit_fn_body_nodes(t, source, "three")
	testing.expect(t, strings.has_prefix(nodes, "node let_tuple 3 a b c 1\n"))
	forest := split_artifact_lines(nodes)
	testing.expect(t, body_forest_is_well_formed(forest, 2))
}

@(test)
test_emit_single_name_let_unchanged :: proc(t: ^testing.T) {
	source := strings.concatenate({LET_TUPLE_HEADER,
		"fn single() -> Int {\n" +
		"  let n = 7\n" +
		"  return n\n" +
		"}\n"}, context.temp_allocator)
	nodes := emit_fn_body_nodes(t, source, "single")
	expected :=
		"node let n 1\n" +
		"node int 7 0\n" +
		"node return 1\n" +
		"node name n 0\n"
	testing.expect_value(t, nodes, expected)
}
