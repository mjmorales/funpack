package cli

import "core:slice"
import "core:testing"

cli_test_noop_run :: proc(_: ^Cli_Invocation) -> int {
	return 0
}

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

@(test)
test_cli_parse_terminator :: proc(t: ^testing.T) {
	root := build_cli_test_tree(context.temp_allocator)

	inv := expect_cli_ok(t, root, {"build", "--", "--host", "-v"})
	testing.expect_value(t, len(inv.args), 2)
	testing.expect_value(t, inv.args[0], "--host")
	testing.expect_value(t, inv.args[1], "-v")
}

@(test)
test_cli_parse_arity :: proc(t: ^testing.T) {
	root := build_cli_test_tree(context.temp_allocator)

	expect_cli_err(t, root, {"build"}, .Bad_Arg_Count)

	inv := expect_cli_ok(t, root, {"build", "x", "y"})
	testing.expect_value(t, len(inv.args), 2)

	expect_cli_err(t, root, {"serve", "-H", "h", "extra"}, .Bad_Arg_Count)
}

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
