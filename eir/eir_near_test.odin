// Near-tier tests: the Type-3 surface's floor is (1) two declarations that diverge in a
// single statement are reported as ONE near-miss pair above a low cutoff, (2) two
// EXACT clones (identical modulo bound-name renaming) are NOT reported — that is the dup
// tier's, and the two surfaces stay disjoint, (3) raising the cutoff past the pair's
// similarity drops it (the cutoff is real), (4) two unrelated declarations produce no pair
// (an empty projection), and (5) the reported pair projects to one `near` Warning whose
// message carries the similarity and attaches the counterpart as a note. Each fixture is a
// real multi-declaration source parsed through the loader, so the tests exercise the tier
// over genuine core:odin/ast trees. The shared fixture helpers (fixture_root / write_fixture
// / remove_tree) come from eir_discover_test.odin.
package eir

import "core:strings"
import "core:testing"

// near_opts is a terse Near_Options constructor for the tests; min_nodes 4 admits the
// small fixture procs as candidates.
@(private = "file")
near_opts :: proc(similarity_pct: int) -> Near_Options {
	return Near_Options{min_nodes = 4, similarity_pct = similarity_pct, fold_literals = false}
}

// NEAR_SRC: two procs that share five of six statements and diverge in exactly one (the
// last assignment is `+` in alpha, `-` in beta). Every bound name is also renamed, so the
// shared statements must collide through positional-slot canonicalization while the one
// differing statement keeps the pair below an exact clone.
@(private = "file")
NEAR_SRC :: `package p

alpha :: proc(a: int) -> int {
	x := a + a
	y := x * a
	z := y - a
	w := z + x
	v := w + y
	return v
}

beta :: proc(b: int) -> int {
	x := b + b
	y := x * b
	z := y - b
	w := z + x
	v := w - y
	return v
}
`

// EXACT_SRC: two procs identical in structure with every bound name renamed (Type-2
// exact). Their proc literals canonicalize identically, so the near tier must EXCLUDE the
// pair — it belongs to `eir dup`.
@(private = "file")
EXACT_SRC :: `package p

gamma :: proc(p: int) -> int {
	m := p + p
	n := m * p
	o := n - p
	return o
}

delta :: proc(q: int) -> int {
	m := q + q
	n := m * q
	o := n - q
	return o
}
`

// DISTINCT_SRC: two procs sharing no statement structure, so the tier reports no pair.
@(private = "file")
DISTINCT_SRC :: `package p

solo_one :: proc(a: int) -> int {
	x := a + a + a + a
	y := x * x * x
	return y - a
}

solo_two :: proc(s: string) -> int {
	n := len(s) + 1
	m := n * n * n
	return m + n
}
`

// test_near_reports_similar_pair: the one-statement divergence is a single near-miss pair
// at a low cutoff, oriented a-before-b by span.
@(test)
test_near_reports_similar_pair :: proc(t: ^testing.T) {
	result := load_source_fixture("near_sim", NEAR_SRC)
	pairs := find_near_clones(result, near_opts(50), context.temp_allocator)

	testing.expect_value(t, len(pairs), 1)
	if len(pairs) == 1 {
		p := pairs[0]
		testing.expect(t, p.a.line_start < p.b.line_start, "the pair must be oriented a-before-b by span")
		testing.expect(t, p.similarity_permille > 0 && p.similarity_permille < 1000, "a near pair is neither disjoint nor exact")
	}
}

// test_near_excludes_exact_clones: two alpha-renamed-identical procs are an EXACT clone,
// excluded from the near surface at any cutoff.
@(test)
test_near_excludes_exact_clones :: proc(t: ^testing.T) {
	result := load_source_fixture("near_exact", EXACT_SRC)
	pairs := find_near_clones(result, near_opts(10), context.temp_allocator)
	testing.expect_value(t, len(pairs), 0)
}

// test_near_respects_threshold: the same pair is found below its similarity and gone at a
// cutoff above it (100% admits only identical fingerprints, which a near pair is not).
@(test)
test_near_respects_threshold :: proc(t: ^testing.T) {
	result := load_source_fixture("near_thresh", NEAR_SRC)

	low := find_near_clones(result, near_opts(10), context.temp_allocator)
	testing.expect(t, len(low) == 1, "a low cutoff must find the near pair")

	high := find_near_clones(result, near_opts(100), context.temp_allocator)
	testing.expect_value(t, len(high), 0)
}

// test_near_diagnostics_projection: the reported pair projects to one `near` Warning whose
// message carries the similarity percent and names the counterpart, with the b-site attached
// as the single related note — the near tier's whole projection onto the shared surface.
@(test)
test_near_diagnostics_projection :: proc(t: ^testing.T) {
	result := load_source_fixture("near_diag", NEAR_SRC)
	pairs := find_near_clones(result, near_opts(50), context.temp_allocator)
	testing.expect_value(t, len(pairs), 1)

	diags := near_diagnostics(pairs, context.temp_allocator)
	testing.expect_value(t, len(diags), 1)
	if len(diags) == 1 {
		testing.expect_value(t, diags[0].severity, Severity.Warning)
		testing.expect_value(t, diags[0].rule, "near")
		testing.expect(t, strings.contains(diags[0].message, "near-miss"), "the message names the relation")
		testing.expect(t, strings.contains(diags[0].message, "%"), "the message carries the similarity percent")
		testing.expect_value(t, len(diags[0].related), 1) // the counterpart site
	}
}

// test_near_no_pairs_empty: unrelated declarations yield no pair, so the projection is empty —
// the shared renderer turns that into the "no findings" line (pinned in the diagnostic test).
@(test)
test_near_no_pairs_empty :: proc(t: ^testing.T) {
	result := load_source_fixture("near_distinct", DISTINCT_SRC)
	pairs := find_near_clones(result, near_opts(50), context.temp_allocator)
	testing.expect_value(t, len(pairs), 0)
	testing.expect_value(t, len(near_diagnostics(pairs, context.temp_allocator)), 0)
}
