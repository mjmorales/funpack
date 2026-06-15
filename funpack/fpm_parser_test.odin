package funpack

import "core:testing"

// The .fpm parser builds the model/rig IR over the Solid algebra (spec §16 §2).
// These tests parse a well-formed `rig Krognid { … }` to the expected
// param/fn/part/mirror/clearance counts — the exact-count pin the golden-source
// shape demands (the live krognid.fpm example) — plus per-production unit checks
// and the casing-rejection paths.

// KROGNID_RIG mirrors the krognid.fpm example (§16 §7): a humanoid
// rig with five params, six mesh fns, six part bindings, one mirror, a clearance,
// and a material. The counts are pinned exactly below; when the example evolves,
// these counts change in lockstep.
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
	// Six part bindings plus the one material binding share the binds slice.
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
	// A `part ... = torso_mesh()` resolves to the capsule geometry the fn returns
	// — the part's modeled mesh is a scorable Solid through the fn (§16 §7).
	unit, err := fpm_parse(fpm_lex(KROGNID_RIG))
	testing.expect_value(t, err, Fpm_Parse_Error.None)
	torso_fn_solid: Fpm_Solid
	for fn in unit.fns {
		if fn.name == "torso_mesh" {
			torso_fn_solid = fn.solid
		}
	}
	// torso_mesh returns capsule(...).up(0) — a transform over a capsule primitive.
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
	// A `model` block (not a rig) with emit/anchor/socket/material/collide members
	// (§16 §2) parses to the expected binding kinds.
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
	// A call takes named arguments (`pbr(color: teal, rough: 0.7)`) — the
	// not-LL(1) labeled-vs-positional peek (fpm.ebnf header). The labels are
	// recorded on the args.
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
	// The bake-time-only imperative forms (§16 §1): an accumulating `for x in
	// a..b` loop and a local reassignment `acc = expr`. Neither has a `.fun`
	// counterpart.
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
	// let, for, return
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
	// A part's attach bone is an UPPER_IDENT (§16 §7); a lowercase bone is a
	// casing error, named Wrong_Case, not a generic Unexpected_Token.
	src := `rig R {
  part torso at torso = torso_mesh()
}
`
	_, err := fpm_parse(fpm_lex(src))
	testing.expect_value(t, err, Fpm_Parse_Error.Wrong_Case)
}

@(test)
test_fpm_parse_rejects_non_block :: proc(t: ^testing.T) {
	// A .fpm unit must open with `model` or `rig`; anything else is rejected.
	_, err := fpm_parse(fpm_lex("param x: Length = 1"))
	testing.expect_value(t, err, Fpm_Parse_Error.Unexpected_Token)
}
