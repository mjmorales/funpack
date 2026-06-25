// The §2.7 tuple-`let` body-node golden (schema v19, ADR
// 2026-06-24-let-tuple-destructure-binding): a `let (a, b, …) = expr` destructure
// in a GAMEPLAY-executable body now serializes to the wire as the `let_tuple` node
// KIND, where v18 refused it before emission (the removed let_tuple_wire_gate). The
// node is count-driven both ways: a binder-count-prefixed name list rides BEFORE the
// trailing generic child count (the single value subtree), so node_child_count and
// node_scalar_fields read it the generic way with no special case (the `string`/`arm`
// exceptions untouched). These tests pin the exact emitted bytes for the canonical
// rng.range destructure, prove the forest reconciles under the funpack body reader,
// prove emission is deterministic (double-emit byte-identical), and guard that the
// single-name `let` encoding is unchanged. Self-contained — no golden checkout — so a
// missing sibling tree never silences the v19 contract.
package funpack

import "core:strings"
import "core:testing"

// LET_TUPLE_HEADER declares the minimal surface a tuple-`let` body fixture needs:
// the engine.rand Rng handle and its range draw, whose return-position `(Int, Rng)`
// tuple is the destructure the v19 wire carries. It is self-contained so the body
// tests run without a golden checkout.
LET_TUPLE_HEADER :: "import engine.rand.{Rng, range}\n"

// emit_fn_body_nodes parses a source, finds a top-level fn, and serializes its body
// to the §2.7 node run — the same emit_body the artifact carries — so a fixture pins
// the exact emitted lines without a full project tree.
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
	// AC (the v19 wire carries the destructure): a gameplay fn doing
	// `let (v, r1) = rng.range(0, 10)` emits the `let_tuple` node line
	// `node let_tuple 2 v r1 1` — kind, BINDER_COUNT 2, the two binders in source
	// order, then the trailing generic child count 1 — over the single value subtree
	// (the rng.range call, a §02 §4 UFCS lowering to `field range` over `rng`).
	// Byte-exact: the runtime decoder is implemented against these exact bytes.
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
	// AC (count-driven reconciliation + determinism, spec §29): the emitted body is
	// exactly two top-level statement subtrees (the tuple-`let` and the `return`)
	// with no leftover line — the `let_tuple` node's trailing child count is read the
	// generic way, so the funpack body-forest reader reconciles it with no special
	// case — and two emissions are byte-identical (no when/where-dependent field).
	source := strings.concatenate({LET_TUPLE_HEADER,
		"fn probe_tuple_let(rng: Rng) -> Int {\n" +
		"  let (v, r1) = rng.range(0, 10)\n" +
		"  return v\n" +
		"}\n"}, context.temp_allocator)
	first := emit_fn_body_nodes(t, source, "probe_tuple_let")
	second := emit_fn_body_nodes(t, source, "probe_tuple_let")
	testing.expect(t, first == second)
	nodes := split_artifact_lines(first)
	// Two top-level statements: the tuple-`let` subtree and the `return` subtree.
	testing.expect(t, body_forest_is_well_formed(nodes, 2))
}

@(test)
test_emit_let_tuple_three_binders_bytes :: proc(t: ^testing.T) {
	// AC (BINDER_COUNT is N, not fixed at 2): a three-binder destructure over a
	// 3-tuple emits `node let_tuple 3 a b c 1` — the count token is the actual
	// arity and every binder rides before the trailing child count. The tuple
	// literal `(1, 2, 3)` is the value subtree, proving the binder list and the
	// value child compose under the count-driven reader at N = 3.
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
	// AC (single-name `let` encoding is byte-stable): a v19 emitter still writes a
	// single-name `let n = e` as `node let NAME 1` over its value subtree — the
	// tuple form takes the distinct `let_tuple` KIND, so the existing single-name
	// wire is untouched (no discriminator field added to the `let` line).
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
