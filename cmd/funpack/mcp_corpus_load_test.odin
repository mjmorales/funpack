package main

import "core:testing"

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

corpus_text_leads_with_prose :: proc(text: string) -> bool {
	if text == "" {
		return false
	}
	for kw in ([]string{"fn ", "extern ", "enum ", "data ", "let "}) {
		if len(text) >= len(kw) && text[:len(kw)] == kw {
			return false
		}
	}
	return true
}
