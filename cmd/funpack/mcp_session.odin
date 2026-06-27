package main

import funpack_runtime "../../runtime"
import "core:mem/virtual"
import "core:strconv"
import "core:strings"

Mcp_Session_Entry :: struct {
	id:      string,
	label:   string,
	// F13: this arena spans the SESSION's lifetime, not a request's — a session must outlive the call that opened it.
	arena:   virtual.Arena,
	session: funpack_runtime.Debug_Session,
	program: ^funpack_runtime.Program,
}

Mcp_Session_Registry :: struct {
	entries: map[string]^Mcp_Session_Entry,
	next_id: int,
}

MCP_SESSION_ID_PREFIX :: "sess-"

mcp_session_registry_make :: proc(allocator := context.allocator) -> Mcp_Session_Registry {
	return Mcp_Session_Registry{entries = make(map[string]^Mcp_Session_Entry, allocator), next_id = 1}
}

mcp_session_registry_open :: proc(
	reg: ^Mcp_Session_Registry,
	artifact_path: string,
	replay_log: string,
	has_replay: bool,
	label: string = "",
	registry_allocator := context.allocator,
	seed_override: Maybe(i64) = nil,
) -> (
	id: string,
	result: funpack_runtime.Open_Session_Result,
) {
	entry := new(Mcp_Session_Entry, registry_allocator)

	if arena_err := virtual.arena_init_growing(&entry.arena); arena_err != .None {
		free(entry, registry_allocator)
		return "", .Session_Alloc_Failed
	}
	session_allocator := virtual.arena_allocator(&entry.arena)

	session, program, open_result := funpack_runtime.open_session_for_artifact(
		artifact_path,
		replay_log,
		has_replay,
		session_allocator,
		seed_override,
	)
	if open_result != .Ok {
		virtual.arena_destroy(&entry.arena)
		free(entry, registry_allocator)
		return "", open_result
	}

	id = mcp_session_mint_id(reg, registry_allocator)
	entry.id = id
	entry.label = label
	entry.session = session
	entry.program = program
	reg.entries[id] = entry
	return id, .Ok
}

mcp_session_mint_id :: proc(reg: ^Mcp_Session_Registry, allocator := context.allocator) -> string {
	b := strings.builder_make(allocator)
	strings.write_string(&b, MCP_SESSION_ID_PREFIX)
	buf: [32]u8
	strings.write_string(&b, strconv.write_int(buf[:], i64(reg.next_id), 10))
	reg.next_id += 1
	return strings.to_string(b)
}

mcp_session_registry_lookup :: proc(reg: ^Mcp_Session_Registry, id: string) -> (entry: ^Mcp_Session_Entry, found: bool) {
	entry, found = reg.entries[id]
	return
}

mcp_session_registry_request :: proc(reg: ^Mcp_Session_Registry, id: string, line: string) -> (response: string, found: bool) {
	entry, ok := reg.entries[id]
	if !ok {
		return "", false
	}
	session_allocator := virtual.arena_allocator(&entry.arena)
	return funpack_runtime.session_request(&entry.session, line, session_allocator), true
}

mcp_session_registry_end :: proc(reg: ^Mcp_Session_Registry, id: string, registry_allocator := context.allocator) -> (found: bool) {
	entry, ok := reg.entries[id]
	if !ok {
		return false
	}
	virtual.arena_destroy(&entry.arena)
	delete_key(&reg.entries, id)
	free(entry, registry_allocator)
	return true
}

mcp_session_registry_destroy :: proc(reg: ^Mcp_Session_Registry, registry_allocator := context.allocator) {
	for _, entry in reg.entries {
		virtual.arena_destroy(&entry.arena)
		free(entry, registry_allocator)
	}
	delete(reg.entries)
	reg.entries = nil
	reg.next_id = 1
}
