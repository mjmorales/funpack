package symbols

import (
	"testing"

	"github.com/mjmorales/funpack/mcp/internal/docs"
)

// loadTable builds a SymbolTable from the real committed corpus. Every test
// exercises the production extractor against production data — there is no
// fixture corpus, so a regression in either the corpus or the extractor surfaces
// here rather than in a synthetic stand-in.
func loadTable(t *testing.T) *SymbolTable {
	t.Helper()
	corpus, err := docs.Load()
	if err != nil {
		t.Fatalf("docs.Load: %v", err)
	}
	tbl := Build(corpus)
	if tbl.Len() == 0 {
		t.Fatal("Build produced an empty table from a non-empty corpus")
	}
	return tbl
}

// TestBuildCoversExpectedCategories asserts the table carries the symbol
// families the corpus supplies: engine declarations, the closed directive set,
// and the declaration keywords. A category dropping to zero means the extractor
// stopped recognizing a source family — a real regression, not a degradation.
func TestBuildCoversExpectedCategories(t *testing.T) {
	tbl := loadTable(t)
	counts := tbl.CountByCategory()

	if counts[CategoryEngine] == 0 {
		t.Error("no engine symbols extracted")
	}
	if got := counts[CategoryDirective]; got != len(DirectiveNames) {
		t.Errorf("directive count = %d, want one per closed name (%d)", got, len(DirectiveNames))
	}
	if counts[CategoryKeyword] == 0 {
		t.Error("no keyword symbols extracted")
	}
	// Diagnostics are absent from the current corpus by design; the category is
	// present-but-empty so a future registry flows through without an API change.
	if counts[CategoryDiagnostic] != 0 {
		t.Logf("diagnostics now present (%d) — corpus gained a diagnostic registry", counts[CategoryDiagnostic])
	}
}

// TestEngineSymbolsCarryAnchorAndSignature asserts every engine symbol resolves
// to a real corpus anchor and a non-empty one-line signature — the fields the
// docs_search tool surfaces and links on. world.resolve is the named exemplar.
func TestEngineSymbolsCarryAnchorAndSignature(t *testing.T) {
	tbl := loadTable(t)
	var sawResolve bool
	for _, s := range tbl.Symbols() {
		if s.Category != CategoryEngine {
			continue
		}
		if s.Anchor == "" {
			t.Errorf("engine symbol %q has empty Anchor", s.Name)
		}
		if s.Signature == "" {
			t.Errorf("engine symbol %q has empty Signature", s.Name)
		}
		if s.Name == "world.resolve" {
			sawResolve = true
			if s.Anchor != "engine/world#resolve" {
				t.Errorf("world.resolve anchor = %q, want engine/world#resolve", s.Anchor)
			}
		}
	}
	if !sawResolve {
		t.Error("world.resolve not found among engine symbols")
	}
}

// TestLookupExactEngineSymbol asserts a fully-qualified engine query lands its
// exact symbol first with an exact match kind.
func TestLookupExactEngineSymbol(t *testing.T) {
	tbl := loadTable(t)
	hits := tbl.Lookup("world.resolve")
	if len(hits) == 0 {
		t.Fatal("Lookup(world.resolve) returned no hits")
	}
	top := hits[0]
	if top.Symbol.Name != "world.resolve" {
		t.Fatalf("top hit = %q, want world.resolve", top.Symbol.Name)
	}
	if top.MatchKind != "exact" {
		t.Errorf("match kind = %q, want exact", top.MatchKind)
	}
	if top.Symbol.Category != CategoryEngine {
		t.Errorf("category = %q, want engine", top.Symbol.Category)
	}
}

// TestLookupAliasResolvesBareDecl asserts a module-less engine query resolves
// via the bare-decl alias. "resolve" must reach "world.resolve" — ranked ahead
// of any incidental substring or fuzzy match for the same query.
func TestLookupAliasResolvesBareDecl(t *testing.T) {
	tbl := loadTable(t)
	hits := tbl.Lookup("resolve")
	if len(hits) == 0 {
		t.Fatal("Lookup(resolve) returned no hits")
	}
	var pos = -1
	for i, h := range hits {
		if h.Symbol.Name == "world.resolve" {
			pos = i
			if h.MatchKind != "alias" && h.MatchKind != "exact" {
				t.Errorf("world.resolve matched as %q, want alias/exact", h.MatchKind)
			}
			break
		}
	}
	if pos == -1 {
		t.Fatal("world.resolve not in hits for bare query 'resolve'")
	}
	// An alias hit must outrank any substring/fuzzy hit, so it sits at the front.
	if hits[0].MatchKind == "substring" || hits[0].MatchKind == "fuzzy" {
		t.Errorf("a substring/fuzzy hit (%q) outranked the alias hit", hits[0].Symbol.Name)
	}
}

// TestLookupFuzzyMisspellingRanksTarget asserts a single-typo query still ranks
// its intended engine symbol first. "resollve" (one inserted char) must put
// world.resolve at the top via the fuzzy path.
func TestLookupFuzzyMisspellingRanksTarget(t *testing.T) {
	tbl := loadTable(t)
	hits := tbl.Lookup("resollve")
	if len(hits) == 0 {
		t.Fatal("Lookup(resollve) returned no hits")
	}
	if hits[0].Symbol.Name != "world.resolve" {
		t.Fatalf("top fuzzy hit = %q, want world.resolve; hits=%v", hits[0].Symbol.Name, names(hits))
	}
	if hits[0].MatchKind != "fuzzy" {
		t.Errorf("match kind = %q, want fuzzy", hits[0].MatchKind)
	}
}

// TestLookupDirectiveResolves asserts a directive query resolves to its symbol
// with the directive category and a spec anchor.
func TestLookupDirectiveResolves(t *testing.T) {
	tbl := loadTable(t)
	hits := tbl.Lookup("@stub")
	if len(hits) == 0 {
		t.Fatal("Lookup(@stub) returned no hits")
	}
	top := hits[0]
	if top.Symbol.Name != "@stub" {
		t.Fatalf("top hit = %q, want @stub", top.Symbol.Name)
	}
	if top.MatchKind != "exact" {
		t.Errorf("match kind = %q, want exact", top.MatchKind)
	}
	if top.Symbol.Category != CategoryDirective {
		t.Errorf("category = %q, want directive", top.Symbol.Category)
	}
	if top.Symbol.Anchor == "" {
		t.Error("@stub resolved with no spec anchor")
	}
}

// TestLookupKeywordResolves asserts a grammar keyword query resolves to its
// keyword symbol exactly.
func TestLookupKeywordResolves(t *testing.T) {
	tbl := loadTable(t)
	hits := tbl.Lookup("behavior")
	if len(hits) == 0 {
		t.Fatal("Lookup(behavior) returned no hits")
	}
	// The keyword exact match must be the top hit (engine names like
	// "ui.behavior_*" can substring-match but rank below an exact keyword hit).
	if hits[0].Symbol.Name != "behavior" || hits[0].Symbol.Category != CategoryKeyword {
		t.Fatalf("top hit = %q/%s, want behavior/keyword", hits[0].Symbol.Name, hits[0].Symbol.Category)
	}
	if hits[0].MatchKind != "exact" {
		t.Errorf("match kind = %q, want exact", hits[0].MatchKind)
	}
}

// TestLookupEmptyQuery asserts an empty or whitespace query returns no hits
// rather than the whole table.
func TestLookupEmptyQuery(t *testing.T) {
	tbl := loadTable(t)
	for _, q := range []string{"", "   ", "\t\n"} {
		if hits := tbl.Lookup(q); len(hits) != 0 {
			t.Errorf("Lookup(%q) = %d hits, want 0", q, len(hits))
		}
	}
}

// TestLookupExactOutranksFuzzy asserts the tier ordering is total: an exact hit
// always precedes every fuzzy hit in the same result set, independent of name
// lengths.
func TestLookupExactOutranksFuzzy(t *testing.T) {
	tbl := loadTable(t)
	hits := tbl.Lookup("world.resolve")
	sawFuzzy := false
	for i, h := range hits {
		if h.MatchKind == "fuzzy" {
			sawFuzzy = true
		}
		if sawFuzzy && h.MatchKind == "exact" {
			t.Fatalf("exact hit at position %d followed a fuzzy hit", i)
		}
	}
}

// TestLevenshteinKnownDistances pins the edit-distance kernel the fuzzy ranker
// depends on; a regression here silently reshuffles every fuzzy result.
func TestLevenshteinKnownDistances(t *testing.T) {
	cases := []struct {
		a, b string
		want int
	}{
		{"", "", 0},
		{"a", "", 1},
		{"resolve", "resolve", 0},
		{"resolve", "resollve", 1},
		{"kitten", "sitting", 3},
		{"flaw", "lawn", 2},
	}
	for _, c := range cases {
		if got := levenshtein(c.a, c.b); got != c.want {
			t.Errorf("levenshtein(%q,%q) = %d, want %d", c.a, c.b, got, c.want)
		}
	}
}

func names(hits []SymbolHit) []string {
	out := make([]string, 0, len(hits))
	for i, h := range hits {
		if i >= 5 {
			break
		}
		out = append(out, h.Symbol.Name)
	}
	return out
}
