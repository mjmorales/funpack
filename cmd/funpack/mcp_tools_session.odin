// The SESSION-LIFECYCLE tool dispatch family — the arm of the tools/call chain
// (mcp_server.odin MCP_DISPATCH_CHAIN) that owns session_start / session_list /
// session_end. It is the family that drives the server-scoped session registry
// (mcp_session.odin) reached through dispatch.registry: session_start opens a session
// on a dedicated arena and returns its id, session_list reports the live entries,
// session_end is the arena_destroy teardown. This file is ONE dispatch seam — it owns
// ONLY this file's dispatch proc, never mcp_handle_tools_call. The registry
// INFRASTRUCTURE it drives lives in mcp_session.odin; this arm wires the three tools
// onto it.
//
// UNLIKE the observe/control families, these tools carry NO §28 request marshalling:
// they manage the registry DIRECTLY (open / enumerate / end), so the int-as-float arg
// trap that bites a §28 fold does not apply here — the only argument is a string
// (`artifact` for start, `session_id` for end). They are server-native tools (the
// generated Tool_Spec group is "session", session_scoped=false, command==name), so the
// claim test is on the spec's .group, never a §28 wire command (there is none).
//
// AUTH-FREE (the resolved ADR, operator-gated): the loopback-token apparatus existed
// only because attach opens a listening TCP port; stdio inverts that — the host forks
// the server and owns its inherited fds, so the peer is trusted. There is no token
// check on session_start; absolute stdout discipline is the sole hard transport
// invariant, owned by the JSON-RPC writer, not by this arm.
//
// NAMESPACE DISCIPLINE: every package-level proc/type/constant this file adds is
// prefixed `sess_` so package main has NO duplicate symbols when all six dispatch
// families merge (each family file owns its own prefix). The one EXCEPTION is the
// dispatch entry point mcp_session_tool_dispatch — its name is fixed by the chain in
// mcp_server.odin (MCP_DISPATCH_CHAIN) and must not change.
package main

import "../../funpack"
import funpack_runtime "../../runtime"
import "core:encoding/json"
import "core:strings"

// mcp_session_tool_dispatch is the session family's arm. It claims session_start /
// session_list / session_end by their generated Tool_Spec .group ("session"), declining
// any other tool (handled=false) so the chain tries the next family. Each claimed tool
// drives dispatch.registry directly — open (returning {session_id, negotiated_version}),
// enumerate (returning the live entries), or end (arena_destroy teardown) — and renders
// the outcome as an MCP tool result. ANY open failure (artifact unreadable/malformed,
// replay mismatch, arena-at-cap) is the in-band IsError envelope with NO orphaned
// arena (mcp_session_registry_open destroys the arena before returning non-Ok), never a
// JSON-RPC error object. The dispatch hint is the spec's .group, so this arm cannot
// drift from the advertised tool set (the generated-projection contract).
mcp_session_tool_dispatch :: proc(dispatch: Mcp_Dispatch, allocator := context.allocator) -> (result: string, handled: bool) {
	if !sess_owns_command(dispatch.spec) {
		return "", false
	}

	switch dispatch.name {
	case "session_start":
		return sess_start(dispatch, allocator), true
	case "session_list":
		return sess_list(dispatch, allocator), true
	case "session_end":
		return sess_end(dispatch, allocator), true
	}

	// A tool in the "session" group this arm does not name is the family's own gap —
	// surfaced as an Internal fault rather than silently declined (a declined claimed
	// group would fall through the chain to the not-implemented stub, masking the gap).
	return mcp_tool_error(
		dispatch.id,
		Mcp_Error{category = .Internal, message = "session-family tool has no dispatch arm", detail = dispatch.name},
		allocator,
	), true
}

// sess_owns_command is the family's claim test: it owns exactly the server-native
// session-lifecycle group. The check is on the generated Tool_Spec's .group ("session")
// — the dispatch family this arm declares — NOT on the tool name, so a renamed tool that
// keeps its group still routes here. Every OTHER group (inspect/time/control/oneshot/
// docs/screenshot) is owned by another family; this arm declines them so the chain
// reaches their file.
sess_owns_command :: proc(spec: funpack.Tool_Spec) -> bool {
	return spec.group == "session"
}

// sess_start opens a fresh debug session over the `artifact` path and registers it,
// returning {session_id, negotiated_version, seeded, seed} as the clean result. The
// negotiated version is the §28 protocol version the opened session speaks
// (INTROSPECT_PROTOCOL_VERSION) — the handle the model uses to confirm the wire
// contract every later session-scoped tool folds through. The OPTIONAL `replay_log`
// arg mirrors `funpack attach`'s second positional: when present, the recording is
// pre-folded so the session opens ON the recorded ticks (time_*/inspect_* navigate
// real gameplay) instead of a fresh empty timeline (friction-9771c0f4); absent,
// has_replay is false and the session opens fresh. The OPTIONAL `seed` arg overrides
// the BARE-open root seed (§25 §60) for a uses_rng game so the bare session reproduces
// the seeded run; it is ignored over a replay log (the log pins its own). The result
// ECHOES the resolved seeded/seed so the agent learns up front whether the session
// folds a recorded seed (seeded:true) or is a genuine seedless read (seeded:false) —
// the friction-7dfc0512 diagnosability gap a seeded bare open closes (without the echo
// a frozen-at-defaults seedless session is indistinguishable from a real seeded one). An
// absent/non-string artifact is Invalid_Input; a
// non-string replay_log / non-integer seed is ignored (treated as absent — optional
// args, not contract violations); any non-Ok open is the runtime's discriminated
// failure mapped to its category, with NO orphaned arena (the registry open destroys
// the per-attempt arena before returning).
sess_start :: proc(dispatch: Mcp_Dispatch, allocator := context.allocator) -> string {
	artifact, has_artifact := sess_string_arg(dispatch.arguments, "artifact")
	if !has_artifact {
		return mcp_tool_error(
			dispatch.id,
			Mcp_Error{category = .Invalid_Input, message = "missing required string argument: artifact"},
			allocator,
		)
	}

	// The optional replay-log selector: present + a string pre-folds the recording; absent
	// opens a fresh window. has_replay is the runtime's "fold this recording" flag — false
	// when the arg is omitted, so the default path is byte-identical to the no-replay open.
	replay_log, has_replay := sess_string_arg(dispatch.arguments, "replay_log")

	// The optional bare-open seed override (§25 §60): present + integer pins the root
	// seed for a uses_rng game; absent (nil) lets the helper resolve the entrypoint
	// config seed / engine default. A non-integer is treated as absent (an optional arg).
	seed_override: Maybe(i64)
	if seed, has_seed := sess_int_arg(dispatch.arguments, "seed"); has_seed {
		seed_override = seed
	}

	// Open ON a dedicated per-session arena (the F13 lifetime fix lives in the registry):
	// the session outlives this tool call. The registry struct + entry use the per-call
	// `allocator`; the session's own state (program, snapshots, COW chain) lives on the
	// arena the registry mints, reaped whole at session_end.
	id, open_result := mcp_session_registry_open(dispatch.registry, artifact, replay_log, has_replay, "", allocator, seed_override)
	if open_result != .Ok {
		return mcp_tool_error(dispatch.id, sess_open_error(open_result, artifact, replay_log), allocator)
	}

	// Read the resolved seed off the freshly-opened entry (the runtime resolved the
	// §25 §60 precedence): seeded=true with the real seed when the session folds one,
	// false otherwise. The lookup is total here (the id was just minted).
	seed := funpack_runtime.NO_SEED
	if entry, found := mcp_session_registry_lookup(dispatch.registry, id); found {
		seed = entry.session.seed
	}

	body := sess_render_start_result(id, funpack_runtime.INTROSPECT_PROTOCOL_VERSION, seed, allocator)
	return mcp_text_result(dispatch.id, body, allocator)
}

// sess_list enumerates every live session in the registry as a clean result —
// {"sessions":[{session_id,label},…]} — the model's reach into what is currently open.
// It takes no arguments (the generated Tool_Spec carries an empty arg set), drives the
// registry map directly (no §28 fold), and is always a clean result (an empty registry
// is the empty array, never an error). The label is the optional caller-supplied name
// carried on each entry; when session_start opens without one it is the empty string.
sess_list :: proc(dispatch: Mcp_Dispatch, allocator := context.allocator) -> string {
	b := strings.builder_make(allocator)
	strings.write_string(&b, "{\"sessions\":[")
	first := true
	for id, entry in dispatch.registry.entries {
		if !first {
			strings.write_byte(&b, ',')
		}
		first = false
		strings.write_string(&b, "{\"session_id\":")
		funpack_runtime.write_json_string(&b, id)
		strings.write_string(&b, ",\"label\":")
		funpack_runtime.write_json_string(&b, entry.label)
		strings.write_byte(&b, '}')
	}
	strings.write_string(&b, "]}")
	return mcp_text_result(dispatch.id, strings.to_string(b), allocator)
}

// sess_end tears a named session down — arena_destroy frees its WHOLE graph in one free
// (mcp_session_registry_end), returning {session_id,ended:true} as the clean ack. An
// absent/non-string session_id is Invalid_Input; an id the registry never minted (or a
// double-end) is the Session-category refusal, never a fault — the registry's
// idempotent found=false contract maps to a clean in-band error the model reads and
// moves past (the session is already gone, which is what the caller wanted).
sess_end :: proc(dispatch: Mcp_Dispatch, allocator := context.allocator) -> string {
	session_id, has_session := sess_string_arg(dispatch.arguments, "session_id")
	if !has_session {
		return mcp_tool_error(
			dispatch.id,
			Mcp_Error{category = .Invalid_Input, message = "missing required string argument: session_id"},
			allocator,
		)
	}

	if !mcp_session_registry_end(dispatch.registry, session_id, allocator) {
		return mcp_tool_error(
			dispatch.id,
			Mcp_Error{category = .Session, message = "unknown session id", detail = session_id},
			allocator,
		)
	}

	b := strings.builder_make(allocator)
	strings.write_string(&b, "{\"session_id\":")
	funpack_runtime.write_json_string(&b, session_id)
	strings.write_string(&b, ",\"ended\":true}")
	return mcp_text_result(dispatch.id, strings.to_string(b), allocator)
}

// sess_render_start_result renders the session_start clean result body —
// {"session_id":…,"negotiated_version":N,"seeded":bool,"seed":N} — built with the same
// strings.Builder + write_json_string idiom the §28 envelope renderers use
// (introspect.odin), so the body is byte-stable. The id is a string handle;
// negotiated_version is the §28 protocol integer the session speaks (so an integer,
// never a float — the model reads it raw). `seeded` is whether the opened session folds
// a recorded/resolved RNG seed (the §25 §60 bare-open resolution or a replay log's
// pinned seed); `seed` is that tick-0 root seed (meaningful only when seeded, 0
// otherwise) — the self-describing pair an agent reads to know a uses_rng session is
// surfacing the real seeded run, not frozen-at-defaults state.
sess_render_start_result :: proc(
	id: string,
	negotiated_version: int,
	seed: funpack_runtime.Run_Seed,
	allocator := context.allocator,
) -> string {
	b := strings.builder_make(allocator)
	strings.write_string(&b, "{\"session_id\":")
	funpack_runtime.write_json_string(&b, id)
	strings.write_string(&b, ",\"negotiated_version\":")
	strings.write_int(&b, negotiated_version)
	strings.write_string(&b, ",\"seeded\":")
	strings.write_string(&b, seed.has_seed ? "true" : "false")
	strings.write_string(&b, ",\"seed\":")
	strings.write_i64(&b, seed.seed)
	strings.write_byte(&b, '}')
	return strings.to_string(b)
}

// sess_open_error maps a runtime Open_Session_Result failure to the MCP error vocabulary
// (mcp_error.odin). A read/IO/arena-cap failure is Resolver (the file could not be
// resolved off disk, or the per-session arena could not be minted — the at-cap path); a
// malformed/identity-mismatched input is Invalid_Input (the bytes the caller pointed at are
// out of contract). The detail names the OFFENDING file: the artifact for an artifact
// failure, the replay log for a replay failure (so a `replay_log` typo or a mismatched
// recording self-corrects to the right path, not the artifact). The switch is exhaustive
// (no default) so a new Open_Session_Result without a mapping is a compile error — the
// closed-enum discipline.
sess_open_error :: proc(result: funpack_runtime.Open_Session_Result, artifact: string, replay_log: string) -> Mcp_Error {
	switch result {
	case .Ok:
		// Unreachable: sess_start only calls this on a non-Ok result. Mapped defensively.
		return Mcp_Error{category = .Internal, message = "open reported Ok on the failure path", detail = artifact}
	case .Artifact_Read_Failed:
		return Mcp_Error{category = .Resolver, message = "the artifact could not be read (or the session arena could not be allocated)", detail = artifact}
	case .Artifact_Malformed:
		return Mcp_Error{category = .Invalid_Input, message = "the artifact bytes did not parse as a funpack build", detail = artifact}
	case .Replay_Read_Failed:
		return Mcp_Error{category = .Resolver, message = "the replay log could not be read", detail = replay_log}
	case .Replay_Malformed:
		return Mcp_Error{category = .Invalid_Input, message = "the replay log did not parse", detail = replay_log}
	case .Replay_Identity_Mismatch:
		return Mcp_Error{category = .Invalid_Input, message = "the replay log was recorded against a different build or seed", detail = replay_log}
	}
	return Mcp_Error{category = .Internal, message = "unmapped open failure", detail = artifact}
}

// sess_string_arg reads a required string argument off the MCP arguments object. Absent
// or non-string is has=false — the arm renders the Invalid_Input refusal naming the
// argument. The mirror of obs_session_id, generalized to any string arg (artifact for
// start, session_id for end).
sess_string_arg :: proc(arguments: json.Object, name: string) -> (value: string, has: bool) {
	field, present := arguments[name]
	if !present {
		return "", false
	}
	text, is_string := field.(json.String)
	if !is_string {
		return "", false
	}
	return string(text), true
}

// sess_int_arg reads an OPTIONAL integer argument off the MCP arguments object,
// accepting json.Integer (the parse_integers path the host's request takes) and a
// json.Float defensively (the int-as-float wire trap). Absent or non-numeric is
// has=false — the caller treats that as "not supplied" (the seed override is optional).
// Mirrors record's rec_int_field so the one optional `seed` arg is read the same way on
// both tools.
sess_int_arg :: proc(arguments: json.Object, name: string) -> (value: i64, has: bool) {
	field, present := arguments[name]
	if !present {
		return 0, false
	}
	#partial switch v in field {
	case json.Integer:
		return i64(v), true
	case json.Float:
		return i64(v), true
	}
	return 0, false
}
