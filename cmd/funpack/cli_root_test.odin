package main

import "../../cli"
import "core:testing"

expect_root_ok :: proc(
	t: ^testing.T,
	root: ^cli.Cli_Command,
	argv: []string,
	loc := #caller_location,
) -> cli.Cli_Invocation {
	inv, err := cli.cli_parse(root, argv, context.temp_allocator)
	testing.expect_value(t, err.kind, cli.Cli_Parse_Error_Kind.None, loc = loc)
	return inv
}

expect_root_reject :: proc(
	t: ^testing.T,
	root: ^cli.Cli_Command,
	argv: []string,
	loc := #caller_location,
) {
	_, err := cli.cli_parse(root, argv, context.temp_allocator)
	testing.expect(t, err.kind != .None, "expected a usage rejection", loc = loc)
}

@(test)
test_root_tree_finalizes :: proc(t: ^testing.T) {
	root := build_root_cli(context.temp_allocator)
	ok, message := cli.cli_finalize(root)
	testing.expect(t, ok, message)
}

@(test)
test_root_verb_set :: proc(t: ^testing.T) {
	root := build_root_cli(context.temp_allocator)
	cli.cli_finalize(root)

	testing.expect_value(t, expect_root_ok(t, root, {"build"}).command.use, "build")
	testing.expect_value(t, expect_root_ok(t, root, {"version"}).command.use, "version")
	testing.expect_value(t, expect_root_ok(t, root, {"warden", "holes"}).command.use, "holes")

	testing.expect_value(t, expect_root_ok(t, root, {"run"}).command.use, "run")
	testing.expect_value(t, expect_root_ok(t, root, {"live", "art"}).command.use, "live")
	testing.expect_value(t, expect_root_ok(t, root, {"attach", "art"}).command.use, "attach")

	testing.expect_value(t, expect_root_ok(t, root, {"mcp"}).command.use, "mcp")
	testing.expect_value(t, expect_root_ok(t, root, {"mcp", "gen-corpus"}).command.use, "gen-corpus")
	testing.expect_value(t, expect_root_ok(t, root, {"mcp", "docs-export"}).command.use, "docs-export")

	expect_root_reject(t, root, {})
	expect_root_reject(t, root, {"bogus"})
}

@(test)
test_verb_args_clamps_empty_argv :: proc(t: ^testing.T) {
	testing.expect_value(t, len(verb_args({})), 0)

	testing.expect_value(t, len(verb_args({"funpack"})), 0)

	tail := verb_args({"funpack", "check"})
	testing.expect_value(t, len(tail), 1)
	testing.expect_value(t, tail[0], "check")

	tail2 := verb_args({"funpack", "warden", "holes"})
	testing.expect_value(t, len(tail2), 2)
	testing.expect_value(t, tail2[0], "warden")
	testing.expect_value(t, tail2[1], "holes")
}
