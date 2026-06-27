package eir

import "core:strings"
import "core:testing"

@(private = "file")
near_opts :: proc(similarity_pct: int) -> Near_Options {
	return Near_Options{min_nodes = 4, similarity_pct = similarity_pct, fold_literals = false}
}

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

@(test)
test_near_excludes_exact_clones :: proc(t: ^testing.T) {
	result := load_source_fixture("near_exact", EXACT_SRC)
	pairs := find_near_clones(result, near_opts(10), context.temp_allocator)
	testing.expect_value(t, len(pairs), 0)
}

@(test)
test_near_respects_threshold :: proc(t: ^testing.T) {
	result := load_source_fixture("near_thresh", NEAR_SRC)

	low := find_near_clones(result, near_opts(10), context.temp_allocator)
	testing.expect(t, len(low) == 1, "a low cutoff must find the near pair")

	high := find_near_clones(result, near_opts(100), context.temp_allocator)
	testing.expect_value(t, len(high), 0)
}

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
		testing.expect_value(t, len(diags[0].related), 1)
	}
}

@(test)
test_near_no_pairs_empty :: proc(t: ^testing.T) {
	result := load_source_fixture("near_distinct", DISTINCT_SRC)
	pairs := find_near_clones(result, near_opts(50), context.temp_allocator)
	testing.expect_value(t, len(pairs), 0)
	testing.expect_value(t, len(near_diagnostics(pairs, context.temp_allocator)), 0)
}
