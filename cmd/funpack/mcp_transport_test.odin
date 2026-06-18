// Deliberate spec for the MCP stdio transport's serve loop — the line-in /
// handler / line-out fold (serve_mcp_connection). These tests pin the FOUNDATIONAL
// junctions of the transport contract as a living spec: the auth-free round-trip
// (the contrast to serve_attach_connection's auth-gated loop), partial-frame
// reassembly + trailing-fragment drop, the EOF close contract, and the handler's
// keep_open shutdown hook.
//
// All run over an IN-MEMORY Line_Transport (never os.stdin/os.stdout), mirroring
// the runtime's file-private Mem_Conn (runtime/introspect_attach_test.odin:82-128),
// so the loop is deterministic and socket-free. The stdio adapter itself
// (mcp_stdio_transport, os.read/os.write) is NOT unit-tested directly — it is a
// thin adapter over this same seam and would require redirecting real fds, exactly
// as the runtime keeps its core:net adapter untested and the pure loop fully
// covered.
package main

import funpack_runtime "../../runtime"
import "core:strings"
import "core:testing"

// --- In-memory transport backing (the Mem_Conn twin for cmd-layer tests) -------

// Mcp_Mem_Conn is an in-memory Line_Transport backing: `incoming` is the byte
// stream the peer "sends" (drained by recv), `outgoing` accumulates what the loop
// frames back (written by send). `chunk` caps how many bytes a single recv hands
// out — a small cap forces a line to split across reads, exercising the
// Line_Reader's partial-frame reassembly through the cmd-layer loop. 0 ⇒ no cap
// (hand out everything remaining).
@(private = "file")
Mcp_Mem_Conn :: struct {
	incoming: []byte,
	read_pos: int,
	chunk:    int,
	outgoing: strings.Builder,
}

// mem_transport builds a Line_Transport over an Mcp_Mem_Conn: recv hands out the
// peer bytes (chunk-capped when conn.chunk > 0), returning (0, true) once drained
// — the graceful-close signal the line reader reads as EOF (recv_tcp returns 0,nil
// too); send appends to the outgoing builder.
@(private = "file")
mem_transport :: proc(conn: ^Mcp_Mem_Conn) -> funpack_runtime.Line_Transport {
	return funpack_runtime.Line_Transport {
		userdata = conn,
		recv = proc(userdata: rawptr, buf: []byte) -> (n: int, ok: bool) {
			conn := (^Mcp_Mem_Conn)(userdata)
			if conn.read_pos >= len(conn.incoming) {
				return 0, true
			}
			avail := conn.incoming[conn.read_pos:]
			limit := len(buf)
			if conn.chunk > 0 && conn.chunk < limit {
				limit = conn.chunk
			}
			n = copy(buf[:limit], avail)
			conn.read_pos += n
			return n, true
		},
		send = proc(userdata: rawptr, buf: []byte) -> (ok: bool) {
			conn := (^Mcp_Mem_Conn)(userdata)
			strings.write_bytes(&conn.outgoing, buf)
			return true
		},
	}
}

// mem_conn builds an Mcp_Mem_Conn whose incoming stream is the given lines joined
// with newline frames (the bytes a peer would write). raw_tail, when non-empty, is
// appended WITHOUT a trailing newline — the unterminated fragment the EOF contract
// must drop.
@(private = "file")
mem_conn :: proc(lines: []string, raw_tail := "", chunk := 0, allocator := context.allocator) -> Mcp_Mem_Conn {
	b := strings.builder_make(allocator)
	for line in lines {
		strings.write_string(&b, line)
		strings.write_byte(&b, '\n')
	}
	strings.write_string(&b, raw_tail)
	return Mcp_Mem_Conn {
		incoming = transmute([]byte)strings.to_string(b),
		chunk    = chunk,
		outgoing = strings.builder_make(allocator),
	}
}

// --- A recording handler so the tests can assert WHAT the loop dispatched --------

// Rec_Handler records every line the loop hands the handler, so a test asserts the
// exact sequence (and count) of dispatched requests. `stop_on` (non-empty) makes
// the handler return keep_open=false when it sees that line — the JSON-RPC
// shutdown hook. The response is the echoed line (the stub contract this task
// ships), so the framed-out stream equals the dispatched lines.
@(private = "file")
Rec_Handler :: struct {
	seen:    [dynamic]string,
	stop_on: string,
}

@(private = "file")
rec_handler :: proc(rec: ^Rec_Handler) -> Mcp_Line_Handler {
	return Mcp_Line_Handler {
		userdata = rec,
		handle = proc(userdata: rawptr, line: string, allocator := context.allocator) -> (response: string, keep_open: bool) {
			rec := (^Rec_Handler)(userdata)
			append(&rec.seen, strings.clone(line, allocator))
			if rec.stop_on != "" && line == rec.stop_on {
				return line, false
			}
			return line, true
		},
	}
}

// --- The junctions ---------------------------------------------------------------

// test_mcp_serve_roundtrip pins the load-bearing junction: the stdio serve loop is
// line-in / line-out with NO auth pre-amble — the contrast to serve_attach_connection's
// auth-gated loop. N NDJSON lines fold through the loop with an echo handler; N
// framed responses come back in order, each newline-terminated, each equal to its
// input line. The FIRST line is already a request (no handshake consumed it).
@(test)
test_mcp_serve_roundtrip :: proc(t: ^testing.T) {
	lines := []string{`{"jsonrpc":"2.0","id":1,"method":"a"}`, `{"jsonrpc":"2.0","id":2,"method":"b"}`, `{"jsonrpc":"2.0","id":3,"method":"c"}`}
	conn := mem_conn(lines, allocator = context.temp_allocator)
	rec := Rec_Handler{seen = make([dynamic]string, context.temp_allocator)}

	serve_mcp_connection(rec_handler(&rec), mem_transport(&conn), context.temp_allocator)

	testing.expect_value(t, len(rec.seen), len(lines))
	for line, i in lines {
		testing.expect_value(t, rec.seen[i], line)
	}
	// The framed-out stream is each response + its newline, in order — the first
	// line was a request, never an auth handshake (no extra leading frame).
	expected := strings.concatenate({lines[0], "\n", lines[1], "\n", lines[2], "\n"}, context.temp_allocator)
	testing.expect_value(t, strings.to_string(conn.outgoing), expected)
}

// test_mcp_serve_partial_frame_reassembly pins that a line split across recv chunks
// is reassembled into ONE complete request before the handler sees it, and a
// trailing unterminated fragment at close is dropped. A 4-byte recv cap splits
// every line mid-way; the handler must still receive each whole line exactly once,
// and the no-newline tail must never reach it (an incomplete line is not a request).
@(test)
test_mcp_serve_partial_frame_reassembly :: proc(t: ^testing.T) {
	lines := []string{`{"id":1,"method":"first"}`, `{"id":2,"method":"second"}`}
	conn := mem_conn(lines, raw_tail = `{"id":3,"unterm`, chunk = 4, allocator = context.temp_allocator)
	rec := Rec_Handler{seen = make([dynamic]string, context.temp_allocator)}

	serve_mcp_connection(rec_handler(&rec), mem_transport(&conn), context.temp_allocator)

	// Only the two NEWLINE-TERMINATED lines reach the handler, each whole and once;
	// the unterminated tail is dropped.
	testing.expect_value(t, len(rec.seen), len(lines))
	testing.expect_value(t, rec.seen[0], lines[0])
	testing.expect_value(t, rec.seen[1], lines[1])
}

// test_mcp_serve_eof_closes pins the EOF close contract: the loop returns after the
// last complete line and the handler is NOT called again past EOF (recv returns 0
// on a drained stream — the Line_Reader EOF signal, introspect_attach.odin:262-270).
@(test)
test_mcp_serve_eof_closes :: proc(t: ^testing.T) {
	lines := []string{`{"id":1}`}
	conn := mem_conn(lines, allocator = context.temp_allocator)
	rec := Rec_Handler{seen = make([dynamic]string, context.temp_allocator)}

	serve_mcp_connection(rec_handler(&rec), mem_transport(&conn), context.temp_allocator)

	// Exactly one dispatch, then the drained recv ends the loop — no spurious call.
	testing.expect_value(t, len(rec.seen), 1)
	testing.expect_value(t, rec.seen[0], lines[0])
}

// test_mcp_serve_handler_close pins the handler's keep_open shutdown hook: when the
// handler returns keep_open=false on a line, the loop stops dispatching AFTER it —
// the JSON-RPC shutdown/exit path the downstream task ends a session through. The
// line that triggered the close is still answered (framed back) before the loop ends.
@(test)
test_mcp_serve_handler_close :: proc(t: ^testing.T) {
	lines := []string{`{"id":1,"method":"initialize"}`, `{"id":2,"method":"shutdown"}`, `{"id":3,"method":"never"}`}
	conn := mem_conn(lines, allocator = context.temp_allocator)
	rec := Rec_Handler{seen = make([dynamic]string, context.temp_allocator), stop_on = lines[1]}

	serve_mcp_connection(rec_handler(&rec), mem_transport(&conn), context.temp_allocator)

	// The loop dispatched up to and INCLUDING the shutdown line, then stopped — the
	// third line was never seen even though the stream still held it.
	testing.expect_value(t, len(rec.seen), 2)
	testing.expect_value(t, rec.seen[0], lines[0])
	testing.expect_value(t, rec.seen[1], lines[1])
	// The shutdown line was still framed back before the close.
	expected := strings.concatenate({lines[0], "\n", lines[1], "\n"}, context.temp_allocator)
	testing.expect_value(t, strings.to_string(conn.outgoing), expected)
}
