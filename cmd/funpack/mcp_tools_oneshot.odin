package main

import "../../funpack"
import funpack_runtime "../../runtime"
import "core:encoding/json"
import "core:os"
import "core:strings"

mcp_oneshot_dispatch :: proc(dispatch: Mcp_Dispatch, allocator := context.allocator) -> (result: string, handled: bool) {
	if dispatch.spec.group != "oneshot" {
		return "", false
	}

	switch dispatch.name {
	case "build":
		return oneshot_build(dispatch, .Dev, allocator), true
	case "export":
		return oneshot_build(dispatch, .Release, allocator), true
	case "check":
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

	return mcp_tool_error(
		dispatch.id,
		Mcp_Error{category = .Internal, message = "one-shot family claimed a tool it does not render", detail = dispatch.name},
		allocator,
	), true
}

oneshot_check_mode :: proc(arguments: json.Object) -> funpack.Build_Mode {
	if field, present := arguments["release"]; present {
		if flag, is_bool := field.(json.Boolean); is_bool && bool(flag) {
			return .Release
		}
	}
	return .Dev
}

oneshot_build :: proc(dispatch: Mcp_Dispatch, mode: funpack.Build_Mode, allocator := context.allocator) -> string {
	dir, has_dir := funpack_runtime.json_string_field(dispatch.arguments, "dir")
	if !has_dir {
		return mcp_tool_error(dispatch.id, mcp_missing_string_field("dir", dispatch.name, allocator), allocator)
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
		strings.write_string(&b, ",\"ok\":false,\"error\":")
		funpack_runtime.write_json_string(&b, fmt_build_error_name(verdict.err))
		strings.write_string(&b, ",\"message\":")
		funpack_runtime.write_json_string(&b, funpack.build_refusal_message(verdict, allocator))
		oneshot_write_diagnostics(&b, verdict.diagnostic, allocator)
		strings.write_byte(&b, '}')
		return mcp_text_result(dispatch.id, strings.to_string(b), allocator)
	}
	strings.write_string(&b, ",\"ok\":true,\"artifact_path\":")
	funpack_runtime.write_json_string(&b, product.artifact_path)
	strings.write_string(&b, ",\"index_path\":")
	funpack_runtime.write_json_string(&b, product.index_path)
	strings.write_byte(&b, '}')
	return mcp_text_result(dispatch.id, strings.to_string(b), allocator)
}

oneshot_test :: proc(dispatch: Mcp_Dispatch, allocator := context.allocator) -> string {
	dir, has_dir := funpack_runtime.json_string_field(dispatch.arguments, "dir")
	if !has_dir {
		return mcp_tool_error(dispatch.id, mcp_missing_string_field("dir", dispatch.name, allocator), allocator)
	}

	project, project_err, project_detail := funpack.read_project(dir)
	if project_err != .None {
		return oneshot_test_refusal(dispatch.id, dir, "malformed_tree", funpack.project_refusal_message(project_err, project_detail, allocator), funpack.Diagnostic{}, allocator)
	}
	report := funpack.run_project_pipeline(funpack.project_pipeline_sources(project))
	if report.index_err != .None {
		return oneshot_test_refusal(dispatch.id, dir, "index_failed", report.failed_path, funpack.Diagnostic{}, allocator)
	}
	if report.module_err != .None {
		return oneshot_test_refusal(dispatch.id, dir, "compile_failed", report.failed_path, report.diagnostic, allocator)
	}

	b := strings.builder_make(allocator)
	strings.write_string(&b, "{\"tool\":\"test\",\"dir\":")
	funpack_runtime.write_json_string(&b, dir)
	strings.write_string(&b, ",\"ok\":")
	strings.write_string(&b, report.failed == 0 ? "true" : "false")
	strings.write_string(&b, ",\"passed\":")
	strings.write_int(&b, report.passed)
	strings.write_string(&b, ",\"failed\":")
	strings.write_int(&b, report.failed)
	strings.write_byte(&b, '}')
	return mcp_text_result(dispatch.id, strings.to_string(b), allocator)
}

oneshot_test_refusal :: proc(id: Mcp_Id, dir: string, error_name: string, message: string, diag: funpack.Diagnostic, allocator := context.allocator) -> string {
	b := strings.builder_make(allocator)
	strings.write_string(&b, "{\"tool\":\"test\",\"dir\":")
	funpack_runtime.write_json_string(&b, dir)
	strings.write_string(&b, ",\"ok\":false,\"error\":")
	funpack_runtime.write_json_string(&b, error_name)
	strings.write_string(&b, ",\"message\":")
	funpack_runtime.write_json_string(&b, message)
	oneshot_write_diagnostics(&b, diag, allocator)
	strings.write_byte(&b, '}')
	return mcp_text_result(id, strings.to_string(b), allocator)
}

oneshot_fmt :: proc(dispatch: Mcp_Dispatch, allocator := context.allocator) -> string {
	dir, has_dir := funpack_runtime.json_string_field(dispatch.arguments, "dir")
	if !has_dir {
		return mcp_tool_error(dispatch.id, mcp_missing_string_field("dir", dispatch.name, allocator), allocator)
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
		return mcp_text_result(dispatch.id, strings.to_string(b), allocator)
	}

	b := strings.builder_make(allocator)
	strings.write_string(&b, "{\"tool\":\"fmt\",\"dir\":")
	funpack_runtime.write_json_string(&b, dir)
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
	return mcp_text_result(dispatch.id, strings.to_string(b), allocator)
}

oneshot_warden :: proc(dispatch: Mcp_Dispatch, cmd: funpack.Warden_Command, allocator := context.allocator) -> string {
	dir, has_dir := funpack_runtime.json_string_field(dispatch.arguments, "dir")
	if !has_dir {
		return mcp_tool_error(dispatch.id, mcp_missing_string_field("dir", dispatch.name, allocator), allocator)
	}

	index, refusal := funpack.read_warden_index(dir, allocator)
	if refusal.err != .None {
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
		return mcp_text_result(dispatch.id, strings.to_string(b), allocator)
	}

	find := funpack.Warden_Find_Query{}
	arg := ""
	if cmd == .Find {
		if query, has_query := funpack_runtime.json_string_field(dispatch.arguments, "query"); has_query {
			find.name = query
		}
	} else if cmd == .Graph {
		if node, has_node := funpack_runtime.json_string_field(dispatch.arguments, "node"); has_node {
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
	return mcp_text_result(dispatch.id, strings.to_string(b), allocator)
}

oneshot_write_diagnostics :: proc(b: ^strings.Builder, diag: funpack.Diagnostic, allocator := context.allocator) {
	if diag.rule == "" {
		return
	}
	source := ""
	if bytes, read_err := os.read_entire_file_from_path(diag.path, allocator); read_err == nil {
		source = string(bytes)
	}
	strings.write_string(b, ",\"diagnostics\":[{\"code\":")
	funpack_runtime.write_json_string(b, diag.rule)
	strings.write_string(b, ",\"stage\":")
	funpack_runtime.write_json_string(b, oneshot_diag_stage_wire(diag.stage))
	strings.write_string(b, ",\"file\":")
	funpack_runtime.write_json_string(b, diag.path)
	strings.write_string(b, ",\"line\":")
	strings.write_int(b, diag.line)
	strings.write_string(b, ",\"col\":")
	strings.write_int(b, diag.col)
	strings.write_string(b, ",\"declaration\":")
	funpack_runtime.write_json_string(b, diag.declaration)
	strings.write_string(b, ",\"message\":")
	funpack_runtime.write_json_string(b, diag.message)
	strings.write_string(b, ",\"hint\":")
	funpack_runtime.write_json_string(b, diag.hint)
	strings.write_string(b, ",\"rendered\":")
	funpack_runtime.write_json_string(b, funpack.render_diagnostic(diag, source, allocator))
	strings.write_string(b, "}]")
}

oneshot_diag_stage_wire :: proc(stage: funpack.Diag_Stage) -> string {
	switch stage {
	case .Parse:
		return "parse"
	case .Gate:
		return "gate"
	case .Typecheck:
		return "typecheck"
	case .Contract:
		return "contract"
	case .Closure:
		return "closure"
	}
	return "unknown"
}

oneshot_mode_wire :: proc(mode: funpack.Build_Mode) -> string {
	switch mode {
	case .Dev:
		return "dev"
	case .Release:
		return "release"
	}
	return "dev"
}

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
	}
	return "unknown"
}

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
