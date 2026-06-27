package main

import "../../funpack"
import "core:encoding/json"
import "core:strings"
import "core:testing"

@(private = "file")
docs_dispatch_tool :: proc(tool_name: string, args_json: string) -> (result: string, handled: bool) {
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
		id        = Mcp_Id{kind = .Integer, integer = 9},
	}
	return mcp_docs_tool_dispatch(dispatch, context.temp_allocator)
}

@(private = "file")
docs_first_anchor :: proc() -> (anchor: string, ok: bool) {
	sections, loaded := load_corpus(context.temp_allocator)
	if !loaded || len(sections) == 0 {
		return "", false
	}
	return sections[0].anchor, true
}

@(test)
test_docs_family_claims_exactly_its_tools :: proc(t: ^testing.T) {
	testing.expect(t, docs_assert_specs_present(), "every docs family tool is a generated Tool_Spec")

	for tool in docs_family_tools {
		_, handled := docs_dispatch_tool(tool, `{}`)
		testing.expect(t, handled, "the docs family claims its own tool")
	}

	other_family := [?]string{"build", "session_start", "control_branch", "time_status", "inspect_screenshot"}
	for other in other_family {
		spec, found := mcp_lookup_tool(other)
		if !found {
			continue
		}
		dispatch := Mcp_Dispatch{spec = spec, name = other, id = Mcp_Id{kind = .Integer, integer = 1}}
		_, handled := mcp_docs_tool_dispatch(dispatch, context.temp_allocator)
		testing.expect(t, !handled, "the docs family declines a tool another family owns")
	}
}

@(test)
test_docs_tools_reachable_through_protocol :: proc(t: ^testing.T) {
	registry := mcp_session_registry_make(context.temp_allocator)
	defer mcp_session_registry_destroy(&registry, context.temp_allocator)

	calls := [?]struct {
		name: string,
		line: string,
	} {
		{"health", `{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"health","arguments":{}}}`},
		{"docs_search", `{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"docs_search","arguments":{"query":"world"}}}`},
	}
	for call in calls {
		response, keep_open := mcp_dispatch_line(&registry, call.line, context.temp_allocator)
		testing.expect(t, keep_open, "the stdio session stays open after a docs tools/call")
		testing.expect(t, strings.contains(response, `"result":`), "a docs tools/call returns a JSON-RPC result")
		testing.expect(t, !strings.contains(response, "tool not yet implemented"), "the tool is no longer the not-implemented stub")
		testing.expect(t, !strings.contains(response, "unknown tool"), "the tool is in TOOL_SPECS (no unknown-tool refusal)")
		testing.expect(t, strings.contains(response, `"isError":false`), "a well-formed docs call succeeds")
	}
}

@(test)
test_docs_get_resolves_known_anchor :: proc(t: ^testing.T) {
	anchor, ok := docs_first_anchor()
	if !ok {
		return
	}

	args := strings.concatenate({`{"anchor":`, docs_quote(anchor), `}`}, context.temp_allocator)
	result, handled := docs_dispatch_tool("docs_get", args)
	testing.expect(t, handled, "docs_get is claimed")
	testing.expect(t, strings.contains(result, `"isError":false`), "a known anchor is a clean result")
	testing.expect(t, strings.contains(result, `\"anchor\":`), "the resolved section echoes its anchor")
	testing.expect(t, strings.contains(result, `\"text\":`), "the full section body is returned")
}

@(test)
test_docs_get_unknown_anchor_is_invalid_input :: proc(t: ^testing.T) {
	result, handled := docs_dispatch_tool("docs_get", `{"anchor":"no/such#anchor-xyzzy"}`)
	testing.expect(t, handled, "docs_get is claimed even on a miss")
	testing.expect(t, strings.contains(result, `"result":`), "the refusal is a JSON-RPC result, not an error object")
	testing.expect(t, !strings.contains(result, `"error":{"code"`), "no JSON-RPC error object for a domain refusal")
	testing.expect(t, strings.contains(result, `"isError":true`), "an unknown anchor is an IsError result")
	testing.expect(t, strings.contains(result, `\"category\":\"invalid_input\"`), "keyed invalid_input")
}

@(test)
test_docs_get_missing_anchor_is_invalid_input :: proc(t: ^testing.T) {
	result, handled := docs_dispatch_tool("docs_get", `{}`)
	testing.expect(t, handled, "docs_get is claimed even with no anchor")
	testing.expect(t, strings.contains(result, `"isError":true`), "a missing anchor is an IsError result")
	testing.expect(t, strings.contains(result, `\"category\":\"invalid_input\"`), "keyed invalid_input")
}

@(test)
test_docs_search_ranks_and_stamps :: proc(t: ^testing.T) {
	result, handled := docs_dispatch_tool("docs_search", `{"query":"world","limit":5}`)
	testing.expect(t, handled, "docs_search is claimed")
	testing.expect(t, strings.contains(result, `"isError":false`), "a non-empty query is a clean result")
	testing.expect(t, strings.contains(result, `\"hits\":[`), "the result carries a hits array")
	testing.expect(t, strings.contains(result, `\"corpus_version\":`), "the corpus version stamps the result")
	testing.expect(t, strings.contains(result, `\"corpus_drift\":`), "the corpus drift rides every search")
}

@(test)
test_docs_search_empty_query_is_invalid_input :: proc(t: ^testing.T) {
	result, handled := docs_dispatch_tool("docs_search", `{"query":"   "}`)
	testing.expect(t, handled, "docs_search is claimed even on an empty query")
	testing.expect(t, strings.contains(result, `"isError":true`), "an empty query is an IsError result")
	testing.expect(t, strings.contains(result, `\"category\":\"invalid_input\"`), "keyed invalid_input")
}

@(test)
test_docs_search_limit_clamps :: proc(t: ^testing.T) {
	result, handled := docs_dispatch_tool("docs_search", `{"query":"world","limit":9999}`)
	testing.expect(t, handled, "docs_search is claimed")
	testing.expect(t, strings.contains(result, `"isError":false`), "an over-cap limit still succeeds")
	hit_count := strings.count(result, `\"source\":`)
	testing.expect(t, hit_count <= DOCS_SEARCH_MAX_LIMIT, "the hit count never exceeds the max limit")
}

@(test)
test_docs_health_reports_status_and_version :: proc(t: ^testing.T) {
	result, handled := docs_dispatch_tool("health", `{}`)
	testing.expect(t, handled, "health is claimed")
	testing.expect(t, strings.contains(result, `"isError":false`), "health is always a clean probe")
	testing.expect(t, strings.contains(result, `\"status\":\"ok\"`), "health reports ok liveness")
	testing.expect(t, strings.contains(result, `\"server\":\"funpack-mcp\"`), "health reports the server name")
	testing.expect(t, strings.contains(result, `\"schemas\":`), "health embeds the §28 version surface (version_report_json)")
	testing.expect(t, strings.contains(result, `\"corpus_drift\":`), "health reports corpus drift")
}

@(test)
test_docs_health_current_build_has_no_drift :: proc(t: ^testing.T) {
	manifest, ok := load_manifest(context.temp_allocator)
	if !ok {
		return
	}
	drift := docs_detect_drift(manifest, context.temp_allocator)
	corpus_version := docs_normalize_version(manifest.funpack_version)
	binary_version := docs_normalize_version(funpack.funpack_version())
	if corpus_version != "" {
		testing.expect_value(t, drift.drift, corpus_version != binary_version)
	}
}

@(test)
test_docs_detect_drift_flags_version_skew :: proc(t: ^testing.T) {
	binary_version := docs_normalize_version(funpack.funpack_version())

	skewed := docs_detect_drift(Corpus_Manifest{funpack_version = "0.0.0-not-this-binary"}, context.temp_allocator)
	testing.expect(t, skewed.drift, "a divergent corpus version is drift")
	testing.expect(t, skewed.warning != "", "drift carries a human-readable warning")
	testing.expect_value(t, skewed.compiler_version, binary_version)

	matched := docs_detect_drift(Corpus_Manifest{funpack_version = binary_version}, context.temp_allocator)
	testing.expect(t, !matched.drift, "a matching corpus version is no drift")

	empty := docs_detect_drift(Corpus_Manifest{}, context.temp_allocator)
	testing.expect(t, !empty.drift, "an empty corpus version is no drift (nothing to compare)")
}

@(private = "file")
docs_quote :: proc(s: string) -> string {
	return strings.concatenate({`"`, s, `"`}, context.temp_allocator)
}
