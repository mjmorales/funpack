// The expression-evaluation junction for the list-combinator surface and the
// §11 §2 Body.apply_impulse battery (evaluate.odin: eval_call's len/combinator
// arm, the §02 §4 UFCS method→free-call lowering, eval_body_apply_impulse).
// Each construct is exercised at its evaluation junction through
// run_test_pipeline (the lex→…→evaluate driver), so the typecheck-admits and
// evaluator-evaluates halves both prove out — the combinator forms the example
// queries and behavior steps reach, pinned as deliberate units beneath the
// golden games.
package funpack

import "core:testing"

// LIST_COMBINATOR_HEADER imports the combinators the UFCS forms reach as
// methods — len/is_empty/contains must be in scope for both the free-call and
// the method-call form (the §02 §4 lowering routes the method to the free call).
LIST_COMBINATOR_HEADER :: "import engine.list.{len, is_empty, contains}\n"

// ── len evaluates to an Int ───────────────────────────────────────────────────

@(test)
test_len_evaluates_to_int_length :: proc(t: ^testing.T) {
	// len(list) -> Int evaluates to the element count and compares Int-equal to
	// the literal length and to another len read — the yard length-read shape.
	source := LIST_COMBINATOR_HEADER + "test \"len reads the count\" {\n" +
		"  assert len([1, 2]) == 2\n" +
		"  assert len([1, 2]) == len([3, 4])\n" +
		"  assert len([]) == 0\n" +
		"}\n"
	report, err := run_test_pipeline(source)
	testing.expect_value(t, err, Pipeline_Error.None)
	testing.expect_value(t, report.passed, 3)
	testing.expect_value(t, report.failed, 0)
}

@(test)
test_len_mismatch_is_a_counted_failure :: proc(t: ^testing.T) {
	// The negative junction: len([1,2]) is 2, not 3, so the assert FAILS (counted,
	// exit 1) rather than fail-closing — proving len is evaluated, not skipped to a
	// compile-class refusal.
	source := LIST_COMBINATOR_HEADER + "test \"len is wrong\" {\n  assert len([1, 2]) == 3\n}\n"
	report, err := run_test_pipeline(source)
	testing.expect_value(t, err, Pipeline_Error.None)
	testing.expect_value(t, report.passed, 0)
	testing.expect_value(t, report.failed, 1)
	testing.expect_value(t, report.exit_code, 1)
}

// ── §02 §4 list-combinator UFCS lowers to the free call ───────────────────────

@(test)
test_list_combinator_ufcs_lowers_to_free_call :: proc(t: ^testing.T) {
	// The method form lowers to the free call (§02 §4 "same function"): x.len()
	// types and evaluates as len(x), and likewise for is_empty/contains.
	source := LIST_COMBINATOR_HEADER + "test \"ufcs forms evaluate\" {\n" +
		"  assert [1, 2].len() == 2\n" +
		"  assert [1, 2].is_empty() == false\n" +
		"  assert [1, 2].contains(1) == true\n" +
		"}\n"
	report, err := run_test_pipeline(source)
	testing.expect_value(t, err, Pipeline_Error.None)
	testing.expect_value(t, report.passed, 3)
	testing.expect_value(t, report.failed, 0)
}

@(test)
test_list_combinator_ufcs_agrees_with_free_call :: proc(t: ^testing.T) {
	// The method form and the free-call form are the SAME function, so they
	// evaluate to equal values — [1,2].len() == len([1,2]) is the identity, and a
	// `let`-bound list (stage_evaluate_indexed binds Let_Node names) resolves the
	// receiver too, not just a literal.
	source := LIST_COMBINATOR_HEADER + "test \"ufcs equals free\" {\n" +
		"  let xs = [1, 2, 3]\n" +
		"  assert [1, 2].len() == len([1, 2])\n" +
		"  assert xs.len() == 3\n" +
		"  assert xs.contains(2) == true\n" +
		"}\n"
	report, err := run_test_pipeline(source)
	testing.expect_value(t, err, Pipeline_Error.None)
	testing.expect_value(t, report.passed, 3)
	testing.expect_value(t, report.failed, 0)
}

// ── §11 §2 Body.apply_impulse accumulates the Vec2 impulse ────────────────────

@(test)
test_apply_impulse_accumulates_and_chains :: proc(t: ^testing.T) {
	// apply_impulse adds the Vec2 onto the body's impulse and chains: two pushes
	// sum (1,0)+(0,2)=(1,2), exactly the yard accumulation, off a Body that omits
	// the impulse field (so the first push accumulates from the schema zero
	// default).
	source := "import engine.math.{Vec2}\n" +
		"import engine.physics.{Body, BodyKind, Shape2}\n" +
		"enum Layer: CollisionLayer { Player, Wall }\n" +
		"test \"impulse sums\" {\n" +
		"  let b = Body{ kind: BodyKind::Dynamic, shape: Shape2::Circle{radius: 5.0}, layer: Layer::Player, mask: [Layer::Wall] }\n" +
		"  let pushed = b.apply_impulse(Vec2{x: 1.0, y: 0.0}).apply_impulse(Vec2{x: 0.0, y: 2.0})\n" +
		"  assert pushed.impulse == Vec2{x: 1.0, y: 2.0}\n" +
		"}\n"
	report, err := run_test_pipeline(source)
	testing.expect_value(t, err, Pipeline_Error.None)
	testing.expect_value(t, report.passed, 1)
	testing.expect_value(t, report.failed, 0)
}

@(test)
test_apply_impulse_from_zero_default_reads_pushed_value :: proc(t: ^testing.T) {
	// A single push over the schema zero default reads back exactly the pushed
	// value — the omitted-impulse default is the zero Vec2 (read off the surface
	// schema), not nil/fail-closed.
	source := "import engine.math.{Vec2}\n" +
		"import engine.physics.{Body, BodyKind, Shape2}\n" +
		"enum Layer: CollisionLayer { Player, Wall }\n" +
		"test \"single push\" {\n" +
		"  let b = Body{ kind: BodyKind::Dynamic, shape: Shape2::Circle{radius: 5.0}, layer: Layer::Player, mask: [Layer::Wall] }\n" +
		"  assert b.apply_impulse(Vec2{x: 3.0, y: -4.0}).impulse == Vec2{x: 3.0, y: -4.0}\n" +
		"}\n"
	report, err := run_test_pipeline(source)
	testing.expect_value(t, err, Pipeline_Error.None)
	testing.expect_value(t, report.passed, 1)
	testing.expect_value(t, report.failed, 0)
}
