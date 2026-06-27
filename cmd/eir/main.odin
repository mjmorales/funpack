package main

import "../../cli"
import "../../eir"
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
