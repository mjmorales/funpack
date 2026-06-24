// The ONE-SHOT compute-tool dispatch family — the arm of the tools/call chain
// (mcp_server.odin MCP_DISPATCH_CHAIN) that owns the STATELESS tools that call a pure
// funpack compute-half directly with NO session and NO subprocess: build / check /
// export → stage_build (funpack/build.odin), test → read_project + run_project_pipeline
// (funpack/pipeline.odin), fmt → fmt_drift (funpack/fmt.odin), and the warden_* readers
// → read_warden_index + warden_command_output (funpack/warden_output.odin). Each is a
// pure projection of the project tree at the caller's `dir`, lifted into the MCP result.
// This file is ONE dispatch seam — it owns ONLY this file's dispatch proc, never
// mcp_handle_tools_call — so the six dispatch families stay independent (each owns its
// own file and its own `oneshot_`-style prefix).
//
// EXIT-CODE-AS-DATA (the family's crux): a non-zero build/check/export VERDICT, a
// non-zero test failed count, and a warden index-refusal (the CLI's exit 2) are all a
// NORMAL ok:false TOOL RESULT — the structured outcome the agent reads and acts on,
// NOT an IsError. The IsError envelope (mcp_error.odin) is reserved for a GENUINE
// internal/boundary fault: a missing required `dir` arg (Invalid_Input) or a compute
// half breaking its own contract (Internal). So a refused build is `{"ok":false,…}`
// carried in a clean tools/call, exactly as the §28 ok:false envelope rides verbatim
// in the observe/control families.
//
// NAMESPACE DISCIPLINE: every package-level proc/type/constant this file adds (tests
// included) is prefixed `oneshot_` so package main has NO duplicate symbols across the
// six dispatch families. The one EXCEPTION is the dispatch entry point
// mcp_oneshot_dispatch — its name is fixed by the chain in mcp_server.odin
// (MCP_DISPATCH_CHAIN) and must not change.
//
// THE COMPUTE-HALVES ARE PURE: stage_build / run_project_pipeline / fmt_drift /
// read_warden_index are pure functions of the tree bytes (they read, never print —
// the print + write side lives in the CLI verb wrappers, main.odin). build / check /
// export here run the pure VERDICT seam ONLY and write NO product, so an MCP build is
// deterministic and side-effect-free — the agent gets the verdict, not a littered tree.
package main

import "../../funpack"
import funpack_runtime "../../runtime"
import "core:encoding/json"
import "core:strings"

// mcp_oneshot_dispatch is the one-shot family's arm. It CLAIMS its tools — build,
// check, export, test, fmt, and warden_find/graph/holes/probes/debt/tags/pipeline — by
// the generated Tool_Spec.group ("oneshot"), folding each through its pure compute-half
// and rendering the outcome into the MCP result. Any tool outside the family is declined
// (handled=false) so the call flows on down the chain (the stub contract every family
// keeps). Claiming on .group, not the name, is the generated-projection invariant: a
// renamed oneshot tool still routes here, and the family cannot drift from the advertised
// set. The per-tool render is dispatched by name within the claimed group.
mcp_oneshot_dispatch :: proc(dispatch: Mcp_Dispatch, allocator := context.allocator) -> (result: string, handled: bool) {
	if dispatch.spec.group != "oneshot" {
		return "", false
	}

	switch dispatch.name {
	case "build":
		return oneshot_build(dispatch, .Dev, allocator), true
	case "export":
		// export is build --release: the shippable artifact's verdict (§29 §4 — a hole
		// or debug probe anywhere refuses, the release-ban arms).
		return oneshot_build(dispatch, .Release, allocator), true
	case "check":
		// check is build's verdict with the write deleted; --release picks the release
		// configuration's ban set (the optional `release` arg).
		return oneshot_build(dispatch, oneshot_check_mode(dispatch.arguments), allocator), true
	case "test":
		return oneshot_test(dispatch, allocator), true
	case "fmt":
		return oneshot_fmt(dispatch, allocator), true
	case "warden_find":
		return oneshot_warden(dispatch, .Find, allocator), true
	case "warden_graph":
		return oneshot_warden(dispatch, .Graph, allocator), true
	case "warden_holes":
		return oneshot_warden(dispatch, .Holes, allocator), true
	case "warden_probes":
		return oneshot_warden(dispatch, .Probes, allocator), true
	case "warden_debt":
		return oneshot_warden(dispatch, .Debt, allocator), true
	case "warden_tags":
		return oneshot_warden(dispatch, .Tags, allocator), true
	case "warden_pipeline":
		return oneshot_warden(dispatch, .Pipeline, allocator), true
	}

	// A tool the contract groups under "oneshot" but this arm does not render: a
	// genuine generator-vs-dispatch gap (a new oneshot tool added to the contract
	// without an arm here). Surface it as an Internal fault rather than silently
	// declining — declining would let the chain fall through to the not-implemented
	// stub, masking the gap; an Internal IsError names the offending tool so the gap
	// is loud, the closed-enum discipline the generated projection depends on.
	return oneshot_tool_error(
		dispatch.id,
		Mcp_Error{category = .Internal, message = "one-shot family claimed a tool it does not render", detail = dispatch.name},
		allocator,
	), true
}

// oneshot_check_mode reads the optional `release` flag off a check call: true selects
// the Release build configuration (its §29 §4 hole/debug bans), absent or false the
// Dev configuration. A non-boolean `release` is treated as absent (Dev) — the schema
// types it boolean, so a malformed value falls back to the safe default rather than
// refusing, mirroring the §28 optional-arg read.
oneshot_check_mode :: proc(arguments: json.Object) -> funpack.Build_Mode {
	if field, present := arguments["release"]; present {
		if flag, is_bool := field.(json.Boolean); is_bool && bool(flag) {
			return .Release
		}
	}
	return .Dev
}

// oneshot_build renders a build/check/export verdict from the PURE stage_build seam
// (NO product write — the MCP tool is verdict-only and side-effect-free). The clean
// verdict (.None) is `{"ok":true,...}` carrying the products' derived paths; a refusal
// is the EXIT-CODE-AS-DATA case — a NORMAL `{"ok":false,...}` result carrying the closed
// Build_Error arm and its operator-facing refusal message (the same line the CLI
// eprints), NOT an IsError. A missing required `dir` is the only IsError here
// (Invalid_Input — a schema violation the agent must correct before any build runs).
oneshot_build :: proc(dispatch: Mcp_Dispatch, mode: funpack.Build_Mode, allocator := context.allocator) -> string {
	dir, has_dir := oneshot_arg_string(dispatch.arguments, "dir")
	if !has_dir {
		return oneshot_tool_error(
			dispatch.id,
			Mcp_Error{category = .Invalid_Input, message = "missing required string argument: dir", detail = dispatch.name},
			allocator,
		)
	}

	product, verdict := funpack.stage_build(dir, mode, allocator)

	b := strings.builder_make(allocator)
	strings.write_string(&b, "{\"tool\":")
	funpack_runtime.write_json_string(&b, dispatch.name)
	strings.write_string(&b, ",\"dir\":")
	funpack_runtime.write_json_string(&b, dir)
	strings.write_string(&b, ",\"mode\":")
	funpack_runtime.write_json_string(&b, oneshot_mode_wire(mode))
	if verdict.err != .None {
		// A build refusal: exit-code-as-data. The closed arm is the machine field; the
		// refusal message is the same operator-facing line the CLI eprints, so the agent
		// reads WHY and what to repair. A clean tools/call carrying ok:false — not an
		// IsError (the refused build resolved; it did not internally fault).
		strings.write_string(&b, ",\"ok\":false,\"error\":")
		funpack_runtime.write_json_string(&b, fmt_build_error_name(verdict.err))
		strings.write_string(&b, ",\"message\":")
		funpack_runtime.write_json_string(&b, funpack.build_refusal_message(verdict, allocator))
		strings.write_byte(&b, '}')
		return oneshot_text_result(dispatch.id, strings.to_string(b), allocator)
	}
	// A clean verdict: report the products' derived paths (artifact_path is "" for a
	// §30 package — no entrypoint, no runtime artifact). The bytes themselves are not
	// written (verdict-only) and not echoed (they are large emit/index streams); the
	// paths tell the agent where a `funpack build` WOULD land them.
	strings.write_string(&b, ",\"ok\":true,\"artifact_path\":")
	funpack_runtime.write_json_string(&b, product.artifact_path)
	strings.write_string(&b, ",\"index_path\":")
	funpack_runtime.write_json_string(&b, product.index_path)
	strings.write_byte(&b, '}')
	return oneshot_text_result(dispatch.id, strings.to_string(b), allocator)
}

// oneshot_test renders a `funpack test` verdict from read_project + run_project_pipeline
// (the test verb's pure substrate, main.odin:run_test_verb). The three outcomes map to
// data, never an IsError unless `dir` is missing: a malformed tree (read_project refusal)
// or a module compile error is `{"ok":false,"error":...}` (the CLI's exit 2 — a compile
// error is never a counted failure, §29 §3); a clean run is `{"ok":<failed==0>,"passed":
// N,"failed":M}` (the CLI's exit 1 when failed>0, exit 0 when all pass) — a FAILED assert
// count is exit-code-as-data, the agent reads the count and fixes the test, never an
// internal fault.
oneshot_test :: proc(dispatch: Mcp_Dispatch, allocator := context.allocator) -> string {
	dir, has_dir := oneshot_arg_string(dispatch.arguments, "dir")
	if !has_dir {
		return oneshot_tool_error(
			dispatch.id,
			Mcp_Error{category = .Invalid_Input, message = "missing required string argument: dir", detail = "test"},
			allocator,
		)
	}

	project, project_err, project_detail := funpack.read_project(dir)
	if project_err != .None {
		return oneshot_test_refusal(dispatch.id, dir, "malformed_tree", funpack.project_refusal_message(project_err, project_detail, allocator), allocator)
	}
	report := funpack.run_project_pipeline(funpack.project_pipeline_sources(project))
	if report.index_err != .None {
		return oneshot_test_refusal(dispatch.id, dir, "index_failed", report.failed_path, allocator)
	}
	if report.module_err != .None {
		// A module compile error (exit 2) — the failing module's path names where to
		// look. The bare path is the message (the CLI renders a richer per-stage
		// diagnostic to stderr; the structured tool result carries the machine fields).
		message := report.failed_path
		return oneshot_test_refusal(dispatch.id, dir, "compile_failed", message, allocator)
	}

	b := strings.builder_make(allocator)
	strings.write_string(&b, "{\"tool\":\"test\",\"dir\":")
	funpack_runtime.write_json_string(&b, dir)
	// ok mirrors the CLI exit code: all-pass (failed==0) is ok:true; a counted failure
	// is ok:false but NOT a refusal — passed/failed carry the verdict the agent acts on.
	strings.write_string(&b, ",\"ok\":")
	strings.write_string(&b, report.failed == 0 ? "true" : "false")
	strings.write_string(&b, ",\"passed\":")
	strings.write_int(&b, report.passed)
	strings.write_string(&b, ",\"failed\":")
	strings.write_int(&b, report.failed)
	strings.write_byte(&b, '}')
	return oneshot_text_result(dispatch.id, strings.to_string(b), allocator)
}

// oneshot_test_refusal renders the test verb's exit-2 refusal (malformed tree / index
// failure / module compile error) as a NORMAL ok:false data result — exit-code-as-data,
// not an IsError. error is the machine arm; message is the offender line the agent reads.
oneshot_test_refusal :: proc(id: Mcp_Id, dir: string, error_name: string, message: string, allocator := context.allocator) -> string {
	b := strings.builder_make(allocator)
	strings.write_string(&b, "{\"tool\":\"test\",\"dir\":")
	funpack_runtime.write_json_string(&b, dir)
	strings.write_string(&b, ",\"ok\":false,\"error\":")
	funpack_runtime.write_json_string(&b, error_name)
	strings.write_string(&b, ",\"message\":")
	funpack_runtime.write_json_string(&b, message)
	strings.write_byte(&b, '}')
	return oneshot_text_result(id, strings.to_string(b), allocator)
}

// oneshot_fmt renders a `funpack fmt --check` verdict from the pure fmt_drift seam (NO
// write — the MCP fmt tool is verdict-only, the --check face). A read_project / read /
// parse refusal is the exit-2 ok:false data case (the closed Fmt_Error arm + its offender
// line); a clean compute is `{"ok":<no drift>,"drifted":[{path,unified_diff},…]}` — a
// drifting tree is ok:false (the CLI's exit 1) carrying each drift's path + unified diff
// so the agent sees exactly what to reformat, never an IsError. Only a missing `dir` is
// an IsError (Invalid_Input).
oneshot_fmt :: proc(dispatch: Mcp_Dispatch, allocator := context.allocator) -> string {
	dir, has_dir := oneshot_arg_string(dispatch.arguments, "dir")
	if !has_dir {
		return oneshot_tool_error(
			dispatch.id,
			Mcp_Error{category = .Invalid_Input, message = "missing required string argument: dir", detail = "fmt"},
			allocator,
		)
	}

	drifted, verdict := funpack.fmt_drift(dir, allocator)
	if verdict.err != .None {
		b := strings.builder_make(allocator)
		strings.write_string(&b, "{\"tool\":\"fmt\",\"dir\":")
		funpack_runtime.write_json_string(&b, dir)
		strings.write_string(&b, ",\"ok\":false,\"error\":")
		funpack_runtime.write_json_string(&b, fmt_error_name(verdict.err))
		strings.write_string(&b, ",\"message\":")
		funpack_runtime.write_json_string(&b, verdict.offender)
		strings.write_byte(&b, '}')
		return oneshot_text_result(dispatch.id, strings.to_string(b), allocator)
	}

	b := strings.builder_make(allocator)
	strings.write_string(&b, "{\"tool\":\"fmt\",\"dir\":")
	funpack_runtime.write_json_string(&b, dir)
	// ok mirrors `funpack fmt --check`: a canonical tree (no drift) is exit 0/ok:true;
	// any drift is exit 1/ok:false, the drifted list carrying the fix.
	strings.write_string(&b, ",\"ok\":")
	strings.write_string(&b, len(drifted) == 0 ? "true" : "false")
	strings.write_string(&b, ",\"drifted\":[")
	for d, i in drifted {
		if i > 0 {
			strings.write_byte(&b, ',')
		}
		strings.write_string(&b, "{\"path\":")
		funpack_runtime.write_json_string(&b, d.path)
		strings.write_string(&b, ",\"unified_diff\":")
		funpack_runtime.write_json_string(&b, d.unified_diff)
		strings.write_byte(&b, '}')
	}
	strings.write_string(&b, "]}")
	return oneshot_text_result(dispatch.id, strings.to_string(b), allocator)
}

// oneshot_warden renders a `funpack warden <cmd>` query from the pure read_warden_index
// acquisition + warden_command_output projection (the warden verb's substrate,
// main.odin:warden_verb_exit). An index refusal (the CLI's exit 2 — a missing/
// schema-mismatched/malformed `.funpack/index.ndjson`) is the EXIT-CODE-AS-DATA case: a
// NORMAL `{"ok":false,"error":...,"message":...}` carrying the refusal's fix-it (run
// `funpack build` to emit the index), NOT an IsError — the agent reads the refusal and
// rebuilds. A decoded index is `{"ok":true,"output":"<ndjson>"}` carrying the command's
// pure NDJSON projection verbatim (an empty projection is a clean empty string). Only a
// missing `dir` is an IsError (Invalid_Input). The find query is read off the optional
// `query` arg for warden_find, "" for every other command; graph reads its optional
// `node` arg as the incident-edge filter.
oneshot_warden :: proc(dispatch: Mcp_Dispatch, cmd: funpack.Warden_Command, allocator := context.allocator) -> string {
	dir, has_dir := oneshot_arg_string(dispatch.arguments, "dir")
	if !has_dir {
		return oneshot_tool_error(
			dispatch.id,
			Mcp_Error{category = .Invalid_Input, message = "missing required string argument: dir", detail = dispatch.name},
			allocator,
		)
	}

	index, refusal := funpack.read_warden_index(dir, allocator)
	if refusal.err != .None {
		// Index-refusal as data: the CLI's exit 2. The arm names the machine cause; the
		// refusal message is the same fix-it the CLI eprints (`funpack build` to emit it).
		b := strings.builder_make(allocator)
		strings.write_string(&b, "{\"tool\":")
		funpack_runtime.write_json_string(&b, dispatch.name)
		strings.write_string(&b, ",\"dir\":")
		funpack_runtime.write_json_string(&b, dir)
		strings.write_string(&b, ",\"ok\":false,\"error\":")
		funpack_runtime.write_json_string(&b, warden_error_name(refusal.err))
		strings.write_string(&b, ",\"message\":")
		funpack_runtime.write_json_string(&b, funpack.warden_refusal_message(refusal, allocator))
		strings.write_byte(&b, '}')
		return oneshot_text_result(dispatch.id, strings.to_string(b), allocator)
	}

	// The find filter: warden_find reads its `query` substring; graph reads its `node`
	// incident-edge positional. Every other command carries the zero query / empty arg.
	find := funpack.Warden_Find_Query{}
	arg := ""
	if cmd == .Find {
		if query, has_query := oneshot_arg_string(dispatch.arguments, "query"); has_query {
			find.name = query
		}
	} else if cmd == .Graph {
		if node, has_node := oneshot_arg_string(dispatch.arguments, "node"); has_node {
			arg = node
		}
	}

	output := funpack.warden_command_output(index, cmd, arg, find, allocator)
	b := strings.builder_make(allocator)
	strings.write_string(&b, "{\"tool\":")
	funpack_runtime.write_json_string(&b, dispatch.name)
	strings.write_string(&b, ",\"dir\":")
	funpack_runtime.write_json_string(&b, dir)
	strings.write_string(&b, ",\"ok\":true,\"output\":")
	funpack_runtime.write_json_string(&b, output)
	strings.write_byte(&b, '}')
	return oneshot_text_result(dispatch.id, strings.to_string(b), allocator)
}

// oneshot_mode_wire is the Build_Mode → wire string for the build/check/export result
// envelope. Exhaustive (no default) so a new Build_Mode without a wire string is a
// compile error — the closed-enum discipline.
oneshot_mode_wire :: proc(mode: funpack.Build_Mode) -> string {
	switch mode {
	case .Dev:
		return "dev"
	case .Release:
		return "release"
	}
	return "dev"
}

// fmt_build_error_name maps a Build_Error arm to its wire name for the ok:false build
// result. Exhaustive over the closed enum so a new arm is a compile error here, never a
// silently-stringified `%v`. (Named `fmt_*` not `oneshot_*` would collide nothing, but
// the family prefix keeps it merge-clean.)
fmt_build_error_name :: proc(err: funpack.Build_Error) -> string {
	switch err {
	case .None:
		return "none"
	case .Malformed_Tree:
		return "malformed_tree"
	case .Compile_Failed:
		return "compile_failed"
	case .Index_Failed:
		return "index_failed"
	case .Holed_Declaration:
		return "holed_declaration"
	case .Debug_Directive:
		return "debug_directive"
	case .Asset_Bake_Failed:
		return "asset_bake_failed"
	case .Let_Tuple_Unsupported_Wire:
		return "let_tuple_unsupported_wire"
	}
	return "unknown"
}

// fmt_error_name maps a Fmt_Error arm to its wire name for the ok:false fmt result.
// Exhaustive over the closed enum.
fmt_error_name :: proc(err: funpack.Fmt_Error) -> string {
	switch err {
	case .None:
		return "none"
	case .Malformed_Tree:
		return "malformed_tree"
	case .Read_Failed:
		return "read_failed"
	case .Parse_Failed:
		return "parse_failed"
	}
	return "unknown"
}

// warden_error_name maps a Warden_Read_Error arm to its wire name for the ok:false
// warden result. Exhaustive over the closed refusal surface.
warden_error_name :: proc(err: funpack.Warden_Read_Error) -> string {
	switch err {
	case .None:
		return "none"
	case .Missing_Index:
		return "missing_index"
	case .Empty_Index:
		return "empty_index"
	case .Missing_Project_Record:
		return "missing_project_record"
	case .Duplicate_Project_Record:
		return "duplicate_project_record"
	case .Schema_Mismatch:
		return "schema_mismatch"
	case .Record_Refused:
		return "record_refused"
	}
	return "unknown"
}

// oneshot_arg_string reads one string argument off the MCP arguments object — the
// required `dir` selector and the optional warden `query`/`node` filters. An absent or
// non-string field is has=false (the schema-violation path the arm maps to Invalid_Input
// for a required arg, or treats as absent for an optional one).
oneshot_arg_string :: proc(arguments: json.Object, key: string) -> (value: string, has: bool) {
	field, present := arguments[key]
	if !present {
		return "", false
	}
	text, is_string := field.(json.String)
	if !is_string {
		return "", false
	}
	return string(text), true
}

// oneshot_text_result wraps an already-rendered structured JSON string into a clean
// (isError=false) MCP tool result with one text content block — the common shape every
// oneshot tool's success AND exit-code-as-data outcome takes. The structured JSON IS the
// result the agent reads; ok:false rides inside it (exit-code-as-data), never as an
// IsError. The IsError path is oneshot_tool_error (a genuine boundary fault only).
oneshot_text_result :: proc(id: Mcp_Id, structured_json: string, allocator := context.allocator) -> string {
	content := make([]Mcp_Content, 1, allocator)
	content[0] = mcp_text_content(structured_json)
	return mcp_render_tool_result(id, Mcp_Tool_Result{content = content, is_error = false}, allocator)
}

// oneshot_tool_error renders a GENUINE boundary fault as the in-band IsError tool result
// (the mcp_error.odin convention — a SUCCESSFUL tools/call carrying isError=true, never a
// JSON-RPC error object). This is the NARROW path: a missing required `dir` arg
// (Invalid_Input) or a generator-vs-dispatch gap (Internal). Exit-code-as-data outcomes
// (a refused build, a failed test, a warden index-refusal) do NOT come here — they ride
// oneshot_text_result as ok:false data.
oneshot_tool_error :: proc(id: Mcp_Id, err: Mcp_Error, allocator := context.allocator) -> string {
	return mcp_render_tool_result(id, mcp_tool_error_result(err, allocator), allocator)
}

// oneshot_family_tools is this family's tool roster — the twelve tools
// mcp_oneshot_dispatch claims. Kept as a package-level table the family's tests walk
// (assert each is in TOOL_SPECS under the oneshot group, assert no other family's tool
// is claimed), so the roster has one source the dispatch and the tests share.
oneshot_family_tools := [?]string {
	"build",
	"check",
	"export",
	"test",
	"fmt",
	"warden_find",
	"warden_graph",
	"warden_holes",
	"warden_probes",
	"warden_debt",
	"warden_tags",
	"warden_pipeline",
}
