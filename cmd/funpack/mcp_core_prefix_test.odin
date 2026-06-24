// Deliberate spec for the invariant-core prefix (mcp_core_prefix.odin) — the
// always-present `instructions` core assembled from the embedded corpus. These pin the
// load-bearing invariants: every CURATED anchor resolves against the committed corpus
// (so a doc rename that orphans an anchor fails the suite, never a shipped empty
// prefix), the build succeeds and carries every section's title plus the five-things
// lead, and a fabricated missing anchor proves the fail-loudly path. Driven directly
// over core_prefix_build / core_prefix_section_text against the real embedded shards
// (mcp_corpus.odin), no SDL.
package main

import "core:strings"
import "core:testing"

// test_core_prefix_anchors_all_resolve pins that EVERY curated anchor in
// CORE_PREFIX_ANCHORS resolves to a real section in the committed corpus. This is the
// fail-loudly guard a doc rename trips: if a skill renames a heading (and the corpus is
// regenerated) the anchor here orphans and this test fails, forcing the curated set to
// be updated rather than shipping a binary whose initialize silently drops instructions.
@(test)
test_core_prefix_anchors_all_resolve :: proc(t: ^testing.T) {
	sections, ok := load_corpus(context.temp_allocator)
	testing.expect(t, ok, "embedded corpus must parse")

	for entry in CORE_PREFIX_ANCHORS {
		_, found := core_prefix_section_text(sections, entry.anchor)
		testing.expectf(t, found, "curated core-prefix anchor must resolve in the corpus: %s", entry.anchor)
	}
}

// test_core_prefix_build_carries_core pins that the assembled prefix builds clean and
// carries the curated core: the preamble, the five-things lead, every entry's title
// heading, and a prelude marker. The byte size is asserted bounded (a few KB) so the
// prefix stays compact — a curation slip that dumped a large section would blow this.
@(test)
test_core_prefix_build_carries_core :: proc(t: ^testing.T) {
	prefix, ok := core_prefix_build(context.temp_allocator)
	testing.expect(t, ok, "core prefix must build clean against the committed corpus")
	testing.expect(t, len(prefix) > 0, "core prefix must be non-empty")

	// Compact: the curated set (five things + a small grammar cheat-sheet + prelude) is
	// a few KB — well under 16 KB. A blown bound means a non-curated section leaked in.
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
	// Every curated label is written as a heading, so each section is navigable.
	for entry in CORE_PREFIX_ANCHORS {
		testing.expectf(
			t,
			strings.contains(prefix, entry.label),
			"core prefix must carry the section heading: %s",
			entry.label,
		)
	}
	// A prelude type the model relies on (Option) must be in the assembled text.
	testing.expect(t, strings.contains(prefix, "prelude.Option"), "core prefix must carry the prelude type list")
}

// test_core_prefix_section_text_missing_anchor proves the fail-loudly path: an anchor
// not in the corpus returns found=false, which core_prefix_build maps to ok=false (no
// instructions emitted) rather than a silently-truncated prefix.
@(test)
test_core_prefix_section_text_missing_anchor :: proc(t: ^testing.T) {
	sections, ok := load_corpus(context.temp_allocator)
	testing.expect(t, ok, "embedded corpus must parse")

	_, found := core_prefix_section_text(sections, "skills/funpack-language/SKILL.md#this-anchor-does-not-exist")
	testing.expect(t, !found, "an unknown anchor must report found=false (the fail-loudly path)")
}
