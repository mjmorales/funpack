// Extractor-unit tests for the corpus generator splitters — the foundational
// junctions of the three extractors, exercised on small inline fixtures so a
// splitter invariant regresses HERE (named) rather than silently shifting the
// committed corpus through the pin test. These pin the gencore invariants the Odin
// port must hold: the heading splitter is fence-aware and dedupes repeated slugs;
// the engine splitter pairs a decl with its immediately-preceding @doc line, drops a
// non-extern fn body to the signature head, and clears a dangling @doc on an
// intervening line. Define-free, run on the default `odin test .` floor.
package main

import "core:strings"
import "core:testing"

// test_split_headings_is_fence_aware pins that a markdown heading INSIDE a ```-fenced
// code block is NOT a split point (the gencore splitHeadings fence rule), while the
// real H2 heading is — so a fenced "# not a heading" stays in the preceding section's
// body rather than minting a spurious section.
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

// test_split_headings_dedupes_repeated_slug pins the duplicate-slug suffixing: two
// headings that slugify to the same anchor fragment within one file get "-2" on the
// second (the gencore slugCounts rule), so anchors stay unique and stable.
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

// test_split_headings_skips_empty_parent pins that an organizational parent heading
// with no body of its own (only subheadings follow) is NOT emitted — only the leaf
// sections that carry a searchable passage are (the gencore empty-body skip).
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

// test_split_engine_pairs_doc_and_drops_fn_body pins the engine extractor's two
// core invariants: a decl is paired with its immediately-preceding @doc line (the
// section text is "<prose>\n\n<sig>"), and a non-extern fn's BODY is dropped so the
// section carries the signature head, not the implementation.
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

// test_split_engine_keeps_type_body pins the type-declaration arm: a data/enum/extern
// type's brace-delimited member list IS the signature and is kept verbatim across
// lines (unlike a fn body, which is dropped) — the gencore signature() type branch.
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

// test_split_engine_clears_dangling_doc pins that a @doc line NOT immediately
// followed by a decl (an intervening non-blank line) is cleared, so the doc never
// attaches to the wrong (later) declaration — the gencore dangling-@doc clear.
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

// test_corpus_slugify_invariants pins the slug normalization: lowercase, backticks
// stripped, non-alphanumeric runs collapse to a single dash, leading/trailing dashes
// trimmed, and an all-punctuation title falls back to "section" — the gencore
// slugify contract anchors depend on for stability across regen.
@(test)
test_corpus_slugify_invariants :: proc(t: ^testing.T) {
	testing.expect_value(t, corpus_slugify("Hello World", context.temp_allocator), "hello-world")
	testing.expect_value(t, corpus_slugify("`code` & punctuation!", context.temp_allocator), "code-punctuation")
	testing.expect_value(t, corpus_slugify("  spaced  out  ", context.temp_allocator), "spaced-out")
	testing.expect_value(t, corpus_slugify("???", context.temp_allocator), "section")
}
