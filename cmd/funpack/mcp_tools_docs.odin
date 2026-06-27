package main

import "../../funpack"
import funpack_runtime "../../runtime"
import "core:encoding/json"
import "core:strings"

DOCS_SEARCH_DEFAULT_LIMIT :: 10

DOCS_SEARCH_MAX_LIMIT :: 50

docs_family_tools := [?]string {
	"docs_get",
	"docs_search",
	"health",
}

mcp_docs_tool_dispatch :: proc(dispatch: Mcp_Dispatch, allocator := context.allocator) -> (result: string, handled: bool) {
	switch dispatch.name {
	case "docs_get":
		return docs_dispatch_get(dispatch, allocator), true
	case "docs_search":
		return docs_dispatch_search(dispatch, allocator), true
	case "health":
		return docs_dispatch_health(dispatch, allocator), true
	case:
		return "", false
	}
}

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
		return mcp_render_tool_result(
			dispatch.id,
			mcp_tool_error_result(
				Mcp_Error{category = .Internal, message = "embedded docs corpus failed to parse"},
				allocator,
			),
			allocator,
		)
	}

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

docs_write_path :: proc(b: ^strings.Builder, docs_root, source: string, allocator := context.allocator) {
	if docs_root == "" || source == "" {
		return
	}
	strings.write_string(b, ",\"path\":")
	funpack_runtime.write_json_string(b, corpus_join({docs_root, source}, allocator))
}

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
	manifest, _ := load_manifest(allocator)
	docs_root, _ := docs_export_root(manifest, allocator)

	engine := search_engine_build(sections, allocator)
	hits := search_engine_search(&engine, query, limit, allocator)

	return mcp_render_tool_result(dispatch.id, docs_search_result(hits, manifest, sections, docs_root, allocator), allocator)
}

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

docs_dispatch_health :: proc(dispatch: Mcp_Dispatch, allocator := context.allocator) -> string {
	manifest, _ := load_manifest(allocator)
	drift := docs_detect_drift(manifest, allocator)

	b := strings.builder_make(allocator)
	strings.write_string(&b, "{\"status\":\"ok\",\"server\":")
	funpack_runtime.write_json_string(&b, MCP_SERVER_NAME)
	strings.write_string(&b, ",\"version\":")
	strings.write_string(&b, funpack.version_report_json(allocator))
	strings.write_string(&b, ",\"corpus_drift\":")
	docs_write_drift(&b, drift)
	strings.write_byte(&b, '}')

	content := make([]Mcp_Content, 1, allocator)
	content[0] = mcp_text_content(strings.to_string(b))
	result := Mcp_Tool_Result{content = content, is_error = false}
	return mcp_render_tool_result(dispatch.id, result, allocator)
}

Docs_Corpus_Drift :: struct {
	drift:            bool,
	corpus_version:   string,
	compiler_version: string,
	warning:          string,
}

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

docs_corpus_version :: proc(manifest: Corpus_Manifest, allocator := context.allocator) -> string {
	return strings.concatenate({"spec ", manifest.spec_ref, " / ", manifest.funpack_version}, allocator)
}

docs_normalize_version :: proc(s: string) -> string {
	trimmed := strings.trim_space(s)
	trimmed = strings.trim_prefix(trimmed, "funpack ")
	return strings.trim_space(trimmed)
}

docs_arg_int :: proc(arguments: json.Object, key: string, fallback: int) -> int {
	value, has := funpack_runtime.json_int_field(arguments, key)
	if !has {
		return fallback
	}
	return int(value)
}

docs_assert_specs_present :: proc() -> bool {
	for tool in docs_family_tools {
		_, found := mcp_lookup_tool(tool)
		if !found {
			return false
		}
	}
	return true
}
