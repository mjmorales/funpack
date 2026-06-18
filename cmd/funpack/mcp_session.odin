// The server-scoped session registry + per-session arena lifetime — the F13 fix at
// its source. The Go path learned it the hard way: a debug session must OUTLIVE the
// tool-call request that opened it (the SDK cancels the request ctx the instant
// session_start returns). Here that is structural, not a discipline: each named
// session owns a DEDICATED core:mem/virtual.Arena, and the runtime Debug_Session it
// holds is opened ON that arena's allocator — so the retained COW version chain and
// the per-boundary Rng states live for the session's lifetime, never the request's.
// session_end is one arena_destroy: a single free, no per-request leak, no
// OS-process-group teardown (the Go reaper's job, now allocator discipline).
//
// SINGLE-THREADED PER SESSION: a control command commits its forked branch head as
// per-session mutable state (introspect.odin Debug_Session.branch), so a session's
// requests are serialized. Concurrent sessions each own their own entry (arena +
// Debug_Session + program), so they never share mutable state — the registry is the
// only shared structure and its map is mutated only on open/end.
//
// WHERE THIS LIVES: cmd/funpack ONLY (the FUNPACK_LIVE build). The registry holds a
// runtime Debug_Session, and pulling that into the pure SDL-free funpack compiler
// subtree would break the deterministic odin test / odin check floor. The registry
// itself touches no SDL — it is define-free here and its tests run in the default
// `odin test .` floor — but it is correctly homed beside the verb that owns it.
//
// THE REQUEST FOLD ALLOCATOR (the retention rule, the F13 crux): a request is folded
// through session_request on the SESSION ARENA allocator, NOT a per-request scratch
// arena. session_request uses one allocator for both the response render AND the COW
// commit a control command makes (introspect.odin:437-462) — exactly as the attach
// serve loop folds on its connection allocator and never frees between lines
// (introspect_attach.odin:286-293). The session arena holds that chain for the
// session's life and reaps it whole at session_end. The OUTER JSON-RPC envelope
// (parse + render) is what uses the protocol loop's per-request scratch; that scratch
// must NEVER touch a session arena (an arena_free_all on it would corrupt the chain).
package main

import funpack_runtime "../../runtime"
import "core:mem/virtual"
import "core:strconv"
import "core:strings"

// Mcp_Session_Entry is one live session the registry owns: its dedicated arena, the
// runtime Debug_Session opened on that arena, and the heap Program the session
// BORROWS (open_session_for_artifact new's the Program on the same arena, so the
// session's `program` pointer stays valid for the entry's life). Everything the
// session allocated — the COW chain, the snapshots, the program — sits in `arena`, so
// arena_destroy frees the entry in one shot. The id is the stable handle the tool
// arms look the entry up by (mcp_session_registry_lookup); label is the optional
// human/agent-supplied name a session_start may carry (the downstream lifecycle tool
// surfaces it in session_list — kept here so the entry is the single record).
Mcp_Session_Entry :: struct {
	id:      string,
	label:   string,
	arena:   virtual.Arena,
	session: funpack_runtime.Debug_Session,
	program: ^funpack_runtime.Program,
}

// Mcp_Session_Registry is the server-scoped session table. It is created once per
// served connection (the server, not the request, owns it) and torn down on shutdown.
// `entries` keys an entry by its minted id; `next_id` is the monotonic id source so
// every session gets a distinct, stable handle for its lifetime. The map and the
// counter are the ONLY mutable shared state — mutated solely on open/end, never on a
// per-request read (lookup borrows the entry, the request fold mutates only the
// entry's own session). The registry struct itself lives on the server allocator; the
// per-session arenas it mints are independent of that allocator.
Mcp_Session_Registry :: struct {
	entries: map[string]^Mcp_Session_Entry,
	next_id: int,
}

// MCP_SESSION_ID_PREFIX prefixes every minted session id ("sess-1", "sess-2", …). A
// prefixed, monotonic id is a stable opaque handle: the tool arms pass it back verbatim
// and never parse it, so the format is free to change behind the prefix.
MCP_SESSION_ID_PREFIX :: "sess-"

// mcp_session_registry_make creates an empty registry on `allocator` — the
// server-scoped table, minted once at serve start. The map allocates on `allocator`;
// each session's own state goes on its dedicated arena, not here.
mcp_session_registry_make :: proc(allocator := context.allocator) -> Mcp_Session_Registry {
	return Mcp_Session_Registry{entries = make(map[string]^Mcp_Session_Entry, allocator), next_id = 1}
}

// mcp_session_registry_open mints a new session over an artifact (and an optional
// replay log), opening the runtime Debug_Session ON a freshly-minted per-session arena
// so the session's retained state outlives the request that opened it (the F13 fix).
// It returns the minted id and the runtime's discriminated open result; on any
// non-`Ok` result the arena is destroyed before returning (no orphaned arena) and id
// is empty. The `label` is the optional caller-supplied name carried on the entry for
// session_list. `registry_allocator` is the server allocator the entry struct + map
// growth use; the SESSION's state (program, snapshots, COW chain) lives on the entry
// arena, never on registry_allocator.
mcp_session_registry_open :: proc(
	reg: ^Mcp_Session_Registry,
	artifact_path: string,
	replay_log: string,
	has_replay: bool,
	label: string = "",
	registry_allocator := context.allocator,
) -> (
	id: string,
	result: funpack_runtime.Open_Session_Result,
) {
	entry := new(Mcp_Session_Entry, registry_allocator)

	// The dedicated per-session arena. A growing virtual arena matches the session's
	// shape: the COW chain and per-request response renders accrete over the session's
	// life and are freed whole at session_end — never per request.
	if arena_err := virtual.arena_init_growing(&entry.arena); arena_err != .None {
		free(entry, registry_allocator)
		return "", .Artifact_Read_Failed
	}
	session_allocator := virtual.arena_allocator(&entry.arena)

	// Open the session ON the session arena: open_session_for_artifact new's the
	// Program and the snapshots on this allocator and folds the recording through
	// open_debug_session, so the whole session graph is arena-owned (introspect_attach
	// .odin:541-548 — a per-session arena frees it in one shot).
	session, program, open_result := funpack_runtime.open_session_for_artifact(
		artifact_path,
		replay_log,
		has_replay,
		session_allocator,
	)
	if open_result != .Ok {
		// The partial allocation (the new'd program, any read bytes) sits in the arena;
		// destroying it reclaims everything — no per-failure leak.
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

// mcp_session_mint_id mints the next monotonic, prefixed session id on `allocator`.
// The id is stored on the entry and returned to the caller as an opaque handle; the
// counter only ever increases, so a reused-then-ended id is never re-minted within a
// server lifetime.
mcp_session_mint_id :: proc(reg: ^Mcp_Session_Registry, allocator := context.allocator) -> string {
	b := strings.builder_make(allocator)
	strings.write_string(&b, MCP_SESSION_ID_PREFIX)
	buf: [32]u8
	strings.write_string(&b, strconv.write_int(buf[:], i64(reg.next_id), 10))
	reg.next_id += 1
	return strings.to_string(b)
}

// mcp_session_registry_lookup borrows the live entry for an id — the seam the tool
// arms dispatch a session-scoped tool through (id → entry → session). It returns the
// entry by POINTER (the request fold mutates the entry's own session in place) and
// found=false for an unknown/ended id (the Session-category refusal path the tool arm
// maps to a stale-session error).
mcp_session_registry_lookup :: proc(reg: ^Mcp_Session_Registry, id: string) -> (entry: ^Mcp_Session_Entry, found: bool) {
	entry, found = reg.entries[id]
	return
}

// mcp_session_registry_request folds one §28 request line through a named session and
// returns the response line. THE F13 CRUX: the fold runs on the SESSION ARENA
// allocator, so a control command's forked branch head (introspect.odin:460) commits
// into the arena that lives for the session's lifetime — a LATER request reads it back
// (the regression the named test pins). The OUTER JSON-RPC envelope's per-request
// scratch is the protocol loop's concern and must never be handed here. An unknown id
// is found=false — the caller renders the stale-session refusal; the session is never
// fabricated.
mcp_session_registry_request :: proc(reg: ^Mcp_Session_Registry, id: string, line: string) -> (response: string, found: bool) {
	entry, ok := reg.entries[id]
	if !ok {
		return "", false
	}
	session_allocator := virtual.arena_allocator(&entry.arena)
	return funpack_runtime.session_request(&entry.session, line, session_allocator), true
}

// mcp_session_registry_end tears one session down: arena_destroy frees its WHOLE graph
// (program, snapshots, COW chain, every request response) in a single free, then the
// entry struct is freed and the map row removed. This is the session_end contract — no
// reaper, no process-group kill, just one arena release. Idempotent on an unknown id
// (found=false), so a double-end is a clean no-op the caller maps to a refusal rather
// than a fault. `registry_allocator` must match the one open used (the entry struct's
// owner).
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

// mcp_session_registry_destroy tears down the WHOLE registry at server shutdown:
// every live session's arena is destroyed (the shutdown teardown the Go path did via
// process-group kill), then each entry struct is freed and the map released. After
// this the registry is empty and reusable. `registry_allocator` must match make's.
mcp_session_registry_destroy :: proc(reg: ^Mcp_Session_Registry, registry_allocator := context.allocator) {
	for _, entry in reg.entries {
		virtual.arena_destroy(&entry.arena)
		free(entry, registry_allocator)
	}
	delete(reg.entries)
	reg.entries = nil
	reg.next_id = 1
}
