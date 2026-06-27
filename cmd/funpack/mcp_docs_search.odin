package main

import "core:slice"
import "core:strings"
import "core:unicode"
import "core:unicode/utf8"

Search_Source :: enum {
	Symbol,
	Passage,
}

search_source_label :: proc(s: Search_Source) -> string {
	switch s {
	case .Symbol:
		return "symbol"
	case .Passage:
		return "passage"
	}
	return ""
}

Search_Result :: struct {
	anchor:  string,
	title:   string,
	kind:    string,
	score:   f64,
	snippet: string,
	source:  Search_Source,
}

Search_Engine :: struct {
	symbols:    Symbol_Table,
	passages:   Passage_Index,
	directives: map[string]bool,
	keywords:   map[string]bool,
	built:      bool,
}

SEARCH_CANDIDATE_POOL :: 50

Search_Shape :: enum {
	Symbol,
	Conceptual,
}

Search_Blend :: struct {
	symbol:  f64,
	passage: f64,
}

search_blend_for :: proc(s: Search_Shape) -> Search_Blend {
	switch s {
	case .Symbol:
		return Search_Blend{symbol = 1.0, passage = 0.6}
	case .Conceptual:
		return Search_Blend{symbol = 0.6, passage = 1.0}
	}
	return Search_Blend{symbol = 0.6, passage = 1.0}
}

search_engine_build :: proc(sections: []Corpus_Section, allocator := context.allocator) -> Search_Engine {
	e := Search_Engine {
		symbols    = symbol_table_build(sections, allocator),
		passages   = passage_index_build(sections, allocator),
		directives = make(map[string]bool, 0, allocator),
		keywords   = make(map[string]bool, 0, allocator),
		built      = true,
	}
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

search_normalize_symbol :: proc(hits: []Symbol_Hit, allocator := context.allocator) -> []f64 {
	scores := make([]f64, len(hits), allocator)
	for h, i in hits {
		scores[i] = h.score
	}
	return search_min_max(scores, allocator)
}

search_normalize_passage :: proc(hits: []Passage_Hit, allocator := context.allocator) -> []f64 {
	scores := make([]f64, len(hits), allocator)
	for h, i in hits {
		scores[i] = h.score
	}
	return search_min_max(scores, allocator)
}

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

search_kind_for_category :: proc(c: Symbol_Category) -> string {
	if c == .Engine {
		return CORPUS_KIND_ENGINE
	}
	return CORPUS_KIND_SPEC
}

search_classify :: proc(q: string, directives, keywords: map[string]bool) -> Search_Shape {
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
