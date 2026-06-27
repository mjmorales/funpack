package main

import "core:strings"
import "core:testing"

@(private = "file")
path_test_section :: proc() -> Corpus_Section {
	return Corpus_Section {
		anchor = "engine/anim#bone",
		kind   = CORPUS_KIND_ENGINE,
		title  = "anim.Bone",
		text   = "A named bone.",
		source = "engine/anim.fun",
	}
}

@(test)
test_docs_get_result_path_present :: proc(t: ^testing.T) {
	section := path_test_section()
	root := "/home/dev/.funpack/docs/9.9.9"

	with_root := docs_get_result(section, root, context.temp_allocator)
	body := with_root.content[0].text
	expected := corpus_join({root, section.source}, context.temp_allocator)
	testing.expectf(t, strings.contains(body, expected), "docs_get must carry path %q, got: %s", expected, body)
	testing.expect(t, strings.contains(body, "\"path\":"), "docs_get must emit a path key when a root resolves")

	without_root := docs_get_result(section, "", context.temp_allocator)
	testing.expect(t, !strings.contains(without_root.content[0].text, "\"path\":"), "docs_get must omit path when no root resolves")
}

@(test)
test_docs_search_result_path_present :: proc(t: ^testing.T) {
	section := path_test_section()
	sections := []Corpus_Section{section}
	hits := []Search_Result {
		{
			anchor = section.anchor,
			title = section.title,
			kind = section.kind,
			score = 1.0,
			snippet = section.text,
			source = .Symbol,
		},
	}
	manifest, _ := load_manifest(context.temp_allocator)
	root := "/home/dev/.funpack/docs/9.9.9"

	with_root := docs_search_result(hits, manifest, sections, root, context.temp_allocator)
	body := with_root.content[0].text
	expected := corpus_join({root, section.source}, context.temp_allocator)
	testing.expectf(t, strings.contains(body, expected), "search hit must carry path %q, got: %s", expected, body)

	without_root := docs_search_result(hits, manifest, sections, "", context.temp_allocator)
	testing.expect(t, !strings.contains(without_root.content[0].text, "\"path\":"), "search hit must omit path when no root resolves")
}

@(test)
test_docs_search_path_matches_export_root :: proc(t: ^testing.T) {
	sections, ok := load_corpus(context.temp_allocator)
	testing.expect(t, ok, "embedded corpus must parse")
	testing.expect(t, len(sections) > 0, "corpus is empty — run `funpack mcp gen-corpus`")

	sample := sections[0]
	hits := []Search_Result {
		{anchor = sample.anchor, title = sample.title, kind = sample.kind, score = 1.0, snippet = sample.text, source = .Passage},
	}
	manifest, _ := load_manifest(context.temp_allocator)
	root := "/tmp/funpack-docs-render-match"

	body := docs_search_result(hits, manifest, sections, root, context.temp_allocator).content[0].text
	expected := corpus_join({root, sample.source}, context.temp_allocator)
	testing.expectf(t, strings.contains(body, expected), "rendered path must equal the exporter's file %q", expected)
}
