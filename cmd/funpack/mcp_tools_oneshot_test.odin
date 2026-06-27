package main

import "core:encoding/json"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:testing"

ONESHOT_MINI_SOURCE :: "@doc(\"Minimal buildable module: an empty pipeline and a deviceless bindings fn.\")\n\nimport engine.input.{Bindings}\n\n@doc(\"No bindings — the minimal deviceless map.\")\nfn bindings() -> Bindings {\n  return Bindings.empty()\n}\n\n@doc(\"The empty schedule.\")\npipeline Loop {\n}\n"

ONESHOT_HOLED_SOURCE :: ONESHOT_MINI_SOURCE + "\n@doc(\"A typed hole: dev compiles it, release refuses to ship it.\")\nfn approx_speed() -> Fixed @stub(Fixed)\n"

ONESHOT_UNKNOWN_MEMBER_SOURCE :: "@doc(\"A module importing a member engine.list does not export.\")\n\nimport engine.list.{nonexistent_member}\n\n@doc(\"No bindings — the minimal deviceless map.\")\nfn bindings() -> Bindings {\n  return Bindings.empty()\n}\n\n@doc(\"The empty schedule.\")\npipeline Loop {\n}\n"

@(private = "file")
oneshot_temp_root :: proc(name: string) -> string {
	base := os.get_env("TMPDIR", context.temp_allocator)
	if base == "" {
		base = "/tmp"
	}
	root, _ := filepath.join({base, name}, context.temp_allocator)
	os.remove_all(root)
	return root
}

@(private = "file")
oneshot_write_tree :: proc(name: string, source: string) -> (root: string, ok: bool) {
	root = oneshot_temp_root(name)
	configs, _ := filepath.join({root, "funpack_configs"}, context.temp_allocator)
	src_dir, _ := filepath.join({root, "src"}, context.temp_allocator)
	if os.make_directory_all(configs) != nil && !os.exists(configs) {
		return "", false
	}
	if os.make_directory_all(src_dir) != nil && !os.exists(src_dir) {
		return "", false
	}
	src_path, _ := filepath.join({src_dir, "mini.fun"}, context.temp_allocator)
	ok_writes :=
		oneshot_write(configs, "project.fcfg", "project mini {\n  version = \"0.1.0\"\n}\n") &&
		oneshot_write(configs, "entrypoints.fcfg", "use mini.{Loop, bindings}\n\nentrypoint main {\n  pipeline = Loop\n  tick = 60hz\n  logical = 160x120\n  bindings = bindings\n}\n") &&
		oneshot_write(configs, "builds.fcfg", "build native {\n  platform = desktop\n}\n") &&
		oneshot_write(configs, "tags.fcfg", "tags {\n  game\n}\n") &&
		os.write_entire_file(src_path, transmute([]u8)source) == nil
	if !ok_writes {
		return "", false
	}
	return root, true
}

@(private = "file")
oneshot_write :: proc(dir: string, name: string, body: string) -> bool {
	path, _ := filepath.join({dir, name}, context.temp_allocator)
	return os.write_entire_file(path, transmute([]u8)body) == nil
}

@(private = "file")
oneshot_dispatch_tool :: proc(tool_name: string, args_json: string) -> (result: string, handled: bool) {
	spec, found := mcp_lookup_tool(tool_name)
	if !found {
		return "", false
	}
	arguments: json.Object
	parsed, err := json.parse(transmute([]u8)args_json, json.DEFAULT_SPECIFICATION, true, context.temp_allocator)
	if err == .None {
		if object, is_object := parsed.(json.Object); is_object {
			arguments = object
		}
	}
	dispatch := Mcp_Dispatch {
		spec      = spec,
		name      = tool_name,
		arguments = arguments,
		id        = Mcp_Id{kind = .Integer, integer = 7},
	}
	return mcp_oneshot_dispatch(dispatch, context.temp_allocator)
}

@(test)
test_oneshot_family_claims_exactly_its_tools :: proc(t: ^testing.T) {
	for tool in oneshot_family_tools {
		_, handled := oneshot_dispatch_tool(tool, `{}`)
		testing.expect(t, handled, "the one-shot family claims its own tool")
		spec, found := mcp_lookup_tool(tool)
		testing.expect(t, found, "every one-shot tool is a generated Tool_Spec")
		testing.expect_value(t, spec.group, "oneshot")
	}

	other_family := [?]string{"docs_search", "session_start", "inspect_pipeline", "control_branch", "inspect_screenshot"}
	for other in other_family {
		spec, found := mcp_lookup_tool(other)
		if !found {
			continue
		}
		dispatch := Mcp_Dispatch{spec = spec, name = other, id = Mcp_Id{kind = .Integer, integer = 1}}
		_, handled := mcp_oneshot_dispatch(dispatch, context.temp_allocator)
		testing.expect(t, !handled, "the one-shot family declines a tool another family owns")
	}
}

@(test)
test_oneshot_missing_dir_is_invalid_input :: proc(t: ^testing.T) {
	result, handled := oneshot_dispatch_tool("build", `{}`)
	testing.expect(t, handled, "the family claims build even when dir is missing")
	testing.expect(t, strings.contains(result, `"result":`), "the refusal is a JSON-RPC result, not an error object")
	testing.expect(t, !strings.contains(result, `"error":{"code"`), "no JSON-RPC error object for a domain refusal")
	testing.expect(t, strings.contains(result, `"isError":true`), "a missing dir is an IsError result")
	testing.expect(t, strings.contains(result, `\"category\":\"invalid_input\"`), "keyed invalid_input")
}

@(test)
test_oneshot_build_clean_tree_ok :: proc(t: ^testing.T) {
	root, ok := oneshot_write_tree("funpack-mcp-oneshot-build", ONESHOT_MINI_SOURCE)
	if !ok {
		return
	}
	defer os.remove_all(root)

	result, handled := oneshot_dispatch_tool("build", oneshot_dir_args(root))
	testing.expect(t, handled, "build is claimed")
	testing.expect(t, strings.contains(result, `"isError":false`), "a clean build is not an error")
	testing.expect(t, strings.contains(result, `\"ok\":true`), "the clean verdict is ok:true data")
	testing.expect(t, strings.contains(result, `\"index_path\":`), "the derived index path is surfaced")
}

@(test)
test_oneshot_check_clean_tree_ok :: proc(t: ^testing.T) {
	root, ok := oneshot_write_tree("funpack-mcp-oneshot-check", ONESHOT_MINI_SOURCE)
	if !ok {
		return
	}
	defer os.remove_all(root)

	result, handled := oneshot_dispatch_tool("check", oneshot_dir_args(root))
	testing.expect(t, handled, "check is claimed")
	testing.expect(t, strings.contains(result, `"isError":false`), "a clean check is not an error")
	testing.expect(t, strings.contains(result, `\"ok\":true`), "the clean check verdict is ok:true data")
}

@(test)
test_oneshot_check_compile_error_surfaces_diagnostics :: proc(t: ^testing.T) {
	root, ok := oneshot_write_tree("funpack-mcp-oneshot-check-diag", ONESHOT_UNKNOWN_MEMBER_SOURCE)
	if !ok {
		return
	}
	defer os.remove_all(root)

	result, handled := oneshot_dispatch_tool("check", oneshot_dir_args(root))
	testing.expect(t, handled, "check is claimed")
	testing.expect(t, strings.contains(result, `"isError":false`), "a compile error is exit-code-as-DATA, never an IsError")
	testing.expect(t, strings.contains(result, `\"ok\":false`), "the refused check verdict is ok:false data")
	testing.expect(t, strings.contains(result, `\"error\":\"compile_failed\"`), "the closed Build_Error arm is the machine field")
	testing.expect(t, strings.contains(result, `\"diagnostics\":[{`), "the diagnostics array rides the failed result")
	testing.expect(t, strings.contains(result, `\"code\":\"Unknown_Member\"`), "the closed rule code is surfaced (not the bare Compile_Failed)")
	testing.expect(t, strings.contains(result, `\"stage\":\"typecheck\"`), "the offending pipeline stage is surfaced")
	testing.expect(t, strings.contains(result, `\"line\":3`), "the 1-based offending line is surfaced")
	testing.expect(t, strings.contains(result, `\"col\":1`), "the 1-based offending column is surfaced")
	testing.expect(t, strings.contains(result, `\"file\":`), "the offending source file is surfaced")
	testing.expect(t, strings.contains(result, `\"rendered\":`), "the full caret-excerpt render rides alongside the machine fields")
	testing.expect(t, strings.contains(result, `import engine.list.{nonexistent_member}`), "the rendered excerpt carries the offending source line")
}

@(test)
test_oneshot_export_holed_tree_is_data_refusal :: proc(t: ^testing.T) {
	root, ok := oneshot_write_tree("funpack-mcp-oneshot-export-holed", ONESHOT_HOLED_SOURCE)
	if !ok {
		return
	}
	defer os.remove_all(root)

	result, handled := oneshot_dispatch_tool("export", oneshot_dir_args(root))
	testing.expect(t, handled, "export is claimed")
	testing.expect(t, strings.contains(result, `"isError":false`), "a refused release build is exit-code-as-DATA, never an IsError")
	testing.expect(t, strings.contains(result, `\"ok\":false`), "the refused verdict is ok:false data")
	testing.expect(t, strings.contains(result, `\"error\":\"holed_declaration\"`), "the closed Build_Error arm is the machine field")
	testing.expect(t, strings.contains(result, `\"mode\":\"release\"`), "export builds in release mode")
}

@(test)
test_oneshot_test_clean_tree_reports_counts :: proc(t: ^testing.T) {
	root, ok := oneshot_write_tree("funpack-mcp-oneshot-test", ONESHOT_MINI_SOURCE)
	if !ok {
		return
	}
	defer os.remove_all(root)

	result, handled := oneshot_dispatch_tool("test", oneshot_dir_args(root))
	testing.expect(t, handled, "test is claimed")
	testing.expect(t, strings.contains(result, `"isError":false`), "a clean test run is not an error")
	testing.expect(t, strings.contains(result, `\"passed\":`), "the passed count is surfaced")
	testing.expect(t, strings.contains(result, `\"failed\":`), "the failed count is surfaced")
}

@(test)
test_oneshot_test_compile_error_surfaces_diagnostics :: proc(t: ^testing.T) {
	root, ok := oneshot_write_tree("funpack-mcp-oneshot-test-diag", ONESHOT_UNKNOWN_MEMBER_SOURCE)
	if !ok {
		return
	}
	defer os.remove_all(root)

	result, handled := oneshot_dispatch_tool("test", oneshot_dir_args(root))
	testing.expect(t, handled, "test is claimed")
	testing.expect(t, strings.contains(result, `"isError":false`), "a compile error is exit-code-as-DATA, never an IsError")
	testing.expect(t, strings.contains(result, `\"ok\":false`), "the refused test verdict is ok:false data")
	testing.expect(t, strings.contains(result, `\"error\":\"compile_failed\"`), "a module compile error is the compile_failed arm (exit 2)")
	testing.expect(t, strings.contains(result, `\"diagnostics\":[{`), "the diagnostics array rides the failed result")
	testing.expect(t, strings.contains(result, `\"code\":\"Unknown_Member\"`), "the closed rule code is surfaced (not the bare source path)")
	testing.expect(t, strings.contains(result, `\"line\":3`), "the 1-based offending line is surfaced")
	testing.expect(t, strings.contains(result, `\"rendered\":`), "the full caret-excerpt render rides alongside the machine fields")
	testing.expect(t, strings.contains(result, `import engine.list.{nonexistent_member}`), "the rendered excerpt carries the offending source line")
}

@(test)
test_oneshot_fmt_canonical_tree_no_drift :: proc(t: ^testing.T) {
	root, ok := oneshot_write_tree("funpack-mcp-oneshot-fmt", ONESHOT_MINI_SOURCE)
	if !ok {
		return
	}
	defer os.remove_all(root)

	result, handled := oneshot_dispatch_tool("fmt", oneshot_dir_args(root))
	testing.expect(t, handled, "fmt is claimed")
	testing.expect(t, strings.contains(result, `"isError":false`), "a clean fmt check is not an error")
	testing.expect(t, strings.contains(result, `\"drifted\":[`), "the drifted list is surfaced")
}

@(test)
test_oneshot_warden_missing_index_is_data_refusal :: proc(t: ^testing.T) {
	root, ok := oneshot_write_tree("funpack-mcp-oneshot-warden", ONESHOT_MINI_SOURCE)
	if !ok {
		return
	}
	defer os.remove_all(root)

	result, handled := oneshot_dispatch_tool("warden_holes", oneshot_dir_args(root))
	testing.expect(t, handled, "warden_holes is claimed")
	testing.expect(t, strings.contains(result, `"isError":false`), "a warden index-refusal is exit-code-as-DATA, never an IsError")
	testing.expect(t, strings.contains(result, `\"ok\":false`), "the refused index is ok:false data")
	testing.expect(t, strings.contains(result, `\"error\":\"missing_index\"`), "the closed Warden_Read_Error arm is the machine field")
}

@(test)
test_oneshot_reachable_through_tools_call :: proc(t: ^testing.T) {
	root, ok := oneshot_write_tree("funpack-mcp-oneshot-e2e", ONESHOT_MINI_SOURCE)
	if !ok {
		return
	}
	defer os.remove_all(root)

	line := strings.concatenate(
		{`{"jsonrpc":"2.0","id":42,"method":"tools/call","params":{"name":"build","arguments":{"dir":`, oneshot_json_string(root), `}}}`},
		context.temp_allocator,
	)
	request, parsed, _ := mcp_parse_request(line, context.temp_allocator)
	testing.expect(t, parsed, "the tools/call line parses as a request")

	registry := mcp_session_registry_make(context.temp_allocator)
	defer mcp_session_registry_destroy(&registry, context.temp_allocator)
	result := mcp_handle_tools_call(&registry, request, context.temp_allocator)

	testing.expect(t, strings.contains(result, `"id":42`), "the JSON-RPC id echoes back")
	testing.expect(t, strings.contains(result, `"result":`), "tools/call returns a JSON-RPC result")
	testing.expect(t, !strings.contains(result, "tool not yet implemented"), "build is no longer the not-implemented stub")
	testing.expect(t, !strings.contains(result, "unknown tool"), "build is a known tool")
	testing.expect(t, strings.contains(result, `\"tool\":\"build\"`), "the structured build verdict is returned")
	testing.expect(t, strings.contains(result, `\"ok\":true`), "the clean build verdict rode through the real dispatch")
}

@(private = "file")
oneshot_dir_args :: proc(dir: string) -> string {
	return strings.concatenate({`{"dir":`, oneshot_json_string(dir), `}`}, context.temp_allocator)
}

@(private = "file")
oneshot_json_string :: proc(s: string) -> string {
	b := strings.builder_make(context.temp_allocator)
	strings.write_byte(&b, '"')
	for r in s {
		switch r {
		case '"':
			strings.write_string(&b, "\\\"")
		case '\\':
			strings.write_string(&b, "\\\\")
		case:
			strings.write_rune(&b, r)
		}
	}
	strings.write_byte(&b, '"')
	return strings.to_string(b)
}
