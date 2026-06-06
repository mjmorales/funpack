package funpack

import "core:testing"

// Hand-built `.flvl` fixtures exercising each §17 production, pinning the parsed
// AST node counts and shapes — NOT the spec arena example yet (that golden
// lands with the bake-integration seam). Each fixture is the minimal source
// that drives one production: a header with bounds, a place with inline params,
// an anchor+offset position, a for-loop, a nested prefab with a dotted override.
// The rejection tests pin that malformed levels fail the grammar — a place
// missing its type, a malformed bounds, an unterminated prefab.

@(test)
test_flvl_parses_header_and_bounds :: proc(t: ^testing.T) {
	src := "level Arena 2d {\n  bounds (0, 0) (160, 120)\n  things arena_world\n}\n"
	level, err := parse_flvl(src)
	testing.expect_value(t, err, Flvl_Parse_Error.None)
	testing.expect_value(t, level.name, "Arena")
	testing.expect_value(t, level.dim, Flvl_Dim.D2)
	testing.expect_value(t, level.has_bounds, true)
	testing.expect_value(t, level.things_module, "arena_world")
	// Each bounds corner is a 2-component coordinate tuple.
	testing.expect_value(t, len(level.bounds_min.components), 2)
	testing.expect_value(t, len(level.bounds_max.components), 2)
	// The corner components parse as Int atoms with the written values.
	min_x, ok_min := level.bounds_min.components[0].(^Flvl_Int_Expr)
	testing.expect(t, ok_min, "bounds min x is an Int atom")
	testing.expect_value(t, min_x.value, 0)
	max_x, ok_max := level.bounds_max.components[0].(^Flvl_Int_Expr)
	testing.expect(t, ok_max, "bounds max x is an Int atom")
	testing.expect_value(t, max_x.value, 160)
	// A bare header has no placements, prefabs, or loops.
	testing.expect_value(t, len(level.places), 0)
	testing.expect_value(t, len(level.prefabs), 0)
	testing.expect_value(t, len(level.fors), 0)
}

@(test)
test_flvl_parses_place_with_params :: proc(t: ^testing.T) {
	// A named placement with two inline blackboard params and a bare-anchor
	// position; one param is a Fixed literal, the other a bare-name (Ref) value.
	src := "level Arena 2d {\n  place Door exit { rate: 2.0, gate: plate } at center\n}\n"
	level, err := parse_flvl(src)
	testing.expect_value(t, err, Flvl_Parse_Error.None)
	testing.expect_value(t, len(level.places), 1)
	place := level.places[0]
	testing.expect_value(t, place.type_name, "Door")
	testing.expect_value(t, place.has_name, true)
	testing.expect_value(t, place.instance_name, "exit")
	testing.expect_value(t, place.has_facing, false)
	testing.expect_value(t, len(place.params), 2)
	// First param: `rate: 2.0` — a flat (single-segment) key, a Fixed value.
	testing.expect_value(t, len(place.params[0].path), 1)
	testing.expect_value(t, place.params[0].path[0], "rate")
	_, rate_is_fixed := place.params[0].value.(^Flvl_Fixed_Expr)
	testing.expect(t, rate_is_fixed, "rate value is a Fixed atom")
	// Second param: `gate: plate` — a bare-name value (resolves to a Ref at bake).
	testing.expect_value(t, place.params[1].path[0], "gate")
	gate_name, gate_is_name := place.params[1].value.(^Flvl_Name_Expr)
	testing.expect(t, gate_is_name, "gate value is a bare-name atom")
	testing.expect_value(t, gate_name.name, "plate")
	// The position is the bare anchor `center`.
	pos_name, pos_is_name := place.position.(^Flvl_Name_Expr)
	testing.expect(t, pos_is_name, "position is a bare anchor name")
	testing.expect_value(t, pos_name.name, "center")
}

@(test)
test_flvl_parses_anchor_offset_position :: proc(t: ^testing.T) {
	// An anchor+offset position with offset arithmetic: a dotted sub-path
	// (`right_edge.center`) plus a named-arg `.offset(x: -48 + i * 24, y: 0)`.
	src := "level Arena 2d {\n  place Pillar at right_edge.center.offset(x: -48 + i * 24, y: 0)\n}\n"
	level, err := parse_flvl(src)
	testing.expect_value(t, err, Flvl_Parse_Error.None)
	testing.expect_value(t, len(level.places), 1)
	place := level.places[0]
	// An anonymous one-off scenery placement: no name, no params, no facing.
	testing.expect_value(t, place.type_name, "Pillar")
	testing.expect_value(t, place.has_name, false)
	testing.expect_value(t, len(place.params), 0)
	// The position is the `.offset(…)` call at the top of the postfix chain.
	offset_call, is_call := place.position.(^Flvl_Call_Expr)
	testing.expect(t, is_call, "position top node is the offset call")
	testing.expect_value(t, len(offset_call.args), 2)
	testing.expect_value(t, len(offset_call.arg_names), 2)
	testing.expect_value(t, offset_call.arg_names[0], "x")
	testing.expect_value(t, offset_call.arg_names[1], "y")
	// The callee is `right_edge.center.offset` — a Member off a Member off the
	// `right_edge` base atom.
	offset_member, is_member := offset_call.callee.(^Flvl_Member_Expr)
	testing.expect(t, is_member, "offset callee is the .offset member step")
	testing.expect_value(t, offset_member.member, "offset")
	center_member, is_center := offset_member.receiver.(^Flvl_Member_Expr)
	testing.expect(t, is_center, "the .center step is a member off right_edge")
	testing.expect_value(t, center_member.member, "center")
	base_name, is_base := center_member.receiver.(^Flvl_Name_Expr)
	testing.expect(t, is_base, "the base atom is the right_edge anchor")
	testing.expect_value(t, base_name.name, "right_edge")
	// The `x:` arg is `-48 + i * 24` — an additive binary whose rhs is a `*`.
	x_add, x_is_add := offset_call.args[0].(^Flvl_Binary_Expr)
	testing.expect(t, x_is_add, "x arg is an additive binary expr")
	testing.expect_value(t, x_add.op, Flvl_Token_Kind.Plus)
	// lhs is the unary-negated 48; rhs is the `i * 24` multiplicative.
	_, lhs_is_neg := x_add.lhs.(^Flvl_Unary_Expr)
	testing.expect(t, lhs_is_neg, "x arg lhs is the negated 48")
	mul, rhs_is_mul := x_add.rhs.(^Flvl_Binary_Expr)
	testing.expect(t, rhs_is_mul, "x arg rhs is i * 24")
	testing.expect_value(t, mul.op, Flvl_Token_Kind.Star)
	loop_var, mul_lhs_is_name := mul.lhs.(^Flvl_Name_Expr)
	testing.expect(t, mul_lhs_is_name, "mul lhs is the loop var i")
	testing.expect_value(t, loop_var.name, "i")
}

@(test)
test_flvl_parses_for_loop :: proc(t: ^testing.T) {
	// A `for i in 0..5 { place … }` repetition with one body placement.
	src := "level Arena 2d {\n  for i in 0..5 {\n    place Pillar at center.offset(x: 12)\n  }\n}\n"
	level, err := parse_flvl(src)
	testing.expect_value(t, err, Flvl_Parse_Error.None)
	testing.expect_value(t, len(level.fors), 1)
	loop := level.fors[0]
	testing.expect_value(t, loop.var, "i")
	// The range bounds are the Int atoms 0 and 5.
	lo, lo_is_int := loop.lo.(^Flvl_Int_Expr)
	testing.expect(t, lo_is_int, "loop lo is an Int atom")
	testing.expect_value(t, lo.value, 0)
	hi, hi_is_int := loop.hi.(^Flvl_Int_Expr)
	testing.expect(t, hi_is_int, "loop hi is an Int atom")
	testing.expect_value(t, hi.value, 5)
	// The body holds exactly one placement, no nested loops or prefabs.
	testing.expect_value(t, len(loop.places), 1)
	testing.expect_value(t, len(loop.fors), 0)
	testing.expect_value(t, len(loop.nested), 0)
	testing.expect_value(t, loop.places[0].type_name, "Pillar")
}

@(test)
test_flvl_parses_nested_prefab_and_override :: proc(t: ^testing.T) {
	// A one-level prefab, a nested prefab inside it, and a placement of the
	// prefab carrying a dotted-path override (`cannon.rate: 4.0`).
	src := "level Arena 2d {\n" +
		"  prefab Turret {\n" +
		"    place Base base at origin\n" +
		"    place Cannon cannon { rate: 2.0 } at base.offset(y: 6)\n" +
		"    prefab Inner {\n" +
		"      place Bolt bolt at origin\n" +
		"    }\n" +
		"  }\n" +
		"  place Turret right_gun { cannon.rate: 4.0 } at right_edge.center.offset(x: -12)\n" +
		"}\n"
	level, err := parse_flvl(src)
	testing.expect_value(t, err, Flvl_Parse_Error.None)
	// One top-level prefab and one top-level placement.
	testing.expect_value(t, len(level.prefabs), 1)
	testing.expect_value(t, len(level.places), 1)
	turret := level.prefabs[0]
	testing.expect_value(t, turret.name, "Turret")
	// The Turret prefab holds two placements and one nested prefab.
	testing.expect_value(t, len(turret.places), 2)
	testing.expect_value(t, len(turret.nested), 1)
	testing.expect_value(t, turret.places[0].type_name, "Base")
	testing.expect_value(t, turret.places[1].instance_name, "cannon")
	// The nested prefab holds its own placement.
	inner := turret.nested[0]
	testing.expect_value(t, inner.name, "Inner")
	testing.expect_value(t, len(inner.places), 1)
	testing.expect_value(t, inner.places[0].type_name, "Bolt")
	// The top-level placement carries a dotted override `cannon.rate: 4.0`.
	place := level.places[0]
	testing.expect_value(t, place.type_name, "Turret")
	testing.expect_value(t, place.instance_name, "right_gun")
	testing.expect_value(t, len(place.params), 1)
	testing.expect_value(t, len(place.params[0].path), 2)
	testing.expect_value(t, place.params[0].path[0], "cannon")
	testing.expect_value(t, place.params[0].path[1], "rate")
	_, rate_is_fixed := place.params[0].value.(^Flvl_Fixed_Expr)
	testing.expect(t, rate_is_fixed, "override value is a Fixed atom")
}

@(test)
test_flvl_rejects_malformed_place :: proc(t: ^testing.T) {
	// A place missing its type name (a lower-case word where UPPER_IDENT is
	// required) rejects as Wrong_Case.
	missing_type := "level Arena 2d {\n  place exit at center\n}\n"
	_, err_type := parse_flvl(missing_type)
	testing.expect_value(t, err_type, Flvl_Parse_Error.Wrong_Case)

	// A malformed bounds (a missing closing paren on the first corner) rejects.
	bad_bounds := "level Arena 2d {\n  bounds (0, 0 (160, 120)\n}\n"
	_, err_bounds := parse_flvl(bad_bounds)
	testing.expect_value(t, err_bounds, Flvl_Parse_Error.Unexpected_Token)

	// An unterminated prefab (no closing `}` before end of input) rejects with
	// the dedicated Unexpected_End arm.
	unterminated := "level Arena 2d {\n  prefab Turret {\n    place Base base at origin\n"
	_, err_prefab := parse_flvl(unterminated)
	testing.expect_value(t, err_prefab, Flvl_Parse_Error.Unexpected_End)
}
