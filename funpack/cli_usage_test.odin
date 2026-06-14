// Usage-renderer tests: the help block is a deterministic function of the linked
// command tree (§29 determinism floor — two renders are byte-identical), a pure
// parent renders its Available Commands list and a `[command]` usage line, and a
// runnable leaf renders a `[flags]` usage line and a Flags block with aligned
// columns, type hints, and the synthetic `-h, --help`. The synthetic tree comes
// from cli_parse_test.odin (build_cli_test_tree).
package funpack

import "core:strings"
import "core:testing"

// test_cli_usage_is_deterministic pins the determinism floor: rendering the same
// command twice yields byte-identical text, because the renderer walks only
// declared slices, never a map.
@(test)
test_cli_usage_is_deterministic :: proc(t: ^testing.T) {
	root := build_cli_test_tree(context.temp_allocator)
	a := cli_usage(root, context.temp_allocator)
	b := cli_usage(root, context.temp_allocator)
	testing.expect_value(t, a, b)

	serve := cli_find_subcommand(root, "serve")
	c := cli_usage(serve, context.temp_allocator)
	d := cli_usage(serve, context.temp_allocator)
	testing.expect_value(t, c, d)
}

// test_cli_usage_parent_block pins a pure parent's help: the description, the
// `[command]` usage line under the full path, an Available Commands list naming
// every child with its short, and the "Use … --help" trailer.
@(test)
test_cli_usage_parent_block :: proc(t: ^testing.T) {
	root := build_cli_test_tree(context.temp_allocator)
	usage := cli_usage(root, context.temp_allocator)

	testing.expect(t, strings.contains(usage, "A synthetic test program"))
	testing.expect(t, strings.contains(usage, "Usage:\n  prog [command]"))
	testing.expect(t, strings.contains(usage, "Available Commands:"))
	testing.expect(t, strings.contains(usage, "serve"))
	testing.expect(t, strings.contains(usage, "Serve the thing"))
	testing.expect(t, strings.contains(usage, "build"))
	testing.expect(t, strings.contains(usage, `Use "prog [command] --help" for more information about a command.`))
	// A pure parent has no `[flags]` leaf usage line of its own.
	testing.expect(t, !strings.contains(usage, "prog [flags]"))
}

// test_cli_usage_leaf_flags pins a runnable leaf's help: the `[flags]` usage line
// under the full path, a Flags block listing each flag with its shorthand, long
// name, and value-type hint, and the synthetic `-h, --help` line naming the
// command.
@(test)
test_cli_usage_leaf_flags :: proc(t: ^testing.T) {
	root := build_cli_test_tree(context.temp_allocator)
	serve := cli_find_subcommand(root, "serve")
	usage := cli_usage(serve, context.temp_allocator)

	testing.expect(t, strings.contains(usage, "Usage:\n  prog serve [flags]"))
	testing.expect(t, strings.contains(usage, "Flags:"))
	testing.expect(t, strings.contains(usage, "-p, --port int"))
	testing.expect(t, strings.contains(usage, "-H, --host string"))
	testing.expect(t, strings.contains(usage, "-v, --verbose"))
	testing.expect(t, strings.contains(usage, "-h, --help"))
	testing.expect(t, strings.contains(usage, "help for serve"))
	// A leaf with no subcommands shows no Available Commands section.
	testing.expect(t, !strings.contains(usage, "Available Commands:"))
}

// test_cli_usage_args_hint pins the positional hint: a command that accepts
// positionals (build, minimum 1) advertises `[flags] [args]` on its usage line,
// and still renders the synthetic `-h, --help`.
@(test)
test_cli_usage_args_hint :: proc(t: ^testing.T) {
	root := build_cli_test_tree(context.temp_allocator)
	build := cli_find_subcommand(root, "build")
	usage := cli_usage(build, context.temp_allocator)

	// build takes positionals (minimum 1), so its usage line advertises [args].
	testing.expect(t, strings.contains(usage, "prog build [flags] [args]"))
	testing.expect(t, strings.contains(usage, "-h, --help"))
}
