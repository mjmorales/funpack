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
test_flvl_parses_tilemap_layer :: proc(t: ^testing.T) {
	// The §18 §3 tilemap layer: a `cell`-sized header (contextual `cell` — the
	// word lexes as an Ident, the header reads its text), a legend covering
	// every bind form (tile / anonymous spawn / named spawn / empty), and a
	// dedented TripleString grid.
	src := "level Dungeon 2d {\n" +
		"  bounds (0, 0) (64, 32)\n" +
		"  things dungeon_world\n" +
		"  tilemap terrain cell 16 {\n" +
		"    legend {\n" +
		"      '#' wall\n" +
		"      '.' floor\n" +
		"      'g' spawn Slime\n" +
		"      'P' spawn Player hero\n" +
		"      ' ' empty\n" +
		"    }\n" +
		"    grid \"\"\"\n" +
		"      ####\n" +
		"      #P g\n" +
		"      ####\n" +
		"    \"\"\"\n" +
		"  }\n" +
		"}\n"
	level, err := parse_flvl(src)
	testing.expect_value(t, err, Flvl_Parse_Error.None)
	testing.expect_value(t, len(level.tilemaps), 1)
	tm := level.tilemaps[0]
	testing.expect_value(t, tm.name, "terrain")
	testing.expect_value(t, tm.cell_size, 16)

	// Five legend entries in declaration order, each carrying its bind form.
	testing.expect_value(t, len(tm.legend), 5)
	testing.expect_value(t, tm.legend[0].char, '#')
	testing.expect_value(t, tm.legend[0].kind, Flvl_Legend_Kind.Tile)
	testing.expect_value(t, tm.legend[0].tile_name, "wall")
	testing.expect_value(t, tm.legend[2].kind, Flvl_Legend_Kind.Spawn)
	testing.expect_value(t, tm.legend[2].spawn_type, "Slime")
	testing.expect_value(t, tm.legend[2].has_spawn_name, false)
	testing.expect_value(t, tm.legend[3].char, 'P')
	testing.expect_value(t, tm.legend[3].spawn_type, "Player")
	testing.expect_value(t, tm.legend[3].has_spawn_name, true)
	testing.expect_value(t, tm.legend[3].spawn_name, "hero")
	testing.expect_value(t, tm.legend[4].char, ' ')
	testing.expect_value(t, tm.legend[4].kind, Flvl_Legend_Kind.Empty)

	// The grid dedents to its three 4-char rows: the block indentation strips
	// (the grammar's common-leading-indentation rule), and the row with the
	// interior legend space keeps it.
	testing.expect_value(t, len(tm.rows), 3)
	testing.expect_value(t, tm.rows[0], "####")
	testing.expect_value(t, tm.rows[1], "#P g")
	testing.expect_value(t, tm.rows[2], "####")

	// The layer rides the interleaved item record like every LevelItem.
	testing.expect_value(t, len(level.items), 1)
	testing.expect_value(t, level.items[0].kind, Flvl_Item_Kind.Tilemap)
}

@(test)
test_flvl_grid_dedent_keeps_meaningful_leading_space :: proc(t: ^testing.T) {
	// The dedent strips only the COMMON prefix: a row legitimately opening
	// with a legend space narrows the common indent for every row, so the
	// meaningful leading char survives. Here row 2 opens two spaces shallower
	// than the others, so only that much strips.
	src := "level Arena 2d {\n" +
		"  bounds (0, 0) (64, 32)\n" +
		"  things arena_world\n" +
		"  tilemap terrain cell 16 {\n" +
		"    legend {\n" +
		"      '#' wall\n" +
		"      ' ' empty\n" +
		"    }\n" +
		"    grid \"\"\"\n" +
		"      ####\n" +
		"    # ###\n" +
		"      ####\n" +
		"    \"\"\"\n" +
		"  }\n" +
		"}\n"
	level, err := parse_flvl(src)
	testing.expect_value(t, err, Flvl_Parse_Error.None)
	tm := level.tilemaps[0]
	testing.expect_value(t, len(tm.rows), 3)
	testing.expect_value(t, tm.rows[0], "  ####")
	testing.expect_value(t, tm.rows[1], "# ###")
	testing.expect_value(t, tm.rows[2], "  ####")
}

@(test)
test_flvl_parses_cell_anchor_callee :: proc(t: ^testing.T) {
	// `cell` stays an ordinary LOWER_IDENT in anchor position (the contextual-
	// keyword requirement): `at cell(13, 4)` parses as a call whose callee is
	// the bare name `cell` with two positional Int args.
	src := "level Arena 2d {\n  place Chest loot { gems: 5 } at cell(13, 4)\n}\n"
	level, err := parse_flvl(src)
	testing.expect_value(t, err, Flvl_Parse_Error.None)
	testing.expect_value(t, len(level.places), 1)
	call, is_call := level.places[0].position.(^Flvl_Call_Expr)
	testing.expect(t, is_call, "cell() position is a call expr")
	callee, is_name := call.callee.(^Flvl_Name_Expr)
	testing.expect(t, is_name, "cell() callee is a bare name")
	testing.expect_value(t, callee.name, "cell")
	testing.expect_value(t, len(call.args), 2)
	testing.expect_value(t, call.arg_names[0], "")
	col, col_is_int := call.args[0].(^Flvl_Int_Expr)
	testing.expect(t, col_is_int, "cell() col arg is an Int atom")
	testing.expect_value(t, col.value, 13)
}

@(test)
test_flvl_rejects_malformed_tilemap :: proc(t: ^testing.T) {
	// Each malformed §18 §3 form rejects with the closed parse arm it trips —
	// grammar violations are parse rejects; the §18 §5 gates are the bake's.
	legend_body :: "    legend {\n      '#' wall\n    }\n"
	grid_body :: "    grid \"\"\"\n      #\n    \"\"\"\n"

	// The grid ahead of the legend violates the fixed body order.
	grid_first := "level A 2d {\n  tilemap terrain cell 16 {\n" + grid_body + legend_body + "  }\n}\n"
	_, err_order := parse_flvl(grid_first)
	testing.expect_value(t, err_order, Flvl_Parse_Error.Unexpected_Token)

	// A missing contextual `cell` word is out of grammar position.
	no_cell := "level A 2d {\n  tilemap terrain 16 {\n" + legend_body + grid_body + "  }\n}\n"
	_, err_cell := parse_flvl(no_cell)
	testing.expect_value(t, err_cell, Flvl_Parse_Error.Unexpected_Token)

	// A multi-char legend literal is not a Char (the lexer's Invalid token).
	multi_char := "level A 2d {\n  tilemap terrain cell 16 {\n    legend {\n      '##' wall\n    }\n" + grid_body + "  }\n}\n"
	_, err_char := parse_flvl(multi_char)
	testing.expect_value(t, err_char, Flvl_Parse_Error.Unexpected_Token)

	// An empty legend violates the LegendEntry+ production.
	empty_legend := "level A 2d {\n  tilemap terrain cell 16 {\n    legend {\n    }\n" + grid_body + "  }\n}\n"
	_, err_legend := parse_flvl(empty_legend)
	testing.expect_value(t, err_legend, Flvl_Parse_Error.Unexpected_Token)

	// A lower-case marker type is Wrong_Case (spawn takes UPPER_IDENT).
	low_marker := "level A 2d {\n  tilemap terrain cell 16 {\n    legend {\n      'g' spawn slime\n    }\n" + grid_body + "  }\n}\n"
	_, err_case := parse_flvl(low_marker)
	testing.expect_value(t, err_case, Flvl_Parse_Error.Wrong_Case)

	// An unterminated grid block ends the input mid-production.
	unterminated := "level A 2d {\n  tilemap terrain cell 16 {\n" + legend_body + "    grid \"\"\"\n      #\n"
	_, err_end := parse_flvl(unterminated)
	testing.expect_value(t, err_end, Flvl_Parse_Error.Unexpected_End)
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
