package main

import funpack_runtime "../../runtime"
import "core:os"

Mcp_Line_Handler :: struct {
	userdata: rawptr,
	handle:   proc(userdata: rawptr, line: string, allocator := context.allocator) -> (response: string, keep_open: bool),
}

mcp_stdio_transport :: proc() -> funpack_runtime.Line_Transport {
	return funpack_runtime.Line_Transport {
		userdata = nil,
		recv = proc(userdata: rawptr, buf: []byte) -> (n: int, ok: bool) {
			read_n, err := os.read(os.stdin, buf)
			if err != nil {
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

serve_mcp_stdio :: proc(handler: Mcp_Line_Handler, allocator := context.allocator) {
	serve_mcp_connection(handler, mcp_stdio_transport(), allocator)
}

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
