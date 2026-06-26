// The HEADLESS-RECORD dispatch family — the arm of the tools/call chain
// (mcp_server.odin MCP_DISPATCH_CHAIN) that owns the single server-native `record`
// tool. It is the agent-loop producer for the replay/time-travel surface: it loads a
// built artifact, folds an agent-supplied input-script into a byte-stable replay log
// (funpack_runtime.record_scripted), and writes that log beside the artifact (or at an
// explicit `out`). The recorded log is exactly what `session_start replay_log=…` then
// re-folds — so this closes the loop the attach/`time_*`/`capture_test` surface needs,
// which an interactive SDL `funpack live` a human plays is otherwise the only producer of.
//
// THE INPUT-SCRIPT IS THE inject_input VOCABULARY, segmented. The agent already
// describes a §23 snapshot to `control_inject_input` as {pressed, held, values, axes}
// arrays of {player, action} records; a record `script` is an ORDERED list of those
// same snapshots, each carrying a `ticks` count — so "idle 600, hold Steer 100, press
// Fire once" is three segments. Each segment's snapshot is built through the SAME
// runtime builder inject_input uses (build_input_snapshot), so a recorded tick and an
// injected tick resolve actions/players/analogs identically.
//
// THE SEED RIDES THE LOG (§25 §60). A `uses_rng` game's tick-0 root seed is resolved by
// the §25 §60 precedence (the optional `seed` arg, then the entrypoint config seed, then
// the engine default) and pinned in the log header — record_scripted owns that. The
// result echoes {path, ticks, has_seed, seed} so the agent learns the length and the
// exact seed baked in, and `session_start` re-feeds that seed automatically (it reads it
// from the log header, introspect_attach.odin), so the recorded run re-folds seeded and
// the timeline populates instead of rendering black.
//
// CLAIM BY GROUP (the generated-projection invariant): this arm owns exactly the tools
// whose generated Tool_Spec.group is "record" (the contract's server_tools.families.record
// family), never by name — a renamed record tool still routes here. Every other group is
// another family's; this arm declines them so the chain reaches their file. NAMESPACE:
// every package-level symbol here is prefixed `rec_` except the dispatch entry point
// mcp_record_dispatch, whose name is fixed by MCP_DISPATCH_CHAIN.
package main

import "../../funpack"
import funpack_runtime "../../runtime"
import "core:encoding/json"
import "core:os"
import "core:strings"

// mcp_record_dispatch is the record family's arm. It claims the "record" group's tools
// by the generated Tool_Spec.group (not the name), folds `record` through rec_record, and
// declines every other group (handled=false) so the call flows on down the chain. A tool
// in the claimed group with no arm is the family's own gap, surfaced as Internal rather
// than silently declined (mirroring the session family's gap handling).
mcp_record_dispatch :: proc(dispatch: Mcp_Dispatch, allocator := context.allocator) -> (result: string, handled: bool) {
	if !rec_owns_command(dispatch.spec) {
		return "", false
	}

	switch dispatch.name {
	case "record":
		return rec_record(dispatch, allocator), true
	}

	return mcp_tool_error(
		dispatch.id,
		Mcp_Error{category = .Internal, message = "record-family tool has no dispatch arm", detail = dispatch.name},
		allocator,
	), true
}

// rec_owns_command is the family's claim test: it owns exactly the "record" group (the
// contract's server_tools.families.record). The check is on the generated Tool_Spec.group,
// not the tool name, so a renamed record tool still routes here. Every other group is
// another family's; this arm declines them so the chain reaches their file. Mirrors
// sess_owns_command.
rec_owns_command :: proc(spec: funpack.Tool_Spec) -> bool {
	return spec.group == "record"
}

// rec_record records an agent-supplied input-script over a built artifact into a replay
// log and returns its path, recorded tick count, and the resolved root seed. It loads the
// artifact (read + load_program — the same seam the live session and the attach registry
// use), retaining the raw bytes so the log's content-hash pins the exact build; parses the
// `script` array into snapshot+ticks segments through the shared inject_input builder;
// resolves the out path (explicit `out`, else `<artifact-stem>.replay` beside it); folds
// the segments into a byte-stable log (record_scripted, which owns the §25 §60 seed
// resolution and the identity header); and writes it. Any input fault (missing/bad
// artifact, bad script, unresolvable action) is the in-band IsError result the model reads
// and self-corrects from — never a JSON-RPC error object.
rec_record :: proc(dispatch: Mcp_Dispatch, allocator := context.allocator) -> string {
	artifact, has_artifact := rec_string_arg(dispatch.arguments, "artifact")
	if !has_artifact {
		return mcp_tool_error(
			dispatch.id,
			Mcp_Error{category = .Invalid_Input, message = "missing required string argument: artifact"},
			allocator,
		)
	}

	// Read the raw bytes ourselves so the replay identity's content hash is over the exact
	// bytes loaded (load_program parses from the same string), exactly as the live session
	// does — the log then pins the build it was recorded against.
	artifact_bytes, read_err := os.read_entire_file_from_path(artifact, allocator)
	if read_err != nil {
		return mcp_tool_error(
			dispatch.id,
			Mcp_Error{category = .Resolver, message = "the artifact could not be read", detail = artifact},
			allocator,
		)
	}
	program, load_err := funpack_runtime.load_program(string(artifact_bytes), allocator)
	if load_err != .None {
		return mcp_tool_error(
			dispatch.id,
			Mcp_Error{category = .Invalid_Input, message = "the artifact bytes did not parse as a funpack build", detail = artifact},
			allocator,
		)
	}

	segments, script_err := rec_parse_script(&program, dispatch.arguments, allocator)
	if script_err.message != "" {
		return mcp_tool_error(dispatch.id, script_err, allocator)
	}

	// The optional `--seed`-style override: present + integer pins the root seed; absent
	// lets record_scripted fall through to the entrypoint config seed / engine default.
	seed_override: Maybe(i64)
	if seed, has_seed := rec_int_arg(dispatch.arguments, "seed"); has_seed {
		seed_override = seed
	}

	out_override, _ := rec_string_arg(dispatch.arguments, "out")
	out_path := funpack_runtime.replay_out_path(artifact, out_override, allocator)

	log_bytes, summary := funpack_runtime.record_scripted(&program, string(artifact_bytes), seed_override, segments, allocator)
	if !funpack_runtime.write_replay_file(out_path, log_bytes) {
		return mcp_tool_error(
			dispatch.id,
			Mcp_Error{category = .Resolver, message = "the replay log could not be written", detail = out_path},
			allocator,
		)
	}

	body := rec_render_result(out_path, summary, allocator)
	return mcp_text_result(dispatch.id, body, allocator)
}

// rec_parse_script reads the required `script` array into snapshot+ticks segments. Each
// element is an object carrying the inject_input snapshot keys (pressed/held/values/axes)
// plus an optional `ticks` count (default 1, must be >= 1) — the snapshot is built through
// the shared runtime builder (build_input_snapshot), so an unresolvable action/player is
// the builder's own error message lifted to Invalid_Input. An absent/empty/non-array
// `script`, a non-object element, or a `ticks` < 1 is Invalid_Input (err.message set); on
// success err.message is "" and segments is the ordered list.
rec_parse_script :: proc(
	program: ^funpack_runtime.Program,
	arguments: json.Object,
	allocator := context.allocator,
) -> (
	segments: []funpack_runtime.Scripted_Segment,
	err: Mcp_Error,
) {
	field, present := arguments["script"]
	if !present {
		return nil, Mcp_Error{category = .Invalid_Input, message = "missing required array argument: script"}
	}
	array, is_array := field.(json.Array)
	if !is_array {
		return nil, Mcp_Error{category = .Invalid_Input, message = "script must be an array of input segments"}
	}
	if len(array) == 0 {
		return nil, Mcp_Error{category = .Invalid_Input, message = "script must carry at least one input segment"}
	}

	built := make([dynamic]funpack_runtime.Scripted_Segment, 0, len(array), allocator)
	for element, i in array {
		object, is_object := element.(json.Object)
		if !is_object {
			return nil, Mcp_Error{category = .Invalid_Input, message = "each script segment must be an object", detail = rec_segment_label(i, allocator)}
		}
		ticks := i64(1)
		if requested, has_ticks := rec_int_field(object, "ticks"); has_ticks {
			ticks = requested
		}
		if ticks < 1 {
			return nil, Mcp_Error{category = .Invalid_Input, message = "each script segment needs ticks >= 1", detail = rec_segment_label(i, allocator)}
		}
		snapshot, build_err := funpack_runtime.build_input_snapshot(program, object, allocator)
		if build_err != "" {
			return nil, Mcp_Error{category = .Invalid_Input, message = build_err, detail = rec_segment_label(i, allocator)}
		}
		append(&built, funpack_runtime.Scripted_Segment{snapshot = snapshot, ticks = int(ticks)})
	}
	return built[:], Mcp_Error{}
}

// rec_segment_label names a script element by index for an error detail — "segment N" —
// so an agent that fat-fingered one of many segments is told which one.
rec_segment_label :: proc(index: int, allocator := context.allocator) -> string {
	b := strings.builder_make(allocator)
	strings.write_string(&b, "segment ")
	strings.write_int(&b, index)
	return strings.to_string(b)
}

// rec_render_result renders the record clean result body — {path, ticks, has_seed, seed}
// — with the same strings.Builder + write_json_string idiom the session family renders
// with, so the body is byte-stable. `ticks` is the recorded tick count (an integer, never
// a float — the model reads it raw); `seed` is the resolved tick-0 root seed pinned in the
// header (meaningful only when has_seed, 0 otherwise).
rec_render_result :: proc(path: string, summary: funpack_runtime.Scripted_Record_Summary, allocator := context.allocator) -> string {
	b := strings.builder_make(allocator)
	strings.write_string(&b, "{\"path\":")
	funpack_runtime.write_json_string(&b, path)
	strings.write_string(&b, ",\"ticks\":")
	strings.write_int(&b, summary.tick_count)
	strings.write_string(&b, ",\"has_seed\":")
	strings.write_string(&b, summary.has_seed ? "true" : "false")
	strings.write_string(&b, ",\"seed\":")
	strings.write_i64(&b, summary.seed)
	strings.write_byte(&b, '}')
	return strings.to_string(b)
}

// rec_string_arg reads an optional string argument off the MCP arguments object — absent
// or non-string is has=false (the caller decides whether that is an error: required for
// `artifact`, optional for `out`). Mirrors sess_string_arg, kept in this file for the
// family's namespace independence.
rec_string_arg :: proc(arguments: json.Object, name: string) -> (value: string, has: bool) {
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

// rec_int_arg reads an optional integer argument off the MCP arguments object. The
// JSON-RPC parser runs with parse_integers=true (mcp_jsonrpc.odin), so a whole number
// arrives as json.Integer; a json.Float with an integral value is also accepted (an agent
// that sent 42.0). Absent or non-numeric is has=false.
rec_int_arg :: proc(arguments: json.Object, name: string) -> (value: i64, has: bool) {
	return rec_int_field(arguments, name)
}

// rec_int_field reads an integer off a json.Object by key, accepting json.Integer (the
// parse_integers path) and an integral json.Float defensively. Absent or non-numeric is
// has=false — the one integer reader both the top-level args (seed) and a script segment
// (ticks) go through, so the int-as-float trap is handled in one place.
rec_int_field :: proc(object: json.Object, name: string) -> (value: i64, has: bool) {
	field, present := object[name]
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
