// The SESSION-LIFECYCLE tool dispatch family — the arm of the tools/call chain
// (mcp_server.odin MCP_DISPATCH_CHAIN) that owns session_start / session_list /
// session_end. It is the family that drives the server-scoped session registry
// (mcp_session.odin) reached through dispatch.registry: session_start opens a session
// on a dedicated arena and returns its id, session_list reports the live entries,
// session_end is the arena_destroy teardown. This file is the SEAM the downstream
// mcp-tools-session-lifecycle task fills — it edits ONLY this file's dispatch proc,
// never mcp_handle_tools_call. The registry INFRASTRUCTURE it drives already exists
// (mcp_session.odin); this arm wires the three tools onto it.
package main

// mcp_session_tool_dispatch is the session family's arm. STUB: it claims no tool yet
// (handled=false), so every tool flows past it down the chain. The downstream
// session-lifecycle task replaces this body — matching session_start/list/end and
// driving dispatch.registry (mcp_session_registry_open/lookup/end) — with ZERO edits
// to the chain caller. The registry it will drive is already live on dispatch.registry.
mcp_session_tool_dispatch :: proc(dispatch: Mcp_Dispatch, allocator := context.allocator) -> (result: string, handled: bool) {
	return "", false
}
