package main

import "core:strings"
import "core:testing"

@(test)
test_core_prefix_anchors_all_resolve :: proc(t: ^testing.T) {
	sections, ok := load_corpus(context.temp_allocator)
	testing.expect(t, ok, "embedded corpus must parse")

	for entry in CORE_PREFIX_ANCHORS {
		_, found := core_prefix_section_text(sections, entry.anchor)
		testing.expectf(t, found, "curated core-prefix anchor must resolve in the corpus: %s", entry.anchor)
	}
}

@(test)
test_core_prefix_build_carries_core :: proc(t: ^testing.T) {
	prefix, ok := core_prefix_build(context.temp_allocator)
	testing.expect(t, ok, "core prefix must build clean against the committed corpus")
	testing.expect(t, len(prefix) > 0, "core prefix must be non-empty")

	testing.expectf(t, len(prefix) < 16 * 1024, "core prefix must stay compact (got %d bytes)", len(prefix))

	testing.expect(
		t,
		strings.contains(prefix, "the invariant core"),
		"core prefix must carry the navigation preamble",
	)
	testing.expect(
		t,
		strings.contains(prefix, "five things that trip people up"),
		"core prefix must lead with the five-things core",
	)
	for entry in CORE_PREFIX_ANCHORS {
		testing.expectf(
			t,
			strings.contains(prefix, entry.label),
			"core prefix must carry the section heading: %s",
			entry.label,
		)
	}
	testing.expect(t, strings.contains(prefix, "prelude.Option"), "core prefix must carry the prelude type list")
}

@(test)
test_core_prefix_section_text_missing_anchor :: proc(t: ^testing.T) {
	sections, ok := load_corpus(context.temp_allocator)
	testing.expect(t, ok, "embedded corpus must parse")

	_, found := core_prefix_section_text(sections, "skills/funpack-language/SKILL.md#this-anchor-does-not-exist")
	testing.expect(t, !found, "an unknown anchor must report found=false (the fail-loudly path)")
}
