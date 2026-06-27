package cli

import "core:strings"
import "core:testing"

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
