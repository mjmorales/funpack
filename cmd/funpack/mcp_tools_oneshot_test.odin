// Deliberate spec for the ONE-SHOT compute-tool dispatch family
// (mcp_tools_oneshot.odin) — the living junction test for the stateless build / check /
// export / test / fmt / warden_* arm of the tools/call chain. It exercises the WHOLE
// seam: an Mcp_Dispatch built exactly as mcp_handle_tools_call builds one (resolved
// Tool_Spec, parsed MCP arguments) folded through mcp_oneshot_dispatch against a real
// §14 project tree on disk, asserting the rendered JSON-RPC result. The tests pin the
// contract this family must keep:
//
//   - family claim: every oneshot tool is claimed (handled=true) and no tool another
//     family owns is claimed (the merge-clean invariant — one owner per tool name);
//   - EXIT-CODE-AS-DATA, the family's crux: a refused build/export (the CLI's exit 2), a
//     warden index-refusal (exit 2), and a failed test count (exit 1) are all a NORMAL
//     ok:false TOOL RESULT (isError:false), NOT an IsError — only a missing required arg
//     is an IsError;
//   - the compute-halves are wired in-process (no subprocess): build/check/export →
//     stage_build, test → run_project_pipeline, fmt → fmt_drift, warden → read_warden_index;
//   - REACHABILITY end to end: a tools/call for an oneshot tool driven through the real
//     mcp_handle_tools_call returns the tool's structured result — NOT the "tool not yet
//     implemented" / unknown-tool stub the family replaced.
//
// DEFINE-FREE FLOOR: everything the arm folds is SDL-free (the compute-halves are the
// compiler's pure seams), so the family's dispatch contract is pinned in the same
// deterministic `odin test .` floor the rest of the compiler tests run in.
package main

import "core:encoding/json"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:testing"

// ONESHOT_MINI_SOURCE is a minimal compileable funpack module: the empty `Loop` pipeline
// and the deviceless `bindings` fn the fixture's entrypoints.fcfg references, so a build
// over the tree resolves and emits. Mirrors funpack/build_test.odin's MINI_SOURCE (kept
// local — the funpack package's test helper is @(private) and unreachable from package
// main, the self-contained-test standard).
ONESHOT_MINI_SOURCE :: "@doc(\"Minimal buildable module: an empty pipeline and a deviceless bindings fn.\")\n\nimport engine.input.{Bindings}\n\n@doc(\"No bindings — the minimal deviceless map.\")\nfn bindings() -> Bindings {\n  return Bindings.empty()\n}\n\n@doc(\"The empty schedule.\")\npipeline Loop {\n}\n"

// ONESHOT_HOLED_SOURCE is the minimal module plus one §05 typed hole — dev builds it,
// release (export) refuses it (Holed_Declaration), the exit-code-as-data fixture.
ONESHOT_HOLED_SOURCE :: ONESHOT_MINI_SOURCE + "\n@doc(\"A typed hole: dev compiles it, release refuses to ship it.\")\nfn approx_speed() -> Fixed @stub(Fixed)\n"

// oneshot_temp_root returns a uniquely-named scratch directory path under TMPDIR for a
// fixture tree, cleared if it already exists.
@(private = "file")
oneshot_temp_root :: proc(name: string) -> string {
	base := os.get_env("TMPDIR", context.temp_allocator)
	if base == "" {
		base = "/tmp"
	}
	root, _ := filepath.join({base, name}, context.temp_allocator)
	os.remove_all(root) // best-effort: clear any stale tree from a prior run before re-staging
	return root
}

// oneshot_write_tree materializes a minimal valid §14 game tree at a fresh temp root
// carrying `source` as src/mini.fun, returning the root. ok=false (skip, never
// false-fail) when the host cannot create the dirs/files — the test standard's
// SKIP-on-IO-refusal so a sandboxed FS never red-fails the determinism floor.
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

// oneshot_write writes one config file under `dir`, returning false on an IO refusal.
@(private = "file")
oneshot_write :: proc(dir: string, name: string, body: string) -> bool {
	path, _ := filepath.join({dir, name}, context.temp_allocator)
	return os.write_entire_file(path, transmute([]u8)body) == nil
}

// oneshot_dispatch_tool resolves the Tool_Spec for `tool_name`, parses `args_json` into
// the MCP arguments object, and folds the assembled Mcp_Dispatch through
// mcp_oneshot_dispatch — the exact path mcp_handle_tools_call drives, so a test exercises
// the real seam (name lookup + arg parse + family arm). Returns the rendered JSON-RPC
// result and whether the family claimed the tool.
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

// test_oneshot_family_claims_exactly_its_tools pins the merge-clean invariant: the family
// claims each of its twelve tools (handled=true) and DECLINES every tool another family
// owns (handled=false), so the chain has exactly one owner per tool name. Claiming is a
// group match — no project tree needed (a claimed tool with a missing dir is still a
// handled IsError result).
@(test)
test_oneshot_family_claims_exactly_its_tools :: proc(t: ^testing.T) {
	for tool in oneshot_family_tools {
		_, handled := oneshot_dispatch_tool(tool, `{}`)
		testing.expect(t, handled, "the one-shot family claims its own tool")
		spec, found := mcp_lookup_tool(tool)
		testing.expect(t, found, "every one-shot tool is a generated Tool_Spec")
		testing.expect_value(t, spec.group, "oneshot")
	}

	// A representative tool from EACH other family is declined — the chain flows past.
	other_family := [?]string{"docs_search", "session_start", "inspect_pipeline", "control_branch", "inspect_screenshot"}
	for other in other_family {
		spec, found := mcp_lookup_tool(other)
		if !found {
			continue // a family not yet in the contract — nothing to decline
		}
		dispatch := Mcp_Dispatch{spec = spec, name = other, id = Mcp_Id{kind = .Integer, integer = 1}}
		_, handled := mcp_oneshot_dispatch(dispatch, context.temp_allocator)
		testing.expect(t, !handled, "the one-shot family declines a tool another family owns")
	}
}

// test_oneshot_missing_dir_is_invalid_input pins the ONLY IsError path: a build call with
// no `dir` is an IsError result keyed invalid_input — a SUCCESSFUL JSON-RPC result
// carrying the failure in-band, never a JSON-RPC error object. This is the boundary that
// separates a genuine schema fault (IsError) from exit-code-as-data (ok:false).
@(test)
test_oneshot_missing_dir_is_invalid_input :: proc(t: ^testing.T) {
	result, handled := oneshot_dispatch_tool("build", `{}`)
	testing.expect(t, handled, "the family claims build even when dir is missing")
	testing.expect(t, strings.contains(result, `"result":`), "the refusal is a JSON-RPC result, not an error object")
	testing.expect(t, !strings.contains(result, `"error":{"code"`), "no JSON-RPC error object for a domain refusal")
	testing.expect(t, strings.contains(result, `"isError":true`), "a missing dir is an IsError result")
	testing.expect(t, strings.contains(result, `\"category\":\"invalid_input\"`), "keyed invalid_input")
}

// test_oneshot_build_clean_tree_ok is the build happy path: stage_build over a minimal
// valid tree yields a clean verdict, rendered as an ok:true (isError:false) result
// carrying the derived index_path. This proves build is wired to the in-process
// stage_build seam (no subprocess) and that a clean build is exit-code-as-data ok:true.
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

// test_oneshot_check_clean_tree_ok pins check as the verdict-only build twin: it adjudicates
// the same minimal tree clean (ok:true) through stage_build with NO write — the same pure
// seam as build, the write deleted.
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

// test_oneshot_export_holed_tree_is_data_refusal is the EXIT-CODE-AS-DATA headline: export
// is build --release, and a §05 typed hole refuses a release build (Holed_Declaration,
// the CLI's exit 2). That refusal is a NORMAL ok:false result (isError:FALSE) carrying the
// closed arm — NOT an IsError. This is the family's crux: a refused build is data the agent
// reads, not a protocol/internal fault.
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

// test_oneshot_test_clean_tree_reports_counts pins test wired to run_project_pipeline: a
// minimal tree with no asserts runs clean (ok:true) and the result carries passed/failed
// counts — the verdict the agent reads. Proves test is the in-process pipeline, no subprocess.
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

// test_oneshot_fmt_canonical_tree_no_drift pins fmt wired to fmt_drift: the minimal source
// is its own canonical form (it round-trips through render_canonical), so fmt reports
// ok:true with an empty drifted list — the verdict-only --check face, no write.
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

// test_oneshot_warden_missing_index_is_data_refusal pins warden's EXIT-CODE-AS-DATA: a
// tree with no emitted `.funpack/index.ndjson` is a Missing_Index refusal (the CLI's exit
// 2 — the warden never recompiles in the reader's place). That refusal is a NORMAL ok:false
// result (isError:FALSE) carrying the missing_index arm and the `funpack build` fix-it —
// NOT an IsError. The minimal tree is never built, so the index is absent by construction.
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

// test_oneshot_reachable_through_tools_call is the REACHABILITY proof. It drives a
// real `tools/call` for `build` through mcp_handle_tools_call (the chain caller, NOT
// the family arm directly), proving the oneshot family is reachable and advertised:
// the result is the family's structured build verdict, NOT the "tool not yet
// implemented" Internal fallthrough stub. The `build` tool is in TOOL_SPECS, so
// mcp_handle_tools_call routes it into this family end to end.
@(test)
test_oneshot_reachable_through_tools_call :: proc(t: ^testing.T) {
	root, ok := oneshot_write_tree("funpack-mcp-oneshot-e2e", ONESHOT_MINI_SOURCE)
	if !ok {
		return
	}
	defer os.remove_all(root)

	// A real tools/call request, parsed exactly as the dispatch loop parses a wire line.
	line := strings.concatenate(
		{`{"jsonrpc":"2.0","id":42,"method":"tools/call","params":{"name":"build","arguments":{"dir":`, oneshot_json_string(root), `}}}`},
		context.temp_allocator,
	)
	request, parsed := mcp_parse_request(line, context.temp_allocator)
	testing.expect(t, parsed, "the tools/call line parses as a request")

	registry := mcp_session_registry_make(context.temp_allocator)
	defer mcp_session_registry_destroy(&registry, context.temp_allocator)
	result := mcp_handle_tools_call(&registry, request, context.temp_allocator)

	// The id echoes back and the result is a JSON-RPC success carrying content.
	testing.expect(t, strings.contains(result, `"id":42`), "the JSON-RPC id echoes back")
	testing.expect(t, strings.contains(result, `"result":`), "tools/call returns a JSON-RPC result")
	// The family OWNS the tool now: the result is the build verdict, NOT the stub.
	testing.expect(t, !strings.contains(result, "tool not yet implemented"), "build is no longer the not-implemented stub")
	testing.expect(t, !strings.contains(result, "unknown tool"), "build is a known tool")
	testing.expect(t, strings.contains(result, `\"tool\":\"build\"`), "the structured build verdict is returned")
	testing.expect(t, strings.contains(result, `\"ok\":true`), "the clean build verdict rode through the real dispatch")
}

// oneshot_dir_args builds an MCP arguments JSON object string carrying only the required
// `dir` selector — the common call shape for every oneshot tool's happy/refusal path.
@(private = "file")
oneshot_dir_args :: proc(dir: string) -> string {
	return strings.concatenate({`{"dir":`, oneshot_json_string(dir), `}`}, context.temp_allocator)
}

// oneshot_json_string renders a string as a JSON string literal (quotes + escapes) so a
// temp path with a backslash or quote embeds cleanly into a test arguments object.
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
