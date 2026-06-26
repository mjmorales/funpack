// The eir-root contract test: cmd/eir composes the eir lint subtree into ONE tree,
// and that tree must be well-formed — unique lint `use` tokens, every node a
// runnable leaf. cli_finalize adjudicates it; this test proves it so
// build_root_cli's startup assert can never fire in a shipped binary. The eir
// analog of cmd/funpack's test_root_tree_finalizes. It also pins that dup
// dispatches and that the copied launch-context floor (verb_args) stays in-bounds.
package main

import "../../cli"
import "core:testing"

// test_root_tree_finalizes pins the composed eir tree is well-formed: unique lint
// names, unique flags/shorthands per command, every node runnable or a parent. A
// `use`-token collision between two registered lints would fail here at test time,
// never as a shipped-binary startup assert.
@(test)
test_root_tree_finalizes :: proc(t: ^testing.T) {
	root := build_root_cli(context.temp_allocator)
	ok, message := cli.cli_finalize(root)
	testing.expect(t, ok, message)
}

// test_root_dispatches_dup pins that the registry's first lint resolves as a verb
// in the composed root — the scaffold's whole point: a binary whose tree
// dispatches the hosted lints. A bare program and an unknown verb stay the usage
// tier (a usage rejection, never a crash).
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

// test_verb_args_clamps_empty_argv pins the launch-context floor at the startup
// seam (verb_args, main.odin): the drop-argv0 slice must stay in-bounds for every
// argv a hostile launcher can hand main, including the argc==0 (no argv0) case BSD
// `find -execdir` and a bare posix_spawn with argv={NULL} can produce — see
// verb_args's doc for why the naive os.args[1:] faults there. The degenerate argvs
// (argc 0 and 1) collapse to the empty verb vector (the usage tier); argc>=2
// surfaces exactly the verb tail.
@(test)
test_verb_args_clamps_empty_argv :: proc(t: ^testing.T) {
	testing.expect_value(t, len(verb_args({})), 0)
	testing.expect_value(t, len(verb_args({"eir"})), 0)

	tail := verb_args({"eir", "dup"})
	testing.expect_value(t, len(tail), 1)
	testing.expect_value(t, tail[0], "dup")
}
