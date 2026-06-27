package eir

import "../cli"
import "core:testing"

@(test)
test_lint_registry_nonempty :: proc(t: ^testing.T) {
	testing.expect(t, len(lint_registry) > 0, "lint registry must host at least one lint")
}

@(test)
test_lint_subtree_is_well_formed :: proc(t: ^testing.T) {
	subtree := build_lint_subtree(context.temp_allocator)
	testing.expect_value(t, len(subtree), len(lint_registry))

	for node, i in subtree {
		testing.expect_value(t, node.use, lint_registry[i].name)
		testing.expect(t, node.run != nil, "a lint node must be a runnable leaf")
		testing.expect_value(t, len(node.subcommands), 0)
	}

	root := cli.cli_new_command(
		cli.Cli_Command{use = "eir", short = "lint host under test", subcommands = subtree},
		context.temp_allocator,
	)
	ok, message := cli.cli_finalize(root)
	testing.expect(t, ok, message)

	testing.expect(
		t,
		cli.cli_find_subcommand(root, "dup") != nil,
		"the dup lint must resolve as a subcommand",
	)
}
