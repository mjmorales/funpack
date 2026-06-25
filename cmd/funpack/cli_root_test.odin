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

	// `mcp` resolves as a unique verb in the same tree (no use-token collision with
	// a compiler or runtime verb — cli_finalize above adjudicated uniqueness). Bare
	// `funpack mcp` serves the stdio server; `funpack mcp gen-corpus` is its child.
	testing.expect_value(t, expect_root_ok(t, root, {"mcp"}).command.use, "mcp")
	testing.expect_value(t, expect_root_ok(t, root, {"mcp", "gen-corpus"}).command.use, "gen-corpus")
	// `funpack mcp docs-export` is the runtime materializer child (the on-disk docs
	// projection), beside the dev-time codegen children.
	testing.expect_value(t, expect_root_ok(t, root, {"mcp", "docs-export"}).command.use, "docs-export")

	// The bare program and an unknown verb are the usage tier.
	expect_root_reject(t, root, {})
	expect_root_reject(t, root, {"bogus"})
}

// test_verb_args_clamps_empty_argv pins the launch-context floor at the startup
// seam (verb_args, main.odin): the drop-argv0 slice must stay in-bounds for every
// argv a hostile launcher can hand main, including the argc==0 (no argv0) case BSD
// `find -execdir` and a bare posix_spawn with argv={NULL} can produce — see
// verb_args's doc for why the naive os.args[1:] faults there. The two degenerate
// argvs (argc 0 and 1) must collapse to the empty verb vector, which
// test_root_verb_set's expect_root_reject(t, root, {}) already proves dispatch
// renders as a usage block at exit 2 — so together they pin "no crash, clean
// non-empty diagnostic".
@(test)
test_verb_args_clamps_empty_argv :: proc(t: ^testing.T) {
	// argc==0: no argv0 at all — the crash case. Must clamp to an empty slice.
	testing.expect_value(t, len(verb_args({})), 0)

	// argc==1: argv0 only (a bare `funpack` invocation) — no verb tokens.
	testing.expect_value(t, len(verb_args({"funpack"})), 0)

	// argc>=2: argv0 + verb — the drop-argv0 must surface exactly the verb tail.
	tail := verb_args({"funpack", "check"})
	testing.expect_value(t, len(tail), 1)
	testing.expect_value(t, tail[0], "check")

	// A verb with its own arguments keeps the whole post-argv0 vector intact.
	tail2 := verb_args({"funpack", "warden", "holes"})
	testing.expect_value(t, len(tail2), 2)
	testing.expect_value(t, tail2[0], "warden")
	testing.expect_value(t, tail2[1], "holes")
}
