// Arity-validator tests: cli_args_check is total over the closed Cli_Args_Kind
// set, so every kind is pinned at its boundary counts, and cli_args_expectation
// renders an advisory phrase that names the rule.
package funpack

import "core:strings"
import "core:testing"

// test_cli_args_check_each_kind pins the boundary behavior of every arity kind:
// Arbitrary accepts any count, None only zero, Exact only its n, Minimum/Maximum
// their half-open bound, and Range its inclusive interval. The off-by-one
// neighbors (just below/above a bound) are the cases a verb's usage tier hinges
// on, so they are asserted explicitly.
@(test)
test_cli_args_check_each_kind :: proc(t: ^testing.T) {
	testing.expect(t, cli_args_check(Cli_Args{kind = .Arbitrary}, 0))
	testing.expect(t, cli_args_check(Cli_Args{kind = .Arbitrary}, 7))

	testing.expect(t, cli_args_check(cli_no_args(), 0))
	testing.expect(t, !cli_args_check(cli_no_args(), 1))

	testing.expect(t, cli_args_check(cli_exact_args(2), 2))
	testing.expect(t, !cli_args_check(cli_exact_args(2), 1))
	testing.expect(t, !cli_args_check(cli_exact_args(2), 3))

	testing.expect(t, cli_args_check(cli_minimum_args(1), 1))
	testing.expect(t, cli_args_check(cli_minimum_args(1), 9))
	testing.expect(t, !cli_args_check(cli_minimum_args(1), 0))

	testing.expect(t, cli_args_check(cli_maximum_args(2), 0))
	testing.expect(t, cli_args_check(cli_maximum_args(2), 2))
	testing.expect(t, !cli_args_check(cli_maximum_args(2), 3))

	testing.expect(t, cli_args_check(cli_range_args(0, 1), 0))
	testing.expect(t, cli_args_check(cli_range_args(0, 1), 1))
	testing.expect(t, !cli_args_check(cli_range_args(0, 1), 2))
}

// test_cli_args_expectation_phrases pins the advisory wording each kind renders
// — the human body a Bad_Arg_Count error carries. Substring checks, since the
// phrase is advisory (the machine contract is the exit code), but the count and
// the pluralization must be right so the message reads true.
@(test)
test_cli_args_expectation_phrases :: proc(t: ^testing.T) {
	testing.expect_value(t, cli_args_expectation(cli_no_args(), context.temp_allocator), "no args")
	testing.expect_value(
		t,
		cli_args_expectation(cli_exact_args(1), context.temp_allocator),
		"exactly 1 arg",
	)
	testing.expect_value(
		t,
		cli_args_expectation(cli_exact_args(2), context.temp_allocator),
		"exactly 2 args",
	)
	testing.expect(
		t,
		strings.contains(cli_args_expectation(cli_minimum_args(1), context.temp_allocator), "at least 1"),
	)
	testing.expect(
		t,
		strings.contains(cli_args_expectation(cli_maximum_args(3), context.temp_allocator), "at most 3"),
	)
	testing.expect(
		t,
		strings.contains(cli_args_expectation(cli_range_args(0, 1), context.temp_allocator), "between 0 and 1"),
	)
}
