// The ONE-SHOT compute-tool dispatch family — the arm of the tools/call chain
// (mcp_server.odin MCP_DISPATCH_CHAIN) that owns the stateless tools that call a pure
// funpack compute-half directly with NO session: build/export/check/fmt, warden_*,
// surface/check, health/version (all return strings, per the resolved ADR). This file
// is the SEAM the downstream mcp-tools-oneshot task fills — it edits ONLY this file's
// dispatch proc, never mcp_handle_tools_call.
package main

// mcp_oneshot_dispatch is the one-shot family's arm. STUB: it claims no tool yet
// (handled=false), so every tool flows past it down the chain to the not-implemented
// stub. The downstream mcp-tools-oneshot task replaces this body — matching the
// one-shot tool names and rendering each compute-half result — with ZERO edits to the
// chain caller.
mcp_oneshot_dispatch :: proc(dispatch: Mcp_Dispatch, allocator := context.allocator) -> (result: string, handled: bool) {
	return "", false
}
