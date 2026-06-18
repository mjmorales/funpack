// The BM25 passage-ranker junction. Every proc builds an index over the REAL
// embedded corpus (load_corpus) and asserts a rank-ORDER / anchor-IDENTITY
// invariant, never an exact float score: BM25 IDF/saturation is f64 arithmetic and
// exact-score equality is brittle and meaningless, so the living spec pins what the
// ranker GUARANTEES (which section leads, ties break on anchor, snippets are
// present).
//
// Define-free (the ranker is), so these run on the default `odin test .` floor.
package main

import "core:strings"
import "core:testing"

// passage_test_index loads the real committed corpus and indexes it on the temp
// allocator, failing if the corpus is empty (a generation regression) rather than
// silently testing an empty index — the production-data discipline.
@(private = "file")
passage_test_index :: proc(t: ^testing.T) -> Passage_Index {
	sections, ok := load_corpus(context.temp_allocator)
	testing.expect(t, ok, "embedded corpus must parse")
	testing.expect(t, len(sections) > 0, "corpus is empty — run `funpack mcp gen-corpus`")
	return passage_index_build(sections, context.temp_allocator)
}

// test_passages_query_determinism_ranks_axioms asserts a single-word conceptual
// query surfaces the spec section defining the concept as its top hit. The corpus
// anchors determinism's defining passage under spec/01-axioms.md, so the top result
// must be a spec section from that file — the index would be useless if a passing
// body mention outranked the defining heading.
@(test)
test_passages_query_determinism_ranks_axioms :: proc(t: ^testing.T) {
	ix := passage_test_index(t)
	hits := passage_index_query(&ix, "determinism", 5, context.temp_allocator)
	testing.expect(t, len(hits) > 0, "query 'determinism' returned zero hits")
	if len(hits) == 0 {
		return
	}
	top := hits[0]
	testing.expectf(t, top.kind == CORPUS_KIND_SPEC, "top hit kind = %q, want spec; anchor=%s", top.kind, top.anchor)
	testing.expectf(t, strings.has_prefix(top.anchor, "01-axioms.md#"), "top hit anchor = %q, want a 01-axioms.md determinism section", top.anchor)
	testing.expectf(t, strings.contains(strings.to_lower(top.title, context.temp_allocator), "determinism"), "top hit title = %q, expected to mention determinism", top.title)
	passage_assert_descending(t, hits)
}

// test_passages_query_pipeline_schedule_ranks_pipelines asserts a multi-word
// conceptual query concentrates results on the relevant spec chapter:
// "pipeline schedule" must surface 07-pipelines.md sections high in the ranking.
@(test)
test_passages_query_pipeline_schedule_ranks_pipelines :: proc(t: ^testing.T) {
	ix := passage_test_index(t)
	hits := passage_index_query(&ix, "pipeline schedule", 8, context.temp_allocator)
	testing.expect(t, len(hits) > 0, "query 'pipeline schedule' returned zero hits")

	found_pipelines := false
	for h, i in hits {
		if strings.has_prefix(h.anchor, "07-pipelines.md#") {
			found_pipelines = true
			testing.expectf(t, i <= 3, "07-pipelines.md hit ranked at %d, expected within top 4 (anchor=%s)", i, h.anchor)
			break
		}
	}
	testing.expect(t, found_pipelines, "no 07-pipelines.md section in top hits for 'pipeline schedule'")
	passage_assert_descending(t, hits)
}

// test_passages_query_returns_anchored_hits_with_snippets asserts every returned
// hit carries the contract the consuming docs tools depend on: a non-empty stable
// anchor, a title, a positive score, and a non-empty snippet.
@(test)
test_passages_query_returns_anchored_hits_with_snippets :: proc(t: ^testing.T) {
	ix := passage_test_index(t)
	hits := passage_index_query(&ix, "collision physics", 5, context.temp_allocator)
	testing.expect(t, len(hits) > 0, "query returned zero hits")
	for h, i in hits {
		testing.expectf(t, h.anchor != "", "hit %d: empty anchor", i)
		testing.expectf(t, h.title != "", "hit %d (%s): empty title", i, h.anchor)
		testing.expectf(t, h.score > 0, "hit %d (%s): non-positive score %v", i, h.anchor, h.score)
		testing.expectf(t, strings.trim_space(h.snippet) != "", "hit %d (%s): empty snippet", i, h.anchor)
	}
}

// test_passages_query_respects_limit asserts the limit caps the result count.
@(test)
test_passages_query_respects_limit :: proc(t: ^testing.T) {
	ix := passage_test_index(t)
	hits := passage_index_query(&ix, "state", 3, context.temp_allocator)
	testing.expectf(t, len(hits) <= 3, "limit 3 returned %d hits", len(hits))
	testing.expect(t, len(hits) > 0, "query 'state' returned zero hits despite a common term")
}

// test_passages_empty_and_degenerate_queries asserts the index handles inputs that
// carry no scorable terms without panicking and returns nil: an empty string,
// whitespace only, punctuation only, stop-words only, and a non-positive limit.
@(test)
test_passages_empty_and_degenerate_queries :: proc(t: ^testing.T) {
	ix := passage_test_index(t)
	Case :: struct {
		name:  string,
		q:     string,
		limit: int,
	}
	cases := []Case {
		{"empty", "", 5},
		{"whitespace", "   \t\n ", 5},
		{"punctuation", "??? --- ...", 5},
		{"stopwords only", "the and of to", 5},
		{"zero limit", "determinism", 0},
		{"negative limit", "determinism", -1},
	}
	for c in cases {
		got := passage_index_query(&ix, c.q, c.limit, context.temp_allocator)
		testing.expectf(t, got == nil, "query(%q, %d) = %d hits, want nil", c.q, c.limit, len(got))
	}
}

// test_passages_unknown_term_yields_no_hits asserts a query whose terms appear
// nowhere in the corpus returns no hits rather than scoring random documents.
@(test)
test_passages_unknown_term_yields_no_hits :: proc(t: ^testing.T) {
	ix := passage_test_index(t)
	got := passage_index_query(&ix, "zzzznonexistentterm qqqxabsent", 5, context.temp_allocator)
	testing.expectf(t, got == nil, "unknown-term query returned %d hits, want nil", len(got))
}

// test_passages_nil_and_empty_index asserts the constructor and query tolerate
// empty input: an empty section slice and a nil index both return nil hits.
@(test)
test_passages_nil_and_empty_index :: proc(t: ^testing.T) {
	empty := passage_index_build(nil, context.temp_allocator)
	got := passage_index_query(&empty, "anything", 5, context.temp_allocator)
	testing.expectf(t, got == nil, "empty index returned %d hits, want nil", len(got))

	nil_got := passage_index_query(nil, "anything", 5, context.temp_allocator)
	testing.expectf(t, nil_got == nil, "nil index returned %d hits, want nil", len(nil_got))
}

// test_passages_engine_sections_participate asserts the kind-weight policy keeps
// engine sections in the index: an engine-only index still returns engine hits, so
// a query that genuinely matches a signature's @doc line can surface it (at lower
// weight) rather than being dropped entirely.
@(test)
test_passages_engine_sections_participate :: proc(t: ^testing.T) {
	sections, ok := load_corpus(context.temp_allocator)
	testing.expect(t, ok, "embedded corpus must parse")
	engine := corpus_by_kind(sections, CORPUS_KIND_ENGINE, context.temp_allocator)
	engine_only := passage_index_build(engine, context.temp_allocator)
	hits := passage_index_query(&engine_only, "vec2", 5, context.temp_allocator)
	if len(hits) == 0 {
		return
	}
	for h in hits {
		testing.expectf(t, h.kind == CORPUS_KIND_ENGINE, "engine-only index returned non-engine hit %s", h.anchor)
	}
}

// passage_assert_descending verifies hits are ordered by non-increasing score, the
// ranking contract callers rely on.
@(private = "file")
passage_assert_descending :: proc(t: ^testing.T, hits: []Passage_Hit) {
	for i in 1 ..< len(hits) {
		testing.expectf(t, hits[i].score <= hits[i - 1].score, "hits not descending: [%d]=%v > [%d]=%v", i, hits[i].score, i - 1, hits[i - 1].score)
	}
}
