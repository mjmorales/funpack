package funpack

import "core:testing"

fpm_gate :: proc(t: ^testing.T, src: string) -> Fpm_Gate_Verdict {
	unit, err := fpm_parse(fpm_lex(src))
	testing.expect_value(t, err, Fpm_Parse_Error.None)
	return fpm_gate_verdict(unit)
}

@(test)
test_fpm_gate_zero_volume_fails :: proc(t: ^testing.T) {
	src := `model Bad {
  emit capsule(0, 16)
}
`
	verdict := fpm_gate(t, src)
	testing.expect_value(t, verdict.err, Fpm_Gate_Error.Zero_Volume)
}

@(test)
test_fpm_gate_zero_volume_via_carved_difference :: proc(t: ^testing.T) {
	src := `model Carved {
  emit difference(box(10, 10, 10), box(10, 10, 10))
}
`
	verdict := fpm_gate(t, src)
	testing.expect_value(t, verdict.err, Fpm_Gate_Error.Zero_Volume)
}

@(test)
test_fpm_gate_over_budget_fails :: proc(t: ^testing.T) {
	src := `model Heavy {
  emit sphere(60)
}
`
	verdict := fpm_gate(t, src)
	testing.expect_value(t, verdict.err, Fpm_Gate_Error.Over_Budget)
}

@(test)
test_fpm_gate_non_manifold_fails :: proc(t: ^testing.T) {
	src := `model Doubled {
  emit union(sphere(7), sphere(7))
}
`
	verdict := fpm_gate(t, src)
	testing.expect_value(t, verdict.err, Fpm_Gate_Error.Non_Manifold)
}

@(test)
test_fpm_gate_self_intersecting_fails :: proc(t: ^testing.T) {
	src := `model Inverted {
  emit box(2, 2, 2).scale(-1)
}
`
	verdict := fpm_gate(t, src)
	testing.expect_value(t, verdict.err, Fpm_Gate_Error.Self_Intersecting)
}

@(test)
test_fpm_gate_decompose_warns_not_fails :: proc(t: ^testing.T) {
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
	unit, err := fpm_parse(fpm_lex(KROGNID_RIG))
	testing.expect_value(t, err, Fpm_Parse_Error.None)
	verdict := fpm_gate_verdict(unit)
	testing.expect_value(t, verdict.err, Fpm_Gate_Error.None)
	testing.expect_value(t, verdict.warning, Fpm_Gate_Warning.None)
}

@(test)
test_fpm_gate_names_offending_binding :: proc(t: ^testing.T) {
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
	src := `model Bad {
  emit capsule(0, 16)
}
`
	unit, err := fpm_parse(fpm_lex(src))
	testing.expect_value(t, err, Fpm_Parse_Error.None)
	testing.expect_value(t, stage_fpm_gates(unit), Fpm_Gate_Error.Zero_Volume)
}
