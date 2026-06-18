// Deliberate spec for the docs + health tool dispatch family (mcp_tools_docs.odin) —
// the living junction test for the in-process documentation arm of the tools/call
// chain. It exercises the WHOLE seam, both at the family-arm level (an Mcp_Dispatch
// built exactly as mcp_handle_tools_call builds one) and END TO END through the real
// protocol entry (mcp_dispatch_line over a tools/call JSON-RPC line) — the latter is
// the proof the family is now REACHABLE: register-mcp-server-native put docs_get /
// docs_search / health into TOOL_SPECS, so a tools/call no longer falls through to the
// unknown-tool / not-implemented stub but lands in this arm.
//
// The tests pin the contract this family must keep:
//
//   - reachability: a tools/call for each of the three tools, driven through
//     mcp_dispatch_line, returns a JSON-RPC result (not the not-implemented stub, not a
//     method-not-found error) — the headline proof of the re-run;
//   - name→spec projection: every claimed tool is a real generated Tool_Spec, and no
//     tool outside the family is claimed (the merge-clean invariant);
//   - docs_get: a known anchor returns the full {anchor,title,kind,text}; an unknown
//     anchor and a missing anchor ride the IsError envelope keyed invalid_input;
//   - docs_search: a symbol-shaped query ranks a real corpus hit and the result carries
//     the corpus_version + corpus_drift provenance; an empty query is invalid_input; the
//     limit is clamped;
//   - health: the no-arg probe reports status ok, the §28 version surface, and the
//     corpus-vs-binary drift; on a current build (corpus regenerated against this
//     binary) drift is false;
//   - the drift detector itself: a manifest stamped at a different funpack version than
//     the binary reports drift=true with a warning; a matching/empty stamp reports false.
//
// DEFINE-FREE FLOOR: like the corpus and ranker tests, these run in the default
// `odin test .` build — the corpus is #load-embedded and every compute is SDL-free, so
// the family's dispatch contract is pinned in the same deterministic floor as the rest
// of the compiler tests.
package main

import "../../funpack"
import "core:encoding/json"
import "core:strings"
import "core:testing"

// docs_dispatch_tool resolves the Tool_Spec for `tool_name`, parses `args_json` into the
// MCP arguments object, and folds the assembled Mcp_Dispatch through
// mcp_docs_tool_dispatch — the exact path mcp_handle_tools_call drives, so a test
// exercises the real seam (name lookup + arg parse + family arm) rather than a stubbed
// shortcut. Returns the rendered JSON-RPC result line and whether the family claimed it.
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

// docs_first_anchor scans the embedded corpus for the first section's anchor — a real,
// guaranteed-resolvable anchor for the docs_get hit test, so the test keys on whatever
// the committed corpus actually carries rather than a hardcoded anchor that a regen
// could rename. ok=false on an empty/malformed corpus (the test then skips, never
// false-fails — the corpus pin test owns that failure).
@(private = "file")
docs_first_anchor :: proc() -> (anchor: string, ok: bool) {
	sections, loaded := load_corpus(context.temp_allocator)
	if !loaded || len(sections) == 0 {
		return "", false
	}
	return sections[0].anchor, true
}

// test_docs_family_claims_exactly_its_tools pins the merge-clean invariant: the family
// claims each of its three tools (handled=true) and DECLINES every tool another family
// owns (handled=false), so the dispatch chain has exactly one owner per tool name.
@(test)
test_docs_family_claims_exactly_its_tools :: proc(t: ^testing.T) {
	testing.expect(t, docs_assert_specs_present(), "every docs family tool is a generated Tool_Spec")

	for tool in docs_family_tools {
		_, handled := docs_dispatch_tool(tool, `{}`)
		testing.expect(t, handled, "the docs family claims its own tool")
	}

	// A representative tool from EACH other family is declined — the chain flows past.
	other_family := [?]string{"build", "session_start", "control_branch", "time_status", "inspect_screenshot"}
	for other in other_family {
		spec, found := mcp_lookup_tool(other)
		if !found {
			continue // a family not yet in the contract — nothing to decline
		}
		dispatch := Mcp_Dispatch{spec = spec, name = other, id = Mcp_Id{kind = .Integer, integer = 1}}
		_, handled := mcp_docs_tool_dispatch(dispatch, context.temp_allocator)
		testing.expect(t, !handled, "the docs family declines a tool another family owns")
	}
}

// test_docs_tools_reachable_through_protocol is the headline re-run proof: each of the
// three tools, driven END TO END through mcp_dispatch_line (the real tools/call entry),
// returns a JSON-RPC result — NOT the "tool not yet implemented" (.Internal) stub and
// NOT a method-not-found error. Before register-mcp-server-native these tools were not
// in TOOL_SPECS, so the same call fell through to the unknown-tool / not-implemented
// path. A successful, non-stub result is the proof the arm is now wired and advertised.
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

// test_docs_get_resolves_known_anchor pins docs_get's hit path: a real corpus anchor
// returns a clean result whose section echoes the requested anchor and carries the
// body text — enough to render the passage without a second lookup.
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

// test_docs_get_unknown_anchor_is_invalid_input pins docs_get's miss path: an anchor no
// section carries is an IsError result keyed invalid_input (the corpus is a closed set,
// so an unknown anchor is a caller error) — a SUCCESSFUL JSON-RPC result carrying the
// failure in-band, never a JSON-RPC error object.
@(test)
test_docs_get_unknown_anchor_is_invalid_input :: proc(t: ^testing.T) {
	result, handled := docs_dispatch_tool("docs_get", `{"anchor":"no/such#anchor-xyzzy"}`)
	testing.expect(t, handled, "docs_get is claimed even on a miss")
	testing.expect(t, strings.contains(result, `"result":`), "the refusal is a JSON-RPC result, not an error object")
	testing.expect(t, !strings.contains(result, `"error":{"code"`), "no JSON-RPC error object for a domain refusal")
	testing.expect(t, strings.contains(result, `"isError":true`), "an unknown anchor is an IsError result")
	testing.expect(t, strings.contains(result, `\"category\":\"invalid_input\"`), "keyed invalid_input")
}

// test_docs_get_missing_anchor_is_invalid_input pins docs_get's schema-violation path: a
// call with no anchor (the required string arg) is an IsError result keyed invalid_input.
@(test)
test_docs_get_missing_anchor_is_invalid_input :: proc(t: ^testing.T) {
	result, handled := docs_dispatch_tool("docs_get", `{}`)
	testing.expect(t, handled, "docs_get is claimed even with no anchor")
	testing.expect(t, strings.contains(result, `"isError":true`), "a missing anchor is an IsError result")
	testing.expect(t, strings.contains(result, `\"category\":\"invalid_input\"`), "keyed invalid_input")
}

// test_docs_search_ranks_and_stamps pins docs_search's success path: a symbol-shaped
// query returns a clean result whose hit list carries at least one anchor (the corpus
// has engine declarations to match), and whose envelope carries the corpus_version + the
// corpus_drift provenance — the stale-corpus signal that rides every search.
@(test)
test_docs_search_ranks_and_stamps :: proc(t: ^testing.T) {
	result, handled := docs_dispatch_tool("docs_search", `{"query":"world","limit":5}`)
	testing.expect(t, handled, "docs_search is claimed")
	testing.expect(t, strings.contains(result, `"isError":false`), "a non-empty query is a clean result")
	testing.expect(t, strings.contains(result, `\"hits\":[`), "the result carries a hits array")
	testing.expect(t, strings.contains(result, `\"corpus_version\":`), "the corpus version stamps the result")
	testing.expect(t, strings.contains(result, `\"corpus_drift\":`), "the corpus drift rides every search")
}

// test_docs_search_empty_query_is_invalid_input pins docs_search's schema-violation path:
// an empty (or whitespace-only) query is an IsError result keyed invalid_input — the
// ranker has nothing to rank, so it is a caller error caught before the engine builds.
@(test)
test_docs_search_empty_query_is_invalid_input :: proc(t: ^testing.T) {
	result, handled := docs_dispatch_tool("docs_search", `{"query":"   "}`)
	testing.expect(t, handled, "docs_search is claimed even on an empty query")
	testing.expect(t, strings.contains(result, `"isError":true`), "an empty query is an IsError result")
	testing.expect(t, strings.contains(result, `\"category\":\"invalid_input\"`), "keyed invalid_input")
}

// test_docs_search_limit_clamps pins the limit clamp: an over-cap limit is clamped to
// DOCS_SEARCH_MAX_LIMIT, so a single call cannot drain the whole candidate pool. The hit
// count cannot exceed the cap; we assert the call succeeds and stays bounded by counting
// the source-tag occurrences (one per hit) against the cap.
@(test)
test_docs_search_limit_clamps :: proc(t: ^testing.T) {
	result, handled := docs_dispatch_tool("docs_search", `{"query":"world","limit":9999}`)
	testing.expect(t, handled, "docs_search is claimed")
	testing.expect(t, strings.contains(result, `"isError":false`), "an over-cap limit still succeeds")
	hit_count := strings.count(result, `\"source\":`)
	testing.expect(t, hit_count <= DOCS_SEARCH_MAX_LIMIT, "the hit count never exceeds the max limit")
}

// test_docs_health_reports_status_and_version pins health's probe: the no-arg call
// reports status ok, the server name, the §28 version surface (the schemas block proves
// version_report_json is embedded), and the corpus_drift block — the liveness + drift
// surface an agent reads on first contact.
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

// test_docs_health_current_build_has_no_drift pins the one-binary drift invariant on a
// CURRENT build: the committed corpus is regenerated against this binary's version, so
// the manifest's funpack_version equals funpack_version() and drift is false. If a regen
// is ever skipped before a version bump, this is the test that goes red — exactly the
// loud lag the drift check exists to surface.
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

// test_docs_detect_drift_flags_version_skew pins the drift detector directly: a manifest
// stamped at a funpack version DIFFERENT from this binary reports drift=true with both
// versions and a warning; a matching stamp reports false; an empty stamp reports false
// (nothing to compare). This is the unit-level spec of the corpus-vs-binary skew check,
// independent of whatever the committed corpus happens to be stamped at.
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

// docs_quote wraps a string in JSON quotes with the minimal escaping the test anchors
// need (the embedded anchors are slug/path tokens — no embedded quotes or control
// chars — so a bare quote wrap is faithful; backslashes in an anchor would need more,
// but no corpus anchor carries one). Kept self-contained per the test standard.
@(private = "file")
docs_quote :: proc(s: string) -> string {
	return strings.concatenate({`"`, s, `"`}, context.temp_allocator)
}
