package funpack_runtime

import "core:testing"

@(test)
test_node_child_count :: proc(t: ^testing.T) {
	c, ok := node_child_count("node binary add 2")
	testing.expect(t, ok)
	testing.expect_value(t, c, 2)

	c, ok = node_child_count("node name self 0")
	testing.expect(t, ok)
	testing.expect_value(t, c, 0)

	c, ok = node_child_count("node match 2 5")
	testing.expect(t, ok)
	testing.expect_value(t, c, 5)

	c, ok = node_child_count("node arm variant_binds Option Some 1 side")
	testing.expect(t, ok)
	testing.expect_value(t, c, 0)

	c, ok = node_child_count("node arm wildcard - - 0")
	testing.expect(t, ok)
	testing.expect_value(t, c, 0)
}

@(test)
test_parse_node_forest_well_formedness :: proc(t: ^testing.T) {
	advance_body := []string {
		"node return 1",
		"node binary add 2",
		"node name at 0",
		"node binary mul 2",
		"node name vel 0",
		"node name dt 0",
	}
	statements, err := parse_node_forest(advance_body, 1, context.temp_allocator)
	testing.expect_value(t, err, Artifact_Error.None)
	testing.expect_value(t, len(statements), 1)

	ret := statements[0]
	testing.expect_value(t, ret.kind, Node_Kind.Return)
	testing.expect_value(t, len(ret.children), 1)
	add := ret.children[0]
	testing.expect_value(t, add.kind, Node_Kind.Binary)
	testing.expect_value(t, add.fields[0], "add")
	testing.expect_value(t, len(add.children), 2)
	testing.expect_value(t, add.children[0].kind, Node_Kind.Name)
	testing.expect_value(t, add.children[0].fields[0], "at")
	mul := add.children[1]
	testing.expect_value(t, mul.kind, Node_Kind.Binary)
	testing.expect_value(t, mul.fields[0], "mul")

	_, under_err := parse_node_forest(advance_body, 2, context.temp_allocator)
	testing.expect_value(t, under_err, Artifact_Error.Body_Count_Mismatch)

	malformed := []string{"node return 0", "node name self 0"}
	_, over_err := parse_node_forest(malformed, 1, context.temp_allocator)
	testing.expect_value(t, over_err, Artifact_Error.Body_Count_Mismatch)
}

@(test)
test_parse_match_arm_shape :: proc(t: ^testing.T) {
	match_body := []string {
		"node match 2 5",
		"node name side 0",
		"node arm bare_variant Side Left 0",
		"node int 1 0",
		"node arm bare_variant Side Right 0",
		"node int 2 0",
	}
	statements, err := parse_node_forest(match_body, 1, context.temp_allocator)
	testing.expect_value(t, err, Artifact_Error.None)
	testing.expect_value(t, len(statements), 1)

	match := statements[0]
	testing.expect_value(t, match.kind, Node_Kind.Match)
	testing.expect_value(t, len(match.children), 5)
	testing.expect_value(t, match.children[0].kind, Node_Kind.Name)
	testing.expect_value(t, match.children[1].kind, Node_Kind.Arm)
	testing.expect_value(t, match.children[2].kind, Node_Kind.Int)
	testing.expect_value(t, match.children[3].kind, Node_Kind.Arm)

	arm := match.children[1]
	testing.expect_value(t, len(arm.children), 0)
	testing.expect_value(t, arm.fields[0], "bare_variant")
	testing.expect_value(t, arm.fields[1], "Side")
	testing.expect_value(t, arm.fields[2], "Left")
}

@(test)
test_parse_variant_binds_arm :: proc(t: ^testing.T) {
	body := []string {
		"node match 2 5",
		"node name x 0",
		"node arm variant_binds Option Some 1 side",
		"node name side 0",
		"node arm bare_variant Option None 0",
		"node int 0 0",
	}
	statements, err := parse_node_forest(body, 1, context.temp_allocator)
	testing.expect_value(t, err, Artifact_Error.None)
	arm := statements[0].children[1]
	testing.expect_value(t, arm.kind, Node_Kind.Arm)
	testing.expect_value(t, len(arm.children), 0)
	testing.expect_value(t, arm.fields[0], "variant_binds")
	testing.expect_value(t, arm.fields[3], "1")
	testing.expect_value(t, arm.fields[4], "side")
}

@(test)
test_parse_node_rejects_unknown_kind :: proc(t: ^testing.T) {
	_, err := parse_node_forest([]string{"node bogus_kind 0"}, 1, context.temp_allocator)
	testing.expect_value(t, err, Artifact_Error.Bad_Body_Node)
}

@(test)
test_golden_bodies_reconstruct :: proc(t: ^testing.T) {
	program, ok := load_golden(t)
	if !ok {
		return
	}
	for fn in program.functions {
		testing.expectf(t, len(fn.body) >= 1, "function %s must carry a body", fn.name)
	}
	for behavior in program.behaviors {
		testing.expectf(t, len(behavior.body) >= 1, "behavior %s must carry a step body", behavior.name)
	}

	goal_side := find_function(program, "goal_side")
	testing.expect(t, goal_side != nil)
	testing.expect_value(t, len(goal_side.body), 3)
	testing.expect_value(t, goal_side.body[0].kind, Node_Kind.If_Return)
	testing.expect_value(t, goal_side.body[1].kind, Node_Kind.If_Return)
	testing.expect_value(t, goal_side.body[2].kind, Node_Kind.Return)

	wall_bounce := find_behavior(program, "wall_bounce")
	testing.expect(t, wall_bounce != nil)
	testing.expect_value(t, len(wall_bounce.body), 2)
}

@(test)
test_body_fixed_node_decodes_through_kernel :: proc(t: ^testing.T) {
	program, ok := load_golden(t)
	if !ok {
		return
	}
	overlaps := find_function(program, "overlaps")
	testing.expect(t, overlaps != nil)
	node := find_node_of_kind(overlaps.body, .Fixed)
	if !testing.expect(t, node != nil, "overlaps body must carry a fixed node") {
		return
	}
	value, decoded := decode_fixed(node.fields[0])
	testing.expect(t, decoded)
	testing.expect_value(t, value, fixed_from_decimal(3, "5"))
}
