package funpack

import "core:testing"

LIST_COMBINATOR_HEADER :: "import engine.list.{len, is_empty, contains}\n"

@(test)
test_len_evaluates_to_int_length :: proc(t: ^testing.T) {
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
	source := LIST_COMBINATOR_HEADER + "test \"len is wrong\" {\n  assert len([1, 2]) == 3\n}\n"
	report, err := run_test_pipeline(source)
	testing.expect_value(t, err, Pipeline_Error.None)
	testing.expect_value(t, report.passed, 0)
	testing.expect_value(t, report.failed, 1)
	testing.expect_value(t, report.exit_code, 1)
}

@(test)
test_list_combinator_ufcs_lowers_to_free_call :: proc(t: ^testing.T) {
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

@(test)
test_find_predicate_evaluates_to_some_then_none :: proc(t: ^testing.T) {
	source := "import engine.list.{find}\n" + "test \"find returns Some on a hit and None on a miss\" {\n" +
		"  assert find([1, 2, 3], fn(x) { return x == 2 }) == Option::Some(2)\n" +
		"  assert find([1, 2, 3], fn(x) { return x == 9 }) == Option::None\n" +
		"}\n"
	report, err := run_test_pipeline(source)
	testing.expect_value(t, err, Pipeline_Error.None)
	testing.expect_value(t, report.passed, 2)
	testing.expect_value(t, report.failed, 0)
}

@(test)
test_append_to_back_and_reverse_flip_order :: proc(t: ^testing.T) {
	source := "import engine.list.{append, reverse, len, get}\n" +
		"test \"append appends, reverse reverses\" {\n" +
		"  assert len(append([1, 2], 3)) == 3\n" +
		"  assert get(append([1, 2], 3), 2) == Option::Some(3)\n" +
		"  assert get(reverse([1, 2, 3]), 0) == Option::Some(3)\n" +
		"  assert get(reverse([1, 2, 3]), 2) == Option::Some(1)\n" +
		"}\n"
	report, err := run_test_pipeline(source)
	testing.expect_value(t, err, Pipeline_Error.None)
	testing.expect_value(t, report.passed, 4)
	testing.expect_value(t, report.failed, 0)
}

@(test)
test_apply_impulse_accumulates_and_chains :: proc(t: ^testing.T) {
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
