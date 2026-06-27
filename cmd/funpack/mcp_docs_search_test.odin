package main

import "core:strings"
import "core:testing"

@(private = "file")
search_test_engine :: proc(t: ^testing.T) -> Search_Engine {
	sections, ok := load_corpus(context.temp_allocator)
	testing.expect(t, ok, "embedded corpus must parse")
	testing.expect(t, len(sections) > 0, "corpus is empty — run `funpack mcp gen-corpus`")
	return search_engine_build(sections, context.temp_allocator)
}

@(test)
test_search_symbol_shaped_query_ranks_symbol_first :: proc(t: ^testing.T) {
	e := search_test_engine(t)
	results := search_engine_search(&e, "world.resolve", 10, context.temp_allocator)
	testing.expect(t, len(results) > 0, "Search(world.resolve) returned no results")
	if len(results) == 0 {
		return
	}
	top := results[0]
	testing.expectf(t, top.source == .Symbol, "top source = %q, want symbol; anchor=%s", search_source_label(top.source), top.anchor)
	testing.expectf(t, top.title == "world.resolve", "top title = %q, want world.resolve", top.title)
	testing.expectf(t, top.anchor == "engine/world#resolve", "top anchor = %q, want engine/world#resolve", top.anchor)
	search_assert_descending(t, results)
}

@(test)
test_search_bare_type_name_ranks_symbol_first :: proc(t: ^testing.T) {
	e := search_test_engine(t)
	results := search_engine_search(&e, "Vec", 10, context.temp_allocator)
	testing.expect(t, len(results) > 0, "Search(Vec) returned no results")
	if len(results) == 0 {
		return
	}
	testing.expectf(t, results[0].source == .Symbol, "top source = %q, want symbol (anchor=%s)", search_source_label(results[0].source), results[0].anchor)
	testing.expectf(t, strings.contains(results[0].title, "Vec"), "top title = %q, expected to contain Vec", results[0].title)
	search_assert_descending(t, results)
}

@(test)
test_search_conceptual_query_ranks_passage_first :: proc(t: ^testing.T) {
	e := search_test_engine(t)
	results := search_engine_search(&e, "how does determinism work", 10, context.temp_allocator)
	testing.expect(t, len(results) > 0, "conceptual query returned no results")
	if len(results) == 0 {
		return
	}
	top := results[0]
	testing.expectf(t, top.source == .Passage, "top source = %q, want passage; anchor=%s", search_source_label(top.source), top.anchor)

	AXIOM :: "01-axioms.md#p1-determinism-two-tiers-both-mandatory-from-r1"
	saw_axiom := false
	for r in results {
		if r.anchor == AXIOM {
			saw_axiom = true
			testing.expectf(t, r.source == .Passage, "axiom hit source = %q, want passage", search_source_label(r.source))
			break
		}
	}
	testing.expectf(t, saw_axiom, "defining determinism spec passage %q absent from top results", AXIOM)
	search_assert_descending(t, results)
}

@(test)
test_search_spec_determinism_passage_leads_on_topical_query :: proc(t: ^testing.T) {
	e := search_test_engine(t)
	results := search_engine_search(&e, "determinism", 10, context.temp_allocator)
	testing.expect(t, len(results) > 0, "Search(determinism) returned no results")
	if len(results) == 0 {
		return
	}
	top := results[0]
	testing.expectf(t, top.source == .Passage, "top source = %q, want passage; anchor=%s", search_source_label(top.source), top.anchor)
	testing.expectf(t, top.kind == CORPUS_KIND_SPEC, "top kind = %q, want spec; anchor=%s", top.kind, top.anchor)
	testing.expectf(t, strings.has_prefix(top.anchor, "01-axioms.md#"), "top anchor = %q, want a 01-axioms.md determinism section", top.anchor)
	search_assert_descending(t, results)
}

@(test)
test_search_directive_query_resolves_symbol :: proc(t: ^testing.T) {
	e := search_test_engine(t)
	results := search_engine_search(&e, "@stub", 10, context.temp_allocator)
	testing.expect(t, len(results) > 0, "Search(@stub) returned no results")
	if len(results) == 0 {
		return
	}
	top := results[0]
	testing.expectf(t, top.source == .Symbol, "top source = %q, want symbol", search_source_label(top.source))
	testing.expectf(t, top.title == "@stub", "top title = %q, want @stub", top.title)
	testing.expect(t, top.anchor != "", "@stub resolved with no spec anchor")
	search_assert_descending(t, results)
}

@(test)
test_search_keyword_query_classifies_symbol :: proc(t: ^testing.T) {
	e := search_test_engine(t)
	results := search_engine_search(&e, "import", 10, context.temp_allocator)
	testing.expect(t, len(results) > 0, "Search(import) returned no results")
	if len(results) == 0 {
		return
	}
	testing.expectf(t, results[0].source == .Symbol, "top source = %q, want symbol (anchor=%s)", search_source_label(results[0].source), results[0].anchor)
	testing.expectf(t, results[0].title == "import", "top title = %q, want import", results[0].title)
}

@(test)
test_search_respects_limit :: proc(t: ^testing.T) {
	e := search_test_engine(t)
	for n in ([]int{1, 3, 5}) {
		got := search_engine_search(&e, "determinism", n, context.temp_allocator)
		testing.expectf(t, len(got) <= n, "limit %d returned %d results", n, len(got))
		testing.expectf(t, len(got) > 0, "limit %d returned zero results for a common query", n)
	}
}

@(test)
test_search_deterministic_ordering :: proc(t: ^testing.T) {
	e := search_test_engine(t)
	Q :: "pipeline schedule"
	first := search_engine_search(&e, Q, 10, context.temp_allocator)
	for i in 0 ..< 5 {
		again := search_engine_search(&e, Q, 10, context.temp_allocator)
		testing.expectf(t, len(again) == len(first), "run %d: length %d != %d", i, len(again), len(first))
		if len(again) != len(first) {
			return
		}
		for j in 0 ..< len(first) {
			testing.expectf(t, again[j].anchor == first[j].anchor && again[j].source == first[j].source, "run %d pos %d: %s/%s != %s/%s", i, j, again[j].anchor, search_source_label(again[j].source), first[j].anchor, search_source_label(first[j].source))
		}
	}
}

@(test)
test_search_surfaces_both_sources :: proc(t: ^testing.T) {
	e := search_test_engine(t)
	results := search_engine_search(&e, "how do pipelines schedule systems", 20, context.temp_allocator)
	testing.expect(t, len(results) > 0, "query returned no results")
	saw_passage := false
	for r in results {
		if r.source == .Passage {
			saw_passage = true
		}
	}
	testing.expect(t, saw_passage, "conceptual query surfaced no passage hits")
}

@(test)
test_search_results_carry_downstream_contract :: proc(t: ^testing.T) {
	e := search_test_engine(t)
	for q in ([]string{"world.resolve", "how does determinism work", "@stub", "Vec2"}) {
		results := search_engine_search(&e, q, 8, context.temp_allocator)
		testing.expectf(t, len(results) > 0, "query %q returned no results", q)
		for r, i in results {
			testing.expectf(t, r.anchor != "", "%q hit %d: empty anchor", q, i)
			testing.expectf(t, r.title != "", "%q hit %d (%s): empty title", q, i, r.anchor)
			testing.expectf(t, r.score > 0, "%q hit %d (%s): non-positive score %v", q, i, r.anchor, r.score)
			testing.expectf(t, corpus_kind_valid(r.kind), "%q hit %d (%s): invalid kind %q", q, i, r.anchor, r.kind)
			testing.expectf(t, r.source == .Symbol || r.source == .Passage, "%q hit %d (%s): unknown source", q, i, r.anchor)
		}
	}
}

@(test)
test_search_degenerate_queries :: proc(t: ^testing.T) {
	e := search_test_engine(t)
	Case :: struct {
		name:  string,
		q:     string,
		limit: int,
	}
	cases := []Case {
		{"empty", "", 5},
		{"whitespace", "  \t\n ", 5},
		{"zero limit", "determinism", 0},
		{"negative limit", "determinism", -1},
	}
	for c in cases {
		got := search_engine_search(&e, c.q, c.limit, context.temp_allocator)
		testing.expectf(t, got == nil, "Search(%q, %d) = %d results, want nil", c.q, c.limit, len(got))
	}

	nil_got := search_engine_search(nil, "anything", 5, context.temp_allocator)
	testing.expectf(t, nil_got == nil, "nil Engine returned %d results, want nil", len(nil_got))

	empty := search_engine_build(nil, context.temp_allocator)
	for r in search_engine_search(&empty, "thing", 5, context.temp_allocator) {
		testing.expectf(t, r.source != .Passage, "nil-corpus engine returned a passage hit %q with no corpus", r.anchor)
	}
}

@(test)
test_search_classify :: proc(t: ^testing.T) {
	directives := make(map[string]bool, 0, context.temp_allocator)
	directives["@stub"] = true
	directives["@doc"] = true
	keywords := make(map[string]bool, 0, context.temp_allocator)
	keywords["import"] = true
	keywords["behavior"] = true
	keywords["fn"] = true

	Case :: struct {
		q:    string,
		want: Search_Shape,
		why:  string,
	}
	cases := []Case {
		{"@stub", .Symbol, "leading @ is always a directive"},
		{"@unknownnewdirective", .Symbol, "leading @ wins even when not in the seeded set"},
		{"import", .Symbol, "exact known keyword"},
		{"behavior", .Symbol, "exact known keyword, beats its all-lowercase look"},
		{"world.resolve", .Symbol, "dotted qualified name"},
		{"spawn_entity", .Symbol, "snake_case identifier"},
		{"Vec2", .Symbol, "leading capital type-style name"},
		{"Vec", .Symbol, "leading capital, no other signal"},
		{"someCamelCase", .Symbol, "internal capital after lowercase"},
		{"physics", .Conceptual, "plain all-lowercase topic word"},
		{"how does determinism work", .Conceptual, "multi-word natural language"},
		{"pipeline schedule", .Conceptual, "two-word phrase even though tokens are identifier-ish"},
		{"@stub directive usage", .Conceptual, "multi-word phrase: whitespace beats the leading @ token"},
	}
	for c in cases {
		got := search_classify(c.q, directives, keywords)
		testing.expectf(t, got == c.want, "classify(%q) = %v, want %v (%s)", c.q, got, c.want, c.why)
	}
}

@(test)
test_search_min_max_normalization :: proc(t: ^testing.T) {
	Case :: struct {
		name:  string,
		input: []f64,
		want:  []f64,
	}
	cases := []Case {
		{"empty", nil, []f64{}},
		{"single", []f64{42}, []f64{1}},
		{"all equal", []f64{5, 5, 5}, []f64{1, 1, 1}},
		{"descending", []f64{10, 6, 2}, []f64{1, 0.5, 0}},
		{"two", []f64{8, 4}, []f64{1, 0}},
	}
	for c in cases {
		got := search_min_max(c.input, context.temp_allocator)
		testing.expectf(t, len(got) == len(c.want), "%s: len %d != %d", c.name, len(got), len(c.want))
		if len(got) != len(c.want) {
			continue
		}
		for i in 0 ..< len(c.want) {
			testing.expectf(t, got[i] == c.want[i], "%s: [%d] = %v, want %v", c.name, i, got[i], c.want[i])
		}
	}
}

@(private = "file")
search_assert_descending :: proc(t: ^testing.T, results: []Search_Result) {
	for i in 1 ..< len(results) {
		testing.expectf(t, results[i].score <= results[i - 1].score, "results not descending: [%d]=%v > [%d]=%v", i, results[i].score, i - 1, results[i - 1].score)
	}
}
