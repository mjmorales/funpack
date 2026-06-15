package symbols

import (
	"sort"
	"strings"
)

// Match-strength tiers. Scores are bucketed by match kind so an exact hit always
// outranks any fuzzy hit regardless of name length, with the fuzzy similarity
// breaking ties only inside the fuzzy bucket. The gaps are wide on purpose:
// no fuzzy similarity (in [0,1]) can lift a fuzzy hit into the substring band.
const (
	scoreExact     = 1000.0
	scoreAlias     = 900.0
	scorePrefix    = 700.0
	scoreSubstring = 500.0
	scoreFuzzyBase = 0.0
	// scoreFuzzySpan scales similarity into the fuzzy band; a perfect-similarity
	// fuzzy hit tops out below scoreSubstring.
	scoreFuzzySpan = 400.0
	// fuzzyFloor is the minimum normalized similarity a fuzzy candidate must
	// reach to be reported at all — below it the match is noise.
	fuzzyFloor = 0.34
)

// Lookup resolves a query to its ranked symbol hits, exact-name matches first
// and fuzzy matches last. It is pure: no I/O, no mutation of the table, so the
// same query against the same table always returns the same ordering.
//
// Ranking, strongest first:
//
//  1. exact — query equals a symbol's canonical Name (case-insensitive)
//  2. alias — query equals an engine symbol's bare decl alias ("resolve" for
//     "world.resolve")
//  3. prefix — a symbol Name starts with the query
//  4. substring — a symbol Name contains the query
//  5. fuzzy — normalized edit-distance similarity at or above [fuzzyFloor]
//
// Within a tier, higher similarity wins, then shorter name, then lexical Name —
// a total order, so ties are never resolved arbitrarily. A symbol contributes at
// most once, at its strongest tier. An empty or whitespace query returns nil.
func (t *SymbolTable) Lookup(query string) []SymbolHit {
	q := strings.TrimSpace(query)
	if q == "" {
		return nil
	}
	ql := strings.ToLower(q)

	// best[i] holds the strongest scoring seen for symbol i this call, so each
	// symbol surfaces once at its best tier rather than once per match path.
	best := make(map[int]SymbolHit, len(t.symbols))
	consider := func(idx int, score float64, kind string) {
		if cur, ok := best[idx]; ok && cur.Score >= score {
			return
		}
		best[idx] = SymbolHit{Symbol: t.symbols[idx], Score: score, MatchKind: kind}
	}

	// Exact / alias: direct key hits. A key may fan out to several symbols.
	for _, idx := range t.byName[ql] {
		s := t.symbols[idx]
		if strings.EqualFold(s.Name, q) {
			consider(idx, scoreExact, "exact")
		} else {
			consider(idx, scoreAlias, "alias")
		}
	}

	// Prefix / substring / fuzzy: scan every symbol once.
	for idx := range t.symbols {
		nameLower := strings.ToLower(t.symbols[idx].Name)
		switch {
		case nameLower == ql:
			// already handled by the exact pass
		case strings.HasPrefix(nameLower, ql):
			consider(idx, scorePrefix-lengthPenalty(nameLower, ql), "prefix")
		case strings.Contains(nameLower, ql):
			consider(idx, scoreSubstring-lengthPenalty(nameLower, ql), "substring")
		default:
			if sim := similarity(ql, nameLower); sim >= fuzzyFloor {
				consider(idx, scoreFuzzyBase+sim*scoreFuzzySpan, "fuzzy")
			}
		}
	}

	hits := make([]SymbolHit, 0, len(best))
	for _, h := range best {
		hits = append(hits, h)
	}
	sort.SliceStable(hits, func(i, j int) bool {
		if hits[i].Score != hits[j].Score {
			return hits[i].Score > hits[j].Score
		}
		if len(hits[i].Symbol.Name) != len(hits[j].Symbol.Name) {
			return len(hits[i].Symbol.Name) < len(hits[j].Symbol.Name)
		}
		return hits[i].Symbol.Name < hits[j].Symbol.Name
	})
	return hits
}

// lengthPenalty nudges shorter, tighter prefix/substring matches above looser
// ones of the same tier without crossing tier boundaries. It is the fraction of
// the name the query does NOT cover, scaled to stay under the inter-tier gap.
func lengthPenalty(name, query string) float64 {
	if len(name) == 0 {
		return 0
	}
	uncovered := float64(len(name)-len(query)) / float64(len(name))
	return uncovered * 50.0
}

// similarity returns a normalized [0,1] closeness between two lowercased strings
// from their Levenshtein edit distance: 1 - dist/max(len). It is the fuzzy rank
// key — a single misspelling of an N-char name scores ~1-1/N, comfortably above
// [fuzzyFloor] for any real symbol name, while an unrelated string falls below it.
func similarity(a, b string) float64 {
	if a == b {
		return 1
	}
	la, lb := len(a), len(b)
	if la == 0 || lb == 0 {
		return 0
	}
	dist := levenshtein(a, b)
	longest := la
	if lb > longest {
		longest = lb
	}
	return 1 - float64(dist)/float64(longest)
}

// levenshtein computes the edit distance between two strings with a rolling
// two-row DP — O(len(a)*len(b)) time, O(min) space. Pure stdlib; no dependency
// is warranted for a table of a few hundred short names.
func levenshtein(a, b string) int {
	ra, rb := []rune(a), []rune(b)
	if len(ra) < len(rb) {
		ra, rb = rb, ra
	}
	prev := make([]int, len(rb)+1)
	curr := make([]int, len(rb)+1)
	for j := range prev {
		prev[j] = j
	}
	for i := 1; i <= len(ra); i++ {
		curr[0] = i
		for j := 1; j <= len(rb); j++ {
			cost := 1
			if ra[i-1] == rb[j-1] {
				cost = 0
			}
			curr[j] = min3(prev[j]+1, curr[j-1]+1, prev[j-1]+cost)
		}
		prev, curr = curr, prev
	}
	return prev[len(rb)]
}

func min3(a, b, c int) int {
	m := a
	if b < m {
		m = b
	}
	if c < m {
		m = c
	}
	return m
}
