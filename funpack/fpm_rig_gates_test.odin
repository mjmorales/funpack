package funpack

import "core:testing"

// The §16.7 rig gate stage scores a parsed `rig` unit against the four rig
// invariants (spec §16 §7, extending P5 to rigs). These tests assert each HARD
// gate FAILs on a hand-built rig fixture — a part whose origin contradicts its bone
// pivot (Part_Pivot_Mismatch), a part binding with no mesh (Unbound_Slot), a part
// authored on a mirror's generated side (Duplicate_Mirrored_Side) — and that a
// joint tighter than the declared clearance only WARNs (Below_Clearance, not a
// fail). The clean krognid rig passes both the hard gates and the warning.
//
// Each fixture is a real `.fpm` rig run through fpm_lex → fpm_parse → the rig gate,
// so the gate is exercised over genuine parser output, not a synthetic IR.

// fpm_rig is the test helper: lex + parse a rig source and return the §16.7
// verdict, failing the test if the source does not parse (a gate fixture must be
// well-formed syntax — the gate scores rig structure, not grammar).
fpm_rig :: proc(t: ^testing.T, src: string) -> Fpm_Rig_Verdict {
	unit, err := fpm_parse(fpm_lex(src))
	testing.expect_value(t, err, Fpm_Parse_Error.None)
	return fpm_rig_verdict(unit)
}

@(test)
test_fpm_rig_part_pivot_mismatch_fails :: proc(t: ^testing.T) {
	// A limb bone's part must hang DOWN from its proximal joint (`.down(h)` — the
	// joint at the modeled origin). Authoring the upper arm `.up(limb_h)` instead
	// puts the geometry above origin, displacing the shoulder joint off (0,0,0) —
	// the §16.7 part-origin-vs-bone-pivot error.
	src := `rig Mis {
  skeleton: humanoid
  param limb_h: Length = 16
  param limb_r: Length = 4
  fn arm() -> Solid { return capsule(limb_r, limb_h).up(limb_h) }
  part upper_arm at L_UPPER_ARM = arm()
}
`
	verdict := fpm_rig(t, src)
	testing.expect_value(t, verdict.err, Fpm_Rig_Error.Part_Pivot_Mismatch)
	testing.expect_value(t, verdict.part, "upper_arm")
}

@(test)
test_fpm_rig_unbound_slot_fails :: proc(t: ^testing.T) {
	// A part binding must resolve to mesh geometry. A `part ... = body` whose value
	// is a non-geometry expression (a bare param, not a Solid-producing fn or
	// primitive) leaves the slot unbound — the §16.7 every-bound-slot-has-a-mesh
	// error.
	src := `rig Empty {
  skeleton: humanoid
  param torso_h: Length = 24
  part torso at TORSO = torso_h
}
`
	verdict := fpm_rig(t, src)
	testing.expect_value(t, verdict.err, Fpm_Rig_Error.Unbound_Slot)
	testing.expect_value(t, verdict.part, "torso")
}

@(test)
test_fpm_rig_duplicate_mirrored_side_fails :: proc(t: ^testing.T) {
	// A `mirror L -> R` GENERATES the right side; authoring a `part ... at R_UPPER_ARM`
	// alongside it is a redundant double-definition — the §16.7
	// mirrored-side-declared-not-duplicated error. The left part is fine; the
	// right-side authoring is the offender.
	src := `rig Dup {
  skeleton: humanoid
  param limb_h: Length = 16
  param limb_r: Length = 4
  fn arm() -> Solid { return capsule(limb_r, limb_h).down(limb_h) }
  part upper_arm  at L_UPPER_ARM = arm()
  part rupper_arm at R_UPPER_ARM = arm()
  mirror L -> R
}
`
	verdict := fpm_rig(t, src)
	testing.expect_value(t, verdict.err, Fpm_Rig_Error.Duplicate_Mirrored_Side)
	testing.expect_value(t, verdict.part, "rupper_arm")
}

@(test)
test_fpm_rig_below_clearance_warns_not_fails :: proc(t: ^testing.T) {
	// A joint tighter than the declared `clearance` floor is a WARNING, not a fail
	// (§16.7). A capsule limb's modeled joint gap is its length minus its radius; a
	// short, fat segment (length 5, radius 4 => gap 1) sits below a `clearance 1.5`
	// floor, so the rig is bakeable but WARNS. The hard verdict stays clean.
	src := `rig Tight {
  skeleton: humanoid
  fn arm() -> Solid { return capsule(4, 5).down(5) }
  part upper_arm at L_UPPER_ARM = arm()
  clearance 1.5
}
`
	verdict := fpm_rig(t, src)
	testing.expect_value(t, verdict.err, Fpm_Rig_Error.None)
	testing.expect_value(t, verdict.warning, Fpm_Rig_Warning.Below_Clearance)
}

@(test)
test_fpm_rig_clearance_met_no_warn :: proc(t: ^testing.T) {
	// A joint at-or-above the clearance floor does NOT warn. A capsule limb (length
	// 16, radius 4 => gap 12) clears a `clearance 1.5` floor, so the rig is both
	// hard-clean and warning-free — the warn-not-fail gate's negative arm.
	src := `rig Roomy {
  skeleton: humanoid
  fn arm() -> Solid { return capsule(4, 16).down(16) }
  part upper_arm at L_UPPER_ARM = arm()
  clearance 1.5
}
`
	verdict := fpm_rig(t, src)
	testing.expect_value(t, verdict.err, Fpm_Rig_Error.None)
	testing.expect_value(t, verdict.warning, Fpm_Rig_Warning.None)
}

@(test)
test_fpm_rig_wellformed_krognid_passes_clean :: proc(t: ^testing.T) {
	// The krognid rig — every part anchored to its bone's pivot discipline (torso
	// `.up`, limbs `.down`, head centered), no part on the generated right side,
	// and every joint clearing the 1.5 floor — passes the §16.7 hard gates AND the
	// clearance warning. A clean, warning-free verdict.
	verdict := fpm_rig(t, KROGNID_RIG)
	testing.expect_value(t, verdict.err, Fpm_Rig_Error.None)
	testing.expect_value(t, verdict.warning, Fpm_Rig_Warning.None)
}

@(test)
test_fpm_rig_digest_counts :: proc(t: ^testing.T) {
	// The §16.7 rest-pose digest projects the named skeleton's bone count (humanoid
	// => 16) and the bound part count (6), pivots verified on a clean rig. The
	// structural post-mirror count adds a generated counterpart per side-prefixed
	// limb part: 6 parts, 4 limbs (the arms and legs) => 10 (the central torso/head
	// generate none). These counts pin the live krognid source; when the example
	// evolves they change in lockstep.
	unit, err := fpm_parse(fpm_lex(KROGNID_RIG))
	testing.expect_value(t, err, Fpm_Parse_Error.None)
	verdict := fpm_rig_verdict(unit)
	testing.expect_value(t, verdict.digest.bones, 16)
	testing.expect_value(t, verdict.digest.parts, 6)
	testing.expect_value(t, verdict.digest.parts_mirrored, 10)
	testing.expect(t, verdict.digest.pivots_verified, "a clean rig verifies every part pivot")
}

@(test)
test_fpm_stage_rig_gates_returns_first_error :: proc(t: ^testing.T) {
	// stage_fpm_rig_gates is the pipeline seam — it returns just the first hard
	// error, the form the bake driver consumes (mirrors stage_fpm_gates for the
	// geometry gate).
	src := `rig Mis {
  skeleton: humanoid
  param limb_h: Length = 16
  param limb_r: Length = 4
  fn arm() -> Solid { return capsule(limb_r, limb_h).up(limb_h) }
  part upper_arm at L_UPPER_ARM = arm()
}
`
	unit, err := fpm_parse(fpm_lex(src))
	testing.expect_value(t, err, Fpm_Parse_Error.None)
	testing.expect_value(t, stage_fpm_rig_gates(unit), Fpm_Rig_Error.Part_Pivot_Mismatch)
}
