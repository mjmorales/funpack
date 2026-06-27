package funpack

import "core:testing"

@(test)
test_flvl_parses_header_and_bounds :: proc(t: ^testing.T) {
	src := "level Arena 2d {\n  bounds (0, 0) (160, 120)\n  things arena_world\n}\n"
	level, err := parse_flvl(src)
	testing.expect_value(t, err, Flvl_Parse_Error.None)
	testing.expect_value(t, level.name, "Arena")
	testing.expect_value(t, level.dim, Flvl_Dim.D2)
	testing.expect_value(t, level.has_bounds, true)
	testing.expect_value(t, level.things_module, "arena_world")
	testing.expect_value(t, len(level.bounds_min.components), 2)
	testing.expect_value(t, len(level.bounds_max.components), 2)
	min_x, ok_min := level.bounds_min.components[0].(^Flvl_Int_Expr)
	testing.expect(t, ok_min, "bounds min x is an Int atom")
	testing.expect_value(t, min_x.value, 0)
	max_x, ok_max := level.bounds_max.components[0].(^Flvl_Int_Expr)
	testing.expect(t, ok_max, "bounds max x is an Int atom")
	testing.expect_value(t, max_x.value, 160)
	testing.expect_value(t, len(level.places), 0)
	testing.expect_value(t, len(level.prefabs), 0)
	testing.expect_value(t, len(level.fors), 0)
}

@(test)
test_flvl_parses_place_with_params :: proc(t: ^testing.T) {
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
	testing.expect_value(t, len(place.params[0].path), 1)
	testing.expect_value(t, place.params[0].path[0], "rate")
	_, rate_is_fixed := place.params[0].value.(^Flvl_Fixed_Expr)
	testing.expect(t, rate_is_fixed, "rate value is a Fixed atom")
	testing.expect_value(t, place.params[1].path[0], "gate")
	gate_name, gate_is_name := place.params[1].value.(^Flvl_Name_Expr)
	testing.expect(t, gate_is_name, "gate value is a bare-name atom")
	testing.expect_value(t, gate_name.name, "plate")
	pos_name, pos_is_name := place.position.(^Flvl_Name_Expr)
	testing.expect(t, pos_is_name, "position is a bare anchor name")
	testing.expect_value(t, pos_name.name, "center")
}

@(test)
test_flvl_parses_anchor_offset_position :: proc(t: ^testing.T) {
	src := "level Arena 2d {\n  place Pillar at right_edge.center.offset(x: -48 + i * 24, y: 0)\n}\n"
	level, err := parse_flvl(src)
	testing.expect_value(t, err, Flvl_Parse_Error.None)
	testing.expect_value(t, len(level.places), 1)
	place := level.places[0]
	testing.expect_value(t, place.type_name, "Pillar")
	testing.expect_value(t, place.has_name, false)
	testing.expect_value(t, len(place.params), 0)
	offset_call, is_call := place.position.(^Flvl_Call_Expr)
	testing.expect(t, is_call, "position top node is the offset call")
	testing.expect_value(t, len(offset_call.args), 2)
	testing.expect_value(t, len(offset_call.arg_names), 2)
	testing.expect_value(t, offset_call.arg_names[0], "x")
	testing.expect_value(t, offset_call.arg_names[1], "y")
	offset_member, is_member := offset_call.callee.(^Flvl_Member_Expr)
	testing.expect(t, is_member, "offset callee is the .offset member step")
	testing.expect_value(t, offset_member.member, "offset")
	center_member, is_center := offset_member.receiver.(^Flvl_Member_Expr)
	testing.expect(t, is_center, "the .center step is a member off right_edge")
	testing.expect_value(t, center_member.member, "center")
	base_name, is_base := center_member.receiver.(^Flvl_Name_Expr)
	testing.expect(t, is_base, "the base atom is the right_edge anchor")
	testing.expect_value(t, base_name.name, "right_edge")
	x_add, x_is_add := offset_call.args[0].(^Flvl_Binary_Expr)
	testing.expect(t, x_is_add, "x arg is an additive binary expr")
	testing.expect_value(t, x_add.op, Flvl_Token_Kind.Plus)
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
	src := "level Arena 2d {\n  for i in 0..5 {\n    place Pillar at center.offset(x: 12)\n  }\n}\n"
	level, err := parse_flvl(src)
	testing.expect_value(t, err, Flvl_Parse_Error.None)
	testing.expect_value(t, len(level.fors), 1)
	loop := level.fors[0]
	testing.expect_value(t, loop.var, "i")
	lo, lo_is_int := loop.lo.(^Flvl_Int_Expr)
	testing.expect(t, lo_is_int, "loop lo is an Int atom")
	testing.expect_value(t, lo.value, 0)
	hi, hi_is_int := loop.hi.(^Flvl_Int_Expr)
	testing.expect(t, hi_is_int, "loop hi is an Int atom")
	testing.expect_value(t, hi.value, 5)
	testing.expect_value(t, len(loop.places), 1)
	testing.expect_value(t, len(loop.fors), 0)
	testing.expect_value(t, len(loop.nested), 0)
	testing.expect_value(t, loop.places[0].type_name, "Pillar")
}

@(test)
test_flvl_parses_nested_prefab_and_override :: proc(t: ^testing.T) {
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
	testing.expect_value(t, len(level.prefabs), 1)
	testing.expect_value(t, len(level.places), 1)
	turret := level.prefabs[0]
	testing.expect_value(t, turret.name, "Turret")
	testing.expect_value(t, len(turret.places), 2)
	testing.expect_value(t, len(turret.nested), 1)
	testing.expect_value(t, turret.places[0].type_name, "Base")
	testing.expect_value(t, turret.places[1].instance_name, "cannon")
	inner := turret.nested[0]
	testing.expect_value(t, inner.name, "Inner")
	testing.expect_value(t, len(inner.places), 1)
	testing.expect_value(t, inner.places[0].type_name, "Bolt")
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

	testing.expect_value(t, len(tm.rows), 3)
	testing.expect_value(t, tm.rows[0], "####")
	testing.expect_value(t, tm.rows[1], "#P g")
	testing.expect_value(t, tm.rows[2], "####")

	testing.expect_value(t, len(level.items), 1)
	testing.expect_value(t, level.items[0].kind, Flvl_Item_Kind.Tilemap)
}

@(test)
test_flvl_grid_dedent_keeps_meaningful_leading_space :: proc(t: ^testing.T) {
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
	legend_body :: "    legend {\n      '#' wall\n    }\n"
	grid_body :: "    grid \"\"\"\n      #\n    \"\"\"\n"

	grid_first := "level A 2d {\n  tilemap terrain cell 16 {\n" + grid_body + legend_body + "  }\n}\n"
	_, err_order := parse_flvl(grid_first)
	testing.expect_value(t, err_order, Flvl_Parse_Error.Unexpected_Token)

	no_cell := "level A 2d {\n  tilemap terrain 16 {\n" + legend_body + grid_body + "  }\n}\n"
	_, err_cell := parse_flvl(no_cell)
	testing.expect_value(t, err_cell, Flvl_Parse_Error.Unexpected_Token)

	multi_char := "level A 2d {\n  tilemap terrain cell 16 {\n    legend {\n      '##' wall\n    }\n" + grid_body + "  }\n}\n"
	_, err_char := parse_flvl(multi_char)
	testing.expect_value(t, err_char, Flvl_Parse_Error.Unexpected_Token)

	empty_legend := "level A 2d {\n  tilemap terrain cell 16 {\n    legend {\n    }\n" + grid_body + "  }\n}\n"
	_, err_legend := parse_flvl(empty_legend)
	testing.expect_value(t, err_legend, Flvl_Parse_Error.Unexpected_Token)

	low_marker := "level A 2d {\n  tilemap terrain cell 16 {\n    legend {\n      'g' spawn slime\n    }\n" + grid_body + "  }\n}\n"
	_, err_case := parse_flvl(low_marker)
	testing.expect_value(t, err_case, Flvl_Parse_Error.Wrong_Case)

	unterminated := "level A 2d {\n  tilemap terrain cell 16 {\n" + legend_body + "    grid \"\"\"\n      #\n"
	_, err_end := parse_flvl(unterminated)
	testing.expect_value(t, err_end, Flvl_Parse_Error.Unexpected_End)
}

@(test)
test_flvl_rejects_malformed_place :: proc(t: ^testing.T) {
	missing_type := "level Arena 2d {\n  place exit at center\n}\n"
	_, err_type := parse_flvl(missing_type)
	testing.expect_value(t, err_type, Flvl_Parse_Error.Wrong_Case)

	bad_bounds := "level Arena 2d {\n  bounds (0, 0 (160, 120)\n}\n"
	_, err_bounds := parse_flvl(bad_bounds)
	testing.expect_value(t, err_bounds, Flvl_Parse_Error.Unexpected_Token)

	unterminated := "level Arena 2d {\n  prefab Turret {\n    place Base base at origin\n"
	_, err_prefab := parse_flvl(unterminated)
	testing.expect_value(t, err_prefab, Flvl_Parse_Error.Unexpected_End)
}
