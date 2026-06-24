// The INVARIANT-CORE PREFIX — the funpack agent-facing core assembled once at
// initialize time into the MCP InitializeResult.instructions field, the
// spec-sanctioned always-present channel (MCP rev 2025-06-18) a client folds into
// its system prompt. Because instructions rides the stable conversation prefix, the
// Anthropic prompt cache holds it once and serves it cheaply for the whole session —
// pay-once, not re-retrieved per query. This is the cache-prefix half of the docs
// surface; the per-call docs_get/docs_search half (mcp_tools_docs.odin) stays for
// everything NOT in the invariant core.
//
// SINGLE-SOURCED: the prefix is composed from a CURATED set of anchors already
// embedded in the docs corpus (mcp_corpus.odin) — NO prose is hand-authored here, so
// the prefix can never drift from the canonical skill/spec text. core_prefix_build
// scans the merged corpus for each anchor in CORE_PREFIX_ANCHORS, in order, and
// concatenates their text under titled sections.
//
// FAIL LOUDLY: a CORE_PREFIX_ANCHORS entry that resolves to NO corpus section is a
// build/curation defect (the anchor was renamed or dropped from a skill, or the
// corpus was not regenerated) — core_prefix_build returns ok=false so the caller emits
// NO instructions rather than a silently-truncated prefix. A test
// (mcp_core_prefix_test.odin) pins that every curated anchor resolves against the
// committed corpus, so a doc rename that orphans an anchor fails the suite, not a
// shipped empty prefix.
//
// WHY NOT anti-priors: the anti-priors table grows with every breaking change, so
// inlining it would bust the cache on each surface change — it stays on-demand via
// docs_search/docs_get (reachable as an embedded corpus section). The invariant core
// is the STABLE subset: the five things, a small grammar cheat-sheet, the prelude type
// list — content that changes only on a deliberate language revision.
package main

import "core:strings"

// Core_Prefix_Anchor is one curated entry of the invariant-core prefix: the corpus
// anchor to pull verbatim and the human heading to write above it. The anchor MUST
// resolve to a real corpus section (the fail-loudly contract); the label is the
// section heading the assembled prefix carries so the model can navigate it.
Core_Prefix_Anchor :: struct {
	anchor: string,
	label:  string,
}

// CORE_PREFIX_ANCHORS is the curated, ORDERED anchor set composing the invariant-core
// prefix — lead with the five things (the highest-leverage trip-ups), then a compact
// grammar cheat-sheet (the structural anchors only — declaration inventory, the
// glyph/precedence rules, types, statements, the compile-error floors — NOT all 26
// grammar sections, so the prefix stays a few KB), then the prelude type list. This is
// the STABLE subset only; the anti-priors table is deliberately excluded (it grows per
// breaking change and would bust the cache). Each anchor is verified to resolve by the
// init-time build and by a test, so a renamed/dropped anchor fails loudly.
CORE_PREFIX_ANCHORS := [?]Core_Prefix_Anchor {
	// The five things that trip people up — the compact, highest-leverage core.
	{
		anchor = "skills/funpack-language/SKILL.md#read-this-first-the-five-things-that-trip-people-up",
		label  = "The five things that trip people up",
	},
	// Grammar cheat-sheet — a curated structural subset, not the full grammar.
	{anchor = "skills/funpack-language/references/grammar.md#all-declaration-productions", label = "Declaration inventory"},
	{anchor = "skills/funpack-language/references/grammar.md#one-concept-per-glyph", label = "One concept per glyph"},
	{anchor = "skills/funpack-language/references/grammar.md#operator-precedence-low-high", label = "Operator precedence (low → high)"},
	{anchor = "skills/funpack-language/references/grammar.md#types", label = "Types"},
	{anchor = "skills/funpack-language/references/grammar.md#statements", label = "Statements"},
	{anchor = "skills/funpack-language/references/grammar.md#structural-floors-compile-errors-not-warnings", label = "Structural floors (compile errors, not warnings)"},
	// The prelude type list — always in scope, no import.
	{anchor = "engine/prelude#bool", label = "prelude.Bool"},
	{anchor = "engine/prelude#int", label = "prelude.Int"},
	{anchor = "engine/prelude#fixed", label = "prelude.Fixed"},
	{anchor = "engine/prelude#float", label = "prelude.Float"},
	{anchor = "engine/prelude#string", label = "prelude.String"},
	{anchor = "engine/prelude#ordering", label = "prelude.Ordering"},
	{anchor = "engine/prelude#option", label = "prelude.Option"},
	{anchor = "engine/prelude#result", label = "prelude.Result"},
	{anchor = "engine/prelude#is-some", label = "prelude.is_some"},
	{anchor = "engine/prelude#or-else", label = "prelude.or_else"},
	{anchor = "engine/prelude#to-fixed", label = "prelude.to_fixed"},
	{anchor = "engine/prelude#to-int", label = "prelude.to_int"},
	{anchor = "engine/prelude#compare", label = "prelude.compare"},
}

// CORE_PREFIX_PREAMBLE is the one-line framing the assembled prefix opens with — it
// tells the model what the block is (the invariant funpack core, always in context)
// and where to go for the rest (docs_search/docs_get for anything not here). It is the
// only hand-authored prose in the prefix and carries no surface facts (so it never
// drifts) — it is navigation, not content.
CORE_PREFIX_PREAMBLE :: "# funpack — the invariant core\n\nThis is funpack's stable agent-facing core, always present in context. It is the language's fixed surface: the common trip-ups, a grammar cheat-sheet, and the always-in-scope prelude. For anything else — the engine stdlib, the full grammar, the anti-priors recalibration table, the spec — call the `docs_search` and `docs_get` tools.\n"

// core_prefix_build assembles the invariant-core prefix string from the embedded
// corpus by resolving each CORE_PREFIX_ANCHORS entry, in order, to its section text
// and writing it under its labelled heading. It loads the corpus once (the same
// load_corpus the docs tools use) and anchor-scans it per entry. ok=false on a corpus
// parse failure OR a curated anchor that resolves to no section (the fail-loudly
// contract — the caller emits NO instructions rather than a truncated prefix).
// Allocated in `allocator`.
core_prefix_build :: proc(allocator := context.allocator) -> (prefix: string, ok: bool) {
	sections, corpus_ok := load_corpus(allocator)
	if !corpus_ok {
		return "", false
	}

	b := strings.builder_make(allocator)
	strings.write_string(&b, CORE_PREFIX_PREAMBLE)

	for entry in CORE_PREFIX_ANCHORS {
		text, found := core_prefix_section_text(sections, entry.anchor)
		if !found {
			// A curated anchor with no matching section is a curation/regen defect —
			// fail loudly so the caller emits no instructions, never a partial prefix.
			return "", false
		}
		strings.write_string(&b, "\n## ")
		strings.write_string(&b, entry.label)
		strings.write_string(&b, "\n\n")
		strings.write_string(&b, text)
		strings.write_byte(&b, '\n')
	}

	return strings.to_string(b), true
}

// core_prefix_section_text finds one corpus section by exact anchor and returns its
// body text. The corpus anchor set is unique (mcp_corpus.odin), so the first match is
// the only match; found=false is the unknown-anchor path the build maps to its
// fail-loudly return.
core_prefix_section_text :: proc(sections: []Corpus_Section, anchor: string) -> (text: string, found: bool) {
	for section in sections {
		if section.anchor == anchor {
			return section.text, true
		}
	}
	return "", false
}
