// The unified-root contract test: the single binary composes the compiler subtree
// (funpack package) with the runtime verbs (run, live, attach — this package) into
// ONE tree, and that tree must be well-formed. The key new invariant consolidation
// introduces is cross-package verb uniqueness: a compiler verb and a runtime verb
// must never share a `use` token. cli_finalize adjudicates it; this test proves it
// so build_root_cli's startup assert can never fire in a shipped binary.
package main

import "../../cli"
import "core:testing"

// expect_root_ok parses argv against the composed root and asserts success.
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

// expect_root_reject parses argv and asserts a usage error of some closed kind.
expect_root_reject :: proc(
	t: ^testing.T,
	root: ^cli.Cli_Command,
	argv: []string,
	loc := #caller_location,
) {
	_, err := cli.cli_parse(root, argv, context.temp_allocator)
	testing.expect(t, err.kind != .None, "expected a usage rejection", loc = loc)
}

// test_root_tree_finalizes pins that the COMPOSED tree (compiler subtree + run +
// live + attach) is well-formed: unique subcommand names ACROSS the compiler and
// runtime nodes, unique flags/shorthands per command, every node runnable or a
// parent. A `use`-token collision between, say, a compiler verb and `run` would
// fail here at test time, never as a shipped-binary startup assert.
@(test)
test_root_tree_finalizes :: proc(t: ^testing.T) {
	root := build_root_cli(context.temp_allocator)
	ok, message := cli.cli_finalize(root)
	testing.expect(t, ok, message)
}

// test_root_verb_set pins that all three runtime verbs resolve alongside the
// compiler verbs in the ONE tree — the consolidation's whole point: a single
// binary whose tree dispatches both halves.
@(test)
test_root_verb_set :: proc(t: ^testing.T) {
	root := build_root_cli(context.temp_allocator)
	cli.cli_finalize(root)

	// Compiler verbs (owned by the funpack subtree) resolve.
	testing.expect_value(t, expect_root_ok(t, root, {"build"}).command.use, "build")
	testing.expect_value(t, expect_root_ok(t, root, {"version"}).command.use, "version")
	testing.expect_value(t, expect_root_ok(t, root, {"warden", "holes"}).command.use, "holes")

	// Runtime verbs (owned by this entry package) resolve in the same tree.
	testing.expect_value(t, expect_root_ok(t, root, {"run"}).command.use, "run")
	testing.expect_value(t, expect_root_ok(t, root, {"live", "art"}).command.use, "live")
	testing.expect_value(t, expect_root_ok(t, root, {"attach", "art"}).command.use, "attach")

	// The bare program and an unknown verb are the usage tier.
	expect_root_reject(t, root, {})
	expect_root_reject(t, root, {"bogus"})
}
