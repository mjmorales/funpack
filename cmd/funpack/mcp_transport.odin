// The stdio JSON-RPC transport scaffolding for `funpack mcp` — the line-framed,
// AUTH-FREE serve loop and its stdin/stdout backing. This is the TWIN of the
// runtime's serve_attach_connection (runtime/introspect_attach.odin:294-320),
// MINUS the auth handshake: MCP over stdio inverts the attach trust model (the
// host forks this server and owns its inherited fds, so there is no listening
// port to gate), so per the resolved AUTH ADR there is NO token, NO handshake,
// NO Attach_Auth — the stdio peer is trusted by construction and absolute stdout
// discipline is the sole hard transport invariant.
//
// THE REUSE (Odin-first): the transport-agnostic byte-stream seam already exists,
// is pure, and is headless-tested in the runtime package — Line_Transport /
// Line_Reader / new_line_reader / reader_next_line / transport_send_line
// (runtime/introspect_attach.odin:224-347, all package-public). This file does
// NOT re-frame NDJSON; it (1) adapts os.stdin/os.stdout into a Line_Transport and
// (2) folds that transport through an auth-free request loop. The newline framing,
// the partial-frame reassembly, and the EOF contract are the runtime seam's, run
// here unchanged.
//
// THE SOFT LSP SEAM (ADR): newline framing ONLY — no Content-Length Framer. The
// serve loop and the stdio transport are written dependency-light so a future
// `funpack lsp` verb lifts them and layers Content-Length framing on top when it
// has a real second consumer; we do not pay that abstraction cost speculatively.
//
// THE HANDLER SEAM: the request semantics (JSON-RPC 2.0 parse / dispatch / the
// tools surface) are the DOWNSTREAM mcp-protocol-verb task's concern, not this
// one. This transport is strictly framing: it hands each complete line to a
// Mcp_Line_Handler callback and frames whatever the handler returns back out. The
// real JSON-RPC handler (mcp_server.odin mcp_jsonrpc_handler) is what cli_run_mcp
// folds through this same callback; the transport stays oblivious to its semantics.
package main

import funpack_runtime "../../runtime"
import "core:os"

// Mcp_Line_Handler is the request-semantics seam the serve loop folds each
// complete request line through. It is a bare proc (not a struct+vtable) to keep
// this transport dependency-light, with a `userdata` rawptr so the downstream
// dispatch can thread per-session state (the JSON-RPC handler + session registry)
// without this file knowing its shape. It returns the response line to frame back
// (empty ⇒ nothing is written, the JSON-RPC notification case — a request with no
// reply) and keep_open (false ⇒ the loop stops after this line, the JSON-RPC
// shutdown/exit hook). The allocator is the per-request scratch the loop owns.
Mcp_Line_Handler :: struct {
	userdata: rawptr,
	handle:   proc(userdata: rawptr, line: string, allocator := context.allocator) -> (response: string, keep_open: bool),
}

// mcp_stdio_transport adapts the process's standard streams into the runtime's
// Line_Transport seam: recv reads up to len(buf) bytes off os.stdin (mapping both
// a 0-byte read AND an EOF error to the graceful-close (0, true) the Line_Reader
// reads as end-of-stream, matching recv_tcp's 0,nil); send writes the whole buffer
// to os.stdout. STDOUT DISCIPLINE: this send is the ONLY writer to os.stdout in
// the mcp verb — it writes nothing but framed handler responses; every diagnostic
// routes to stderr. The os.read/os.write faults map to ok=false so the loop ends
// the stream rather than spinning on a broken pipe.
mcp_stdio_transport :: proc() -> funpack_runtime.Line_Transport {
	return funpack_runtime.Line_Transport {
		userdata = nil,
		recv = proc(userdata: rawptr, buf: []byte) -> (n: int, ok: bool) {
			read_n, err := os.read(os.stdin, buf)
			if err != nil {
				// EOF and any read fault alike map to the graceful-close signal
				// the Line_Reader expects (0, true): an unterminated tail is
				// dropped and the loop ends cleanly. A partial read before EOF
				// still returns its n bytes here (err is nil for those).
				return 0, true
			}
			return read_n, true
		},
		send = proc(userdata: rawptr, buf: []byte) -> (ok: bool) {
			written, err := os.write(os.stdout, buf)
			return err == nil && written == len(buf)
		},
	}
}

// serve_mcp_stdio runs the MCP server over the process's standard streams: it
// builds the stdio transport and folds it through the auth-free serve loop. This
// is the verb's entry — a thin compose over the testable pure loop below (the
// stdio adapter itself is NOT unit-tested, exactly as the runtime keeps the
// when-gated core:net adapter untested and the pure loop fully covered).
serve_mcp_stdio :: proc(handler: Mcp_Line_Handler, allocator := context.allocator) {
	serve_mcp_connection(handler, mcp_stdio_transport(), allocator)
}

// serve_mcp_connection serves ONE MCP connection over a Line_Transport — the
// AUTH-FREE twin of serve_attach_connection. There is NO auth handshake: the
// first line is already a request. Each complete NDJSON line is folded through the
// handler; a non-empty response is framed back with its newline (transport_send_line),
// an empty response is the notification case (nothing written). The loop ends on
// (1) a peer close (reader_next_line ok=false — the Line_Reader EOF contract,
// runtime/introspect_attach.odin:262-270), (2) the handler signalling keep_open
// =false (the JSON-RPC shutdown hook), or (3) a send fault.
//
// Pure over (handler, transport) so the buffer-backed tests exercise the loop
// end-to-end with no stdin/stdout, exactly as Mem_Conn fills the same seam for the
// attach loop. The downstream JSON-RPC handler is the only moving part swapped in.
serve_mcp_connection :: proc(handler: Mcp_Line_Handler, transport: funpack_runtime.Line_Transport, allocator := context.allocator) {
	reader := funpack_runtime.new_line_reader(transport, allocator)
	defer delete(reader.pending)

	for {
		line, have_request := funpack_runtime.reader_next_line(&reader, allocator)
		if !have_request {
			return
		}
		response, keep_open := handler.handle(handler.userdata, line, allocator)
		if response != "" {
			if !funpack_runtime.transport_send_line(transport, response, allocator) {
				return
			}
		}
		if !keep_open {
			return
		}
	}
}
