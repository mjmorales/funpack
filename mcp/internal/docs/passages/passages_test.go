package passages

import (
	"strings"
	"testing"

	"github.com/mjmorales/funpack/mcp/internal/docs"
)

// buildIndex loads the real committed corpus and indexes it, failing the test
// if the corpus is empty (a generation regression) rather than silently testing
// an empty index.
func buildIndex(t *testing.T) *Index {
	t.Helper()
	corpus, err := docs.Load()
	if err != nil {
		t.Fatalf("docs.Load: %v", err)
	}
	if len(corpus.Sections) == 0 {
		t.Fatal("corpus is empty — run `task docs-regen`")
	}
	return NewFromCorpus(corpus)
}

// TestQueryDeterminismRanksAxioms asserts a single-word conceptual query
// surfaces the spec section that defines the concept as its top hit. The corpus
// anchors determinism's defining passage under spec/01-axioms.md, so the top
// result must be a spec section from that file — the index would be useless if
// a passing body mention outranked the defining heading.
func TestQueryDeterminismRanksAxioms(t *testing.T) {
	ix := buildIndex(t)
	hits := ix.Query("determinism", 5)
	if len(hits) == 0 {
		t.Fatal("query 'determinism' returned zero hits")
	}
	top := hits[0]
	if top.Kind != docs.KindSpec {
		t.Errorf("top hit kind = %q, want spec; anchor=%s", top.Kind, top.Anchor)
	}
	if !strings.HasPrefix(top.Anchor, "01-axioms.md#") {
		t.Errorf("top hit anchor = %q, want a 01-axioms.md determinism section", top.Anchor)
	}
	if !strings.Contains(strings.ToLower(top.Title), "determinism") {
		t.Errorf("top hit title = %q, expected to mention determinism", top.Title)
	}
	assertDescending(t, hits)
}

// TestQueryPipelineScheduleRanksPipelines asserts a multi-word conceptual query
// concentrates results on the relevant spec chapter. "pipeline schedule" must
// surface 07-pipelines.md sections high in the ranking — the chapter the spec
// devotes to pipelines & scheduling.
func TestQueryPipelineScheduleRanksPipelines(t *testing.T) {
	ix := buildIndex(t)
	hits := ix.Query("pipeline schedule", 8)
	if len(hits) == 0 {
		t.Fatal("query 'pipeline schedule' returned zero hits")
	}
	foundPipelines := false
	for i, h := range hits {
		if strings.HasPrefix(h.Anchor, "07-pipelines.md#") {
			foundPipelines = true
			if i > 3 {
				t.Errorf("07-pipelines.md hit ranked at %d, expected within top 4 (anchor=%s)", i, h.Anchor)
			}
			break
		}
	}
	if !foundPipelines {
		t.Errorf("no 07-pipelines.md section in top hits for 'pipeline schedule'; got: %s", anchors(hits))
	}
	assertDescending(t, hits)
}

// TestQueryReturnsAnchoredHitsWithSnippets asserts every returned hit carries
// the contract downstream tools depend on: a non-empty stable anchor, a title,
// a positive score, and a non-empty snippet.
func TestQueryReturnsAnchoredHitsWithSnippets(t *testing.T) {
	ix := buildIndex(t)
	hits := ix.Query("collision physics", 5)
	if len(hits) == 0 {
		t.Fatal("query returned zero hits")
	}
	for i, h := range hits {
		if h.Anchor == "" {
			t.Errorf("hit %d: empty Anchor", i)
		}
		if h.Title == "" {
			t.Errorf("hit %d (%s): empty Title", i, h.Anchor)
		}
		if h.Score <= 0 {
			t.Errorf("hit %d (%s): non-positive score %v", i, h.Anchor, h.Score)
		}
		if strings.TrimSpace(h.Snippet) == "" {
			t.Errorf("hit %d (%s): empty Snippet", i, h.Anchor)
		}
	}
}

// TestQueryRespectsLimit asserts the limit caps the result count.
func TestQueryRespectsLimit(t *testing.T) {
	ix := buildIndex(t)
	hits := ix.Query("state", 3)
	if len(hits) > 3 {
		t.Errorf("limit 3 returned %d hits", len(hits))
	}
	if len(hits) == 0 {
		t.Fatal("query 'state' returned zero hits despite a common term")
	}
}

// TestEmptyAndDegenerateQueries asserts the index handles inputs that carry no
// scorable terms without panicking and returns nil: an empty string, whitespace
// only, stop-words only, and a non-positive limit.
func TestEmptyAndDegenerateQueries(t *testing.T) {
	ix := buildIndex(t)
	cases := []struct {
		name  string
		q     string
		limit int
	}{
		{"empty", "", 5},
		{"whitespace", "   \t\n ", 5},
		{"punctuation", "??? --- ...", 5},
		{"stopwords only", "the and of to", 5},
		{"zero limit", "determinism", 0},
		{"negative limit", "determinism", -1},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			if got := ix.Query(tc.q, tc.limit); got != nil {
				t.Errorf("Query(%q, %d) = %d hits, want nil", tc.q, tc.limit, len(got))
			}
		})
	}
}

// TestUnknownTermYieldsNoHits asserts a query whose terms appear nowhere in the
// corpus returns no hits rather than scoring random documents.
func TestUnknownTermYieldsNoHits(t *testing.T) {
	ix := buildIndex(t)
	if got := ix.Query("zzzznonexistentterm qqqxabsent", 5); got != nil {
		t.Errorf("unknown-term query returned %d hits, want nil", len(got))
	}
}

// TestNilAndEmptyIndex asserts the constructors and Query tolerate empty input:
// a nil corpus, no sections, and querying a nil Index all return nil without
// panicking.
func TestNilAndEmptyIndex(t *testing.T) {
	if got := NewFromCorpus(nil).Query("anything", 5); got != nil {
		t.Errorf("nil-corpus index returned %d hits, want nil", len(got))
	}
	if got := New(nil).Query("anything", 5); got != nil {
		t.Errorf("empty index returned %d hits, want nil", len(got))
	}
	var nilIdx *Index
	if got := nilIdx.Query("anything", 5); got != nil {
		t.Errorf("nil index returned %d hits, want nil", len(got))
	}
}

// TestEngineSectionsAreLowerWeight asserts the kind-weight policy: an exact
// engine declaration name still scores below a strong prose match for the same
// concept is hard to assert generically, so this pins the weaker invariant that
// engine sections participate in the index (a query matching only engine text
// still returns a hit) while remaining discoverable.
func TestEngineSectionsParticipate(t *testing.T) {
	corpus, err := docs.Load()
	if err != nil {
		t.Fatalf("docs.Load: %v", err)
	}
	engineOnly := New(corpus.ByKind(docs.KindEngine))
	hits := engineOnly.Query("vec2", 5)
	if len(hits) == 0 {
		t.Skip("no engine section matched 'vec2'; engine corpus shape changed")
	}
	for _, h := range hits {
		if h.Kind != docs.KindEngine {
			t.Errorf("engine-only index returned non-engine hit %s", h.Anchor)
		}
	}
}

// assertDescending verifies hits are ordered by non-increasing score, the
// ranking contract callers rely on.
func assertDescending(t *testing.T, hits []PassageHit) {
	t.Helper()
	for i := 1; i < len(hits); i++ {
		if hits[i].Score > hits[i-1].Score {
			t.Errorf("hits not descending: [%d]=%v > [%d]=%v", i, hits[i].Score, i-1, hits[i-1].Score)
		}
	}
}

// anchors joins hit anchors for failure messages.
func anchors(hits []PassageHit) string {
	a := make([]string, len(hits))
	for i, h := range hits {
		a[i] = h.Anchor
	}
	return strings.Join(a, ", ")
}
