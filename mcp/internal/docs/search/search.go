// Package search is the unified docs-search ranker: it fuses the symbol half
// ([symbols.SymbolTable]) and the prose half ([passages.Index]) of the funpack
// docs index into ONE ranked result list, choosing the blend by the SHAPE of
// the query.
//
// Two rankers, two query intents. A symbol-shaped query — an identifier or
// signature fragment like "world.resolve", "@stub", "Vec", a dotted/camel/snake
// token, or a known directive/keyword — wants the declaration it names, so the
// engine ranks SYMBOL hits first and folds passages in as fallback. A conceptual
// query — multi-word natural language like "how does determinism work" — wants
// the prose that explains the idea, so the engine ranks PASSAGE hits first while
// still surfacing a strong symbol hit. The classifier ([classify]) decides which
// intent a query carries; the merge ([Engine.Search]) blends the two normalized
// rankings under that intent's bias.
//
// Why normalize before blending: the symbol ranker scores in wide bucketed bands
// (exact ~1000 down to fuzzy ~0, see the symbols package) while the passage
// ranker scores in small BM25 floats (single digits). Blended raw, the symbol
// scale would always dominate by sheer magnitude regardless of intent. So each
// ranker's scores are min-max normalized into [0,1] within the result set first,
// then a per-source intent weight ([blend]) tilts the merge — never raw scale.
//
// [Engine] builds both indices once from a corpus and is immutable thereafter;
// [Engine.Search] is pure (no I/O, no mutation), so it is safe to share across
// concurrent MCP tool invocations and produces a deterministic order for a given
// corpus and query.
package search

import (
	"sort"
	"strings"
	"unicode"

	"github.com/mjmorales/funpack/mcp/internal/docs"
	"github.com/mjmorales/funpack/mcp/internal/docs/passages"
	"github.com/mjmorales/funpack/mcp/internal/docs/symbols"
)

// Source is the closed set of result origins: which underlying ranker produced a
// hit. A consumer (the docs_search tool) can present or filter on it.
type Source string

const (
	// SourceSymbol is a hit from the symbol table — a resolved engine
	// declaration, directive, or keyword.
	SourceSymbol Source = "symbol"
	// SourcePassage is a hit from the BM25 passage index — a prose section.
	SourcePassage Source = "passage"
)

// Result is one unified ranked hit, source-tagged so a caller knows whether it
// resolved a named symbol or a prose passage. Score is the blended, normalized
// rank key: higher ranks earlier, and it is only comparable within one
// [Engine.Search] call (a relative key, not an absolute metric). Anchor is the
// stable corpus anchor a tool re-resolves the hit against.
type Result struct {
	// Anchor is the matched section's stable corpus anchor (re-resolvable).
	Anchor string
	// Title is the human-readable heading or symbol name.
	Title string
	// Kind is the corpus source category the hit's section belongs to.
	Kind docs.Kind
	// Score is the blended, normalized relative rank key; higher ranks earlier.
	Score float64
	// Snippet is a short display window: the matching prose for a passage hit,
	// or the symbol's one-line signature for a symbol hit.
	Snippet string
	// Source distinguishes a symbol hit from a passage hit.
	Source Source
}

// Engine fuses the symbol and passage rankers into one query-shape-aware search.
// Build it once with [New]; [Engine.Search] never mutates it, so it is safe to
// share across concurrent invocations. Construct only via [New] — the zero value
// is not usable.
type Engine struct {
	symbols    *symbols.SymbolTable
	passages   *passages.Index
	directives map[string]struct{}
	keywords   map[string]struct{}
}

// New builds an Engine over a corpus, constructing both underlying indices once.
// It is total over any well-formed corpus: a missing source family yields the
// corresponding ranker empty, never an error. A nil corpus produces an Engine
// whose Search returns nil — guarded here because the symbol builder dereferences
// the corpus eagerly (only the passage builder is itself nil-tolerant).
func New(c *docs.Corpus) *Engine {
	if c == nil {
		c = &docs.Corpus{}
	}
	e := &Engine{
		symbols:    symbols.Build(c),
		passages:   passages.NewFromCorpus(c),
		directives: make(map[string]struct{}),
		keywords:   make(map[string]struct{}),
	}
	// Seed the classifier's known-name sets from the symbol table's closed
	// families so an exact directive/keyword query is recognized as symbol-shaped
	// even when it carries no other identifier signal (e.g. "import", "@doc").
	for _, s := range e.symbols.Symbols() {
		switch s.Category {
		case symbols.CategoryDirective:
			e.directives[strings.ToLower(s.Name)] = struct{}{}
		case symbols.CategoryKeyword:
			e.keywords[strings.ToLower(s.Name)] = struct{}{}
		}
	}
	return e
}

// candidatePool bounds how many hits each ranker contributes before the merge.
// It is generous relative to any realistic limit so the bias re-ranking has room
// to reorder, while keeping the merge O(pool log pool) rather than corpus-wide.
const candidatePool = 50

// shape is the classified intent of a query: symbol-shaped or conceptual.
type shape int

const (
	// shapeSymbol — the query looks like an identifier/signature or names a known
	// directive/keyword; symbol hits should rank first.
	shapeSymbol shape = iota
	// shapeConceptual — the query is multi-word natural language; passages first.
	shapeConceptual
)

// blend holds the per-source score weights for one query shape. The dominant
// source keeps its full normalized score; the fallback is attenuated so a strong
// fallback hit still surfaces but does not outrank a comparable dominant hit.
type blend struct {
	symbol  float64
	passage float64
}

// blendFor maps a classified shape to its source weights. A symbol-shaped query
// weights symbols full and passages as a 0.6 fallback; a conceptual query mirrors
// it. The fallback weight is high enough that a clearly stronger fallback hit can
// still lead, low enough that ties resolve toward the query's intent.
func blendFor(s shape) blend {
	switch s {
	case shapeSymbol:
		return blend{symbol: 1.0, passage: 0.6}
	default:
		return blend{symbol: 0.6, passage: 1.0}
	}
}

// Search resolves a query to a unified, best-first ranked result list, blending
// the symbol and passage rankers by the query's classified shape. It returns up
// to limit results. An empty/whitespace query, a limit <= 0, or a nil Engine
// yields nil. Ordering is deterministic for a fixed corpus and query: ties break
// on anchor.
func (e *Engine) Search(query string, limit int) []Result {
	if e == nil || limit <= 0 {
		return nil
	}
	q := strings.TrimSpace(query)
	if q == "" {
		return nil
	}

	weights := blendFor(classify(q, e.directives, e.keywords))

	symHits := e.symbols.Lookup(q)
	if len(symHits) > candidatePool {
		symHits = symHits[:candidatePool]
	}
	passHits := e.passages.Query(q, candidatePool)

	// Normalize each ranker's scores into [0,1] independently, then apply the
	// shape-driven source weight. Normalizing per ranker is what lets the two
	// incomparable score scales (bucketed symbol bands vs small BM25 floats) be
	// merged without one dominating by raw magnitude.
	symScores := normalizeSymbol(symHits)
	passScores := normalizePassage(passHits)

	results := make([]Result, 0, len(symHits)+len(passHits))
	for i, h := range symHits {
		results = append(results, Result{
			Anchor:  h.Symbol.Anchor,
			Title:   h.Symbol.Name,
			Kind:    kindForCategory(h.Symbol.Category),
			Score:   symScores[i] * weights.symbol,
			Snippet: h.Symbol.Signature,
			Source:  SourceSymbol,
		})
	}
	for i, h := range passHits {
		results = append(results, Result{
			Anchor:  h.Anchor,
			Title:   h.Title,
			Kind:    h.Kind,
			Score:   passScores[i] * weights.passage,
			Snippet: h.Snippet,
			Source:  SourcePassage,
		})
	}

	sort.SliceStable(results, func(i, j int) bool {
		if results[i].Score != results[j].Score {
			return results[i].Score > results[j].Score
		}
		// Deterministic tie-break: symbol before passage, then by anchor. A
		// symbol hit and a passage hit can share an anchor (a directive resolves
		// to the same spec section a passage indexes), so source orders first.
		if results[i].Source != results[j].Source {
			return results[i].Source == SourceSymbol
		}
		return results[i].Anchor < results[j].Anchor
	})

	if len(results) > limit {
		results = results[:limit]
	}
	return results
}

// normalizeSymbol min-max scales symbol hit scores into [0,1], preserving the
// ranker's order. A single hit, or an all-equal set, maps to 1.0 (it is the best
// of its kind). The result index aligns with the input hits slice.
func normalizeSymbol(hits []symbols.SymbolHit) []float64 {
	scores := make([]float64, len(hits))
	for i, h := range hits {
		scores[i] = h.Score
	}
	return minMax(scores)
}

// normalizePassage min-max scales passage hit scores into [0,1]. Same contract
// as normalizeSymbol; the index aligns with the input hits slice.
func normalizePassage(hits []passages.PassageHit) []float64 {
	scores := make([]float64, len(hits))
	for i, h := range hits {
		scores[i] = h.Score
	}
	return minMax(scores)
}

// minMax scales a descending-ranked score slice into [0,1]: the max maps to 1,
// the min to 0, preserving relative order. A degenerate range (one element, or
// all-equal) maps every element to 1.0 — each is a top-of-its-set hit, so the
// fallback's intra-set ordering is its own rank, not an accidental zero.
func minMax(scores []float64) []float64 {
	out := make([]float64, len(scores))
	if len(scores) == 0 {
		return out
	}
	lo, hi := scores[0], scores[0]
	for _, s := range scores {
		if s < lo {
			lo = s
		}
		if s > hi {
			hi = s
		}
	}
	span := hi - lo
	if span <= 0 {
		for i := range out {
			out[i] = 1.0
		}
		return out
	}
	for i, s := range scores {
		out[i] = (s - lo) / span
	}
	return out
}

// kindForCategory maps a symbol's category to the corpus Kind its hit reports.
// Engine declarations are KindEngine; directives and keywords document spec
// sections, so they report KindSpec — the kind of the section their anchor names.
func kindForCategory(c symbols.Category) docs.Kind {
	if c == symbols.CategoryEngine {
		return docs.KindEngine
	}
	return docs.KindSpec
}

// classify decides whether a query is symbol-shaped or conceptual. The heuristic,
// in precedence order:
//
//  1. A multi-token query (contains whitespace) is conceptual — natural language
//     phrases are prose intent, even when a token is an identifier ("@stub
//     directive usage", "world.resolve semantics"). This is checked first so a
//     phrase is never mistaken for a symbol on the strength of one token.
//  2. A single-token query naming a known directive (starts with "@", or is an
//     exact directive name) or an exact declaration keyword is symbol-shaped —
//     these are the closed language vocabularies, and a query that IS one wants
//     that symbol.
//  3. A single-token query carrying an identifier signal — a dot, an underscore,
//     an internal capital (camelCase), or a leading capital — is symbol-shaped:
//     "world.resolve", "spawn_entity", "Vec2", "Vec".
//  4. Anything else (a single all-lowercase plain word like "physics") is
//     conceptual: it reads as a topic, and the passage ranker handles it while a
//     strong symbol hit still surfaces via the fallback weight.
//
// The bias is soft, not a gate: classify only tilts the blend weights, so a
// misclassified query still surfaces the other source's hits, just lower.
func classify(q string, directives, keywords map[string]struct{}) shape {
	// Multi-token first: a phrase with whitespace is natural language, conceptual
	// even when its leading token looks like an identifier ("@stub directive
	// usage", "world.resolve semantics"). Only single-token queries reach the
	// identifier-signal checks below.
	if strings.ContainsFunc(q, unicode.IsSpace) {
		return shapeConceptual
	}

	lower := strings.ToLower(q)
	if strings.HasPrefix(q, "@") {
		return shapeSymbol
	}
	if _, ok := directives[lower]; ok {
		return shapeSymbol
	}
	if _, ok := keywords[lower]; ok {
		return shapeSymbol
	}
	if looksLikeIdentifier(q) {
		return shapeSymbol
	}
	return shapeConceptual
}

// looksLikeIdentifier reports whether a single whitespace-free token carries a
// structural identifier signal: a dot (qualified name), an underscore (snake),
// an internal capital after a lowercase (camelCase), or a leading uppercase (a
// type-style name like "Vec"). A plain all-lowercase word carries none of these
// and reads as a topic word, so it falls through to conceptual.
func looksLikeIdentifier(tok string) bool {
	if strings.ContainsAny(tok, "._") {
		return true
	}
	runes := []rune(tok)
	if len(runes) == 0 {
		return false
	}
	if unicode.IsUpper(runes[0]) {
		return true
	}
	for i := 1; i < len(runes); i++ {
		if unicode.IsUpper(runes[i]) && unicode.IsLower(runes[i-1]) {
			return true
		}
	}
	return false
}
