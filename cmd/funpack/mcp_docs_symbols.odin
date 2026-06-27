package main

import "core:slice"
import "core:strings"
import "core:unicode/utf8"

Symbol_Category :: enum {
	Engine,
	Directive,
	Keyword,
	Diagnostic,
}

symbol_category_label :: proc(c: Symbol_Category) -> string {
	switch c {
	case .Engine:
		return "engine"
	case .Directive:
		return "directive"
	case .Keyword:
		return "keyword"
	case .Diagnostic:
		return "diagnostic"
	}
	return ""
}

SYMBOL_DIRECTIVE_NAMES :: []string {
	"@behavior",
	"@break",
	"@click",
	"@client",
	"@doc",
	"@event",
	"@expose",
	"@gtag",
	"@index",
	"@log",
	"@migrate",
	"@server",
	"@spatial",
	"@stub",
	"@todo",
	"@trace",
	"@unique",
	"@watch",
}

SYMBOL_KEYWORD_NAMES :: []string {
	"behavior",
	"data",
	"enum",
	"fn",
	"import",
	"let",
	"pipeline",
	"query",
	"signal",
	"singleton",
	"test",
	"thing",
}

Symbol :: struct {
	name:      string,
	category:  Symbol_Category,
	anchor:    string,
	title:     string,
	signature: string,
}

Symbol_Match_Kind :: enum {
	Exact,
	Alias,
	Prefix,
	Substring,
	Fuzzy,
}

symbol_match_kind_label :: proc(k: Symbol_Match_Kind) -> string {
	switch k {
	case .Exact:
		return "exact"
	case .Alias:
		return "alias"
	case .Prefix:
		return "prefix"
	case .Substring:
		return "substring"
	case .Fuzzy:
		return "fuzzy"
	}
	return ""
}

Symbol_Hit :: struct {
	symbol:     Symbol,
	score:      f64,
	match_kind: Symbol_Match_Kind,
}

Symbol_Table :: struct {
	symbols: []Symbol,
	by_name: map[string][dynamic]int,
}

SYMBOL_SCORE_EXACT :: 1000.0
SYMBOL_SCORE_ALIAS :: 900.0
SYMBOL_SCORE_PREFIX :: 700.0
SYMBOL_SCORE_SUBSTRING :: 500.0
SYMBOL_SCORE_FUZZY_BASE :: 0.0
SYMBOL_SCORE_FUZZY_SPAN :: 400.0
SYMBOL_FUZZY_FLOOR :: 0.34

symbol_table_build :: proc(sections: []Corpus_Section, allocator := context.allocator) -> Symbol_Table {
	t := Symbol_Table {
		by_name = make(map[string][dynamic]int, 0, allocator),
	}
	symbols := make([dynamic]Symbol, 0, 256, allocator)

	for s in symbol_engine_symbols(sections, allocator) {
		symbol_table_add(&t, &symbols, s, symbol_alias_of(s), allocator)
	}
	for s in symbol_directive_symbols(sections, allocator) {
		symbol_table_add(&t, &symbols, s, "", allocator)
	}
	for s in symbol_keyword_symbols(sections, allocator) {
		symbol_table_add(&t, &symbols, s, "", allocator)
	}
	for s in symbol_scan_diagnostics(sections, allocator) {
		symbol_table_add(&t, &symbols, s, "", allocator)
	}

	t.symbols = symbols[:]
	return t
}

symbol_table_add :: proc(
	t: ^Symbol_Table,
	symbols: ^[dynamic]Symbol,
	s: Symbol,
	alias: string,
	allocator := context.allocator,
) {
	idx := len(symbols)
	append(symbols, s)
	symbol_table_index(t, strings.to_lower(s.name, allocator), idx, allocator)
	if alias != "" && !strings.equal_fold(alias, s.name) {
		symbol_table_index(t, strings.to_lower(alias, allocator), idx, allocator)
	}
}

symbol_table_index :: proc(t: ^Symbol_Table, key: string, idx: int, allocator := context.allocator) {
	bucket := &t.by_name[key]
	if bucket == nil {
		t.by_name[key] = make([dynamic]int, 0, allocator)
		bucket = &t.by_name[key]
	}
	append(bucket, idx)
}

symbol_table_count_by_category :: proc(t: Symbol_Table) -> [Symbol_Category]int {
	out: [Symbol_Category]int
	for s in t.symbols {
		out[s.category] += 1
	}
	return out
}

symbol_alias_of :: proc(s: Symbol) -> string {
	if s.category != .Engine {
		return ""
	}
	if i := strings.last_index(s.name, "."); i >= 0 && i + 1 < len(s.name) {
		return s.name[i + 1:]
	}
	return ""
}

symbol_engine_symbols :: proc(sections: []Corpus_Section, allocator := context.allocator) -> []Symbol {
	secs := corpus_by_kind(sections, CORPUS_KIND_ENGINE, allocator)
	out := make([dynamic]Symbol, 0, len(secs), allocator)
	for s in secs {
		append(
			&out,
			Symbol {
				name = s.title,
				category = .Engine,
				anchor = s.anchor,
				title = s.title,
				signature = symbol_decl_synopsis(s.text, s.title),
			},
		)
	}
	slice.stable_sort_by(out[:], proc(a, b: Symbol) -> bool { return a.name < b.name })
	return out[:]
}

symbol_decl_synopsis :: proc(text, fallback: string) -> string {
	lines := strings.split(text, "\n", context.temp_allocator)
	for line in lines {
		trimmed := strings.trim_space(line)
		if trimmed == "" {
			continue
		}
		if symbol_has_decl_lead(trimmed) {
			return trimmed
		}
	}
	return fallback
}

symbol_has_decl_lead :: proc(line: string) -> bool {
	for lead in ([]string{"extern fn ", "fn ", "data ", "enum ", "let ", "type "}) {
		if strings.has_prefix(line, lead) {
			return true
		}
	}
	return false
}

symbol_directive_symbols :: proc(sections: []Corpus_Section, allocator := context.allocator) -> []Symbol {
	spec := corpus_by_kind(sections, CORPUS_KIND_SPEC, allocator)
	index := symbol_directives_index_section(spec)

	out := make([dynamic]Symbol, 0, len(SYMBOL_DIRECTIVE_NAMES), allocator)
	for name in SYMBOL_DIRECTIVE_NAMES {
		sec := symbol_best_directive_section(spec, name, index)
		title := name
		anchor := ""
		if sec != nil {
			title = sec.title
			anchor = sec.anchor
		}
		append(
			&out,
			Symbol{name = name, category = .Directive, anchor = anchor, title = title, signature = name},
		)
	}
	return out[:]
}

symbol_directives_index_section :: proc(spec: []Corpus_Section) -> ^Corpus_Section {
	for i in 0 ..< len(spec) {
		if spec[i].anchor == "05-directives.md#05-directives" {
			return &spec[i]
		}
	}
	return nil
}

symbol_best_directive_section :: proc(
	spec: []Corpus_Section,
	name: string,
	index: ^Corpus_Section,
) -> ^Corpus_Section {
	any_title: ^Corpus_Section
	for i in 0 ..< len(spec) {
		if !strings.contains(spec[i].title, name) {
			continue
		}
		if strings.has_prefix(spec[i].anchor, "05-directives.md#") &&
		   spec[i].anchor != "05-directives.md#05-directives" {
			return &spec[i]
		}
		if any_title == nil {
			any_title = &spec[i]
		}
	}
	if any_title != nil {
		return any_title
	}
	return index
}

symbol_keyword_symbols :: proc(sections: []Corpus_Section, allocator := context.allocator) -> []Symbol {
	GRAMMAR_ANCHOR :: "02-language-core.md#7-declaration-inventory-grammar-only"
	spec := corpus_by_kind(sections, CORPUS_KIND_SPEC, allocator)

	title := "Declaration inventory (grammar only)"
	anchor := ""
	for i in 0 ..< len(spec) {
		if spec[i].anchor == GRAMMAR_ANCHOR {
			title = spec[i].title
			anchor = spec[i].anchor
			break
		}
	}

	out := make([dynamic]Symbol, 0, len(SYMBOL_KEYWORD_NAMES), allocator)
	for kw in SYMBOL_KEYWORD_NAMES {
		append(
			&out,
			Symbol{name = kw, category = .Keyword, anchor = anchor, title = title, signature = kw},
		)
	}
	return out[:]
}

symbol_scan_diagnostics :: proc(sections: []Corpus_Section, allocator := context.allocator) -> []Symbol {
	return nil
}

symbol_table_lookup :: proc(t: ^Symbol_Table, query: string, allocator := context.allocator) -> []Symbol_Hit {
	q := strings.trim_space(query)
	if q == "" {
		return nil
	}
	ql := strings.to_lower(q, allocator)

	best := make(map[int]Symbol_Hit, 0, allocator)
	defer delete(best)
	consider := proc(best: ^map[int]Symbol_Hit, symbols: []Symbol, idx: int, score: f64, kind: Symbol_Match_Kind) {
		if cur, ok := best[idx]; ok && cur.score >= score {
			return
		}
		best[idx] = Symbol_Hit{symbol = symbols[idx], score = score, match_kind = kind}
	}

	if bucket, ok := t.by_name[ql]; ok {
		for idx in bucket {
			s := t.symbols[idx]
			if strings.equal_fold(s.name, q) {
				consider(&best, t.symbols, idx, SYMBOL_SCORE_EXACT, .Exact)
			} else {
				consider(&best, t.symbols, idx, SYMBOL_SCORE_ALIAS, .Alias)
			}
		}
	}

	for idx in 0 ..< len(t.symbols) {
		name_lower := strings.to_lower(t.symbols[idx].name, allocator)
		switch {
		case name_lower == ql:
		case strings.has_prefix(name_lower, ql):
			consider(&best, t.symbols, idx, SYMBOL_SCORE_PREFIX - symbol_length_penalty(name_lower, ql), .Prefix)
		case strings.contains(name_lower, ql):
			consider(
				&best,
				t.symbols,
				idx,
				SYMBOL_SCORE_SUBSTRING - symbol_length_penalty(name_lower, ql),
				.Substring,
			)
		case:
			if sim := symbol_similarity(ql, name_lower); sim >= SYMBOL_FUZZY_FLOOR {
				consider(&best, t.symbols, idx, SYMBOL_SCORE_FUZZY_BASE + sim * SYMBOL_SCORE_FUZZY_SPAN, .Fuzzy)
			}
		}
	}

	hits := make([dynamic]Symbol_Hit, 0, len(best), allocator)
	for _, h in best {
		append(&hits, h)
	}
	slice.sort_by(hits[:], proc(a, b: Symbol_Hit) -> bool {
		if a.score != b.score {
			return a.score > b.score
		}
		if len(a.symbol.name) != len(b.symbol.name) {
			return len(a.symbol.name) < len(b.symbol.name)
		}
		return a.symbol.name < b.symbol.name
	})
	return hits[:]
}

symbol_length_penalty :: proc(name, query: string) -> f64 {
	if len(name) == 0 {
		return 0
	}
	uncovered := f64(len(name) - len(query)) / f64(len(name))
	return uncovered * 50.0
}

symbol_similarity :: proc(a, b: string) -> f64 {
	if a == b {
		return 1
	}
	la, lb := len(a), len(b)
	if la == 0 || lb == 0 {
		return 0
	}
	dist := symbol_levenshtein(a, b)
	longest := la
	if lb > longest {
		longest = lb
	}
	return 1 - f64(dist) / f64(longest)
}

symbol_levenshtein :: proc(a, b: string) -> int {
	ra := utf8.string_to_runes(a, context.temp_allocator)
	rb := utf8.string_to_runes(b, context.temp_allocator)
	if len(ra) < len(rb) {
		ra, rb = rb, ra
	}
	prev := make([]int, len(rb) + 1, context.temp_allocator)
	curr := make([]int, len(rb) + 1, context.temp_allocator)
	for j in 0 ..< len(prev) {
		prev[j] = j
	}
	for i in 1 ..= len(ra) {
		curr[0] = i
		for j in 1 ..= len(rb) {
			cost := 1
			if ra[i - 1] == rb[j - 1] {
				cost = 0
			}
			curr[j] = symbol_min3(prev[j] + 1, curr[j - 1] + 1, prev[j - 1] + cost)
		}
		prev, curr = curr, prev
	}
	return prev[len(rb)]
}

symbol_min3 :: proc(a, b, c: int) -> int {
	m := a
	if b < m {
		m = b
	}
	if c < m {
		m = c
	}
	return m
}
