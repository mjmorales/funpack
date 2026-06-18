// The corpus embed/load round-trip junction — the Odin re-home of the deleted Go
// mcp/internal/docs/docs_test.go. It guards the loader contract independent of
// regeneration: #load + parse the committed shards through load_corpus /
// load_manifest and assert the loaded corpus is well-formed — every Kind is a valid
// closed-enum value, every Section carries non-empty Anchor/Title/Text/Source, and
// the per-kind section counts equal the manifest's declared counts. This is the
// check that fails if the embed/parse path regresses (a malformed shard, a renamed
// JSON key, a stale embed), separate from the pin test's drift gate.
//
// Define-free (the loader is; see mcp_corpus.odin), so these run on the default
// `odin test .` floor — no FUNPACK_LIVE arm needed.
package main

import "core:testing"

// test_corpus_load_parses_and_is_well_formed asserts the embedded corpus loads and
// every section is structurally sound: a valid closed-enum kind, and non-empty
// anchor/title/text/source. A malformed shard or a renamed key would surface here as
// a parse failure or an empty field.
@(test)
test_corpus_load_parses_and_is_well_formed :: proc(t: ^testing.T) {
	sections, ok := load_corpus(context.temp_allocator)
	testing.expect(t, ok, "embedded corpus shards must parse")
	if !ok {
		return
	}
	testing.expect(t, len(sections) > 0, "loaded corpus must be non-empty")

	for s, i in sections {
		testing.expectf(t, corpus_kind_valid(s.kind), "section %d has invalid kind %q", i, s.kind)
		testing.expectf(t, s.anchor != "", "section %d (%q) has an empty anchor", i, s.kind)
		testing.expectf(t, s.title != "", "section %q has an empty title", s.anchor)
		testing.expectf(t, s.text != "", "section %q has an empty text", s.anchor)
		testing.expectf(t, s.source != "", "section %q has an empty source", s.anchor)
	}
}

// test_corpus_load_counts_match_manifest asserts the loaded per-kind section counts
// equal the manifest's declared per-source counts, and that the total equals the
// manifest's total_sections — the loader-side cross-check that the embedded shards
// and the embedded manifest agree (a shard regenerated without its manifest, or
// vice versa, fails here).
@(test)
test_corpus_load_counts_match_manifest :: proc(t: ^testing.T) {
	sections, sections_ok := load_corpus(context.temp_allocator)
	testing.expect(t, sections_ok, "embedded corpus shards must parse")
	manifest, manifest_ok := load_manifest(context.temp_allocator)
	testing.expect(t, manifest_ok, "embedded manifest must parse")
	if !sections_ok || !manifest_ok {
		return
	}

	loaded := make(map[string]int, 3, context.temp_allocator)
	for s in sections {
		loaded[s.kind] += 1
	}

	declared := manifest_count_by_kind(manifest, context.temp_allocator)
	for kind in ([]string{CORPUS_KIND_SPEC, CORPUS_KIND_ENGINE, CORPUS_KIND_PLUGIN}) {
		testing.expectf(
			t,
			loaded[kind] == declared[kind],
			"kind %q: loaded %d sections, manifest declares %d",
			kind,
			loaded[kind],
			declared[kind],
		)
	}
	testing.expectf(
		t,
		len(sections) == manifest.total_sections,
		"loaded %d sections, manifest total_sections is %d",
		len(sections),
		manifest.total_sections,
	)
}

// test_corpus_by_kind_partitions asserts corpus_by_kind returns exactly the sections
// of the requested kind and nothing else — the accessor the downstream docs ranker
// (mcp-docs-search-port) reads per-kind partitions through. Guards the partition
// contract so a future ranker can trust it.
@(test)
test_corpus_by_kind_partitions :: proc(t: ^testing.T) {
	sections, ok := load_corpus(context.temp_allocator)
	testing.expect(t, ok, "embedded corpus shards must parse")
	if !ok {
		return
	}

	engine := corpus_by_kind(sections, CORPUS_KIND_ENGINE, context.temp_allocator)
	testing.expect(t, len(engine) > 0, "the engine partition must be non-empty")
	for s in engine {
		testing.expectf(t, s.kind == CORPUS_KIND_ENGINE, "corpus_by_kind(engine) returned a %q section", s.kind)
	}

	// The three partitions are disjoint and cover the whole corpus.
	spec := corpus_by_kind(sections, CORPUS_KIND_SPEC, context.temp_allocator)
	plugin := corpus_by_kind(sections, CORPUS_KIND_PLUGIN, context.temp_allocator)
	testing.expectf(
		t,
		len(spec) + len(engine) + len(plugin) == len(sections),
		"the three kind partitions (%d+%d+%d) do not cover the whole corpus (%d)",
		len(spec),
		len(engine),
		len(plugin),
		len(sections),
	)
}

// test_corpus_engine_sections_carry_doc_prose pins the DOCS-GEN decision's critical
// correction: an engine section's text is the @doc PROSE followed by the signature,
// NOT a bare signature — proving the stdlib/engine/*.fun @doc lines (not the
// doc-text-free surface_dump_json) are the engine corpus source. It samples the
// engine partition for a section whose text begins with prose (a sentence) ahead of
// a `fn`/`enum`/`data`/`extern` signature token, asserting at least one such
// prose-bearing section exists.
@(test)
test_corpus_engine_sections_carry_doc_prose :: proc(t: ^testing.T) {
	sections, ok := load_corpus(context.temp_allocator)
	testing.expect(t, ok, "embedded corpus shards must parse")
	if !ok {
		return
	}
	engine := corpus_by_kind(sections, CORPUS_KIND_ENGINE, context.temp_allocator)
	testing.expect(t, len(engine) > 0, "the engine partition must be non-empty")

	prose_bearing := 0
	for s in engine {
		// A @doc-paired section is "<prose>\n\n<signature>": the prose comes FIRST,
		// so the text does NOT start with a decl keyword. surface_dump_json could
		// only ever produce signature-leading text (it has zero doc prose), so a
		// prose-leading section can ONLY have come from the .fun @doc source.
		if corpus_text_leads_with_prose(s.text) {
			prose_bearing += 1
		}
	}
	testing.expectf(
		t,
		prose_bearing > 0,
		"no engine section carries @doc prose ahead of its signature — engine.json appears sourced from a doc-text-free projection (surface_dump_json), not the .fun @doc lines",
	)
}

// corpus_text_leads_with_prose reports whether text begins with @doc prose rather
// than a bare declaration signature — true when the first token is NOT a stdlib
// decl keyword (fn/extern/enum/data/let). A @doc-paired engine section is
// "<prose>\n\n<sig>", so its text leads with the prose sentence; a signature-only
// section (no @doc) leads with the keyword.
corpus_text_leads_with_prose :: proc(text: string) -> bool {
	if text == "" {
		return false
	}
	// Lead keywords a signature-only section would start with.
	for kw in ([]string{"fn ", "extern ", "enum ", "data ", "let "}) {
		if len(text) >= len(kw) && text[:len(kw)] == kw {
			return false
		}
	}
	return true
}
