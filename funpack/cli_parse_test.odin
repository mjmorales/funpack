// Parser tests over a synthetic command tree that exercises every framework
// feature the concrete funpack tree does not yet use — shorthands, int and
// required flags, `--flag=value` / `-fvalue` / `-f=value` value forms, the `--`
// end-of-flags terminator, and the full closed Cli_Parse_Error vocabulary. The
// funpack tree's own argument contract is pinned separately in
// cli_funpack_test.odin; this file proves the resolver in isolation.
package funpack

import "core:slice"
import "core:testing"

// cli_test_noop_run is the synthetic tree's handler — never invoked by the
// parser (parse is pure), present only so leaf commands are runnable and pass
// cli_finalize.
cli_test_noop_run :: proc(_: ^Cli_Invocation) -> int {
	return 0
}

// build_cli_test_tree constructs the synthetic `prog` tree: `serve` carries an
// int flag with a default (--port/-p), a required string flag (--host/-H), and a
// bool flag (--verbose/-v), and takes no positionals; `build` takes at least one
// positional and no flags. Allocated in `allocator` (a scratch arena in tests).
build_cli_test_tree :: proc(allocator := context.allocator) -> ^Cli_Command {
	serve := cli_new_command(
		Cli_Command {
			use = "serve",
			short = "Serve the thing",
			flags = slice.clone(
				[]Cli_Flag {
					{name = "port", shorthand = 'p', kind = .Int, usage = "Listen port", default = 8080},
					{name = "host", shorthand = 'H', kind = .String, usage = "Bind host", required = true},
					{name = "verbose", shorthand = 'v', kind = .Bool, usage = "Verbose logging"},
				},
				allocator,
			),
			args = cli_no_args(),
			run = cli_test_noop_run,
		},
		allocator,
	)
	build := cli_new_command(
		Cli_Command {
			use = "build",
			short = "Build the thing",
			args = cli_minimum_args(1),
			run = cli_test_noop_run,
		},
		allocator,
	)
	root := cli_new_command(
		Cli_Command {
			use = "prog",
			short = "A synthetic test program",
			subcommands = slice.clone([]^Cli_Command{serve, build}, allocator),
		},
		allocator,
	)
	ok, message := cli_finalize(root)
	assert(ok, message)
	return root
}

// expect_cli_ok parses argv and asserts success, returning the invocation for
// further inspection.
expect_cli_ok :: proc(
	t: ^testing.T,
	root: ^Cli_Command,
	argv: []string,
	loc := #caller_location,
) -> Cli_Invocation {
	inv, err := cli_parse(root, argv, context.temp_allocator)
	testing.expect_value(t, err.kind, Cli_Parse_Error_Kind.None, loc = loc)
	return inv
}

// expect_cli_err parses argv and asserts the exact closed error kind, so a
// rejection is pinned to its reason, not merely to "some failure".
expect_cli_err :: proc(
	t: ^testing.T,
	root: ^Cli_Command,
	argv: []string,
	want: Cli_Parse_Error_Kind,
	loc := #caller_location,
) {
	_, err := cli_parse(root, argv, context.temp_allocator)
	testing.expect_value(t, err.kind, want, loc = loc)
}

// test_cli_parse_descent_and_flags resolves a leaf and binds its flags through
// the long form: the command path descends to `serve`, the required string
// binds, the bool defaults false when absent, and the int returns its declared
// default when the flag is unset.
@(test)
test_cli_parse_descent_and_flags :: proc(t: ^testing.T) {
	root := build_cli_test_tree(context.temp_allocator)

	inv := expect_cli_ok(t, root, {"serve", "--host", "example.com"})
	testing.expect_value(t, inv.command.use, "serve")
	testing.expect_value(t, cli_flag_string(&inv, "host"), "example.com")
	testing.expect_value(t, cli_flag_bool(&inv, "verbose"), false)
	testing.expect_value(t, cli_flag_int(&inv, "port"), 8080)
	testing.expect_value(t, len(inv.args), 0)
}

// test_cli_parse_value_forms pins the equivalent value spellings: `--flag value`,
// `--flag=value`, `-f value`, `-fvalue`, and `-f=value` all bind the same, and a
// bool shorthand sets true.
@(test)
test_cli_parse_value_forms :: proc(t: ^testing.T) {
	root := build_cli_test_tree(context.temp_allocator)

	inv := expect_cli_ok(t, root, {"serve", "--host=example.com", "--port=9090", "--verbose"})
	testing.expect_value(t, cli_flag_string(&inv, "host"), "example.com")
	testing.expect_value(t, cli_flag_int(&inv, "port"), 9090)
	testing.expect_value(t, cli_flag_bool(&inv, "verbose"), true)

	inv = expect_cli_ok(t, root, {"serve", "-H", "h", "-p", "70", "-v"})
	testing.expect_value(t, cli_flag_string(&inv, "host"), "h")
	testing.expect_value(t, cli_flag_int(&inv, "port"), 70)
	testing.expect_value(t, cli_flag_bool(&inv, "verbose"), true)

	inv = expect_cli_ok(t, root, {"serve", "-Hh", "-p9090"})
	testing.expect_value(t, cli_flag_string(&inv, "host"), "h")
	testing.expect_value(t, cli_flag_int(&inv, "port"), 9090)

	inv = expect_cli_ok(t, root, {"serve", "-H=h"})
	testing.expect_value(t, cli_flag_string(&inv, "host"), "h")
}

// test_cli_parse_bool_explicit pins the explicit bool value: `--verbose=false`
// binds false, `--verbose=true` true, and a non-bool value is a usage error
// rather than a silent coercion. A bare bool never consumes the next token, so
// `serve --verbose --host h` binds both flags.
@(test)
test_cli_parse_bool_explicit :: proc(t: ^testing.T) {
	root := build_cli_test_tree(context.temp_allocator)

	inv := expect_cli_ok(t, root, {"serve", "-H", "h", "--verbose=false"})
	testing.expect_value(t, cli_flag_bool(&inv, "verbose"), false)

	inv = expect_cli_ok(t, root, {"serve", "-H", "h", "--verbose=true"})
	testing.expect_value(t, cli_flag_bool(&inv, "verbose"), true)

	expect_cli_err(t, root, {"serve", "-H", "h", "--verbose=maybe"}, .Invalid_Flag_Value)

	inv = expect_cli_ok(t, root, {"serve", "--verbose", "--host", "h"})
	testing.expect_value(t, cli_flag_bool(&inv, "verbose"), true)
	testing.expect_value(t, cli_flag_string(&inv, "host"), "h")
}

// test_cli_parse_terminator pins `--`: every token after it is positional, so a
// flag-looking argument reaches the positional list verbatim.
@(test)
test_cli_parse_terminator :: proc(t: ^testing.T) {
	root := build_cli_test_tree(context.temp_allocator)

	inv := expect_cli_ok(t, root, {"build", "--", "--host", "-v"})
	testing.expect_value(t, len(inv.args), 2)
	testing.expect_value(t, inv.args[0], "--host")
	testing.expect_value(t, inv.args[1], "-v")
}

// test_cli_parse_arity pins positional arity end-to-end through the resolver:
// `build` needs at least one positional (zero is Bad_Arg_Count), and `serve`
// takes none (a trailing token is Bad_Arg_Count).
@(test)
test_cli_parse_arity :: proc(t: ^testing.T) {
	root := build_cli_test_tree(context.temp_allocator)

	expect_cli_err(t, root, {"build"}, .Bad_Arg_Count)

	inv := expect_cli_ok(t, root, {"build", "x", "y"})
	testing.expect_value(t, len(inv.args), 2)

	expect_cli_err(t, root, {"serve", "-H", "h", "extra"}, .Bad_Arg_Count)
}

// test_cli_parse_error_taxonomy pins each closed parse-error kind to the shape
// that produces it: an unknown command, a missing subcommand on the pure parent,
// an unknown flag, a value-flag with no value, a duplicate flag, an unparsable
// int, and a missing required flag.
@(test)
test_cli_parse_error_taxonomy :: proc(t: ^testing.T) {
	root := build_cli_test_tree(context.temp_allocator)

	expect_cli_err(t, root, {"nope"}, .Unknown_Command)
	expect_cli_err(t, root, {}, .Missing_Subcommand)
	expect_cli_err(t, root, {"serve", "--nope", "-H", "h"}, .Unknown_Flag)
	expect_cli_err(t, root, {"serve", "--host"}, .Missing_Flag_Value)
	expect_cli_err(t, root, {"serve", "-H", "a", "--host", "b"}, .Duplicate_Flag)
	expect_cli_err(t, root, {"serve", "-H", "h", "-p", "abc"}, .Invalid_Flag_Value)
	expect_cli_err(t, root, {"serve", "-v"}, .Missing_Required_Flag)
}

// test_cli_parse_help pins `--help`/`-h`: recognized at any command level, it
// returns a successful invocation flagged help with the command it was requested
// against, so the caller renders that command's usage.
@(test)
test_cli_parse_help :: proc(t: ^testing.T) {
	root := build_cli_test_tree(context.temp_allocator)

	inv, err := cli_parse(root, {"--help"}, context.temp_allocator)
	testing.expect_value(t, err.kind, Cli_Parse_Error_Kind.None)
	testing.expect(t, inv.help)
	testing.expect_value(t, inv.command.use, "prog")

	inv, err = cli_parse(root, {"serve", "-h"}, context.temp_allocator)
	testing.expect_value(t, err.kind, Cli_Parse_Error_Kind.None)
	testing.expect(t, inv.help)
	testing.expect_value(t, inv.command.use, "serve")
}
