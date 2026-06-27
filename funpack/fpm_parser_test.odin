package funpack

import "core:testing"

KROGNID_RIG :: `// krognid.fpm — a rig: parts + skeleton + their pivots. Bake-time, imperative, float-ok.
rig Krognid {
  skeleton: humanoid

  param torso_h: Length = 24
  param torso_r: Length = 10
  param head_r:  Length = 7
  param limb_h:  Length = 16
  param limb_r:  Length = 4

  fn torso_mesh() -> Solid { return capsule(torso_r, torso_h).up(0) }
  fn head_mesh()  -> Solid { return sphere(head_r) }
  fn upper_arm()  -> Solid { return capsule(limb_r, limb_h).down(limb_h) }
  fn lower_arm()  -> Solid { return capsule(limb_r * 0.85, limb_h).down(limb_h) }
  fn upper_leg()  -> Solid { return capsule(limb_r * 1.2, limb_h).down(limb_h) }
  fn lower_leg()  -> Solid { return capsule(limb_r, limb_h).down(limb_h) }

  part torso     at TORSO       = torso_mesh()
  part head      at HEAD        = head_mesh()
  part upper_arm at L_UPPER_ARM = upper_arm()
  part lower_arm at L_LOWER_ARM = lower_arm()
  part upper_leg at L_UPPER_LEG = upper_leg()
  part lower_leg at L_LOWER_LEG = lower_leg()

  mirror L -> R
  clearance 1.5

  material body = pbr(color: teal, rough: 0.7)
}
`

@(test)
test_fpm_parse_krognid_rig_counts :: proc(t: ^testing.T) {
	unit, err := fpm_parse(fpm_lex(KROGNID_RIG))
	testing.expect_value(t, err, Fpm_Parse_Error.None)
	testing.expect_value(t, unit.name, "Krognid")
	testing.expect(t, unit.is_rig, "Krognid is a rig block")
	testing.expect_value(t, unit.skeleton, "humanoid")
	testing.expect_value(t, len(unit.params), 5)
	testing.expect_value(t, len(unit.fns), 6)
	part_count := 0
	material_count := 0
	for bind in unit.binds {
		if bind.kind == .Part {
			part_count += 1
		}
		if bind.kind == .Material {
			material_count += 1
		}
	}
	testing.expect_value(t, part_count, 6)
	testing.expect_value(t, material_count, 1)
	testing.expect_value(t, len(unit.mirrors), 1)
	testing.expect_value(t, unit.mirrors[0].from, "L")
	testing.expect_value(t, unit.mirrors[0].to, "R")
	testing.expect(t, unit.has_clearance, "clearance is declared")
	testing.expect(t, abs(unit.clearance - 1.5) < 1e-9, "clearance is 1.5")
}

@(test)
test_fpm_parse_part_resolves_to_solid_via_fn :: proc(t: ^testing.T) {
	unit, err := fpm_parse(fpm_lex(KROGNID_RIG))
	testing.expect_value(t, err, Fpm_Parse_Error.None)
	torso_fn_solid: Fpm_Solid
	for fn in unit.fns {
		if fn.name == "torso_mesh" {
			torso_fn_solid = fn.solid
		}
	}
	xf, is_xf := torso_fn_solid.(^Fpm_Transform)
	testing.expect(t, is_xf, "torso_mesh returns a transform")
	if is_xf {
		testing.expect_value(t, xf.kind, Fpm_Transform_Kind.Up)
		prim, is_prim := xf.inner.(^Fpm_Primitive)
		testing.expect(t, is_prim, "the transform wraps a capsule primitive")
		if is_prim {
			testing.expect_value(t, prim.kind, Fpm_Prim_Kind.Capsule)
		}
	}
}

@(test)
test_fpm_parse_model_block :: proc(t: ^testing.T) {
	src := `model Table {
  param width: Length = 120
  fn leg() -> Solid { return box(6, 6, 70) }
  emit union(box(120, 80, 4), leg())
  anchor seat_top = box(1, 1, 1)
  collide proxy = box(120, 80, 70)
  material body = pbr(color: oak, rough: 0.6)
}
`
	unit, err := fpm_parse(fpm_lex(src))
	testing.expect_value(t, err, Fpm_Parse_Error.None)
	testing.expect_value(t, unit.name, "Table")
	testing.expect(t, !unit.is_rig, "Table is a model, not a rig")
	testing.expect_value(t, len(unit.params), 1)
	testing.expect_value(t, len(unit.fns), 1)
	emit_count, collide_count := 0, 0
	for bind in unit.binds {
		if bind.kind == .Emit {
			emit_count += 1
		}
		if bind.kind == .Collide {
			collide_count += 1
		}
	}
	testing.expect_value(t, emit_count, 1)
	testing.expect_value(t, collide_count, 1)
}

@(test)
test_fpm_parse_named_call_args :: proc(t: ^testing.T) {
	unit, err := fpm_parse(fpm_lex("model M {\nmaterial body = pbr(color: teal, rough: 0.7)\n}\n"))
	testing.expect_value(t, err, Fpm_Parse_Error.None)
	testing.expect_value(t, len(unit.binds), 1)
	call, is_call := unit.binds[0].value.(^Fpm_Call)
	testing.expect(t, is_call, "material value is a call")
	if is_call {
		testing.expect_value(t, len(call.args), 2)
		testing.expect(t, call.args[0].labeled, "first arg is labeled")
		testing.expect_value(t, call.args[0].label, "color")
		testing.expect(t, call.args[1].labeled, "second arg is labeled")
		testing.expect_value(t, call.args[1].label, "rough")
	}
}

@(test)
test_fpm_parse_accumulating_loop_and_assign :: proc(t: ^testing.T) {
	src := `model M {
  fn build() -> Solid {
    let acc = box(1, 1, 1)
    for i in 0..3 {
      acc = union(acc, box(1, 1, 1))
    }
    return acc
  }
}
`
	unit, err := fpm_parse(fpm_lex(src))
	testing.expect_value(t, err, Fpm_Parse_Error.None)
	testing.expect_value(t, len(unit.fns), 1)
	body := unit.fns[0].body
	testing.expect_value(t, len(body), 3)
	_, is_for := body[1].(Fpm_For)
	testing.expect(t, is_for, "second statement is a for-loop")
	if is_for {
		loop := body[1].(Fpm_For)
		_, is_range := loop.iterable.(^Fpm_Range)
		testing.expect(t, is_range, "the loop iterates a range")
		testing.expect_value(t, len(loop.body), 1)
		_, is_assign := loop.body[0].(Fpm_Assign)
		testing.expect(t, is_assign, "the loop body reassigns acc")
	}
}

@(test)
test_fpm_parse_rejects_wrong_case_bone :: proc(t: ^testing.T) {
	src := `rig R {
  part torso at torso = torso_mesh()
}
`
	_, err := fpm_parse(fpm_lex(src))
	testing.expect_value(t, err, Fpm_Parse_Error.Wrong_Case)
}

@(test)
test_fpm_parse_rejects_non_block :: proc(t: ^testing.T) {
	_, err := fpm_parse(fpm_lex("param x: Length = 1"))
	testing.expect_value(t, err, Fpm_Parse_Error.Unexpected_Token)
}
