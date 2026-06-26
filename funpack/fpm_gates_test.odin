package funpack

import "core:testing"

// The §16.3 geometry-invariant gate stage scores the Solid IR (spec §16 §3).
// These tests assert each HARD gate (Non_Manifold, Self_Intersecting,
// Zero_Volume, Over_Budget) FAILs on a hand-built fixture, the SOFT
// size-threshold decomposition guidance only WARNs (warn-not-fail), and a
// well-formed rig (the krognid example) passes clean — one passing case per
// Fpm_Gate_Error arm, plus the warn case the acceptance criterion calls for.
//
// Each fixture is a real `.fpm` source run through fpm_lex → fpm_parse → the
// gate, so the gate is exercised over genuine parser output, not a synthetic IR.

// fpm_gate is the test helper: lex + parse a .fpm source and return the gate
// verdict, failing the test if the source does not parse (a gate fixture must be
// well-formed syntax — the gate scores geometry, not grammar).
fpm_gate :: proc(t: ^testing.T, src: string) -> Fpm_Gate_Verdict {
	unit, err := fpm_parse(fpm_lex(src))
	testing.expect_value(t, err, Fpm_Parse_Error.None)
	return fpm_gate_verdict(unit)
}

@(test)
test_fpm_gate_zero_volume_fails :: proc(t: ^testing.T) {
	// A zero-radius capsule is a degenerate primitive — zero volume — the §16.3
	// Zero_Volume hard fail.
	src := `model Bad {
  emit capsule(0, 16)
}
`
	verdict := fpm_gate(t, src)
	testing.expect_value(t, verdict.err, Fpm_Gate_Error.Zero_Volume)
}

@(test)
test_fpm_gate_zero_volume_via_carved_difference :: proc(t: ^testing.T) {
	// A difference whose subtrahend fully carves the base leaves zero volume —
	// the §16.3 Zero_Volume case for a degenerate boolean. Identical box operands:
	// base minus an equal-volume cut carves to nothing.
	src := `model Carved {
  emit difference(box(10, 10, 10), box(10, 10, 10))
}
`
	verdict := fpm_gate(t, src)
	testing.expect_value(t, verdict.err, Fpm_Gate_Error.Zero_Volume)
}

@(test)
test_fpm_gate_over_budget_fails :: proc(t: ^testing.T) {
	// An oversized primitive tessellates past the hard triangle ceiling
	// (MAX_TRIANGLES) — the §16.3 Over_Budget hard fail. A radius-60 sphere is
	// well over budget while staying watertight and non-degenerate, so Over_Budget
	// is the gate that fires (not zero-volume or non-manifold).
	src := `model Heavy {
  emit sphere(60)
}
`
	verdict := fpm_gate(t, src)
	testing.expect_value(t, verdict.err, Fpm_Gate_Error.Over_Budget)
}

@(test)
test_fpm_gate_non_manifold_fails :: proc(t: ^testing.T) {
	// A union of two COINCIDENT solids (identical geometry in the same place)
	// welds a non-manifold doubled seam — the §16.3 Non_Manifold hard fail.
	src := `model Doubled {
  emit union(sphere(7), sphere(7))
}
`
	verdict := fpm_gate(t, src)
	testing.expect_value(t, verdict.err, Fpm_Gate_Error.Non_Manifold)
}

@(test)
test_fpm_gate_self_intersecting_fails :: proc(t: ^testing.T) {
	// A negative scale flips the surface inside-out — an inverted-normal,
	// self-intersecting solid — the §16.3 Self_Intersecting hard fail.
	src := `model Inverted {
  emit box(2, 2, 2).scale(-1)
}
`
	verdict := fpm_gate(t, src)
	testing.expect_value(t, verdict.err, Fpm_Gate_Error.Self_Intersecting)
}

@(test)
test_fpm_gate_decompose_warns_not_fails :: proc(t: ^testing.T) {
	// A mesh past the SOFT size threshold (DECOMPOSE_TRIANGLES) but under the hard
	// ceiling is bakeable — it WARNS that it should decompose, it does NOT fail
	// (§16 §3). A radius-30 sphere lands between the two thresholds: clean hard
	// verdict, Should_Decompose warning.
	src := `model Big {
  emit sphere(30)
}
`
	verdict := fpm_gate(t, src)
	testing.expect_value(t, verdict.err, Fpm_Gate_Error.None)
	testing.expect_value(t, verdict.warning, Fpm_Gate_Warning.Should_Decompose)
}

@(test)
test_fpm_gate_wellformed_rig_passes_clean :: proc(t: ^testing.T) {
	// The krognid rig — every part a rig-scale capsule/sphere — passes the hard
	// gates AND stays under the soft threshold: a clean, warning-free verdict.
	unit, err := fpm_parse(fpm_lex(KROGNID_RIG))
	testing.expect_value(t, err, Fpm_Parse_Error.None)
	verdict := fpm_gate_verdict(unit)
	testing.expect_value(t, verdict.err, Fpm_Gate_Error.None)
	testing.expect_value(t, verdict.warning, Fpm_Gate_Warning.None)
}

@(test)
test_fpm_gate_names_offending_binding :: proc(t: ^testing.T) {
	// A hard verdict names the offending binding (the diagnostic anchor), so a
	// multi-binding model points at the degenerate one. A collide proxy with a
	// zero height fails and names "proxy".
	src := `model Named {
  emit sphere(7)
  collide proxy = box(10, 10, 0)
}
`
	verdict := fpm_gate(t, src)
	testing.expect_value(t, verdict.err, Fpm_Gate_Error.Zero_Volume)
	testing.expect_value(t, verdict.binding, "proxy")
}

@(test)
test_fpm_gate_intersect_verdict_is_operand_order_independent :: proc(t: ^testing.T) {
	// An intersect's manifold verdict must not depend on operand order. A
	// self-intersecting big operand (box.scale(-1), volume 8) intersected with a
	// smaller clean operand (box, volume 1) is self-intersecting EITHER way — the OR
	// accumulates over all operands, not just the min-volume one. Before the fix, the
	// big-first order dropped the inverted-surface flag when `out` was replaced by the
	// smaller clean operand, so only the clean-first order fired the gate.
	big_first := `model BigFirst {
  emit intersect(box(2, 2, 2).scale(-1), box(1, 1, 1))
}
`
	clean_first := `model CleanFirst {
  emit intersect(box(1, 1, 1), box(2, 2, 2).scale(-1))
}
`
	testing.expect_value(t, fpm_gate(t, big_first).err, Fpm_Gate_Error.Self_Intersecting)
	testing.expect_value(t, fpm_gate(t, clean_first).err, Fpm_Gate_Error.Self_Intersecting)
}

@(test)
test_fpm_stage_gates_returns_first_error :: proc(t: ^testing.T) {
	// stage_fpm_gates is the pipeline seam — it returns just the first hard error,
	// the form the bake driver consumes (mirrors stage_gates for .fun).
	src := `model Bad {
  emit capsule(0, 16)
}
`
	unit, err := fpm_parse(fpm_lex(src))
	testing.expect_value(t, err, Fpm_Parse_Error.None)
	testing.expect_value(t, stage_fpm_gates(unit), Fpm_Gate_Error.Zero_Volume)
}
