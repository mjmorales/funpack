// The `funpack mcp` verb — the native Odin MCP dev server. It speaks MCP
// (JSON-RPC 2.0) over stdio, hand-rolled on core: primitives, AUTH-FREE (the host
// forks this server and owns its inherited fds — there is no listening port to
// gate). It lives ONLY in this entry package, the single FUNPACK_LIVE/SDL-linking
// build, beside run/live/attach.
//
// The parent verb is deliberately MINIMAL and EXTENSIBLE: it owns the stdio
// transport and the serve loop, and the protocol dispatch (initialize /
// tools/list / tools/call), the session registry, the per-tool arms, and the
// docs/codegen subcommands all build ON it via their own files. Keep this parent
// thin so additions graft onto it rather than around it.
package main

import "../../cli"
import "core:slice"

// build_mcp_command declares the `funpack mcp` verb node, mirroring
// build_run/live/attach_command (cli_runtime.odin). It is MINIMAL and EXTENSIBLE:
// no positionals (the server reads its protocol off stdin, not argv) and no flags
// today. It carries both a `run` (serve the stdio server when invoked bare) AND
// subcommands (the dev-time `gen-corpus` regenerator); the framework descends to a
// subcommand on a leading non-flag token and otherwise runs the serve handler. The
// dev-time codegen subcommands hang here: gen-corpus (docs-corpus shards) and
// gen-contract (funpack/api_contract.gen.odin). Further subcommands append here
// without re-authoring the parent.
build_mcp_command :: proc(allocator := context.allocator) -> ^cli.Cli_Command {
	subs := slice.clone(
		[]^cli.Cli_Command {
			build_mcp_gen_corpus_command(allocator),
			build_mcp_gen_contract_command(allocator),
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

// cli_run_mcp is the thin verb adapter (the cli_runtime.odin pattern): it relays
// to run_mcp_verb, the verb core that builds the JSON-RPC handler, serves it over
// the auth-free stdio transport, and owns the {0,1,2} exit contract. The framework
// owns usage/help (this verb takes no args, so usage never reaches the core); the
// core owns 0 on a clean serve-then-EOF / handler shutdown and 1 on a server fault.
cli_run_mcp :: proc(inv: ^cli.Cli_Invocation) -> int {
	return run_mcp_verb()
}
