package main

import "../../cli"
import "core:slice"

build_mcp_command :: proc(allocator := context.allocator) -> ^cli.Cli_Command {
	subs := slice.clone(
		[]^cli.Cli_Command {
			build_mcp_gen_corpus_command(allocator),
			build_mcp_gen_contract_command(allocator),
			build_mcp_docs_export_command(allocator),
		},
		allocator,
	)
	return cli.cli_new_command(
		cli.Cli_Command {
			use = "mcp",
			short = "Serve the funpack MCP dev server over stdio (JSON-RPC 2.0)",
			long = "Serve the Model Context Protocol dev server for funpack over stdio — line-framed JSON-RPC 2.0, auth-free (the MCP host forks the server and owns its inherited fds, so there is no port to gate). The server reads requests off stdin and writes framed responses to stdout (absolute stdout discipline: stdout carries ONLY framed JSON-RPC, every diagnostic routes to stderr). Run by an MCP host, not directly at a terminal. The `gen-corpus` subcommand is a dev-time tool that regenerates the committed docs-corpus shards.",
			args = cli.cli_no_args(),
			run = cli_run_mcp,
			subcommands = subs,
		},
		allocator,
	)
}

cli_run_mcp :: proc(inv: ^cli.Cli_Invocation) -> int {
	return run_mcp_verb()
}
