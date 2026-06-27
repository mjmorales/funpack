package main

import "core:testing"

@(private = "file")
symbol_test_table :: proc(t: ^testing.T) -> Symbol_Table {
	sections, ok := load_corpus(context.temp_allocator)
	testing.expect(t, ok, "embedded corpus must parse")
	testing.expect(t, len(sections) > 0, "corpus is empty — run `funpack mcp gen-corpus`")
	return symbol_table_build(sections, context.temp_allocator)
}

@(test)
test_symbols_build_covers_expected_categories :: proc(t: ^testing.T) {
	tbl := symbol_test_table(t)
	counts := symbol_table_count_by_category(tbl)

	testing.expect(t, counts[.Engine] > 0, "no engine symbols extracted")
	testing.expectf(t, counts[.Directive] == len(SYMBOL_DIRECTIVE_NAMES), "directive count = %d, want one per closed name (%d)", counts[.Directive], len(SYMBOL_DIRECTIVE_NAMES))
	testing.expect(t, counts[.Keyword] > 0, "no keyword symbols extracted")
	testing.expect(t, counts[.Diagnostic] == 0, "diagnostics unexpectedly present — corpus gained a diagnostic registry")
}

@(test)
test_symbols_engine_symbols_carry_anchor_and_signature :: proc(t: ^testing.T) {
	tbl := symbol_test_table(t)
	saw_resolve := false
	for s in tbl.symbols {
		if s.category != .Engine {
			continue
		}
		testing.expectf(t, s.anchor != "", "engine symbol %q has empty anchor", s.name)
		testing.expectf(t, s.signature != "", "engine symbol %q has empty signature", s.name)
		if s.name == "world.resolve" {
			saw_resolve = true
			testing.expectf(t, s.anchor == "engine/world#resolve", "world.resolve anchor = %q, want engine/world#resolve", s.anchor)
		}
	}
	testing.expect(t, saw_resolve, "world.resolve not found among engine symbols")
}

@(test)
test_symbols_lookup_exact_engine_symbol :: proc(t: ^testing.T) {
	tbl := symbol_test_table(t)
	hits := symbol_table_lookup(&tbl, "world.resolve", context.temp_allocator)
	testing.expect(t, len(hits) > 0, "Lookup(world.resolve) returned no hits")
	if len(hits) == 0 {
		return
	}
	top := hits[0]
	testing.expectf(t, top.symbol.name == "world.resolve", "top hit = %q, want world.resolve", top.symbol.name)
	testing.expectf(t, top.match_kind == .Exact, "match kind = %q, want exact", symbol_match_kind_label(top.match_kind))
	testing.expectf(t, top.symbol.category == .Engine, "category = %q, want engine", symbol_category_label(top.symbol.category))
}

@(test)
test_symbols_lookup_alias_resolves_bare_decl :: proc(t: ^testing.T) {
	tbl := symbol_test_table(t)
	hits := symbol_table_lookup(&tbl, "resolve", context.temp_allocator)
	testing.expect(t, len(hits) > 0, "Lookup(resolve) returned no hits")
	if len(hits) == 0 {
		return
	}
	pos := -1
	for h, i in hits {
		if h.symbol.name == "world.resolve" {
			pos = i
			testing.expectf(t, h.match_kind == .Alias || h.match_kind == .Exact, "world.resolve matched as %q, want alias/exact", symbol_match_kind_label(h.match_kind))
			break
		}
	}
	testing.expect(t, pos != -1, "world.resolve not in hits for bare query 'resolve'")
	testing.expect(t, hits[0].match_kind != .Substring && hits[0].match_kind != .Fuzzy, "a substring/fuzzy hit outranked the alias hit")
}

@(test)
test_symbols_lookup_fuzzy_misspelling_ranks_target :: proc(t: ^testing.T) {
	tbl := symbol_test_table(t)
	hits := symbol_table_lookup(&tbl, "resollve", context.temp_allocator)
	testing.expect(t, len(hits) > 0, "Lookup(resollve) returned no hits")
	if len(hits) == 0 {
		return
	}
	testing.expectf(t, hits[0].symbol.name == "world.resolve", "top fuzzy hit = %q, want world.resolve", hits[0].symbol.name)
	testing.expectf(t, hits[0].match_kind == .Fuzzy, "match kind = %q, want fuzzy", symbol_match_kind_label(hits[0].match_kind))
}

@(test)
test_symbols_lookup_directive_resolves :: proc(t: ^testing.T) {
	tbl := symbol_test_table(t)
	hits := symbol_table_lookup(&tbl, "@stub", context.temp_allocator)
	testing.expect(t, len(hits) > 0, "Lookup(@stub) returned no hits")
	if len(hits) == 0 {
		return
	}
	top := hits[0]
	testing.expectf(t, top.symbol.name == "@stub", "top hit = %q, want @stub", top.symbol.name)
	testing.expectf(t, top.match_kind == .Exact, "match kind = %q, want exact", symbol_match_kind_label(top.match_kind))
	testing.expectf(t, top.symbol.category == .Directive, "category = %q, want directive", symbol_category_label(top.symbol.category))
	testing.expect(t, top.symbol.anchor != "", "@stub resolved with no spec anchor")
}

@(test)
test_symbols_lookup_keyword_resolves :: proc(t: ^testing.T) {
	tbl := symbol_test_table(t)
	hits := symbol_table_lookup(&tbl, "behavior", context.temp_allocator)
	testing.expect(t, len(hits) > 0, "Lookup(behavior) returned no hits")
	if len(hits) == 0 {
		return
	}
	testing.expectf(t, hits[0].symbol.name == "behavior" && hits[0].symbol.category == .Keyword, "top hit = %q/%s, want behavior/keyword", hits[0].symbol.name, symbol_category_label(hits[0].symbol.category))
	testing.expectf(t, hits[0].match_kind == .Exact, "match kind = %q, want exact", symbol_match_kind_label(hits[0].match_kind))
}

@(test)
test_symbols_lookup_empty_query :: proc(t: ^testing.T) {
	tbl := symbol_test_table(t)
	for q in ([]string{"", "   ", "\t\n"}) {
		hits := symbol_table_lookup(&tbl, q, context.temp_allocator)
		testing.expectf(t, len(hits) == 0, "Lookup(%q) = %d hits, want 0", q, len(hits))
	}
}

@(test)
test_symbols_lookup_exact_outranks_fuzzy :: proc(t: ^testing.T) {
	tbl := symbol_test_table(t)
	hits := symbol_table_lookup(&tbl, "world.resolve", context.temp_allocator)
	saw_fuzzy := false
	for h, i in hits {
		if h.match_kind == .Fuzzy {
			saw_fuzzy = true
		}
		testing.expectf(t, !(saw_fuzzy && h.match_kind == .Exact), "exact hit at position %d followed a fuzzy hit", i)
	}
}

@(test)
test_symbols_levenshtein_known_distances :: proc(t: ^testing.T) {
	Case :: struct {
		a, b: string,
		want: int,
	}
	cases := []Case {
		{"", "", 0},
		{"a", "", 1},
		{"resolve", "resolve", 0},
		{"resolve", "resollve", 1},
		{"kitten", "sitting", 3},
		{"flaw", "lawn", 2},
	}
	for c in cases {
		got := symbol_levenshtein(c.a, c.b)
		testing.expectf(t, got == c.want, "levenshtein(%q,%q) = %d, want %d", c.a, c.b, got, c.want)
	}
}
