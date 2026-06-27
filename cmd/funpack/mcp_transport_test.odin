package main

import funpack_runtime "../../runtime"
import "core:strings"
import "core:testing"

@(private = "file")
Mcp_Mem_Conn :: struct {
	incoming: []byte,
	read_pos: int,
	chunk:    int,
	outgoing: strings.Builder,
}

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
	expected := strings.concatenate({lines[0], "\n", lines[1], "\n", lines[2], "\n"}, context.temp_allocator)
	testing.expect_value(t, strings.to_string(conn.outgoing), expected)
}

@(test)
test_mcp_serve_partial_frame_reassembly :: proc(t: ^testing.T) {
	lines := []string{`{"id":1,"method":"first"}`, `{"id":2,"method":"second"}`}
	conn := mem_conn(lines, raw_tail = `{"id":3,"unterm`, chunk = 4, allocator = context.temp_allocator)
	rec := Rec_Handler{seen = make([dynamic]string, context.temp_allocator)}

	serve_mcp_connection(rec_handler(&rec), mem_transport(&conn), context.temp_allocator)

	testing.expect_value(t, len(rec.seen), len(lines))
	testing.expect_value(t, rec.seen[0], lines[0])
	testing.expect_value(t, rec.seen[1], lines[1])
}

@(test)
test_mcp_serve_eof_closes :: proc(t: ^testing.T) {
	lines := []string{`{"id":1}`}
	conn := mem_conn(lines, allocator = context.temp_allocator)
	rec := Rec_Handler{seen = make([dynamic]string, context.temp_allocator)}

	serve_mcp_connection(rec_handler(&rec), mem_transport(&conn), context.temp_allocator)

	testing.expect_value(t, len(rec.seen), 1)
	testing.expect_value(t, rec.seen[0], lines[0])
}

@(test)
test_mcp_serve_handler_close :: proc(t: ^testing.T) {
	lines := []string{`{"id":1,"method":"initialize"}`, `{"id":2,"method":"shutdown"}`, `{"id":3,"method":"never"}`}
	conn := mem_conn(lines, allocator = context.temp_allocator)
	rec := Rec_Handler{seen = make([dynamic]string, context.temp_allocator), stop_on = lines[1]}

	serve_mcp_connection(rec_handler(&rec), mem_transport(&conn), context.temp_allocator)

	testing.expect_value(t, len(rec.seen), 2)
	testing.expect_value(t, rec.seen[0], lines[0])
	testing.expect_value(t, rec.seen[1], lines[1])
	expected := strings.concatenate({lines[0], "\n", lines[1], "\n"}, context.temp_allocator)
	testing.expect_value(t, strings.to_string(conn.outgoing), expected)
}
