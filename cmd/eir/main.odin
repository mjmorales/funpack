// eir — the repo-local Odin dev binary. It hosts source-tree lints over the
// funpack monorepo (dup, an AST DRY/clone checker, is the first) and is NOT a
// funpack product or subcommand: it lives OFF the funpack release/binary path,
// never defines FUNPACK_LIVE, and never links SDL. Its only dependencies are the
// domain-free cli framework (the same package cmd/funpack composes its tree
// through) and the eir lint-host package — so the build is deterministic and
// SDL-free, which is the whole point of a dev tool that runs in CI and locally
// with no native libraries.
//
// This is a SEPARATE `main` from cmd/funpack: the two binaries share the cli
// framework but compose disjoint command trees, so a lint never ships inside the
// funpack binary and the funpack compiler never pulls in the lint host.
package main

import "../../cli"
import "../../eir"
import "core:os"

// main composes the eir command tree, finalizes it (asserting the authored tree
// is well-formed — a programmer error caught by test_root_tree_finalizes, never a
// user path), and hands the argument vector to the framework's dispatch: a usage
// error prints to stderr and exits 2, `--help` prints to stdout and exits 0, and
// a resolved lint runs and exits with ITS code. The dispatch never decides an
// exit number — each lint owns its {0, 1, 2} contract.
main :: proc() {
	root := build_root_cli()
	ok, message := cli.cli_finalize(root)
	assert(ok, message)
	os.exit(cli.cli_dispatch(root, verb_args(os.args)))
}

// verb_args drops argv0 to yield the verb's argument vector, GUARDING the empty-argv
// launch context. os.args[1:] is an out-of-range slice when the process is started
// with NO argv0 (argc==0) — a context POSIX permits and that a hostile/adjusted
// launcher (BSD `find -execdir`, a bare posix_spawn with argv={NULL}) can produce.
// An unguarded os.args[1:] over a zero-length os.args reads `[1:0]` out of `0..<0`
// and faults (SIGSEGV / a bounds-check SIGTRAP) BEFORE dispatch emits anything —
// the worst failure mode: a non-zero exit with an empty stream, indistinguishable
// to CI or an agent from a hang-kill or a missing binary. Clamping a zero/one-element
// argv to an empty slice routes it to the no-verb path, which cli_dispatch renders as
// the usage block (a non-empty stderr diagnostic) and exits 2 — never a crash. Pure:
// a function of args alone, so the launch-context floor is unit-pinned without a
// process spawn.
verb_args :: proc(args: []string) -> []string {
	return args[1:] if len(args) > 1 else {}
}

// build_root_cli composes the eir root from the lint subtree the eir package
// exposes — one runnable subcommand per registered lint. It returns the root
// UNFINALIZED: main and the contract test finalize it, so the test asserts
// cli_finalize's verdict (proving no lint-name collision across the registry)
// instead of an internal assert masking it.
build_root_cli :: proc(allocator := context.allocator) -> ^cli.Cli_Command {
	return cli.cli_new_command(
		cli.Cli_Command {
			use = "eir",
			short = "Repo-local Odin dev lints for the funpack source tree",
			long = "eir hosts repo-local source lints over the funpack monorepo — dev-time checks that run off the funpack release path and never link SDL. Each lint is a registered subcommand; dup (an AST DRY/clone checker) is the first. eir is a developer tool, not a funpack product or subcommand.",
			subcommands = eir.build_lint_subtree(allocator),
		},
		allocator,
	)
}
