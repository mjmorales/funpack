package funpack

import "core:testing"

fpm_rig :: proc(t: ^testing.T, src: string) -> Fpm_Rig_Verdict {
	unit, err := fpm_parse(fpm_lex(src))
	testing.expect_value(t, err, Fpm_Parse_Error.None)
	return fpm_rig_verdict(unit)
}

@(test)
test_fpm_rig_part_pivot_mismatch_fails :: proc(t: ^testing.T) {
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
	verdict := fpm_rig(t, KROGNID_RIG)
	testing.expect_value(t, verdict.err, Fpm_Rig_Error.None)
	testing.expect_value(t, verdict.warning, Fpm_Rig_Warning.None)
}

@(test)
test_fpm_rig_digest_counts :: proc(t: ^testing.T) {
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
