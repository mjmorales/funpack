package main

import "core:strings"

Core_Prefix_Anchor :: struct {
	anchor: string,
	label:  string,
}

CORE_PREFIX_ANCHORS := [?]Core_Prefix_Anchor {
	{
		anchor = "skills/funpack-language/SKILL.md#read-this-first-the-five-things-that-trip-people-up",
		label  = "The five things that trip people up",
	},
	{anchor = "skills/funpack-language/references/grammar.md#all-declaration-productions", label = "Declaration inventory"},
	{anchor = "skills/funpack-language/references/grammar.md#one-concept-per-glyph", label = "One concept per glyph"},
	{anchor = "skills/funpack-language/references/grammar.md#operator-precedence-low-high", label = "Operator precedence (low → high)"},
	{anchor = "skills/funpack-language/references/grammar.md#types", label = "Types"},
	{anchor = "skills/funpack-language/references/grammar.md#statements", label = "Statements"},
	{anchor = "skills/funpack-language/references/grammar.md#structural-floors-compile-errors-not-warnings", label = "Structural floors (compile errors, not warnings)"},
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

CORE_PREFIX_PREAMBLE :: "# funpack — the invariant core\n\nThis is funpack's stable agent-facing core, always present in context. It is the language's fixed surface: the common trip-ups, a grammar cheat-sheet, and the always-in-scope prelude. For anything else — the engine stdlib, the full grammar, the anti-priors recalibration table, the spec — call the `docs_search` and `docs_get` tools.\n"

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

core_prefix_section_text :: proc(sections: []Corpus_Section, anchor: string) -> (text: string, found: bool) {
	for section in sections {
		if section.anchor == anchor {
			return section.text, true
		}
	}
	return "", false
}
