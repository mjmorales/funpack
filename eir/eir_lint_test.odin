// Lint-host registry tests: the host is a registry of lint nodes, so its floor is
// (1) the registry is non-empty — an empty host would make `eir --help` a shell
// with no verbs — and (2) build_lint_subtree turns every entry into a runnable
// leaf command the framework finalizes cleanly. These pin the registry contract
// the entry binary (cmd/eir) composes over, independent of any one lint's engine.
package eir

import "../cli"
import "core:testing"

// test_lint_registry_nonempty pins that eir hosts at least one lint. The registry
// is the single source `eir --help` enumerates, so an empty one is a host with no
// surface — caught here, not at the binary.
@(test)
test_lint_registry_nonempty :: proc(t: ^testing.T) {
	testing.expect(t, len(lint_registry) > 0, "lint registry must host at least one lint")
}

// test_lint_subtree_is_well_formed pins the builder's happy path and one edge.
// Happy path: build_lint_subtree yields one node per registry entry, each a
// runnable leaf (a handler, no subcommands) whose use token is the lint's name,
// and a root carrying the subtree passes cli_finalize — the same well-formedness
// the shipped tree asserts (unique names, every node runnable). Edge: a registered
// lint resolves through the framework's own lookup, proving the host dispatches
// exactly what the registry declares.
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
