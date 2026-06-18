// The symbol half of the funpack docs index — the Odin re-home of the deleted Go
// mcp/internal/docs/symbols package (symbols.go + match.go). A name-keyed table
// built from the embedded corpus (load_corpus) resolves a query to the engine
// declarations, directives, and grammar keywords it most likely names.
//
// It exists so a symbol-shaped query ("world.resolve", "@stub", "behavior", a
// misspelling like "resollve") lands on the right declaration directly rather
// than competing in the passage-relevance ranking. The query-shape router
// (mcp_docs_search.odin) prefers this table for symbol-shaped queries and falls
// back to the passage index for prose-shaped ones. symbol_table_lookup is pure:
// same corpus in, same ranked hits out, no I/O and no global state.
//
// WHY a custom name-keyed table + fuzzy match and not a core: facility: Odin core
// ships no symbol table, no Levenshtein, and no fuzzy ranker, so this bespoke
// matcher on core:strings/slice is the Odin-first answer.
//
// Symbol categories (Symbol_Category):
//   - .Engine — one engine.* declaration, from every CORPUS_KIND_ENGINE section.
//     Name is the section title ("module.decl", e.g. "world.resolve"); the table
//     also indexes the bare decl ("resolve") as an alias.
//   - .Directive — a compiler-native annotation from the closed directive family
//     (@doc, @stub, …). The family is closed in the spec, so SYMBOL_DIRECTIVE_NAMES
//     is the authoritative seed; each resolves to its best spec section.
//   - .Keyword — a declaration keyword opening a top-level form (import, let, …),
//     from the closed SYMBOL_KEYWORD_NAMES seed.
//   - .Diagnostic — present-but-empty: the funpack spec has no diagnostic registry,
//     so scan_diagnostics yields none today, but the category exists so a future
//     registry flows through without an API change.
package main

import "core:slice"
import "core:strings"
import "core:unicode/utf8"

// Symbol_Category is the closed set of symbol categories — an Odin enum per the
// closed-enum discipline. Every Symbol carries exactly one; a consumer can switch
// over it exhaustively. Adding a value is a deliberate change.
Symbol_Category :: enum {
	Engine,
	Directive,
	Keyword,
	Diagnostic,
}

// symbol_category_label is the lowercase wire token for a category, mirroring the
// Go docs.Category string values — the form the seed classifier and any external
// presentation key on.
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

// SYMBOL_DIRECTIVE_NAMES is the closed funpack directive family, leading "@"
// included. The spec declares the directive category closed and individual
// directives non-user-definable, so this seed is authoritative: the extractor
// binds each name to its best spec section rather than discovering names from
// prose. Kept sorted for deterministic table order.
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

// SYMBOL_KEYWORD_NAMES is the closed set of declaration keywords that open a
// top-level form, taken from the spec's grammar-only declaration inventory. There
// is deliberately no "module" keyword (a module's name is its file path), so it
// is absent. Kept sorted for deterministic table order.
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

// Symbol is one indexable name in the table. name is the canonical, queryable
// identifier (an engine "module.decl", a directive "@name", or a keyword). anchor
// is the corpus section the symbol documents, so a hit links straight to the
// passage. signature is a short one-line synopsis for display (the engine decl's
// first signature line, or the symbol's spec title), never the full section body.
Symbol :: struct {
	name:      string,
	category:  Symbol_Category,
	anchor:    string,
	title:     string,
	signature: string,
}

// Symbol_Match_Kind names how a query matched a symbol. The closed set mirrors
// the Go MatchKind string values a consumer presents or filters on.
Symbol_Match_Kind :: enum {
	Exact,
	Alias,
	Prefix,
	Substring,
	Fuzzy,
}

// symbol_match_kind_label is the lowercase wire token for a match kind, mirroring
// the Go MatchKind strings ("exact"/"alias"/"prefix"/"substring"/"fuzzy").
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

// Symbol_Hit is one ranked lookup result: the matched Symbol plus why it ranked
// where it did. score is higher-is-better and only comparable within a single
// symbol_table_lookup call (a relative rank key, not an absolute metric).
Symbol_Hit :: struct {
	symbol:     Symbol,
	score:      f64,
	match_kind: Symbol_Match_Kind,
}

// Symbol_Table is a name-keyed view of the corpus's symbols. Build it once with
// symbol_table_build and reuse it; symbol_table_lookup never mutates it. All
// storage is owned by `allocator`.
Symbol_Table :: struct {
	// symbols is every distinct symbol, in deterministic build order (engine then
	// directive then keyword, each sorted).
	symbols: []Symbol,
	// by_name maps a lowercased lookup key to the symbol indices it resolves. A key
	// may be a canonical name or an alias (a bare engine decl name); one key can
	// fan out to several symbols (e.g. two modules sharing a decl name like "spawn").
	by_name: map[string][dynamic]int,
}

// Match-strength tiers. Scores are bucketed by match kind so an exact hit always
// outranks any fuzzy hit regardless of name length, with the fuzzy similarity
// breaking ties only inside the fuzzy bucket. The gaps are wide on purpose: no
// fuzzy similarity (in [0,1]) can lift a fuzzy hit into the substring band.
SYMBOL_SCORE_EXACT :: 1000.0
SYMBOL_SCORE_ALIAS :: 900.0
SYMBOL_SCORE_PREFIX :: 700.0
SYMBOL_SCORE_SUBSTRING :: 500.0
SYMBOL_SCORE_FUZZY_BASE :: 0.0
// SYMBOL_SCORE_FUZZY_SPAN scales similarity into the fuzzy band; a
// perfect-similarity fuzzy hit tops out below SYMBOL_SCORE_SUBSTRING.
SYMBOL_SCORE_FUZZY_SPAN :: 400.0
// SYMBOL_FUZZY_FLOOR is the minimum normalized similarity a fuzzy candidate must
// reach to be reported at all — below it the match is noise.
SYMBOL_FUZZY_FLOOR :: 0.34

// symbol_table_build constructs a Symbol_Table from the loaded corpus. It is
// total over any well-formed corpus: a corpus missing a source family yields a
// table with that category empty, never an error. The build is deterministic —
// the same corpus produces the same table and the same lookup ordering. All
// storage is owned by `allocator`.
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

// symbol_table_add appends a symbol and indexes it under its lowercased name plus
// an optional alias key. Duplicate canonical names are tolerated: every symbol
// gets a table slot, and a shared key fans out to all of them.
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

// symbol_table_count_by_category tallies symbols per category. Categories with
// zero symbols read zero (the returned array is indexed by Symbol_Category).
symbol_table_count_by_category :: proc(t: Symbol_Table) -> [Symbol_Category]int {
	out: [Symbol_Category]int
	for s in t.symbols {
		out[s.category] += 1
	}
	return out
}

// symbol_alias_of returns the bare declaration name of an engine symbol — the
// part after the final dot of a "module.decl" name — so a module-less query
// ("resolve") still resolves. Returns "" when the name is undotted or not engine.
symbol_alias_of :: proc(s: Symbol) -> string {
	if s.category != .Engine {
		return ""
	}
	if i := strings.last_index(s.name, "."); i >= 0 && i + 1 < len(s.name) {
		return s.name[i + 1:]
	}
	return ""
}

// symbol_engine_symbols turns every CORPUS_KIND_ENGINE section into one .Engine
// symbol. The section title is already the canonical "module.decl" name; the
// signature synopsis is the first declaration-shaped line of the section text,
// falling back to the title when no such line is present. Sorted by name (stable),
// allocated in `allocator`.
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

// symbol_decl_synopsis extracts a one-line signature from an engine section body.
// Engine sections lead with a prose @doc sentence and then carry the declaration;
// the synopsis is the first line containing a declaration keyword. Falls back to
// `fallback` (the title) when no declaration line is found.
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

// symbol_has_decl_lead reports whether a line opens with an engine declaration
// form.
symbol_has_decl_lead :: proc(line: string) -> bool {
	for lead in ([]string{"extern fn ", "fn ", "data ", "enum ", "let ", "type "}) {
		if strings.has_prefix(line, lead) {
			return true
		}
	}
	return false
}

// symbol_directive_symbols binds each name in the closed SYMBOL_DIRECTIVE_NAMES
// family to one .Directive symbol, anchored at the spec section that best
// documents it. Resolution picks the spec section whose title names the directive,
// preferring a 05-directives.md section, then falls back to the directives index.
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

// symbol_directives_index_section returns the 05-directives.md overview section,
// the fallback anchor for a directive with no dedicated section, or nil if absent.
symbol_directives_index_section :: proc(spec: []Corpus_Section) -> ^Corpus_Section {
	for i in 0 ..< len(spec) {
		if spec[i].anchor == "05-directives.md#05-directives" {
			return &spec[i]
		}
	}
	return nil
}

// symbol_best_directive_section finds the spec section that best documents a
// directive name. It prefers a section under 05-directives.md whose title contains
// the directive, then any spec section whose title contains it, then the
// directives index, then nil.
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

// symbol_keyword_symbols turns the closed SYMBOL_KEYWORD_NAMES set into .Keyword
// symbols, all anchored at the spec's grammar-only declaration inventory (the
// single section that enumerates every declaration keyword).
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

// symbol_scan_diagnostics extracts named compiler diagnostics from the corpus.
// The funpack spec carries no diagnostic-code registry, so this returns an empty
// slice today; it exists so a future spec that adds one is picked up without an
// API change.
symbol_scan_diagnostics :: proc(sections: []Corpus_Section, allocator := context.allocator) -> []Symbol {
	return nil
}

// symbol_table_lookup resolves a query to its ranked symbol hits, exact-name
// matches first and fuzzy matches last. It is pure: no I/O, no mutation of the
// table, so the same query against the same table always returns the same order.
//
// Ranking, strongest first:
//   1. exact     — query equals a symbol's canonical name (case-insensitive)
//   2. alias     — query equals an engine symbol's bare decl alias
//   3. prefix    — a symbol name starts with the query
//   4. substring — a symbol name contains the query
//   5. fuzzy     — normalized edit-distance similarity at or above SYMBOL_FUZZY_FLOOR
//
// Within a tier, higher similarity wins, then shorter name, then lexical name — a
// total order, so ties are never resolved arbitrarily. A symbol contributes at
// most once, at its strongest tier. An empty or whitespace query returns nil.
// Hits are allocated in `allocator`.
symbol_table_lookup :: proc(t: ^Symbol_Table, query: string, allocator := context.allocator) -> []Symbol_Hit {
	q := strings.trim_space(query)
	if q == "" {
		return nil
	}
	ql := strings.to_lower(q, allocator)

	// best[i] holds the strongest scoring seen for symbol i this call, so each
	// symbol surfaces once at its best tier rather than once per match path.
	best := make(map[int]Symbol_Hit, 0, allocator)
	defer delete(best)
	consider := proc(best: ^map[int]Symbol_Hit, symbols: []Symbol, idx: int, score: f64, kind: Symbol_Match_Kind) {
		if cur, ok := best[idx]; ok && cur.score >= score {
			return
		}
		best[idx] = Symbol_Hit{symbol = symbols[idx], score = score, match_kind = kind}
	}

	// Exact / alias: direct key hits. A key may fan out to several symbols.
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

	// Prefix / substring / fuzzy: scan every symbol once.
	for idx in 0 ..< len(t.symbols) {
		name_lower := strings.to_lower(t.symbols[idx].name, allocator)
		switch {
		case name_lower == ql:
		// already handled by the exact pass
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

// symbol_length_penalty nudges shorter, tighter prefix/substring matches above
// looser ones of the same tier without crossing tier boundaries. It is the
// fraction of the name the query does NOT cover, scaled to stay under the
// inter-tier gap.
symbol_length_penalty :: proc(name, query: string) -> f64 {
	if len(name) == 0 {
		return 0
	}
	uncovered := f64(len(name) - len(query)) / f64(len(name))
	return uncovered * 50.0
}

// symbol_similarity returns a normalized [0,1] closeness between two lowercased
// strings from their Levenshtein edit distance: 1 - dist/max(len). It is the
// fuzzy rank key — a single misspelling of an N-char name scores ~1-1/N,
// comfortably above SYMBOL_FUZZY_FLOOR for any real symbol name, while an
// unrelated string falls below it.
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

// symbol_levenshtein computes the edit distance between two strings with a
// rolling two-row DP over runes — O(len(a)*len(b)) time, O(min) space. Pure
// stdlib; no dependency is warranted for a table of a few hundred short names.
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
