// funpack — the single binary. ONE command tree dispatches the pure compiler
// verbs (version, test, build, check, fmt, warden — owned by the funpack package)
// and the runtime verbs (run, live, attach — which drive funpack_runtime). This
// is the only `main` in the repo and the only package that imports both the
// compiler and the runtime, so it is the only build that links SDL (under
// -define:FUNPACK_LIVE=true). The compiler and runtime packages stay independent
// libraries — the deterministic SDL-free test/CI floor is enforced at the package
// level (odin test/check per package), which this binary never touches.
//
// The CLI framework lives in its own domain-free package (cli); neither the
// compiler nor the runtime depends on it. This entry package composes their two
// command subtrees under one root and drives cli.cli_dispatch.
package main

import "../../cli"
import "../../funpack"
import "core:os"

// main composes the unified command tree, finalizes it (asserting the authored
// tree is well-formed — a programmer error caught by test_root_tree_finalizes,
// never a user path), and hands the argument vector to the framework's dispatch:
// a usage error prints to stderr and exits 2, `--help` prints to stdout and exits
// 0, and a resolved verb runs and exits with ITS code. The dispatch never decides
// an exit number — each verb core owns its {0, 1, 2} contract (§29 §3).
main :: proc() {
	root := build_root_cli()
	ok, message := cli.cli_finalize(root)
	assert(ok, message)
	os.exit(cli.cli_dispatch(root, os.args[1:]))
}

// build_root_cli composes the root from the compiler subtree (the funpack
// package's pure verbs) plus the runtime verbs (run, live, attach, mcp — declared
// in this package because they call into funpack_runtime; mcp serves the MCP dev
// server over stdio). It returns the root
// UNFINALIZED: main and the contract test finalize it, so the test asserts
// cli_finalize's verdict (proving no verb-name collision across the compiler and
// runtime nodes) instead of an internal assert masking it.
build_root_cli :: proc(allocator := context.allocator) -> ^cli.Cli_Command {
	subs := make([dynamic]^cli.Cli_Command, 0, 16, allocator)
	append(&subs, ..funpack.build_funpack_compiler_subtree(allocator))
	append(&subs, build_run_command(allocator))
	append(&subs, build_live_command(allocator))
	append(&subs, build_attach_command(allocator))
	append(&subs, build_mcp_command(allocator))
	return cli.cli_new_command(
		cli.Cli_Command {
			use = "funpack",
			short = "The funpack source → artifact compiler and live runtime",
			long = "funpack compiles a §14 project tree to its versioned artifacts (a runnable game artifact and the Index Contract NDJSON) and plays them. The compiler core is pure — no clock, no DB, no network in scope; `run`/`live`/`attach` drive the live SDL runtime.",
			subcommands = subs[:],
		},
		allocator,
	)
}
