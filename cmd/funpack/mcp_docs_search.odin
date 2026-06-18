// The unified docs-search ranker. It fuses the symbol half (Symbol_Table) and
// the prose half (Passage_Index) of the funpack docs index into ONE ranked result
// list, choosing the blend by the SHAPE of the query.
//
// Two rankers, two query intents. A symbol-shaped query — an identifier or
// signature fragment like "world.resolve", "@stub", "Vec", a dotted/camel/snake
// token, or a known directive/keyword — wants the declaration it names, so the
// engine ranks SYMBOL hits first and folds passages in as fallback. A conceptual
// query — multi-word natural language like "how does determinism work" — wants the
// prose that explains the idea, so the engine ranks PASSAGE hits first while still
// surfacing a strong symbol hit. search_classify decides which intent a query
// carries; search_engine_search blends the two normalized rankings under that
// intent's bias.
//
// WHY normalize before blending: the symbol ranker scores in wide bucketed bands
// (exact ~1000 down to fuzzy ~0) while the passage ranker scores in small BM25
// floats (single digits). Blended raw, the symbol scale would always dominate by
// sheer magnitude regardless of intent. So each ranker's scores are min-max
// normalized into [0,1] within the result set first, then a per-source intent
// weight tilts the merge — never raw scale.
//
// WHY a custom blend and not a core: facility: the query-shape classifier and the
// normalize-then-blend merge are bespoke to this index — Odin core ships nothing
// equivalent, so this is the Odin-first answer built on core:strings/slice/unicode.
//
// Search_Engine builds both indices once from a corpus and is immutable
// thereafter; search_engine_search is pure (no I/O, no mutation) and produces a
// deterministic order for a given corpus and query.
package main

import "core:slice"
import "core:strings"
import "core:unicode"
import "core:unicode/utf8"

// Search_Source is the closed set of result origins: which underlying ranker
// produced a hit. A consumer (the docs_search tool) can present or filter on it.
Search_Source :: enum {
	Symbol,
	Passage,
}

// search_source_label is the lowercase wire token for a source, mirroring the Go
// Source string values ("symbol"/"passage").
search_source_label :: proc(s: Search_Source) -> string {
	switch s {
	case .Symbol:
		return "symbol"
	case .Passage:
		return "passage"
	}
	return ""
}

// Search_Result is one unified ranked hit, source-tagged so a caller knows whether
// it resolved a named symbol or a prose passage. score is the blended, normalized
// rank key (higher ranks earlier), only comparable within one
// search_engine_search call. anchor is the stable corpus anchor a tool re-resolves
// the hit against.
Search_Result :: struct {
	anchor:  string,
	title:   string,
	// kind is the corpus source category the hit's section belongs to (CORPUS_KIND_*).
	kind:    string,
	score:   f64,
	// snippet is the matching prose for a passage hit, or the symbol's one-line
	// signature for a symbol hit.
	snippet: string,
	source:  Search_Source,
}

// Search_Engine fuses the symbol and passage rankers into one query-shape-aware
// search. Build it once with search_engine_build; search_engine_search never
// mutates it. All storage is owned by the build allocator.
Search_Engine :: struct {
	symbols:    Symbol_Table,
	passages:   Passage_Index,
	// directives / keywords seed the classifier's known-name sets from the symbol
	// table's closed families, so an exact directive/keyword query is recognized as
	// symbol-shaped even when it carries no other identifier signal.
	directives: map[string]bool,
	keywords:   map[string]bool,
	// built records whether a corpus was supplied — a nil/empty corpus still yields
	// a usable engine (the closed vocabularies seed independent of any prose).
	built:      bool,
}

// SEARCH_CANDIDATE_POOL bounds how many hits each ranker contributes before the
// merge. It is generous relative to any realistic limit so the bias re-ranking has
// room to reorder, while keeping the merge O(pool log pool) rather than corpus-wide.
SEARCH_CANDIDATE_POOL :: 50

// Search_Shape is the classified intent of a query: symbol-shaped or conceptual.
Search_Shape :: enum {
	Symbol,
	Conceptual,
}

// Search_Blend holds the per-source score weights for one query shape. The
// dominant source keeps its full normalized score; the fallback is attenuated so a
// strong fallback hit still surfaces but does not outrank a comparable dominant hit.
Search_Blend :: struct {
	symbol:  f64,
	passage: f64,
}

// search_blend_for maps a classified shape to its source weights. A symbol-shaped
// query weights symbols full and passages as a 0.6 fallback; a conceptual query
// mirrors it. The fallback weight is high enough that a clearly stronger fallback
// hit can still lead, low enough that ties resolve toward the query's intent.
search_blend_for :: proc(s: Search_Shape) -> Search_Blend {
	switch s {
	case .Symbol:
		return Search_Blend{symbol = 1.0, passage = 0.6}
	case .Conceptual:
		return Search_Blend{symbol = 0.6, passage = 1.0}
	}
	return Search_Blend{symbol = 0.6, passage = 1.0}
}

// search_engine_build builds an engine over a corpus, constructing both underlying
// indices once. It is total over any well-formed corpus: a missing source family
// yields the corresponding ranker empty, never an error. An empty section slice
// produces an engine whose search returns symbol-only hits (the closed
// vocabularies seed independent of prose). All storage is owned by `allocator`.
search_engine_build :: proc(sections: []Corpus_Section, allocator := context.allocator) -> Search_Engine {
	e := Search_Engine {
		symbols    = symbol_table_build(sections, allocator),
		passages   = passage_index_build(sections, allocator),
		directives = make(map[string]bool, 0, allocator),
		keywords   = make(map[string]bool, 0, allocator),
		built      = true,
	}
	// Seed the classifier's known-name sets from the symbol table's closed families
	// so an exact directive/keyword query is recognized as symbol-shaped even when
	// it carries no other identifier signal (e.g. "import", "@doc").
	for s in e.symbols.symbols {
		#partial switch s.category {
		case .Directive:
			e.directives[strings.to_lower(s.name, allocator)] = true
		case .Keyword:
			e.keywords[strings.to_lower(s.name, allocator)] = true
		}
	}
	return e
}

// search_engine_search resolves a query to a unified, best-first ranked result
// list, blending the symbol and passage rankers by the query's classified shape.
// It returns up to limit results. An unbuilt engine, an empty/whitespace query, or
// a limit <= 0 yields nil. Ordering is deterministic for a fixed corpus and query:
// ties break on source (symbol before passage) then anchor. Results are allocated
// in `allocator`.
search_engine_search :: proc(
	e: ^Search_Engine,
	query: string,
	limit: int,
	allocator := context.allocator,
) -> []Search_Result {
	if e == nil || !e.built || limit <= 0 {
		return nil
	}
	q := strings.trim_space(query)
	if q == "" {
		return nil
	}

	weights := search_blend_for(search_classify(q, e.directives, e.keywords))

	sym_hits := symbol_table_lookup(&e.symbols, q, allocator)
	if len(sym_hits) > SEARCH_CANDIDATE_POOL {
		sym_hits = sym_hits[:SEARCH_CANDIDATE_POOL]
	}
	pass_hits := passage_index_query(&e.passages, q, SEARCH_CANDIDATE_POOL, allocator)

	// Normalize each ranker's scores into [0,1] independently, then apply the
	// shape-driven source weight. Normalizing per ranker is what lets the two
	// incomparable score scales (bucketed symbol bands vs small BM25 floats) be
	// merged without one dominating by raw magnitude.
	sym_scores := search_normalize_symbol(sym_hits, allocator)
	pass_scores := search_normalize_passage(pass_hits, allocator)

	results := make([dynamic]Search_Result, 0, len(sym_hits) + len(pass_hits), allocator)
	for h, i in sym_hits {
		append(
			&results,
			Search_Result {
				anchor = h.symbol.anchor,
				title = h.symbol.name,
				kind = search_kind_for_category(h.symbol.category),
				score = sym_scores[i] * weights.symbol,
				snippet = h.symbol.signature,
				source = .Symbol,
			},
		)
	}
	for h, i in pass_hits {
		append(
			&results,
			Search_Result {
				anchor = h.anchor,
				title = h.title,
				kind = h.kind,
				score = pass_scores[i] * weights.passage,
				snippet = h.snippet,
				source = .Passage,
			},
		)
	}

	slice.sort_by(results[:], proc(a, b: Search_Result) -> bool {
		if a.score != b.score {
			return a.score > b.score
		}
		// Deterministic tie-break: symbol before passage, then by anchor. A symbol
		// hit and a passage hit can share an anchor (a directive resolves to the same
		// spec section a passage indexes), so source orders first.
		if a.source != b.source {
			return a.source == .Symbol
		}
		return a.anchor < b.anchor
	})

	out := results[:]
	if len(out) > limit {
		out = out[:limit]
	}
	return out
}

// search_normalize_symbol min-max scales symbol hit scores into [0,1], preserving
// the ranker's order. A single hit, or an all-equal set, maps to 1.0. The result
// index aligns with the input hits slice. Allocated in `allocator`.
search_normalize_symbol :: proc(hits: []Symbol_Hit, allocator := context.allocator) -> []f64 {
	scores := make([]f64, len(hits), allocator)
	for h, i in hits {
		scores[i] = h.score
	}
	return search_min_max(scores, allocator)
}

// search_normalize_passage min-max scales passage hit scores into [0,1]. Same
// contract as search_normalize_symbol; the index aligns with the input hits slice.
// Allocated in `allocator`.
search_normalize_passage :: proc(hits: []Passage_Hit, allocator := context.allocator) -> []f64 {
	scores := make([]f64, len(hits), allocator)
	for h, i in hits {
		scores[i] = h.score
	}
	return search_min_max(scores, allocator)
}

// search_min_max scales a descending-ranked score slice into [0,1]: the max maps
// to 1, the min to 0, preserving relative order. A degenerate range (one element,
// or all-equal) maps every element to 1.0 — each is a top-of-its-set hit, so the
// fallback's intra-set ordering is its own rank, not an accidental zero. Allocated
// in `allocator`.
search_min_max :: proc(scores: []f64, allocator := context.allocator) -> []f64 {
	out := make([]f64, len(scores), allocator)
	if len(scores) == 0 {
		return out
	}
	lo, hi := scores[0], scores[0]
	for s in scores {
		if s < lo {
			lo = s
		}
		if s > hi {
			hi = s
		}
	}
	span := hi - lo
	if span <= 0 {
		for i in 0 ..< len(out) {
			out[i] = 1.0
		}
		return out
	}
	for s, i in scores {
		out[i] = (s - lo) / span
	}
	return out
}

// search_kind_for_category maps a symbol's category to the corpus kind its hit
// reports. Engine declarations are CORPUS_KIND_ENGINE; directives and keywords
// document spec sections, so they report CORPUS_KIND_SPEC — the kind of the section
// their anchor names.
search_kind_for_category :: proc(c: Symbol_Category) -> string {
	if c == .Engine {
		return CORPUS_KIND_ENGINE
	}
	return CORPUS_KIND_SPEC
}

// search_classify decides whether a query is symbol-shaped or conceptual. The
// heuristic, in precedence order:
//   1. A multi-token query (contains whitespace) is conceptual — natural-language
//      phrases are prose intent, even when a token is an identifier. Checked first
//      so a phrase is never mistaken for a symbol on the strength of one token.
//   2. A single-token query naming a known directive (starts with "@", or is an
//      exact directive name) or an exact declaration keyword is symbol-shaped —
//      these are the closed language vocabularies.
//   3. A single-token query carrying an identifier signal — a dot, an underscore,
//      an internal capital (camelCase), or a leading capital — is symbol-shaped.
//   4. Anything else (a single all-lowercase plain word like "physics") is
//      conceptual: it reads as a topic, and the passage ranker handles it while a
//      strong symbol hit still surfaces via the fallback weight.
//
// The bias is soft, not a gate: classify only tilts the blend weights, so a
// misclassified query still surfaces the other source's hits, just lower.
search_classify :: proc(q: string, directives, keywords: map[string]bool) -> Search_Shape {
	// Multi-token first: a phrase with whitespace is natural language, conceptual
	// even when its leading token looks like an identifier. Only single-token
	// queries reach the identifier-signal checks below.
	for r in q {
		if unicode.is_space(r) {
			return .Conceptual
		}
	}

	lower := strings.to_lower(q, context.temp_allocator)
	if strings.has_prefix(q, "@") {
		return .Symbol
	}
	if directives[lower] {
		return .Symbol
	}
	if keywords[lower] {
		return .Symbol
	}
	if search_looks_like_identifier(q) {
		return .Symbol
	}
	return .Conceptual
}

// search_looks_like_identifier reports whether a single whitespace-free token
// carries a structural identifier signal: a dot (qualified name), an underscore
// (snake), an internal capital after a lowercase (camelCase), or a leading
// uppercase (a type-style name like "Vec"). A plain all-lowercase word carries none
// and reads as a topic word, so it falls through to conceptual.
search_looks_like_identifier :: proc(tok: string) -> bool {
	if strings.contains_any(tok, "._") {
		return true
	}
	runes := utf8.string_to_runes(tok, context.temp_allocator)
	if len(runes) == 0 {
		return false
	}
	if unicode.is_upper(runes[0]) {
		return true
	}
	for i in 1 ..< len(runes) {
		if unicode.is_upper(runes[i]) && unicode.is_lower(runes[i - 1]) {
			return true
		}
	}
	return false
}
