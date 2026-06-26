// The DOCS + HEALTH tool dispatch family — the arm of the tools/call chain
// (mcp_server.odin MCP_DISPATCH_CHAIN) that owns the three in-process documentation
// tools over the embedded corpus (mcp_corpus.odin) and its ranker
// (mcp_docs_search.odin): docs_get (anchor → full section), docs_search (the
// query-shape-blended BM25 + symbol ranker), and health (server liveness + corpus
// drift + the §28 version_report_json surface). This file is ONE dispatch seam — it
// owns ONLY this file's dispatch proc, never mcp_handle_tools_call, so the six
// families stay independent.
//
// THE FOLD: each tool reads its args off the parsed MCP arguments object, runs a PURE
// in-process compute over the compile-time-embedded corpus, and renders a structured
// JSON result into one text content block. No session, no subprocess, no filesystem
// read at call time — the corpus rode in via #load (mcp_corpus.odin), so a docs tool
// is a deterministic function of the binary plus its arguments. A bad argument or an
// unknown anchor is the IsError envelope (mcp_error.odin) keyed .Invalid_Input, never
// a JSON-RPC error object — the model reads the category and self-corrects.
//
// WHY BUILD PER CALL (the one notable cost): a family dispatch arm receives only the
// Mcp_Dispatch — there is no docs-scoped server-init seam the way the session family
// has the registry. So load_corpus / search_engine_build run once PER docs_search
// call, into the per-request allocator the protocol loop resets after the call. This
// is correct (pure, leak-free under the per-request arena) and bounded — the corpus is
// ~700 sections, the build is O(corpus) string work, and a docs query is a
// human-paced, low-frequency operation, not a hot loop. docs_get and health skip the
// ranker entirely (an anchor scan / a manifest read), so only docs_search pays it.
//
// HEALTH IS ONE-BINARY-AWARE: there is no external funpack to resolve — the MCP
// server IS funpack, one binary — so "the compiler version" is the in-process
// funpack_version() and a schema-compat probe is moot (a compiler can never disagree
// with itself). Drift stays a REAL check: the corpus is committed (mcp/corpus/*.json)
// and embedded at build time,
// so a corpus generated against an older funpack then built into a newer binary without
// a regen is a genuine, detectable skew — manifest.funpack_version vs funpack_version().
package main

import "../../funpack"
import funpack_runtime "../../runtime"
import "core:encoding/json"
import "core:strings"

// DOCS_SEARCH_DEFAULT_LIMIT is the hit cap applied when a caller omits `limit` (or
// passes <= 0): a screenful of ranked hits, enough to choose from without flooding
// the model's context (mirroring docs_search.go docsSearchDefaultLimit).
DOCS_SEARCH_DEFAULT_LIMIT :: 10

// DOCS_SEARCH_MAX_LIMIT caps an explicit `limit` so one call cannot drain the whole
// ranked candidate pool into a single response (docs_search.go docsSearchMaxLimit).
DOCS_SEARCH_MAX_LIMIT :: 50

// docs_family_tools is this family's tool roster — the three tools
// mcp_docs_tool_dispatch claims. Kept as a package-level table the family's tests walk
// (assert each is in TOOL_SPECS, assert the dispatch claims it, assert no other
// family's tool is claimed), so the roster has one source the dispatch and the tests
// share — the same merge-clean invariant the control family pins.
docs_family_tools := [?]string {
	"docs_get",
	"docs_search",
	"health",
}

// mcp_docs_tool_dispatch is the docs + health family's arm. It CLAIMS its three tools
// (handled=true, returning the rendered JSON-RPC result) and DECLINES every tool
// another family owns (handled=false) so the call flows on down the chain (the stub
// contract every family keeps). At most one family claims any tool name, so the chain
// order is immaterial to correctness.
mcp_docs_tool_dispatch :: proc(dispatch: Mcp_Dispatch, allocator := context.allocator) -> (result: string, handled: bool) {
	switch dispatch.name {
	case "docs_get":
		return docs_dispatch_get(dispatch, allocator), true
	case "docs_search":
		return docs_dispatch_search(dispatch, allocator), true
	case "health":
		return docs_dispatch_health(dispatch, allocator), true
	case:
		// Not one of this family's tools — decline so the next arm in the chain tries.
		return "", false
	}
}

// docs_dispatch_get resolves docs_get: a single required `anchor` arg selects one
// section in the embedded corpus, returning its full {anchor,title,kind,text} so the
// caller renders the passage without a second lookup (docs_get.go). A missing/non-string
// anchor is Invalid_Input; an anchor that matches no section is Invalid_Input "unknown
// anchor" (the corpus is the closed set, so an unknown anchor is a caller error, not an
// engine fault) — both ride the IsError envelope, never a JSON-RPC error object.
docs_dispatch_get :: proc(dispatch: Mcp_Dispatch, allocator := context.allocator) -> string {
	anchor, has_anchor := funpack_runtime.json_string_field(dispatch.arguments, "anchor")
	if !has_anchor {
		return mcp_render_tool_result(
			dispatch.id,
			mcp_tool_error_result(mcp_missing_string_field("anchor", dispatch.name, allocator), allocator),
			allocator,
		)
	}

	sections, ok := load_corpus(allocator)
	if !ok {
		// The shards are committed and the pin test guards them, so a parse failure here
		// is a build defect, not a caller error — keyed .Internal so the model does not
		// retry with a different argument.
		return mcp_render_tool_result(
			dispatch.id,
			mcp_tool_error_result(
				Mcp_Error{category = .Internal, message = "embedded docs corpus failed to parse"},
				allocator,
			),
			allocator,
		)
	}

	// Resolve the on-disk projection root so the resolved section carries a `path` deep-link
	// the agent can Read/Grep directly (the server materialized this tree at startup). A
	// missing managed home yields an empty root and the `path` field is simply omitted.
	manifest, _ := load_manifest(allocator)
	docs_root, _ := docs_export_root(manifest, allocator)

	for section in sections {
		if section.anchor == anchor {
			return mcp_render_tool_result(dispatch.id, docs_get_result(section, docs_root, allocator), allocator)
		}
	}

	return mcp_render_tool_result(
		dispatch.id,
		mcp_tool_error_result(
			Mcp_Error{category = .Invalid_Input, message = "unknown anchor", detail = anchor},
			allocator,
		),
		allocator,
	)
}

// docs_get_result renders one resolved section as the docs_get success result: a single
// text content block holding {anchor,title,kind,text,path?} JSON. `path` (the on-disk
// deep-link into the materialized projection, docs_root + section.source) is present only
// when docs_root resolved — a client without a managed home still gets the full inline
// section. The key set is the docs_get output contract a client reads. Built with the
// byte-stable write_json_string idiom the §28 renderers use.
docs_get_result :: proc(section: Corpus_Section, docs_root: string, allocator := context.allocator) -> Mcp_Tool_Result {
	b := strings.builder_make(allocator)
	strings.write_string(&b, "{\"anchor\":")
	funpack_runtime.write_json_string(&b, section.anchor)
	strings.write_string(&b, ",\"title\":")
	funpack_runtime.write_json_string(&b, section.title)
	strings.write_string(&b, ",\"kind\":")
	funpack_runtime.write_json_string(&b, section.kind)
	strings.write_string(&b, ",\"text\":")
	funpack_runtime.write_json_string(&b, section.text)
	docs_write_path(&b, docs_root, section.source, allocator)
	strings.write_byte(&b, '}')

	content := make([]Mcp_Content, 1, allocator)
	content[0] = mcp_text_content(strings.to_string(b))
	return Mcp_Tool_Result{content = content, is_error = false}
}

// docs_write_path appends the optional `path` field — the on-disk deep-link into the
// materialized projection (docs_root joined with the section's corpus-relative source) —
// to a docs result object. It is OMITTED when docs_root is empty (no managed home, the
// server could not materialize) or the source is unknown, so a client without an on-disk
// tree never receives a dangling path. The agent Reads this file and greps the section's
// anchor marker ("<!-- anchor: <id>") to land on the passage.
docs_write_path :: proc(b: ^strings.Builder, docs_root, source: string, allocator := context.allocator) {
	if docs_root == "" || source == "" {
		return
	}
	strings.write_string(b, ",\"path\":")
	funpack_runtime.write_json_string(b, corpus_join({docs_root, source}, allocator))
}

// docs_dispatch_search resolves docs_search: a required `query` and an optional `limit`
// drive the query-shape ranker (search_engine_search) over the embedded corpus,
// returning the ranked hits plus the corpus version and the corpus-vs-binary drift so a
// stale corpus is loud on every search. An empty query is Invalid_Input. The limit is
// clamped to [1, DOCS_SEARCH_MAX_LIMIT], defaulting to DOCS_SEARCH_DEFAULT_LIMIT when
// omitted or <= 0.
docs_dispatch_search :: proc(dispatch: Mcp_Dispatch, allocator := context.allocator) -> string {
	query, has_query := funpack_runtime.json_string_field(dispatch.arguments, "query")
	if !has_query || strings.trim_space(query) == "" {
		return mcp_render_tool_result(
			dispatch.id,
			mcp_tool_error_result(
				Mcp_Error{category = .Invalid_Input, message = "query must not be empty"},
				allocator,
			),
			allocator,
		)
	}

	limit := docs_arg_int(dispatch.arguments, "limit", 0)
	if limit <= 0 {
		limit = DOCS_SEARCH_DEFAULT_LIMIT
	}
	if limit > DOCS_SEARCH_MAX_LIMIT {
		limit = DOCS_SEARCH_MAX_LIMIT
	}

	sections, ok := load_corpus(allocator)
	if !ok {
		return mcp_render_tool_result(
			dispatch.id,
			mcp_tool_error_result(
				Mcp_Error{category = .Internal, message = "embedded docs corpus failed to parse"},
				allocator,
			),
			allocator,
		)
	}
	manifest, _ := load_manifest(allocator) // a missing manifest yields a zeroed drift, never a failure
	docs_root, _ := docs_export_root(manifest, allocator) // empty when no managed home — `path` is then omitted

	engine := search_engine_build(sections, allocator)
	hits := search_engine_search(&engine, query, limit, allocator)

	return mcp_render_tool_result(dispatch.id, docs_search_result(hits, manifest, sections, docs_root, allocator), allocator)
}

// docs_search_result renders the ranked hits plus provenance as the docs_search success
// result: one text content block holding {hits:[…],corpus_version,corpus_drift}. Each
// hit carries {anchor,title,kind,score,snippet,source,path?} — anchor re-feeds docs_get,
// source tags which ranker produced it, and `path` (present when docs_root resolved) is
// the on-disk deep-link into the materialized projection. `sections` supplies the
// anchor→file-source map the `path` needs (the ranker hit carries the corpus anchor, not
// the source file). This key set is the docs_search output contract a client reads.
docs_search_result :: proc(
	hits: []Search_Result,
	manifest: Corpus_Manifest,
	sections: []Corpus_Section,
	docs_root: string,
	allocator := context.allocator,
) -> Mcp_Tool_Result {
	src_by_anchor := make(map[string]string, len(sections), allocator)
	for s in sections {
		src_by_anchor[s.anchor] = s.source
	}

	b := strings.builder_make(allocator)
	strings.write_string(&b, "{\"hits\":[")
	for hit, i in hits {
		if i > 0 {
			strings.write_byte(&b, ',')
		}
		docs_write_hit(&b, hit, docs_root, src_by_anchor[hit.anchor], allocator)
	}
	strings.write_string(&b, "],\"corpus_version\":")
	funpack_runtime.write_json_string(&b, docs_corpus_version(manifest, allocator))
	strings.write_string(&b, ",\"corpus_drift\":")
	docs_write_drift(&b, docs_detect_drift(manifest, allocator))
	strings.write_byte(&b, '}')

	content := make([]Mcp_Content, 1, allocator)
	content[0] = mcp_text_content(strings.to_string(b))
	return Mcp_Tool_Result{content = content, is_error = false}
}

// docs_write_hit renders one Search_Result as the MCP hit object:
// {anchor,title,kind,score,snippet,source,path?}. The score is the blended relative rank
// key, only comparable within this response; source is the lowercase ranker label; `path`
// (the on-disk deep-link, docs_root + the hit's file source) is appended only when both
// resolve, so a host without a materialized tree gets the same hit minus `path`.
docs_write_hit :: proc(b: ^strings.Builder, hit: Search_Result, docs_root, source: string, allocator := context.allocator) {
	strings.write_string(b, "{\"anchor\":")
	funpack_runtime.write_json_string(b, hit.anchor)
	strings.write_string(b, ",\"title\":")
	funpack_runtime.write_json_string(b, hit.title)
	strings.write_string(b, ",\"kind\":")
	funpack_runtime.write_json_string(b, hit.kind)
	strings.write_string(b, ",\"score\":")
	strings.write_f64(b, hit.score, 'g')
	strings.write_string(b, ",\"snippet\":")
	funpack_runtime.write_json_string(b, hit.snippet)
	strings.write_string(b, ",\"source\":")
	funpack_runtime.write_json_string(b, search_source_label(hit.source))
	docs_write_path(b, docs_root, source, allocator)
	strings.write_byte(b, '}')
}

// docs_dispatch_health resolves health: a no-argument liveness probe that reports server
// identity, the §28 version surface, and the corpus-vs-binary drift, so a stale corpus
// is visible before the agent trusts a docs result. A schema-compat surface is OMITTED
// by design — there is no external funpack to disagree with the in-process schema
// constants (one binary), so a compat probe would always be trivially compatible. The
// version block is version_report_json verbatim (the contract's {version,schemas}
// shape), embedded as the `version` field so health doubles as the machine version
// surface.
docs_dispatch_health :: proc(dispatch: Mcp_Dispatch, allocator := context.allocator) -> string {
	manifest, _ := load_manifest(allocator)
	drift := docs_detect_drift(manifest, allocator)

	b := strings.builder_make(allocator)
	strings.write_string(&b, "{\"status\":\"ok\",\"server\":")
	funpack_runtime.write_json_string(&b, MCP_SERVER_NAME)
	strings.write_string(&b, ",\"version\":")
	// version_report_json already emits a JSON object ({version,schemas}); embed it as a
	// nested object so health carries the full §28 version surface, not just a string.
	strings.write_string(&b, funpack.version_report_json(allocator))
	strings.write_string(&b, ",\"corpus_drift\":")
	docs_write_drift(&b, drift)
	strings.write_byte(&b, '}')

	content := make([]Mcp_Content, 1, allocator)
	content[0] = mcp_text_content(strings.to_string(b))
	result := Mcp_Tool_Result{content = content, is_error = false}
	return mcp_render_tool_result(dispatch.id, result, allocator)
}

// Docs_Corpus_Drift reports a version skew between the embedded docs corpus and the
// funpack binary it shipped inside. drift=true means the corpus was generated against
// a DIFFERENT funpack version than the binary now serving it, so any surface change
// since corpus_version is invisible to docs_search — the silent lag this makes loud.
// compiler_version is always the in-process funpack_version() (there is no external
// compiler to resolve), so the comparison always has both sides — there is no "no
// compiler resolved" arm.
Docs_Corpus_Drift :: struct {
	drift:            bool,
	corpus_version:   string,
	compiler_version: string,
	warning:          string,
}

// docs_detect_drift compares the manifest's funpack version against the in-process
// funpack_version() and builds a Docs_Corpus_Drift. Both strings are normalized (the
// `funpack ` prefix the manifest stamp may carry is stripped) before the equality test,
// so "funpack 0.6.1" and "0.6.1" compare on the same bare-semver footing
// (docs_normalize_version). A manifest with an empty funpack_version (no manifest, or
// a malformed one) reports no drift — there is nothing to compare.
docs_detect_drift :: proc(manifest: Corpus_Manifest, allocator := context.allocator) -> Docs_Corpus_Drift {
	corpus_version := docs_normalize_version(manifest.funpack_version)
	compiler_version := docs_normalize_version(funpack.funpack_version())

	if corpus_version == "" || corpus_version == compiler_version {
		return Docs_Corpus_Drift{drift = false, corpus_version = corpus_version, compiler_version = compiler_version}
	}

	warning := strings.concatenate(
		{
			"docs corpus is funpack ",
			corpus_version,
			" but this binary is funpack ",
			compiler_version,
			" — docs_search may describe an older toolchain than the one that compiles; regenerate the corpus (funpack mcp gen-corpus) and rebuild",
		},
		allocator,
	)
	return Docs_Corpus_Drift{
		drift            = true,
		corpus_version   = corpus_version,
		compiler_version = compiler_version,
		warning          = warning,
	}
}

// docs_write_drift renders a Docs_Corpus_Drift as the MCP corpus_drift object:
// {drift,corpus_version,compiler_version,warning}. The version fields and warning are
// omitted when empty (the omitempty convention), so a no-drift probe carries the
// minimal {drift:false,…} shape.
docs_write_drift :: proc(b: ^strings.Builder, drift: Docs_Corpus_Drift) {
	strings.write_string(b, "{\"drift\":")
	strings.write_string(b, drift.drift ? "true" : "false")
	if drift.corpus_version != "" {
		strings.write_string(b, ",\"corpus_version\":")
		funpack_runtime.write_json_string(b, drift.corpus_version)
	}
	if drift.compiler_version != "" {
		strings.write_string(b, ",\"compiler_version\":")
		funpack_runtime.write_json_string(b, drift.compiler_version)
	}
	if drift.warning != "" {
		strings.write_string(b, ",\"warning\":")
		funpack_runtime.write_json_string(b, drift.warning)
	}
	strings.write_byte(b, '}')
}

// docs_corpus_version stamps a single human-readable version string from the manifest:
// the spec ref the prose/engine sources were read at, joined with the funpack version
// the plugin sources came from (docs_search.go corpusVersion). Both halves are
// content-derived (no timestamp, no path), so the stamp is stable across a regen of
// unchanged sources. A zero manifest yields "spec  / " — harmless, and only seen when no
// manifest embedded (a build the pin test would already have failed).
docs_corpus_version :: proc(manifest: Corpus_Manifest, allocator := context.allocator) -> string {
	return strings.concatenate({"spec ", manifest.spec_ref, " / ", manifest.funpack_version}, allocator)
}

// docs_normalize_version strips a leading `funpack ` prefix and surrounding whitespace
// so a manifest stamp ("funpack 0.6.1") and the in-process funpack_version() ("0.6.1")
// compare on the same bare-semver footing.
docs_normalize_version :: proc(s: string) -> string {
	trimmed := strings.trim_space(s)
	trimmed = strings.trim_prefix(trimmed, "funpack ")
	return strings.trim_space(trimmed)
}

// docs_arg_int reads an optional integer arg off the MCP arguments object (the `limit`
// cap), returning `fallback` when the field is absent or not an integer. Reads through
// the one shared int reader (funpack_runtime.json_int_field), so `limit:42` and the
// integral `limit:42.0` are both honored — one int policy across every MCP int arg; a
// fractional or non-numeric `limit` is out of contract and falls back.
docs_arg_int :: proc(arguments: json.Object, key: string, fallback: int) -> int {
	value, has := funpack_runtime.json_int_field(arguments, key)
	if !has {
		return fallback
	}
	return int(value)
}

// docs_assert_specs_present confirms every docs_family_tools entry resolves to a real
// generated Tool_Spec (the name→spec projection guard the family test walks): if a tool
// name here is not in TOOL_SPECS, the dispatch claims a tool tools/list never
// advertised. Kept tiny and pure so it is a test helper, not a runtime path.
docs_assert_specs_present :: proc() -> bool {
	for tool in docs_family_tools {
		_, found := mcp_lookup_tool(tool)
		if !found {
			return false
		}
	}
	return true
}
