// The OBSERVE + TIME-TRAVEL tool dispatch family — the arm of the tools/call chain
// (mcp_server.odin MCP_DISPATCH_CHAIN) that owns the §28 observe commands (pipeline,
// signals, trace, diff, replay_behavior, draw_list) and the time-travel commands
// (load, run, pause, step, rewind, reset, status) over a NAMED session. Each tool here
// marshals its args into a §28 request line and folds it through
// mcp_session_registry_request (mcp_session.odin) on the session's arena, lifting the
// result back into the MCP result. This file is ONE dispatch seam — it owns ONLY this
// file's dispatch proc, never mcp_handle_tools_call.
//
// THE FAMILY IS PURE RE-FOLD READS: every command here is class "observe" (the
// generated Tool_Spec, api_contract.gen.odin) — observe re-folds a recorded tick and
// time-travel only moves the cursor / forks no canonical state. So this arm threads the
// optional `branch` selector through verbatim and NEVER mutates Debug_Session directly:
// the runtime's session_request owns the fold (the engine boundary — the model reads,
// the engine folds). The control (perturbing) tools live in the SEPARATE control family
// (mcp_tools_control.odin); this arm declines any tool it does not own (handled=false).
//
// NAMESPACE DISCIPLINE: every package-level proc/type/constant this file adds is
// prefixed `obs_` so package main has NO duplicate symbols when all six dispatch
// families merge (each family file owns its own prefix). The one EXCEPTION is the
// dispatch entry point mcp_observe_time_dispatch — its name is fixed by the chain in
// mcp_server.odin (MCP_DISPATCH_CHAIN) and must not change.
package main

import "../../funpack"
import funpack_runtime "../../runtime"
import "core:encoding/json"
import "core:strings"

// OBS_TOOL_REQUEST_ID is the §28 envelope id stamped on every request this family
// folds through a session. The MCP boundary correlates a tool call by its JSON-RPC id
// (the OUTER envelope, mcp_jsonrpc.odin) — the INNER §28 id is single-shot per fold
// (one request, one response, awaited inline by mcp_session_registry_request), so a
// fixed id is sufficient and keeps the request line byte-stable. It is not zero so a
// refusal echoing it is distinguishable from the malformed-line id-0 case.
OBS_TOOL_REQUEST_ID :: 1

// mcp_observe_time_dispatch is the observe+time family's arm. It claims the §28 observe
// commands (signals/pipeline/trace/diff/replay_behavior/draw_list) and the time-travel
// commands (load/run/pause/step/rewind/reset/status) by their generated Tool_Spec
// .command, declining any other tool (handled=false) so the chain tries the next family.
// For a claimed tool it resolves the named session, builds the §28 request line from the
// MCP arguments, folds it through the registry on the session arena, and lifts the §28
// result back into the MCP tool result — an unknown session id is the Session-category
// refusal, a §28 ok:false is the runtime's refusal text, an ok:true lifts the result
// object verbatim. The dispatch hint is the spec's .command (the §28 wire name), so this
// arm cannot drift from the advertised tool set (the generated-projection contract).
mcp_observe_time_dispatch :: proc(dispatch: Mcp_Dispatch, allocator := context.allocator) -> (result: string, handled: bool) {
	if !obs_owns_command(dispatch.spec) {
		return "", false
	}

	// Resolve the named session up front: an unknown/ended id is the Session-category
	// refusal (never a fabricated session), exactly the registry's found=false contract.
	session_id, has_session := obs_session_id(dispatch.arguments)
	if !has_session {
		return mcp_tool_error(
			dispatch.id,
			Mcp_Error{category = .Invalid_Input, message = "missing required string argument: session_id"},
			allocator,
		), true
	}
	if _, found := mcp_session_registry_lookup(dispatch.registry, session_id); !found {
		return mcp_tool_error(
			dispatch.id,
			Mcp_Error{category = .Session, message = "unknown session id", detail = session_id},
			allocator,
		), true
	}

	// Build the §28 request line from the MCP arguments (session_id dropped — it keys
	// the session, it is not a §28 arg) and fold it on the SESSION arena. The fold's
	// allocator is the session's, owned by mcp_session_registry_request (the F13
	// retention rule); the LINE itself is built on the per-call `allocator` (scratch).
	line := obs_build_request_line(dispatch.spec.command, dispatch.arguments, allocator)
	response, found := mcp_session_registry_request(dispatch.registry, session_id, line)
	if !found {
		// The session vanished between the lookup and the fold (it cannot, single-
		// threaded per session, but the contract is honored, not assumed).
		return mcp_tool_error(
			dispatch.id,
			Mcp_Error{category = .Session, message = "unknown session id", detail = session_id},
			allocator,
		), true
	}

	// The inspect DATA-PROBE commands (state/signals/trace/diff/draw_list/replay_behavior/
	// pipeline) are the surface whose empty result, lifted bare, is the friction-0007
	// defect: a swarm-wiped-out, a wrong tick, a behavior that ran nothing, and a
	// fresh-seedless timeline ALL encode as the same `[]`. So a data-probe result is lifted
	// SELF-DESCRIBING: it carries the session's seeded/loaded/recorded precondition (read by
	// folding a status request through the SAME session) and, when the result set is empty
	// AND a precondition is unmet, a diagnostic naming the missing prerequisite plus the
	// next action.
	if obs_enriches_command(dispatch.spec) {
		precondition := obs_read_precondition(dispatch.registry, session_id, allocator)
		return obs_lift_inspect_response(dispatch.id, dispatch.spec.command, response, precondition, allocator), true
	}

	// time_status is the ORIENTATION read, and the unloaded read disproves the once-held
	// claim that its payload is always self-describing: on a fresh session it reports
	// loaded:false alongside ticks_recorded:N, which reads as "N ticks of data are here to
	// inspect" — so the agent calls time_step / inspect_*, which fail or return empty. The
	// enriched lift attaches a next_action naming time_load (the required arming step) ONLY
	// when loaded:false, mirroring the self-describing precondition/next_action shape. A loaded status, the
	// time position acks ({tick}), and screenshot (a render-capture payload owned by its own
	// family) carry no hint, so all of those lift verbatim.
	if obs_enriches_status(dispatch.spec) {
		return obs_lift_status_response(dispatch.id, dispatch.spec.command, response, allocator), true
	}

	return obs_lift_response(dispatch.id, dispatch.spec.command, response, allocator), true
}

// obs_enriches_command is the precondition-enrichment claim: the inspect group's DATA-PROBE
// commands whose empty results must be self-describing (friction-0007), EXCLUDING screenshot
// (a render-capture payload owned by its own family, not a collection probe). The time
// group's position acks ({tick}) lift verbatim; its status read enriches through the
// SEPARATE obs_enriches_status claim. The check is on the generated
// Tool_Spec's .group + .command, the same sources obs_owns_command claims by, so a renamed
// data-probe tool still enriches.
obs_enriches_command :: proc(spec: funpack.Tool_Spec) -> bool {
	return spec.group == "inspect" && spec.command != "screenshot"
}

// obs_enriches_status is the time-status enrichment claim: the time group's `status`
// command — the orientation read whose loaded:false payload must carry a next_action naming
// the required time_load step. It is the ONLY time command that enriches: the position acks
// (load/run/pause/step/rewind/reset) return a {tick} that is already unambiguous. The check
// is on the generated Tool_Spec's .group + .command (the same sources obs_owns_command
// claims by), so a renamed status tool that keeps its group + command still enriches.
obs_enriches_status :: proc(spec: funpack.Tool_Spec) -> bool {
	return spec.group == "time" && spec.command == "status"
}

// obs_owns_command is the family's claim test: it owns exactly the §28 observe-class
// commands the inspect/time groups declare. The check is on the generated Tool_Spec's
// .group (inspect / time) — the two §28 groups this family dispatches — NOT on the tool
// name, so a renamed tool that keeps its group still routes here. The break/self_heal
// observe groups (break/watch/clear, capture_test/audit) and the control group are owned
// by OTHER families; this arm declines them so the chain reaches their file.
obs_owns_command :: proc(spec: funpack.Tool_Spec) -> bool {
	return spec.group == "inspect" || spec.group == "time"
}

// obs_session_id reads the required session_id off the MCP arguments object. Absent or
// non-string is has=false — the arm renders the Invalid_Input refusal (the session
// handle is the one universally-required arg, SESSION_ID_ARG in every spec).
obs_session_id :: proc(arguments: json.Object) -> (id: string, has: bool) {
	field, present := arguments["session_id"]
	if !present {
		return "", false
	}
	text, is_string := field.(json.String)
	if !is_string {
		return "", false
	}
	return string(text), true
}

// obs_build_request_line renders one §28 request line for a command, projecting the MCP
// arguments (minus session_id) into the `args` object. The session_id keys the live
// session — it is NOT a §28 wire arg, so it is dropped here. Every OTHER argument the
// tool carried passes through verbatim by its JSON type (tick/from/to/until as integers,
// behavior/branch as strings, include_drawlist as a boolean) so the §28 arg names ARE
// the MCP arg names (the generated-projection contract — no per-arg translation table).
// An empty args object is elided (a no-arg command like pipeline sends just {id,cmd}),
// matching session_request's optional-args read (introspect.odin).
obs_build_request_line :: proc(command: string, arguments: json.Object, allocator := context.allocator) -> string {
	b := strings.builder_make(allocator)
	strings.write_string(&b, "{\"id\":")
	strings.write_int(&b, OBS_TOOL_REQUEST_ID)
	strings.write_string(&b, ",\"cmd\":")
	funpack_runtime.write_json_string(&b, command)

	// Project every non-session_id argument into the §28 args object, preserving its
	// JSON type. The order is the map's iteration order — irrelevant to the §28 reader
	// (it reads args by key, introspect.odin json_*_field), and the request line is not
	// part of the byte-stable §28 RESPONSE log (only the response envelope is, :997).
	first := true
	for key, value in arguments {
		if key == "session_id" {
			continue
		}
		if first {
			strings.write_string(&b, ",\"args\":{")
			first = false
		} else {
			strings.write_byte(&b, ',')
		}
		funpack_runtime.write_json_string(&b, key)
		strings.write_byte(&b, ':')
		obs_write_json_value(&b, value)
	}
	if !first {
		strings.write_byte(&b, '}')
	}
	strings.write_byte(&b, '}')
	return strings.to_string(b)
}

// obs_write_json_value renders one parsed JSON value back to its wire form for the §28
// args object. The argument types the observe/time tools carry are the scalar set
// (integer/float/string/boolean/null); objects and arrays pass through via json.marshal
// (no observe/time arg uses them today, but the projection stays total so a future arg
// shape needs no change here). Integers render as integers (the parse used
// parse_integers=true, mcp_jsonrpc.odin), so a §10 tick never becomes a float.
obs_write_json_value :: proc(b: ^strings.Builder, value: json.Value) {
	switch v in value {
	case json.Integer:
		strings.write_i64(b, i64(v))
	case json.Float:
		strings.write_f64(b, f64(v), 'g')
	case json.String:
		funpack_runtime.write_json_string(b, string(v))
	case json.Boolean:
		strings.write_string(b, v ? "true" : "false")
	case json.Null:
		strings.write_string(b, "null")
	case json.Object, json.Array:
		// No observe/time arg is a container today; marshal keeps the projection total.
		if bytes, err := json.marshal(value, {}, context.temp_allocator); err == nil {
			strings.write_bytes(b, bytes)
		} else {
			strings.write_string(b, "null")
		}
	}
}

// obs_lift_response lifts a §28 response line into an MCP tool result. The §28 envelope
// is the dual of the MCP one: ok:true carries a `result` object (lifted VERBATIM into a
// Text content block — the structured payload the model reads), ok:false carries an
// `error` string (mapped to a Session-category IsError envelope — the runtime's refusal
// the model self-corrects from, e.g. "tick out of range", "no timeline loaded"). A
// response the server cannot parse, or an ok:true with no result, is an Internal fault
// (the runtime broke its own §28 contract) — surfaced, never masked. This is the Go
// path's mapResponseError + decodeResult collapsed into one lift, MINUS the per-tool
// typed structs (the ADR lifts the result object verbatim, no re-typing).
obs_lift_response :: proc(id: Mcp_Id, command: string, response: string, allocator := context.allocator) -> string {
	parsed, parse_err := json.parse(transmute([]u8)response, json.DEFAULT_SPECIFICATION, true, allocator)
	if parse_err != .None {
		return mcp_tool_error(
			id,
			Mcp_Error{category = .Internal, message = "session response was not valid JSON", detail = command},
			allocator,
		)
	}
	envelope, is_object := parsed.(json.Object)
	if !is_object {
		return mcp_tool_error(
			id,
			Mcp_Error{category = .Internal, message = "session response was not a JSON object", detail = command},
			allocator,
		)
	}

	ok_field, has_ok := envelope["ok"]
	ok_bool, ok_is_bool := ok_field.(json.Boolean)
	if !has_ok || !ok_is_bool {
		return mcp_tool_error(
			id,
			Mcp_Error{category = .Internal, message = "session response missing ok field", detail = command},
			allocator,
		)
	}

	if !bool(ok_bool) {
		// A §28 refusal: the runtime declined the command (bad tick, unknown behavior,
		// unsupported branch refold, no timeline loaded). Surface its text as a Refused-
		// category refusal so the model reads the reason and retries with corrected args
		// (the session is healthy — fix the command, not the session).
		message := strings.concatenate({command, ": runtime refused the command"}, allocator)
		if error_field, has_error := envelope["error"]; has_error {
			if error_text, error_is_string := error_field.(json.String); error_is_string {
				message = string(error_text)
			}
		}
		return mcp_tool_error(id, Mcp_Error{category = .Refused, message = message}, allocator)
	}

	// ok:true — lift the `result` object verbatim into a Text content block. A missing
	// result on an ok response is the runtime breaking its own contract (Internal).
	result_field, has_result := envelope["result"]
	if !has_result {
		return mcp_tool_error(
			id,
			Mcp_Error{category = .Internal, message = "session ok response carried no result", detail = command},
			allocator,
		)
	}
	result_json, marshal_err := json.marshal(result_field, {}, allocator)
	if marshal_err != nil {
		return mcp_tool_error(
			id,
			Mcp_Error{category = .Internal, message = "rendering the session result failed", detail = command},
			allocator,
		)
	}

	content := make([]Mcp_Content, 1, allocator)
	content[0] = mcp_text_content(string(result_json))
	return mcp_render_tool_result(id, Mcp_Tool_Result{content = content, is_error = false}, allocator)
}
// --- friction-0007: self-describing empty inspect results -------------------

// Obs_Precondition is the session-shape an inspect result is read AGAINST — the
// timeline facts that explain an empty result set. `loaded` is whether the time cursor
// is armed (time_load); `seeded` is whether the session folds a recorded RNG seed;
// `uses_rng` is whether the PROGRAM draws randomness anywhere (any behavior/function
// binds an `Rng` param); `ticks_recorded` is the recording's extent. The seeded/uses_rng
// PAIR is the friction-116a1681 distinction: a missing seed only explains an empty result
// when the game actually consumes RNG (uses_rng && !seeded is an unmet precondition); a
// no-RNG game's empty result is a genuine state read, NOT a missing-seed defect. `known`
// is false when the status fold could not be read (a defensive miss, not a fault) — the
// enricher then omits the precondition block rather than fabricating one. The facts are
// exactly what the §28 status command (runtime/introspect_time.odin time_status) reports,
// read back through the SAME session.
Obs_Precondition :: struct {
	known:          bool,
	loaded:         bool,
	seeded:         bool,
	uses_rng:       bool,
	ticks_recorded: i64,
}

// obs_read_precondition folds a §28 `status` request through the same session and lifts
// the loaded/seeded/ticks_recorded facts. It is a PURE READ (status is observe-class,
// runtime/introspect_time.odin) on the session arena, so it never perturbs the session
// or the result being enriched. A parse miss or a missing field yields known=false (the
// enricher omits the block) — the enrichment is best-effort context, never a path that
// can turn a clean inspect into a fault.
obs_read_precondition :: proc(reg: ^Mcp_Session_Registry, session_id: string, allocator := context.allocator) -> Obs_Precondition {
	line := "{\"id\":1,\"cmd\":\"status\"}"
	response, found := mcp_session_registry_request(reg, session_id, line)
	if !found {
		return Obs_Precondition{known = false}
	}
	parsed, parse_err := json.parse(transmute([]u8)response, json.DEFAULT_SPECIFICATION, true, allocator)
	if parse_err != .None {
		return Obs_Precondition{known = false}
	}
	envelope, is_object := parsed.(json.Object)
	if !is_object {
		return Obs_Precondition{known = false}
	}
	result_field, has_result := envelope["result"]
	result, result_is_object := result_field.(json.Object)
	if !has_result || !result_is_object {
		return Obs_Precondition{known = false}
	}
	pre := Obs_Precondition {
		known = true,
	}
	if loaded, ok := result["loaded"].(json.Boolean); ok {
		pre.loaded = bool(loaded)
	}
	if seeded, ok := result["seeded"].(json.Boolean); ok {
		pre.seeded = bool(seeded)
	}
	if uses_rng, ok := result["uses_rng"].(json.Boolean); ok {
		pre.uses_rng = bool(uses_rng)
	}
	if ticks, ok := result["ticks_recorded"].(json.Integer); ok {
		pre.ticks_recorded = i64(ticks)
	}
	return pre
}

// obs_inspect_collection_key maps a data-probe command to the result-object array key whose
// emptiness is the friction-0007 signal: an empty `instances` (state/replay_behavior),
// `routes` (signals), `steps` (trace/pipeline), `commands` (draw_list), or `tables`
// (diff). The key set is the closed data-probe surface (the §28 result shapes,
// runtime/introspect.odin) — screenshot is excluded upstream (obs_enriches_command), so it
// never reaches here. An unmapped command is ("", false) — it carries no empty-set signal,
// so the enricher attaches the precondition block without an emptiness verdict.
obs_inspect_collection_key :: proc(command: string) -> (key: string, has: bool) {
	switch command {
	case "state", "replay_behavior":
		return "instances", true
	case "signals":
		return "routes", true
	case "trace", "pipeline":
		return "steps", true
	case "draw_list":
		return "commands", true
	case "diff":
		return "tables", true
	}
	return "", false
}

// obs_result_collection_empty reports whether the lifted §28 result's primary collection
// is empty — the emptiness that, paired with an unmet precondition, is the friction-0007
// defect. A command with no collection key (screenshot), or a result missing the key, or
// a non-array under it, is empty=false (no empty-set claim made). For a mapped command
// the verdict is len(array) == 0.
obs_result_collection_empty :: proc(command: string, result: json.Object) -> bool {
	key, has_key := obs_inspect_collection_key(command)
	if !has_key {
		return false
	}
	field, present := result[key]
	if !present {
		return false
	}
	array, is_array := field.(json.Array)
	if !is_array {
		return false
	}
	return len(array) == 0
}

// obs_precondition_diagnostic returns the diagnostic + next-action naming the unmet
// prerequisite that most likely produced an empty inspect result, or has=false when the
// preconditions are all met (a genuinely-empty-but-VALID result — the case that must stay
// distinguishable from a precondition failure). The ordering is causal:
//
//   - A program that DRAWS RNG but folds NO recorded seed (uses_rng && !seeded) is the
//     friction-0007 root — an RNG-driven setup cannot populate without a seed, so this is
//     named first as the unmet precondition.
//   - A program that uses NO RNG (!uses_rng) can never be seedless-broken: its empty
//     result is a genuine state read, named with the no-RNG-by-design diagnostic that does
//     NOT blame a missing seed (the friction-116a1681 misdiagnosis fix). It still points at
//     control_spawn / control_set as the way to populate the state to inspect.
//   - An empty recording (no ticks) is named next, for either RNG class.
//
// A recorded, seeded (or no-RNG) session whose empty probe is NOT the no-RNG genuine-empty
// shape is valid-empty — no diagnostic.
obs_precondition_diagnostic :: proc(pre: Obs_Precondition) -> (diagnostic: string, next_action: string, has: bool) {
	if !pre.known {
		return "", "", false
	}
	// An empty recording is the root cause for EITHER RNG class — there is no timeline to
	// inspect — so it is named first, ahead of the RNG-class split.
	if pre.ticks_recorded <= 0 {
		return "the session has no recorded ticks, so there is no simulated timeline to inspect",
			"run the timeline forward (time_load then time_run) or attach over a recording before inspecting",
			true
	}
	// uses_rng && !seeded is the genuine friction-0007 precondition failure: an RNG-driven
	// setup cannot populate without a recorded seed.
	if pre.uses_rng && !pre.seeded {
		return "the session is seedless: this game draws RNG, but a fresh session_start opens without a recorded RNG seed, so an RNG-driven setup (e.g. a spawn-on-start swarm) never populates and every inspect_* reads empty — this is distinct from a genuinely-empty tick",
			"re-open the session over a recorded replay log (session_start with a recording that pins the seed) to reproduce the seeded run, or use control_spawn / control_set to populate the state you want to inspect",
			true
	}
	// A no-RNG game can NEVER be seedless-broken: a missing seed cannot explain its empty
	// result (the friction-116a1681 misdiagnosis). Name the no-RNG-by-design cause instead of
	// blaming a missing seed — the result is a genuine state read of a deterministic game.
	if !pre.uses_rng {
		return "this game uses no RNG (no behavior or function draws from an Rng), so a missing seed cannot explain the empty result — the inspected tick genuinely produced no instances for this thing",
			"verify the thing name and tick, or use control_spawn / control_set to populate the state you want to inspect",
			true
	}
	return "", "", false
}

// obs_lift_inspect_response is the SELF-DESCRIBING lift for the inspect group — the
// friction-0007 fix. It runs obs_lift_response's §28→MCP mapping (a §28 ok:false stays a
// Session refusal, an unparseable/result-less ok stays an Internal fault, both verbatim),
// then on a CLEAN result wraps the lifted §28 result in an envelope that always carries
// the session `precondition` (seeded/loaded/ticks_recorded) and, when the result set is
// empty AND a precondition is unmet, a `diagnostic` + `next_action` naming the missing
// prerequisite. The wrap is structural, not textual: the §28 `result` rides under a
// `result` key VERBATIM (no re-typing, the ADR's lift-verbatim contract), so an existing
// reader still reaches the data — the precondition/diagnostic are an additive superset.
// A genuinely-empty-but-valid result (all preconditions met) carries the precondition
// block but NO diagnostic, the distinguishability the acceptance bar requires.
obs_lift_inspect_response :: proc(
	id: Mcp_Id,
	command: string,
	response: string,
	precondition: Obs_Precondition,
	allocator := context.allocator,
) -> string {
	parsed, parse_err := json.parse(transmute([]u8)response, json.DEFAULT_SPECIFICATION, true, allocator)
	if parse_err != .None {
		return mcp_tool_error(
			id,
			Mcp_Error{category = .Internal, message = "session response was not valid JSON", detail = command},
			allocator,
		)
	}
	envelope, is_object := parsed.(json.Object)
	if !is_object {
		return mcp_tool_error(
			id,
			Mcp_Error{category = .Internal, message = "session response was not a JSON object", detail = command},
			allocator,
		)
	}
	ok_field, has_ok := envelope["ok"]
	ok_bool, ok_is_bool := ok_field.(json.Boolean)
	if !has_ok || !ok_is_bool {
		return mcp_tool_error(
			id,
			Mcp_Error{category = .Internal, message = "session response missing ok field", detail = command},
			allocator,
		)
	}
	if !bool(ok_bool) {
		// A §28 refusal (bad tick, unknown thing, unsupported branch) — the runtime
		// already names the cause, so it stays the verbatim Refused refusal obs_lift_
		// response renders; the precondition enrichment is for the EMPTY-but-ok case.
		message := strings.concatenate({command, ": runtime refused the command"}, allocator)
		if error_field, has_error := envelope["error"]; has_error {
			if error_text, error_is_string := error_field.(json.String); error_is_string {
				message = string(error_text)
			}
		}
		return mcp_tool_error(id, Mcp_Error{category = .Refused, message = message}, allocator)
	}
	result_field, has_result := envelope["result"]
	result_object, result_is_object := result_field.(json.Object)
	if !has_result || !result_is_object {
		return mcp_tool_error(
			id,
			Mcp_Error{category = .Internal, message = "session ok response carried no result object", detail = command},
			allocator,
		)
	}

	result_json, marshal_err := json.marshal(result_field, {}, allocator)
	if marshal_err != nil {
		return mcp_tool_error(
			id,
			Mcp_Error{category = .Internal, message = "rendering the session result failed", detail = command},
			allocator,
		)
	}

	empty := obs_result_collection_empty(command, result_object)
	diagnostic, next_action, has_diagnostic := obs_precondition_diagnostic(precondition)
	// A diagnostic fires only for an EMPTY result with an unmet precondition — a populated
	// result (or a valid-empty one with every precondition met) carries the precondition
	// block alone, so the agent reads the timeline shape without false-alarm noise.
	attach_diagnostic := empty && has_diagnostic

	b := strings.builder_make(allocator)
	strings.write_string(&b, "{\"result\":")
	strings.write_string(&b, string(result_json))
	if precondition.known {
		strings.write_string(&b, ",\"precondition\":{\"seeded\":")
		strings.write_string(&b, precondition.seeded ? "true" : "false")
		strings.write_string(&b, ",\"uses_rng\":")
		strings.write_string(&b, precondition.uses_rng ? "true" : "false")
		strings.write_string(&b, ",\"loaded\":")
		strings.write_string(&b, precondition.loaded ? "true" : "false")
		strings.write_string(&b, ",\"ticks_recorded\":")
		strings.write_i64(&b, precondition.ticks_recorded)
		strings.write_byte(&b, '}')
	}
	if attach_diagnostic {
		strings.write_string(&b, ",\"diagnostic\":")
		funpack_runtime.write_json_string(&b, diagnostic)
		strings.write_string(&b, ",\"next_action\":")
		funpack_runtime.write_json_string(&b, next_action)
	}
	strings.write_byte(&b, '}')

	content := make([]Mcp_Content, 1, allocator)
	content[0] = mcp_text_content(strings.to_string(b))
	return mcp_render_tool_result(id, Mcp_Tool_Result{content = content, is_error = false}, allocator)
}

// --- self-describing unloaded time_status -------------------

// OBS_STATUS_LOAD_NEXT_ACTION is the next-step hint stamped on a loaded:false status read.
// It names the required arming command (time_load) and the calls it unblocks (time_step /
// inspect_*) so the orientation read carries the SAME guidance the time_step pre-load error
// ("no timeline loaded — issue load first") already does. The text is fixed (no session
// detail), so the enriched status payload stays byte-stable for the unloaded case.
OBS_STATUS_LOAD_NEXT_ACTION :: "time_load — arm the timeline before time_step / inspect_*"

// obs_lift_status_response is the SELF-DESCRIBING lift for time_status. It
// runs the same §28→MCP mapping obs_lift_response does (an ok:false stays a Session refusal,
// an unparseable / result-less ok stays an Internal fault), then on a CLEAN result wraps the
// lifted §28 result in an envelope that, WHEN loaded:false, additively carries a `next_action`
// naming time_load as the required step. The wrap is structural, not textual: the §28 status
// `result` rides under a `result` key VERBATIM (loaded/tick/ticks_recorded/ring/branch stay
// byte-stable), so an existing reader still reaches every field — next_action is a pure
// additive superset. A loaded:true status carries NO next_action: the timeline is already
// armed, so the orientation hint would be false-alarm noise (the distinguishability the
// acceptance bar requires). The `loaded` flag is read off the lifted result object; a
// missing / non-boolean loaded is treated as loaded (no hint) — the enrichment never turns a
// clean status into a fault.
obs_lift_status_response :: proc(id: Mcp_Id, command: string, response: string, allocator := context.allocator) -> string {
	parsed, parse_err := json.parse(transmute([]u8)response, json.DEFAULT_SPECIFICATION, true, allocator)
	if parse_err != .None {
		return mcp_tool_error(
			id,
			Mcp_Error{category = .Internal, message = "session response was not valid JSON", detail = command},
			allocator,
		)
	}
	envelope, is_object := parsed.(json.Object)
	if !is_object {
		return mcp_tool_error(
			id,
			Mcp_Error{category = .Internal, message = "session response was not a JSON object", detail = command},
			allocator,
		)
	}
	ok_field, has_ok := envelope["ok"]
	ok_bool, ok_is_bool := ok_field.(json.Boolean)
	if !has_ok || !ok_is_bool {
		return mcp_tool_error(
			id,
			Mcp_Error{category = .Internal, message = "session response missing ok field", detail = command},
			allocator,
		)
	}
	if !bool(ok_bool) {
		// A §28 refusal — the runtime already named the cause, so it stays the verbatim
		// Refused refusal; the next_action enrichment is for the loaded:false ok case.
		message := strings.concatenate({command, ": runtime refused the command"}, allocator)
		if error_field, has_error := envelope["error"]; has_error {
			if error_text, error_is_string := error_field.(json.String); error_is_string {
				message = string(error_text)
			}
		}
		return mcp_tool_error(id, Mcp_Error{category = .Refused, message = message}, allocator)
	}
	result_field, has_result := envelope["result"]
	result_object, result_is_object := result_field.(json.Object)
	if !has_result || !result_is_object {
		return mcp_tool_error(
			id,
			Mcp_Error{category = .Internal, message = "session ok response carried no result object", detail = command},
			allocator,
		)
	}

	result_json, marshal_err := json.marshal(result_field, {}, allocator)
	if marshal_err != nil {
		return mcp_tool_error(
			id,
			Mcp_Error{category = .Internal, message = "rendering the session result failed", detail = command},
			allocator,
		)
	}

	// loaded:false is the unloaded orientation read — the only case that carries the hint.
	// A missing / non-boolean loaded is treated as loaded (no hint), so the enrichment can
	// never fabricate a fault out of an unexpected status shape.
	loaded := true
	if loaded_field, ok := result_object["loaded"].(json.Boolean); ok {
		loaded = bool(loaded_field)
	}

	b := strings.builder_make(allocator)
	strings.write_string(&b, "{\"result\":")
	strings.write_string(&b, string(result_json))
	if !loaded {
		strings.write_string(&b, ",\"next_action\":")
		funpack_runtime.write_json_string(&b, OBS_STATUS_LOAD_NEXT_ACTION)
	}
	strings.write_byte(&b, '}')

	content := make([]Mcp_Content, 1, allocator)
	content[0] = mcp_text_content(strings.to_string(b))
	return mcp_render_tool_result(id, Mcp_Tool_Result{content = content, is_error = false}, allocator)
}
