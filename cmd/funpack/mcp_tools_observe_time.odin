// The OBSERVE + TIME-TRAVEL tool dispatch family — the arm of the tools/call chain
// (mcp_server.odin MCP_DISPATCH_CHAIN) that owns the §28 observe commands (pipeline,
// signals, trace, diff, replay_behavior, draw_list) and the time-travel commands
// (load, run, pause, step, rewind, reset, status) over a NAMED session. Each tool here
// marshals its args into a §28 request line and folds it through
// mcp_session_registry_request (mcp_session.odin) on the session's arena, lifting the
// result back into the MCP result. This file is the SEAM the downstream observe/time
// tools task fills — it edits ONLY this file's dispatch proc, never mcp_handle_tools_call.
package main

// mcp_observe_time_dispatch is the observe+time family's arm. STUB: it claims no tool
// yet (handled=false), so every tool flows past it down the chain. The downstream task
// replaces this body — matching the observe/time tool names and folding each through
// dispatch.registry's session — with ZERO edits to the chain caller.
mcp_observe_time_dispatch :: proc(dispatch: Mcp_Dispatch, allocator := context.allocator) -> (result: string, handled: bool) {
	return "", false
}
