// Package symbols is the symbol half of the funpack docs index: a name-keyed
// table built from the committed docs corpus ([docs.Load]) that resolves a
// query to the engine declarations, directives, and grammar keywords it most
// likely names.
//
// It exists so a symbol-shaped query ("world.resolve", "@stub", "behavior",
// a misspelling like "resollve") lands on the right declaration directly,
// rather than competing in the passage-relevance ranking. The query-shape
// router (a later task) prefers this table for symbol-shaped queries and falls
// back to the passage index for prose-shaped ones; the docs_search tool surfaces
// both. To keep that contract clean, [Lookup] is pure: same corpus in, same
// ranked hits out, with no I/O and no global state.
//
// What is a symbol, by category ([Category]):
//
//   - [CategoryEngine] — one engine.* declaration (fn, type, data, enum, const),
//     extracted from every [docs.KindEngine] section. Name is the section Title
//     ("module.decl", e.g. "world.resolve"); the table also indexes the bare
//     decl ("resolve") as an alias so a module-less query still hits.
//   - [CategoryDirective] — a compiler-native annotation from the closed
//     directive family (@doc, @gtag, @stub, …). The directive family is closed
//     in the spec (a directive is not user-definable), so [DirectiveNames] is the
//     seed; each is resolved to the best-matching spec section for its anchor.
//   - [CategoryKeyword] — a declaration keyword that opens a top-level form
//     (import, let, data, enum, thing, singleton, signal, behavior, fn,
//     pipeline, query, test), distilled from the spec's grammar-only declaration
//     inventory. These are the grammar productions the table carries.
//
// Diagnostics: the funpack-spec has no error-code or named-diagnostic registry
// (it favors "errors are values" over a numbered diagnostic catalog), so the
// corpus yields no diagnostic identifiers and this table carries none. The
// extractor scans for them anyway ([scanDiagnostics]); the category is therefore
// present-but-empty rather than absent, so a future spec that introduces a
// diagnostic registry flows through without an API change.
package symbols

import (
	"sort"
	"strings"

	"github.com/mjmorales/funpack/mcp/internal/docs"
)

// Category is the closed set of symbol categories. Every [Symbol] carries
// exactly one; a consumer (the ranker, the docs_search tool) can switch over it
// exhaustively. Adding a value is a deliberate change, never an ad-hoc addition.
type Category string

const (
	// CategoryEngine is an engine.* declaration (fn, type, data, enum, const).
	CategoryEngine Category = "engine"
	// CategoryDirective is a compiler-native annotation (@doc, @stub, …) from
	// the closed directive family.
	CategoryDirective Category = "directive"
	// CategoryKeyword is a declaration keyword opening a top-level form (fn,
	// thing, behavior, …) — a grammar production of the language.
	CategoryKeyword Category = "keyword"
	// CategoryDiagnostic is a named compiler diagnostic or error identifier.
	// Present for forward-compatibility; the current corpus yields none.
	CategoryDiagnostic Category = "diagnostic"
)

// DirectiveNames is the closed funpack directive family, leading "@" included.
// The spec declares the directive category closed and individual directives
// non-user-definable, so this seed is authoritative: the extractor binds each
// name to its best spec section rather than discovering names from prose. Kept
// sorted for deterministic table order.
var DirectiveNames = []string{
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

// keywordNames is the closed set of declaration keywords that open a top-level
// form, taken from the spec's grammar-only declaration inventory. There is
// deliberately no "module" keyword (a module's name is its file path), so it is
// absent here. Kept sorted for deterministic table order.
var keywordNames = []string{
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

// Symbol is one indexable name in the table. Name is the canonical, queryable
// identifier (an engine "module.decl", a directive "@name", or a keyword). Anchor
// is the corpus section the symbol documents, so a hit links straight to the
// passage. Signature is a short one-line synopsis for display (the engine decl's
// first signature line, or the symbol's spec title), never the full section body.
type Symbol struct {
	// Name is the canonical queryable identifier.
	Name string
	// Category is the closed symbol category.
	Category Category
	// Anchor is the docs corpus section anchor this symbol documents.
	Anchor string
	// Title is the human-readable section title the symbol came from.
	Title string
	// Signature is a short one-line synopsis (decl signature or title), for
	// display alongside a hit. Never the full section text.
	Signature string
}

// SymbolHit is one ranked lookup result: the matched [Symbol] plus why it
// ranked where it did. Score is higher-is-better and only comparable within a
// single [Lookup] call (it is a relative rank key, not an absolute metric).
type SymbolHit struct {
	// Symbol is the matched table entry.
	Symbol Symbol
	// Score is the relative match strength; higher ranks earlier. Compare only
	// within one Lookup result set.
	Score float64
	// MatchKind names how the query matched: "exact", "alias", "prefix",
	// "substring", or "fuzzy". A consumer can present or filter on it.
	MatchKind string
}

// SymbolTable is an immutable name-keyed view of the corpus's symbols. Build it
// once with [Build] and reuse it; [Lookup] never mutates it, so it is safe to
// share across concurrent tool invocations. Construct only via [Build] — the
// zero value is not usable.
type SymbolTable struct {
	// symbols is every distinct symbol, in deterministic build order (engine
	// then directive then keyword, each sorted).
	symbols []Symbol
	// byName maps a lowercased lookup key to the symbols it resolves. A key may
	// be a canonical Name or an alias (a bare engine decl name); one key can map
	// to several symbols (e.g. two modules sharing a decl name like "spawn").
	byName map[string][]int
}

// Build constructs a [SymbolTable] from the loaded docs corpus. It is total over
// any well-formed corpus: a corpus missing a source family yields a table with
// that category empty, never an error. The build is deterministic — the same
// corpus produces the same table and the same [Lookup] ordering.
func Build(c *docs.Corpus) *SymbolTable {
	t := &SymbolTable{byName: map[string][]int{}}

	for _, s := range engineSymbols(c) {
		t.add(s, aliasOf(s))
	}
	for _, s := range directiveSymbols(c) {
		t.add(s, "")
	}
	for _, s := range keywordSymbols(c) {
		t.add(s, "")
	}
	for _, s := range scanDiagnostics(c) {
		t.add(s, "")
	}
	return t
}

// add appends a symbol and indexes it under its lowercased Name plus an optional
// alias key. Duplicate canonical names are tolerated: every symbol gets a table
// slot, and a shared key fans out to all of them.
func (t *SymbolTable) add(s Symbol, alias string) {
	idx := len(t.symbols)
	t.symbols = append(t.symbols, s)
	t.index(strings.ToLower(s.Name), idx)
	if alias != "" && !strings.EqualFold(alias, s.Name) {
		t.index(strings.ToLower(alias), idx)
	}
}

func (t *SymbolTable) index(key string, idx int) {
	t.byName[key] = append(t.byName[key], idx)
}

// Len reports the number of symbols in the table.
func (t *SymbolTable) Len() int { return len(t.symbols) }

// Symbols returns the table's symbols in build order. The returned slice is a
// copy header over the table's backing array; callers must not mutate elements.
func (t *SymbolTable) Symbols() []Symbol { return t.symbols }

// CountByCategory tallies symbols per [Category]. Categories with zero symbols
// are omitted from the map.
func (t *SymbolTable) CountByCategory() map[Category]int {
	out := map[Category]int{}
	for _, s := range t.symbols {
		out[s.Category]++
	}
	return out
}

// aliasOf returns the bare declaration name of an engine symbol — the part after
// the final dot of a "module.decl" Name — so a module-less query ("resolve")
// still resolves. Returns "" when the name is undotted.
func aliasOf(s Symbol) string {
	if s.Category != CategoryEngine {
		return ""
	}
	if i := strings.LastIndex(s.Name, "."); i >= 0 && i+1 < len(s.Name) {
		return s.Name[i+1:]
	}
	return ""
}

// engineSymbols turns every KindEngine section into one CategoryEngine symbol.
// The section Title is already the canonical "module.decl" name; the signature
// synopsis is the first non-empty line of the section text that looks like a
// declaration (an "extern fn …" / "data …" / "enum …" line), falling back to the
// Title when no such line is present.
func engineSymbols(c *docs.Corpus) []Symbol {
	secs := c.ByKind(docs.KindEngine)
	out := make([]Symbol, 0, len(secs))
	for _, s := range secs {
		out = append(out, Symbol{
			Name:      s.Title,
			Category:  CategoryEngine,
			Anchor:    s.Anchor,
			Title:     s.Title,
			Signature: declSynopsis(s.Text, s.Title),
		})
	}
	sort.SliceStable(out, func(i, j int) bool { return out[i].Name < out[j].Name })
	return out
}

// declSynopsis extracts a one-line signature from an engine section body. Engine
// sections lead with a prose @doc sentence and then carry the declaration; the
// synopsis is the first line containing a declaration keyword. Falls back to
// fallback (the Title) when no declaration line is found.
func declSynopsis(text, fallback string) string {
	for _, line := range strings.Split(text, "\n") {
		trimmed := strings.TrimSpace(line)
		if trimmed == "" {
			continue
		}
		if hasDeclLead(trimmed) {
			return trimmed
		}
	}
	return fallback
}

// hasDeclLead reports whether a line opens with an engine declaration form.
func hasDeclLead(line string) bool {
	for _, lead := range []string{"extern fn ", "fn ", "data ", "enum ", "let ", "type "} {
		if strings.HasPrefix(line, lead) {
			return true
		}
	}
	return false
}

// directiveSymbols binds each name in the closed [DirectiveNames] family to one
// CategoryDirective symbol, anchored at the spec section that best documents it.
// The 05-directives.md sections cover directives in groups (one section titles
// several), so resolution picks the spec section whose Title names the directive,
// preferring a directives-file section, then falls back to the directives index.
func directiveSymbols(c *docs.Corpus) []Symbol {
	spec := c.ByKind(docs.KindSpec)
	index := directivesIndexSection(spec)

	out := make([]Symbol, 0, len(DirectiveNames))
	for _, name := range DirectiveNames {
		sec := bestDirectiveSection(spec, name, index)
		title := name
		anchor := ""
		if sec != nil {
			title = sec.Title
			anchor = sec.Anchor
		}
		out = append(out, Symbol{
			Name:      name,
			Category:  CategoryDirective,
			Anchor:    anchor,
			Title:     title,
			Signature: name,
		})
	}
	return out
}

// directivesIndexSection returns the 05-directives.md overview section, the
// fallback anchor for a directive with no dedicated section, or nil if absent.
func directivesIndexSection(spec []docs.Section) *docs.Section {
	for i := range spec {
		if spec[i].Anchor == "05-directives.md#05-directives" {
			return &spec[i]
		}
	}
	return nil
}

// bestDirectiveSection finds the spec section that best documents a directive
// name. It prefers a section under 05-directives.md whose Title contains the
// directive, then any spec section whose Title contains it, then the directives
// index, then nil.
func bestDirectiveSection(spec []docs.Section, name string, index *docs.Section) *docs.Section {
	var anyTitle *docs.Section
	for i := range spec {
		if !strings.Contains(spec[i].Title, name) {
			continue
		}
		if strings.HasPrefix(spec[i].Anchor, "05-directives.md#") && spec[i].Anchor != "05-directives.md#05-directives" {
			return &spec[i]
		}
		if anyTitle == nil {
			anyTitle = &spec[i]
		}
	}
	if anyTitle != nil {
		return anyTitle
	}
	return index
}

// keywordSymbols turns the closed [keywordNames] set into CategoryKeyword
// symbols, all anchored at the spec's grammar-only declaration inventory (the
// single section that enumerates every declaration keyword).
func keywordSymbols(c *docs.Corpus) []Symbol {
	const grammarAnchor = "02-language-core.md#7-declaration-inventory-grammar-only"
	spec := c.ByKind(docs.KindSpec)

	title := "Declaration inventory (grammar only)"
	anchor := ""
	for i := range spec {
		if spec[i].Anchor == grammarAnchor {
			title = spec[i].Title
			anchor = spec[i].Anchor
			break
		}
	}

	out := make([]Symbol, 0, len(keywordNames))
	for _, kw := range keywordNames {
		out = append(out, Symbol{
			Name:      kw,
			Category:  CategoryKeyword,
			Anchor:    anchor,
			Title:     title,
			Signature: kw,
		})
	}
	return out
}

// scanDiagnostics extracts named compiler diagnostics from the corpus. The
// funpack-spec carries no diagnostic-code registry, so this returns nil today;
// it exists so a future spec that adds one is picked up without an API change.
func scanDiagnostics(_ *docs.Corpus) []Symbol {
	return nil
}
