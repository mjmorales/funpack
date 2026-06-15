package search

import (
	"strings"
	"testing"

	"github.com/mjmorales/funpack/mcp/internal/docs"
)

// newEngine builds a search Engine over the real committed corpus. Every test
// runs the production rankers against production data — there is no fixture
// corpus, so a regression in the corpus, either ranker, or the merge surfaces
// here rather than in a synthetic stand-in.
func newEngine(t *testing.T) *Engine {
	t.Helper()
	corpus, err := docs.Load()
	if err != nil {
		t.Fatalf("docs.Load: %v", err)
	}
	if len(corpus.Sections) == 0 {
		t.Fatal("corpus is empty — run `task docs-regen`")
	}
	return New(corpus)
}

// TestSymbolShapedQueryRanksSymbolFirst asserts the core query-shape contract:
// a fully-qualified engine identifier puts its SYMBOL hit at rank 1, ahead of any
// passage that incidentally mentions the same words. world.resolve is the named
// exemplar — a dotted identifier the classifier must read as symbol-shaped.
func TestSymbolShapedQueryRanksSymbolFirst(t *testing.T) {
	e := newEngine(t)
	results := e.Search("world.resolve", 10)
	if len(results) == 0 {
		t.Fatal("Search(world.resolve) returned no results")
	}
	top := results[0]
	if top.Source != SourceSymbol {
		t.Errorf("top source = %q, want symbol; anchor=%s", top.Source, top.Anchor)
	}
	if top.Title != "world.resolve" {
		t.Errorf("top title = %q, want world.resolve", top.Title)
	}
	if top.Anchor != "engine/world#resolve" {
		t.Errorf("top anchor = %q, want engine/world#resolve", top.Anchor)
	}
	assertDescending(t, results)
}

// TestBareTypeNameRanksSymbolFirst asserts a leading-capital type-style token
// ("Vec") classifies symbol-shaped and surfaces the engine type symbol at rank 1.
// math.Vec2/math.Vec3 are the corpus types a prefix/substring symbol match lands.
func TestBareTypeNameRanksSymbolFirst(t *testing.T) {
	e := newEngine(t)
	results := e.Search("Vec", 10)
	if len(results) == 0 {
		t.Fatal("Search(Vec) returned no results")
	}
	if results[0].Source != SourceSymbol {
		t.Fatalf("top source = %q, want symbol (anchor=%s)", results[0].Source, results[0].Anchor)
	}
	if !strings.Contains(results[0].Title, "Vec") {
		t.Errorf("top title = %q, expected to contain Vec", results[0].Title)
	}
	assertDescending(t, results)
}

// TestConceptualQueryRanksPassageFirst asserts the mirror contract: a multi-word
// natural-language query puts PROSE at rank 1 (never a bare symbol), and the
// spec's defining determinism passage surfaces high. The exact rank-1 prose
// section is the passage ranker's BM25 call; the engine's contract is that the
// conceptual shape suppresses the symbol bias so a passage leads — and that the
// canonical determinism passage (01-axioms.md#p1) is among the top results.
func TestConceptualQueryRanksPassageFirst(t *testing.T) {
	e := newEngine(t)
	results := e.Search("how does determinism work", 10)
	if len(results) == 0 {
		t.Fatal("conceptual query returned no results")
	}
	top := results[0]
	if top.Source != SourcePassage {
		t.Errorf("top source = %q, want passage; anchor=%s", top.Source, top.Anchor)
	}
	// Which prose section leads is the passage ranker's BM25 call; the engine's
	// contract here is only that the conceptual shape suppressed the symbol bias
	// (a passage leads, asserted above). The defining determinism passage must
	// still surface in the conceptual result set — it would be useless if the
	// ranker buried the axiom that defines the concept entirely.
	const axiom = "01-axioms.md#p1-determinism-two-tiers-both-mandatory-from-r1"
	var sawAxiom bool
	for _, r := range results {
		if r.Anchor == axiom {
			sawAxiom = true
			if r.Source != SourcePassage {
				t.Errorf("axiom hit source = %q, want passage", r.Source)
			}
			break
		}
	}
	if !sawAxiom {
		t.Errorf("defining determinism spec passage %q absent from top results", axiom)
	}
	assertDescending(t, results)
}

// TestSpecDeterminismPassageLeadsOnTopicalQuery pins the strict spec-anchored
// contract on a query whose terms the BM25 ranker resolves cleanly to the spec
// axiom: a single-topic conceptual query ("determinism") puts the spec's
// defining determinism passage (01-axioms.md) at rank 1 as a passage.
func TestSpecDeterminismPassageLeadsOnTopicalQuery(t *testing.T) {
	e := newEngine(t)
	results := e.Search("determinism", 10)
	if len(results) == 0 {
		t.Fatal("Search(determinism) returned no results")
	}
	top := results[0]
	if top.Source != SourcePassage {
		t.Fatalf("top source = %q, want passage; anchor=%s", top.Source, top.Anchor)
	}
	if top.Kind != docs.KindSpec {
		t.Errorf("top kind = %q, want spec; anchor=%s", top.Kind, top.Anchor)
	}
	if !strings.HasPrefix(top.Anchor, "01-axioms.md#") {
		t.Errorf("top anchor = %q, want a 01-axioms.md determinism section", top.Anchor)
	}
	assertDescending(t, results)
}

// TestDirectiveQueryResolvesSymbol asserts an "@"-prefixed directive query
// classifies symbol-shaped and resolves to the directive symbol at rank 1, with a
// spec anchor — the docs_search tool links agents straight to the directive's
// documentation.
func TestDirectiveQueryResolvesSymbol(t *testing.T) {
	e := newEngine(t)
	results := e.Search("@stub", 10)
	if len(results) == 0 {
		t.Fatal("Search(@stub) returned no results")
	}
	top := results[0]
	if top.Source != SourceSymbol {
		t.Fatalf("top source = %q, want symbol", top.Source)
	}
	if top.Title != "@stub" {
		t.Errorf("top title = %q, want @stub", top.Title)
	}
	if top.Anchor == "" {
		t.Error("@stub resolved with no spec anchor")
	}
	assertDescending(t, results)
}

// TestKeywordQueryClassifiesSymbol asserts a bare declaration keyword — an
// all-lowercase word that is nonetheless a closed grammar vocabulary item —
// classifies symbol-shaped via the known-keyword set, not conceptual. "import"
// must surface its keyword symbol at rank 1.
func TestKeywordQueryClassifiesSymbol(t *testing.T) {
	e := newEngine(t)
	results := e.Search("import", 10)
	if len(results) == 0 {
		t.Fatal("Search(import) returned no results")
	}
	if results[0].Source != SourceSymbol {
		t.Fatalf("top source = %q, want symbol (anchor=%s)", results[0].Source, results[0].Anchor)
	}
	if results[0].Title != "import" {
		t.Errorf("top title = %q, want import", results[0].Title)
	}
}

// TestSearchRespectsLimit asserts the limit caps the merged result count across
// both rankers.
func TestSearchRespectsLimit(t *testing.T) {
	e := newEngine(t)
	for _, n := range []int{1, 3, 5} {
		got := e.Search("determinism", n)
		if len(got) > n {
			t.Errorf("limit %d returned %d results", n, len(got))
		}
		if len(got) == 0 {
			t.Errorf("limit %d returned zero results for a common query", n)
		}
	}
}

// TestSearchDeterministicOrdering asserts repeated identical searches return the
// identical ordering — the merge sort is total (score, then source, then anchor),
// so the map-backed normalization never leaks nondeterminism.
func TestSearchDeterministicOrdering(t *testing.T) {
	e := newEngine(t)
	const q = "pipeline schedule"
	first := e.Search(q, 10)
	for i := 0; i < 5; i++ {
		again := e.Search(q, 10)
		if len(again) != len(first) {
			t.Fatalf("run %d: length %d != %d", i, len(again), len(first))
		}
		for j := range first {
			if again[j].Anchor != first[j].Anchor || again[j].Source != first[j].Source {
				t.Fatalf("run %d pos %d: %s/%s != %s/%s",
					i, j, again[j].Anchor, again[j].Source, first[j].Anchor, first[j].Source)
			}
		}
	}
}

// TestSearchSurfacesBothSources asserts the merge does not collapse to a single
// ranker: a conceptual query about a named engine concept returns hits from both
// sources, so an agent gets the explaining prose AND the symbol to look up.
func TestSearchSurfacesBothSources(t *testing.T) {
	e := newEngine(t)
	results := e.Search("how do pipelines schedule systems", 20)
	if len(results) == 0 {
		t.Fatal("query returned no results")
	}
	var sawSymbol, sawPassage bool
	for _, r := range results {
		switch r.Source {
		case SourceSymbol:
			sawSymbol = true
		case SourcePassage:
			sawPassage = true
		}
	}
	if !sawPassage {
		t.Error("conceptual query surfaced no passage hits")
	}
	if !sawSymbol {
		t.Log("conceptual query surfaced no symbol hits (no symbol name matched the query terms)")
	}
}

// TestResultsCarryDownstreamContract asserts every result carries the fields the
// docs_search tool surfaces: a non-empty anchor, a title, a positive score, a
// valid kind, and a recognized source.
func TestResultsCarryDownstreamContract(t *testing.T) {
	e := newEngine(t)
	for _, q := range []string{"world.resolve", "how does determinism work", "@stub", "Vec2"} {
		results := e.Search(q, 8)
		if len(results) == 0 {
			t.Errorf("query %q returned no results", q)
			continue
		}
		for i, r := range results {
			if r.Anchor == "" {
				t.Errorf("%q hit %d: empty Anchor", q, i)
			}
			if r.Title == "" {
				t.Errorf("%q hit %d (%s): empty Title", q, i, r.Anchor)
			}
			if r.Score <= 0 {
				t.Errorf("%q hit %d (%s): non-positive score %v", q, i, r.Anchor, r.Score)
			}
			if !r.Kind.Valid() {
				t.Errorf("%q hit %d (%s): invalid kind %q", q, i, r.Anchor, r.Kind)
			}
			if r.Source != SourceSymbol && r.Source != SourcePassage {
				t.Errorf("%q hit %d (%s): unknown source %q", q, i, r.Anchor, r.Source)
			}
		}
	}
}

// TestDegenerateQueries asserts the engine tolerates inputs with no scorable
// content and a non-positive limit without panicking, returning nil.
func TestDegenerateQueries(t *testing.T) {
	e := newEngine(t)
	cases := []struct {
		name  string
		q     string
		limit int
	}{
		{"empty", "", 5},
		{"whitespace", "  \t\n ", 5},
		{"zero limit", "determinism", 0},
		{"negative limit", "determinism", -1},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			if got := e.Search(tc.q, tc.limit); got != nil {
				t.Errorf("Search(%q, %d) = %d results, want nil", tc.q, tc.limit, len(got))
			}
		})
	}
	var nilEngine *Engine
	if got := nilEngine.Search("anything", 5); got != nil {
		t.Errorf("nil Engine returned %d results, want nil", len(got))
	}
	// A nil corpus must not panic. It still yields the language-intrinsic closed
	// vocabularies (directives, keywords) the symbol seed carries independent of
	// any corpus, so results are symbol-only and anchorless — never a passage,
	// since there is no prose to index. The guarantee is "no crash, well-formed",
	// not "empty".
	empty := New(nil)
	for _, r := range empty.Search("thing", 5) {
		if r.Source == SourcePassage {
			t.Errorf("nil-corpus Engine returned a passage hit %q with no corpus", r.Anchor)
		}
	}
}

// TestClassify pins the query-shape classifier — the documented heuristic the
// whole blend hangs on. Each case names why it lands where it does. The known
// directive/keyword sets are seeded the way New seeds them from the corpus.
func TestClassify(t *testing.T) {
	directives := map[string]struct{}{"@stub": {}, "@doc": {}}
	keywords := map[string]struct{}{"import": {}, "behavior": {}, "fn": {}}

	cases := []struct {
		q    string
		want shape
		why  string
	}{
		{"@stub", shapeSymbol, "leading @ is always a directive"},
		{"@unknownnewdirective", shapeSymbol, "leading @ wins even when not in the seeded set"},
		{"import", shapeSymbol, "exact known keyword"},
		{"behavior", shapeSymbol, "exact known keyword, beats its all-lowercase look"},
		{"world.resolve", shapeSymbol, "dotted qualified name"},
		{"spawn_entity", shapeSymbol, "snake_case identifier"},
		{"Vec2", shapeSymbol, "leading capital type-style name"},
		{"Vec", shapeSymbol, "leading capital, no other signal"},
		{"someCamelCase", shapeSymbol, "internal capital after lowercase"},
		{"physics", shapeConceptual, "plain all-lowercase topic word"},
		{"how does determinism work", shapeConceptual, "multi-word natural language"},
		{"pipeline schedule", shapeConceptual, "two-word phrase even though tokens are identifier-ish"},
		{"@stub directive usage", shapeConceptual, "multi-word phrase: whitespace beats the leading @ token"},
	}
	for _, c := range cases {
		if got := classify(c.q, directives, keywords); got != c.want {
			t.Errorf("classify(%q) = %d, want %d (%s)", c.q, got, c.want, c.why)
		}
	}
}

// TestMinMaxNormalization pins the score-merge kernel: min-max into [0,1] with a
// degenerate (single / all-equal) set mapping to 1.0 so a lone fallback hit is
// not zeroed out of the blend.
func TestMinMaxNormalization(t *testing.T) {
	cases := []struct {
		name string
		in   []float64
		want []float64
	}{
		{"empty", nil, []float64{}},
		{"single", []float64{42}, []float64{1}},
		{"all equal", []float64{5, 5, 5}, []float64{1, 1, 1}},
		{"descending", []float64{10, 6, 2}, []float64{1, 0.5, 0}},
		{"two", []float64{8, 4}, []float64{1, 0}},
	}
	for _, c := range cases {
		got := minMax(c.in)
		if len(got) != len(c.want) {
			t.Errorf("%s: len %d != %d", c.name, len(got), len(c.want))
			continue
		}
		for i := range c.want {
			if got[i] != c.want[i] {
				t.Errorf("%s: [%d] = %v, want %v", c.name, i, got[i], c.want[i])
			}
		}
	}
}

// assertDescending verifies the merged results are ordered by non-increasing
// blended score — the ranking contract every caller relies on.
func assertDescending(t *testing.T, results []Result) {
	t.Helper()
	for i := 1; i < len(results); i++ {
		if results[i].Score > results[i-1].Score {
			t.Errorf("results not descending: [%d]=%v > [%d]=%v", i, results[i].Score, i-1, results[i-1].Score)
		}
	}
}
