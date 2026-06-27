package main

import "../../cli"
import "core:testing"

@(test)
test_root_tree_finalizes :: proc(t: ^testing.T) {
	root := build_root_cli(context.temp_allocator)
	ok, message := cli.cli_finalize(root)
	testing.expect(t, ok, message)
}

@(test)
test_root_dispatches_dup :: proc(t: ^testing.T) {
	root := build_root_cli(context.temp_allocator)
	cli.cli_finalize(root)

	inv, err := cli.cli_parse(root, {"dup"}, context.temp_allocator)
	testing.expect_value(t, err.kind, cli.Cli_Parse_Error_Kind.None)
	testing.expect_value(t, inv.command.use, "dup")

	_, no_verb := cli.cli_parse(root, {}, context.temp_allocator)
	testing.expect(t, no_verb.kind != .None, "bare eir is the usage tier")
	_, unknown := cli.cli_parse(root, {"bogus"}, context.temp_allocator)
	testing.expect(t, unknown.kind != .None, "an unknown lint is a usage rejection")
}

@(test)
test_verb_args_clamps_empty_argv :: proc(t: ^testing.T) {
	testing.expect_value(t, len(verb_args({})), 0)
	testing.expect_value(t, len(verb_args({"eir"})), 0)

	tail := verb_args({"eir", "dup"})
	testing.expect_value(t, len(tail), 1)
	testing.expect_value(t, tail[0], "dup")
}
