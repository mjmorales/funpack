package funpack

import "core:testing"

RAND_HEADER :: "import engine.rand.{Rng, seed, next, range, chance, split, pick}\n"

RAND_HELPERS :: "fn first_fixed(rng: Rng) -> Fixed {\n" +
	"  return match rng.next() { (f, nx) => f }\n" +
	"}\n" +
	"fn first_fixed_in_unit(rng: Rng) -> Bool {\n" +
	"  return match rng.next() { (f, nx) => f >= 0.0 }\n" +
	"}\n" +
	"fn first_fixed_below_one(rng: Rng) -> Bool {\n" +
	"  return match rng.next() { (f, nx) => f < 1.0 }\n" +
	"}\n" +
	"fn first_range(rng: Rng) -> Int {\n" +
	"  return match rng.range(0, 100) { (n, nx) => n }\n" +
	"}\n" +
	"fn range_after_next(rng: Rng) -> Int {\n" +
	"  return match rng.next() { (f, r1) => first_range(r1) }\n" +
	"}\n" +
	"fn first_chance(rng: Rng, p: Fixed) -> Bool {\n" +
	"  return match rng.chance(p) { (b, nx) => b }\n" +
	"}\n" +
	"fn split_first_ranges_differ(rng: Rng) -> Bool {\n" +
	"  return match rng.split() { (ra, rb) => first_range(ra) != first_range(rb) }\n" +
	"}\n"

@(test)
test_rand_draws_pin_seed_42_golden_stream :: proc(t: ^testing.T) {
	source :=
		RAND_HEADER +
		RAND_HELPERS +
		"test \"seed 42 golden stream\" {\n" +
		"  assert first_fixed_in_unit(seed(42)) == true\n" +
		"  assert first_fixed_below_one(seed(42)) == true\n" +
		"  assert first_range(seed(42)) == 74\n" +
		"  assert range_after_next(seed(42)) == 15\n" +
		"  assert first_chance(seed(42), 0.0) == false\n" +
		"  assert first_chance(seed(42), 1.0) == true\n" +
		"}\n"
	report, err := run_test_pipeline(source)
	testing.expect_value(t, err, Pipeline_Error.None)
	testing.expect_value(t, report.passed, 6)
	testing.expect_value(t, report.failed, 0)
}

@(test)
test_rand_draws_are_deterministic_same_seed :: proc(t: ^testing.T) {
	source :=
		RAND_HEADER +
		RAND_HELPERS +
		"test \"determinism\" {\n" +
		"  assert first_range(seed(42)) == first_range(seed(42))\n" +
		"  assert first_fixed(seed(7)) == first_fixed(seed(7))\n" +
		"  assert seed(42) == seed(42)\n" +
		"}\n"
	report, err := run_test_pipeline(source)
	testing.expect_value(t, err, Pipeline_Error.None)
	testing.expect_value(t, report.passed, 3)
	testing.expect_value(t, report.failed, 0)
}

@(test)
test_rand_split_yields_decorrelated_streams :: proc(t: ^testing.T) {
	source :=
		RAND_HEADER +
		RAND_HELPERS +
		"test \"split decorrelates\" {\n" +
		"  assert split_first_ranges_differ(seed(42)) == true\n" +
		"}\n"
	report, err := run_test_pipeline(source)
	testing.expect_value(t, err, Pipeline_Error.None)
	testing.expect_value(t, report.passed, 1)
	testing.expect_value(t, report.failed, 0)
}

@(test)
test_rand_draw_mismatch_is_a_counted_failure :: proc(t: ^testing.T) {
	source :=
		RAND_HEADER +
		RAND_HELPERS +
		"test \"wrong draw\" {\n  assert first_range(seed(42)) == 0\n}\n"
	report, err := run_test_pipeline(source)
	testing.expect_value(t, err, Pipeline_Error.None)
	testing.expect_value(t, report.passed, 0)
	testing.expect_value(t, report.failed, 1)
	testing.expect_value(t, report.exit_code, 1)
}

RAND_LET_HELPERS :: "fn let_first_range(rng: Rng) -> Int {\n" +
	"  let (n, nx) = rng.range(0, 100)\n" +
	"  return n\n" +
	"}\n" +
	"fn let_range_after_next(rng: Rng) -> Int {\n" +
	"  let (f, r1) = rng.next()\n" +
	"  let (n, r2) = r1.range(0, 100)\n" +
	"  return n\n" +
	"}\n"

@(test)
test_let_tuple_destructure_threads_rng_deterministically :: proc(t: ^testing.T) {
	source :=
		RAND_HEADER +
		RAND_HELPERS +
		RAND_LET_HELPERS +
		"test \"let-threaded draws match the match-threaded goldens\" {\n" +
		"  assert let_first_range(seed(42)) == 74\n" +
		"  assert let_range_after_next(seed(42)) == 15\n" +
		"  assert let_first_range(seed(42)) == first_range(seed(42))\n" +
		"  assert let_range_after_next(seed(42)) == range_after_next(seed(42))\n" +
		"}\n"
	report, err := run_test_pipeline(source)
	testing.expect_value(t, err, Pipeline_Error.None)
	testing.expect_value(t, report.passed, 4)
	testing.expect_value(t, report.failed, 0)
}

@(test)
test_let_tuple_destructure_in_test_body :: proc(t: ^testing.T) {
	source :=
		RAND_HEADER +
		"test \"destructure in test body\" {\n" +
		"  let (n, nx) = seed(42).range(0, 100)\n" +
		"  let (n2, nx2) = nx.range(0, 100)\n" +
		"  assert n == 74\n" +
		"  assert n2 >= 0\n" +
		"}\n"
	report, err := run_test_pipeline(source)
	testing.expect_value(t, err, Pipeline_Error.None)
	testing.expect_value(t, report.passed, 2)
	testing.expect_value(t, report.failed, 0)
}

@(test)
test_let_tuple_destructure_arity_mismatch_is_compile_error :: proc(t: ^testing.T) {
	source :=
		RAND_HEADER +
		"fn bad(rng: Rng) -> Int {\n" +
		"  let (a, b, c) = rng.range(0, 100)\n" +
		"  return a\n" +
		"}\n" +
		"test \"arity\" {\n  assert bad(seed(42)) == 0\n}\n"
	_, err := run_test_pipeline(source)
	testing.expect_value(t, err, Pipeline_Error.Typecheck_Failed)
}

@(test)
test_let_tuple_destructure_non_tuple_rhs_is_compile_error :: proc(t: ^testing.T) {
	source :=
		RAND_HEADER +
		"fn bad(rng: Rng) -> Int {\n" +
		"  let (a, b) = 5\n" +
		"  return a\n" +
		"}\n" +
		"test \"non-tuple\" {\n  assert bad(seed(42)) == 0\n}\n"
	_, err := run_test_pipeline(source)
	testing.expect_value(t, err, Pipeline_Error.Typecheck_Failed)
}

@(test)
test_rand_pick_self_first_evaluates :: proc(t: ^testing.T) {
	source :=
		RAND_HEADER +
		"fn picked(rng: Rng) -> Int {\n" +
		"  return match rng.pick([10, 20, 30, 40, 50, 60, 70, 80, 90, 100]) {\n" +
		"    (got, nx) => match got { Option::Some(v) => v, Option::None => -1 }\n" +
		"  }\n" +
		"}\n" +
		"test \"pick self-first\" {\n" +
		"  assert picked(seed(42)) == 80\n" +
		"}\n"
	report, err := run_test_pipeline(source)
	testing.expect_value(t, err, Pipeline_Error.None)
	testing.expect_value(t, report.passed, 1)
	testing.expect_value(t, report.failed, 0)
}
