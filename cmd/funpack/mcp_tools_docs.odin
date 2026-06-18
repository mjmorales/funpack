// The DOCS-tool dispatch family — the arm of the tools/call chain (mcp_server.odin
// MCP_DISPATCH_CHAIN) that owns docs_get / docs_search over the embedded corpus + the
// ported BM25/symbol/blend ranker (mcp_docs_search.odin et al). This file is the SEAM
// the downstream docs-tools task fills — it edits ONLY this file's dispatch proc,
// never mcp_handle_tools_call.
package main

// mcp_docs_tool_dispatch is the docs family's arm. STUB: it claims no tool yet
// (handled=false), so every tool flows past it down the chain. The downstream docs
// task replaces this body — matching docs_get/docs_search and rendering the ranked
// results — with ZERO edits to the chain caller.
mcp_docs_tool_dispatch :: proc(dispatch: Mcp_Dispatch, allocator := context.allocator) -> (result: string, handled: bool) {
	return "", false
}
