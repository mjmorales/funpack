package main

import "core:strings"
import "core:testing"

@(test)
test_split_headings_is_fence_aware :: proc(t: ^testing.T) {
	doc := strings.join(
		{
			"# Top",
			"intro prose",
			"```",
			"# not a heading inside a fence",
			"```",
			"more body",
			"## Real Sub",
			"sub body",
		},
		"\n",
		context.temp_allocator,
	)
	out := make([dynamic]Corpus_Section, 0, 4, context.temp_allocator)
	split_headings(doc, "f.md", CORPUS_KIND_SPEC, &out, context.temp_allocator)

	testing.expectf(t, len(out) == 2, "expected 2 sections (Top, Real Sub), got %d", len(out))
	if len(out) != 2 {
		return
	}
	testing.expect_value(t, out[0].title, "Top")
	testing.expect(
		t,
		strings.contains(out[0].text, "# not a heading inside a fence"),
		"the fenced heading must stay in the Top section body, not split a new section",
	)
	testing.expect_value(t, out[1].title, "Real Sub")
}

@(test)
test_split_headings_dedupes_repeated_slug :: proc(t: ^testing.T) {
	doc := strings.join(
		{"# Notes", "first body", "## Notes", "second body"},
		"\n",
		context.temp_allocator,
	)
	out := make([dynamic]Corpus_Section, 0, 4, context.temp_allocator)
	split_headings(doc, "f.md", CORPUS_KIND_SPEC, &out, context.temp_allocator)

	testing.expectf(t, len(out) == 2, "expected 2 sections, got %d", len(out))
	if len(out) != 2 {
		return
	}
	testing.expect_value(t, out[0].anchor, "f.md#notes")
	testing.expect_value(t, out[1].anchor, "f.md#notes-2")
}

@(test)
test_split_headings_skips_empty_parent :: proc(t: ^testing.T) {
	doc := strings.join(
		{"# Parent", "## Child", "child body"},
		"\n",
		context.temp_allocator,
	)
	out := make([dynamic]Corpus_Section, 0, 4, context.temp_allocator)
	split_headings(doc, "f.md", CORPUS_KIND_PLUGIN, &out, context.temp_allocator)

	testing.expectf(t, len(out) == 1, "expected only the Child section, got %d", len(out))
	if len(out) != 1 {
		return
	}
	testing.expect_value(t, out[0].title, "Child")
}

@(test)
test_split_engine_pairs_doc_and_drops_fn_body :: proc(t: ^testing.T) {
	src := strings.join(
		{
			"@doc(\"Clamp v into [lo, hi].\")",
			"fn clamp(v: Int, lo: Int, hi: Int) -> Int {",
			"  if v < lo { return lo }",
			"  return v",
			"}",
		},
		"\n",
		context.temp_allocator,
	)
	out := make([dynamic]Corpus_Section, 0, 2, context.temp_allocator)
	split_engine_file(src, "math", "engine/math.fun", &out, context.temp_allocator)

	testing.expectf(t, len(out) == 1, "expected one engine section, got %d", len(out))
	if len(out) != 1 {
		return
	}
	testing.expect_value(t, out[0].title, "math.clamp")
	testing.expect_value(t, out[0].anchor, "engine/math#clamp")
	testing.expect(t, strings.has_prefix(out[0].text, "Clamp v into [lo, hi]."), "the @doc prose must lead the section text")
	testing.expect(t, strings.contains(out[0].text, "fn clamp(v: Int, lo: Int, hi: Int) -> Int"), "the signature head must be present")
	testing.expect(t, !strings.contains(out[0].text, "return v"), "the fn BODY must be dropped from the signature section")
}

@(test)
test_split_engine_keeps_type_body :: proc(t: ^testing.T) {
	src := strings.join(
		{
			"@doc(\"A 2D point.\")",
			"data Point {",
			"  x: Int,",
			"  y: Int,",
			"}",
		},
		"\n",
		context.temp_allocator,
	)
	out := make([dynamic]Corpus_Section, 0, 2, context.temp_allocator)
	split_engine_file(src, "geom", "engine/geom.fun", &out, context.temp_allocator)

	testing.expectf(t, len(out) == 1, "expected one engine section, got %d", len(out))
	if len(out) != 1 {
		return
	}
	testing.expect_value(t, out[0].title, "geom.Point")
	testing.expect(t, strings.contains(out[0].text, "x: Int"), "a type's field list must be kept in the signature")
	testing.expect(t, strings.contains(out[0].text, "y: Int"), "a multi-line type body must be kept verbatim")
}

@(test)
test_split_engine_clears_dangling_doc :: proc(t: ^testing.T) {
	src := strings.join(
		{
			"@doc(\"Orphan doc with no decl after it.\")",
			"import core",
			"fn plain() -> Int",
		},
		"\n",
		context.temp_allocator,
	)
	out := make([dynamic]Corpus_Section, 0, 2, context.temp_allocator)
	split_engine_file(src, "core", "engine/core.fun", &out, context.temp_allocator)

	testing.expectf(t, len(out) == 1, "expected one engine section, got %d", len(out))
	if len(out) != 1 {
		return
	}
	testing.expect_value(t, out[0].title, "core.plain")
	testing.expect(
		t,
		!strings.contains(out[0].text, "Orphan doc"),
		"a @doc separated from its decl by an intervening line must NOT attach",
	)
	testing.expect(t, strings.has_prefix(out[0].text, "fn plain()"), "the signature-only section leads with its keyword")
}

@(test)
test_corpus_slugify_invariants :: proc(t: ^testing.T) {
	testing.expect_value(t, corpus_slugify("Hello World", context.temp_allocator), "hello-world")
	testing.expect_value(t, corpus_slugify("`code` & punctuation!", context.temp_allocator), "code-punctuation")
	testing.expect_value(t, corpus_slugify("  spaced  out  ", context.temp_allocator), "spaced-out")
	testing.expect_value(t, corpus_slugify("???", context.temp_allocator), "section")
}
