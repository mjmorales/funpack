// The SCREENSHOT tool dispatch family — the arm of the tools/call chain
// (mcp_server.odin MCP_DISPATCH_CHAIN) that owns inspect_screenshot over a NAMED
// session. Per the resolved ADR this arm hand-rolls a minimal stored-block PNG encoder
// (core has no PNG encoder — core:image/png is decode-only) so MCP ImageContent
// carries a renderable image/png; it returns an .Image content block, not text. This
// file is the SEAM the downstream mcp-tools-screenshot task fills — it edits ONLY this
// file's dispatch proc, never mcp_handle_tools_call.
package main

// mcp_screenshot_dispatch is the screenshot family's arm. STUB: it claims no tool yet
// (handled=false), so every tool flows past it down the chain. The downstream
// screenshot task replaces this body — matching inspect_screenshot, folding the
// session capture, and emitting the encoded image content — with ZERO edits to the
// chain caller.
mcp_screenshot_dispatch :: proc(dispatch: Mcp_Dispatch, allocator := context.allocator) -> (result: string, handled: bool) {
	return "", false
}
