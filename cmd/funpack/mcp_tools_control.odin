// The CONTROL tool dispatch family — the arm of the tools/call chain (mcp_server.odin
// MCP_DISPATCH_CHAIN) that owns the §28 control commands (branch, checkout,
// inject_input, set, spawn, despawn, emit, reload) plus break/watch/clear and the
// capture_test / audit tools over a NAMED session. A control command PERTURBS, so it
// forks the session's branch head as per-session mutable state — committed THROUGH the
// session arena (mcp_session_registry_request, the F13 retention rule) so a later
// request reads it back. This file is the SEAM the downstream control tools task fills
// — it edits ONLY this file's dispatch proc, never mcp_handle_tools_call.
package main

// mcp_control_dispatch is the control family's arm. STUB: it claims no tool yet
// (handled=false), so every tool flows past it down the chain. The downstream task
// replaces this body — matching the control tool names and folding each through
// dispatch.registry's session — with ZERO edits to the chain caller.
mcp_control_dispatch :: proc(dispatch: Mcp_Dispatch, allocator := context.allocator) -> (result: string, handled: bool) {
	return "", false
}
