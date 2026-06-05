// Body node-forest reader proof (docs/artifact-format.md §2.7). The encoding is
// total and count-driven: a reader consumes a node then exactly its declared
// child_count subtrees, never looking ahead. The ONE exception is `arm` (always
// 0 children, trailing binder list). These tests pin the shape directly with
// hand-built fragments and against the golden fixture's real bodies.
package funpack_runtime

import "core:testing"

// node_child_count reads the trailing child count, and an `arm` line is fixed at
// 0 children regardless of its trailing binder token (§2.7) — the primitive the
// whole forest reader rests on.
@(test)
test_node_child_count :: proc(t: ^testing.T) {
	c, ok := node_child_count("node binary add 2")
	testing.expect(t, ok)
	testing.expect_value(t, c, 2)

	c, ok = node_child_count("node name self 0")
	testing.expect(t, ok)
	testing.expect_value(t, c, 0)

	// A `match` line carries arm_count then child_count; the LAST token is the
	// child count (1 + 2*arm_count).
	c, ok = node_child_count("node match 2 5")
	testing.expect(t, ok)
	testing.expect_value(t, c, 5)

	// An `arm` ends in its binder list, not a child count — fixed at 0.
	c, ok = node_child_count("node arm variant_binds Option Some 1 side")
	testing.expect(t, ok)
	testing.expect_value(t, c, 0)

	c, ok = node_child_count("node arm wildcard - - 0")
	testing.expect(t, ok)
	testing.expect_value(t, c, 0)
}

// A well-formed pre-order run rebuilds into exactly the declared statement
// count, and an over- or under-shaped run is refused (§2.7). `advance`'s body is
// one `return` of `at + vel * dt`.
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

	// The tree shape: return → (binary add → (name at, binary mul → (name vel,
	// name dt))).
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

	// Declaring 2 statements over a 1-statement run under-consumes (overruns the
	// slice) — refused.
	_, under_err := parse_node_forest(advance_body, 2, context.temp_allocator)
	testing.expect_value(t, under_err, Artifact_Error.Body_Count_Mismatch)

	// A leftover trailing node is an over-shaped body — refused.
	malformed := []string{"node return 0", "node name self 0"}
	_, over_err := parse_node_forest(malformed, 1, context.temp_allocator)
	testing.expect_value(t, over_err, Artifact_Error.Body_Count_Mismatch)
}

// A `match` reconstructs as 1 scrutinee + (per arm: an arm node then its body) =
// 1 + 2*arm_count children, with the arm's binder list kept as scalar fields and
// the arm's body as the FOLLOWING sibling (§2.7). serve_velocity's body is a
// single match over Side with two bare-variant arms.
@(test)
test_parse_match_arm_shape :: proc(t: ^testing.T) {
	// match e { Side::Left => Vec2{...}, Side::Right => Vec2{...} } — the
	// reflect-velocity match from serve_velocity, trimmed to its skeleton.
	match_body := []string {
		"node match 2 5",
		"node name side 0",
		"node arm bare_variant Side Left 0",
		"node int 1 0", // stand-in body for the Left arm
		"node arm bare_variant Side Right 0",
		"node int 2 0", // stand-in body for the Right arm
	}
	statements, err := parse_node_forest(match_body, 1, context.temp_allocator)
	testing.expect_value(t, err, Artifact_Error.None)
	testing.expect_value(t, len(statements), 1)

	match := statements[0]
	testing.expect_value(t, match.kind, Node_Kind.Match)
	// 1 scrutinee + 2 arms each followed by a body = 5 children.
	testing.expect_value(t, len(match.children), 5)
	testing.expect_value(t, match.children[0].kind, Node_Kind.Name) // scrutinee
	testing.expect_value(t, match.children[1].kind, Node_Kind.Arm) // first arm
	testing.expect_value(t, match.children[2].kind, Node_Kind.Int) // its body
	testing.expect_value(t, match.children[3].kind, Node_Kind.Arm) // second arm

	// An arm keeps its pattern tokens as scalar fields: `bare_variant Side Left`.
	arm := match.children[1]
	testing.expect_value(t, len(arm.children), 0) // arm has no child of its own
	testing.expect_value(t, arm.fields[0], "bare_variant")
	testing.expect_value(t, arm.fields[1], "Side")
	testing.expect_value(t, arm.fields[2], "Left")
}

// A `variant_binds` arm with a payload binder keeps the binder name in its
// scalar fields and is still fixed at 0 children (§2.7) — the score behavior's
// `Option::Some(side)` arm.
@(test)
test_parse_variant_binds_arm :: proc(t: ^testing.T) {
	body := []string {
		"node match 2 5",
		"node name x 0",
		"node arm variant_binds Option Some 1 side",
		"node name side 0", // the Some arm's body
		"node arm bare_variant Option None 0",
		"node int 0 0", // the None arm's body
	}
	statements, err := parse_node_forest(body, 1, context.temp_allocator)
	testing.expect_value(t, err, Artifact_Error.None)
	arm := statements[0].children[1]
	testing.expect_value(t, arm.kind, Node_Kind.Arm)
	testing.expect_value(t, len(arm.children), 0)
	// fields: pat=variant_binds, type=Option, case=Some, binder_count=1, binder=side
	testing.expect_value(t, arm.fields[0], "variant_binds")
	testing.expect_value(t, arm.fields[3], "1")
	testing.expect_value(t, arm.fields[4], "side")
}

// An unknown node kind is refused — the kind set is closed, a new kind is a
// schema-version bump (§1).
@(test)
test_parse_node_rejects_unknown_kind :: proc(t: ^testing.T) {
	_, err := parse_node_forest([]string{"node bogus_kind 0"}, 1, context.temp_allocator)
	testing.expect_value(t, err, Artifact_Error.Bad_Body_Node)
}

// Every function and behavior body in the golden fixture reconstructs into a
// well-formed forest from its own declared body_count — the load-bearing
// guarantee that the runtime interprets pong's bodies FROM THE ARTIFACT, with
// zero funpack source. If any body failed to reconstruct, load_program would
// have refused, so a successful golden load already proves this; this test makes
// the body-count accounting explicit per record.
@(test)
test_golden_bodies_reconstruct :: proc(t: ^testing.T) {
	program, ok := load_golden(t)
	if !ok {
		return
	}
	// 10 functions + 10 behaviors, each with a reconstructed (possibly multi-
	// statement) body forest.
	for fn in program.functions {
		testing.expectf(t, len(fn.body) >= 1, "function %s must carry a body", fn.name)
	}
	for behavior in program.behaviors {
		testing.expectf(t, len(behavior.body) >= 1, "behavior %s must carry a step body", behavior.name)
	}

	// goal_side's body is exactly three top-level statements (two if_return, one
	// return) — the §2.7 worked example.
	goal_side := find_function(program, "goal_side")
	testing.expect(t, goal_side != nil)
	testing.expect_value(t, len(goal_side.body), 3)
	testing.expect_value(t, goal_side.body[0].kind, Node_Kind.If_Return)
	testing.expect_value(t, goal_side.body[1].kind, Node_Kind.If_Return)
	testing.expect_value(t, goal_side.body[2].kind, Node_Kind.Return)

	// wall_bounce's step body is two statements (the bounce if_return, then the
	// pass-through return) — the §10 worked example.
	wall_bounce := find_behavior(program, "wall_bounce")
	testing.expect(t, wall_bounce != nil)
	testing.expect_value(t, len(wall_bounce.body), 2)
}

// A body `fixed` node carries its raw Q32.32 bits as a token; decoding it
// through the kernel is bit-exact (§2.3) — proving the body path, like the setup
// path, never touches a float. goal_side's first if_return compares `at.x < 0.0`,
// so a `fixed 0` node decodes to Fixed(0).
@(test)
test_body_fixed_node_decodes_through_kernel :: proc(t: ^testing.T) {
	program, ok := load_golden(t)
	if !ok {
		return
	}
	// overlaps' body has `fixed 17179869184` (4.0) — the paddle half-width.
	overlaps := find_function(program, "overlaps")
	testing.expect(t, overlaps != nil)
	node := find_node_of_kind(overlaps.body, .Fixed)
	if !testing.expect(t, node != nil, "overlaps body must carry a fixed node") {
		return
	}
	value, decoded := decode_fixed(node.fields[0])
	testing.expect(t, decoded)
	testing.expect_value(t, value, to_fixed(4)) // 4.0, bit-exact through the kernel
}
