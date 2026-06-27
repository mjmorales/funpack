package main

import "../../cli"
import "../../funpack"
import "core:os"

main :: proc() {
	root := build_root_cli()
	ok, message := cli.cli_finalize(root)
	assert(ok, message)
	os.exit(cli.cli_dispatch(root, verb_args(os.args)))
}

verb_args :: proc(args: []string) -> []string {
	return args[1:] if len(args) > 1 else {}
}

build_root_cli :: proc(allocator := context.allocator) -> ^cli.Cli_Command {
	subs := make([dynamic]^cli.Cli_Command, 0, 16, allocator)
	append(&subs, ..funpack.build_funpack_compiler_subtree(allocator))
	append(&subs, build_run_command(allocator))
	append(&subs, build_render_check_command(allocator))
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
