// The `funpack mcp` verb — the native Odin MCP dev server (the clean-break fold of
// the deleted Go funpack-mcp module). It speaks MCP (JSON-RPC 2.0) over stdio,
// hand-rolled on core: primitives, AUTH-FREE (the host forks this server and owns
// its inherited fds — there is no listening port to gate). It lives ONLY in this
// entry package, the single FUNPACK_LIVE/SDL-linking build, beside run/live/attach.
//
// THIS TASK (mcp-transport) ships the MINIMAL, EXTENSIBLE parent verb + the stdio
// transport scaffolding. The verb here starts, reads lines off stdin, and frames a
// response per line through the transport with a stub echo handler — proving the
// transport end-to-end. The DOWNSTREAM mcp-protocol-verb task swaps the echo
// handler for the real JSON-RPC dispatch (initialize / tools/list / tools/call),
// the session registry, and the per-tool arms; mcp-docs-corpus-embed adds the
// docs subcommands. Keep this parent minimal so those build ON it, not around it.
package main

import "../../cli"

// build_mcp_command declares the `funpack mcp` verb node, mirroring
// build_run/live/attach_command (cli_runtime.odin). It is MINIMAL and EXTENSIBLE:
// no positionals (the server reads its protocol off stdin, not argv) and no flags
// today. Downstream tasks append subcommands here (e.g. `funpack mcp gen-corpus`)
// and/or flags; the parent stays a thin shell over serve_mcp_stdio so the protocol
// surface grows in mcp_server.odin/mcp_tools.odin, never in this verb declaration.
build_mcp_command :: proc(allocator := context.allocator) -> ^cli.Cli_Command {
	return cli.cli_new_command(
		cli.Cli_Command {
			use = "mcp",
			short = "Serve the funpack MCP dev server over stdio (JSON-RPC 2.0)",
			long = "Serve the Model Context Protocol dev server for funpack over stdio — line-framed JSON-RPC 2.0, auth-free (the MCP host forks the server and owns its inherited fds, so there is no port to gate). The server reads requests off stdin and writes framed responses to stdout (absolute stdout discipline: stdout carries ONLY framed JSON-RPC, every diagnostic routes to stderr). Run by an MCP host, not directly at a terminal.",
			args = cli.cli_no_args(),
			run = cli_run_mcp,
		},
		allocator,
	)
}

// cli_run_mcp is the thin verb adapter (the cli_runtime.odin pattern): it
// constructs the auth-free stdio serve loop and runs it with the request handler.
// For THIS task the handler is the echo stub (mcp_echo_handler) — enough to prove
// the transport round-trips a line; mcp-protocol-verb swaps in the JSON-RPC
// handler over this same Mcp_Line_Handler seam. serve_mcp_stdio runs until the
// stdin peer closes (EOF) or the handler ends the session, then the verb exits 0
// (a clean serve-then-EOF is success; the JSON-RPC layer owns any error exits).
cli_run_mcp :: proc(inv: ^cli.Cli_Invocation) -> int {
	serve_mcp_stdio(mcp_echo_handler())
	return 0
}

// mcp_echo_handler is the STUB request handler this task ships to prove the
// transport: it echoes each request line straight back as the response and keeps
// the connection open. It is NOT the protocol — mcp-protocol-verb replaces it with
// the JSON-RPC parse/dispatch handler. Kept here (not in mcp_transport.odin) so
// the transport file is pure framing with no placeholder request semantics, and so
// the swap is a one-line change in cli_run_mcp.
mcp_echo_handler :: proc() -> Mcp_Line_Handler {
	return Mcp_Line_Handler {
		userdata = nil,
		handle = proc(userdata: rawptr, line: string, allocator := context.allocator) -> (response: string, keep_open: bool) {
			return line, true
		},
	}
}
