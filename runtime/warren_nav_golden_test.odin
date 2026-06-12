// The §12 emitted-warren end-to-end nav golden: the runtime loads the
// PRODUCER-REAL warren artifact (built by funpack stage_build from
// funpack-spec/examples/warren — the cross-package byte seam
// test_emit_warren_matches_runtime_testdata pins the committed copy to the
// live emitter) and answers the whole engine nav surface over the baked maze
// graph with EXACT pins — exact node/edge counts, exact route steps + cost,
// exact error arms — never a range. Every expected value below is computed
// from warren.flvl by hand (the 16×12 cell-8 maze, top-left anchor (0,96),
// center of cell (c,r) = (8c+4, 92−8r); node index = row-major rank among the
// 80 walkable cells), never read back from the implementation.
//
// The artifact is #load-embedded, so the golden runs hermetically — no
// filesystem, no cwd, no funpack source (the hunt/krognid acceptance mold).
// The queries run through the REAL eval_method_call dispatch over a committed
// World_Version aliasing the bake's tile layers, exercising in one pass: the
// §12 §2 containing-cell endpoint resolution (ADR
// 2026-06-11-path-endpoints-resolve-to-containing-cell), the §12 §3 los
// occupancy verdict over the 1:1 maze layer (ADR
// 2026-06-11-engine-los-reads-live-tilemap-occupancy), Unreachable on the
// sealed burrow warren.flvl promises, and OffNav from a solid cell.
package funpack_runtime

import "core:testing"

WARREN_ARTIFACT := #load("testdata/warren.artifact", string)

// Hand-derived warren.flvl anchors (cell 8, bounds (0,0)-(128,96)): the four
// spawn markers sit on their cells' centers.
warren_doe :: proc() -> Vec2 {
	return Vec2{x = to_fixed(12), y = to_fixed(84)} // R at (1,1) — node 0
}
warren_den :: proc() -> Vec2 {
	return Vec2{x = to_fixed(116), y = to_fixed(84)} // O at (14,1) — node 11
}
warren_sealed :: proc() -> Vec2 {
	return Vec2{x = to_fixed(28), y = to_fixed(20)} // S at (3,9) — node 65, fully walled
}
warren_hob :: proc() -> Vec2 {
	return Vec2{x = to_fixed(116), y = to_fixed(20)} // F at (14,9) — node 73
}

// warren_nav_world loads the embedded artifact and builds the committed world
// the engine queries answer over: the version's tile layers alias the bake
// (the pre-first-tick committed state), the interp reads that version.
warren_nav_world :: proc(t: ^testing.T) -> (program: Program, ok: bool) {
	loaded, err := load_program(WARREN_ARTIFACT, context.temp_allocator)
	if !testing.expectf(t, err == .None, "warren golden artifact must load, got %v", err) {
		return {}, false
	}
	return loaded, true
}

// warren_eval_nav drives `nav.<method>(args…)` through the real dispatch over
// the loaded program + a committed version aliasing its bake.
warren_eval_nav :: proc(program: ^Program, method: string, args: ..Value) -> (result: Value, ok: bool) {
	version := World_Version {
		tilemaps = program.tilemaps,
	}
	interp := new_interp(program, &version, nil, empty(), tilemap_time_resource(), context.temp_allocator)
	return nav_eval_method(&interp, nav_handle_value("maze"), method, ..args)
}

@(test)
test_warren_golden_graph_decodes_exact :: proc(t: ^testing.T) {
	// AC (decode pins): ONE graph named "maze" (1:1 with the maze tile layer),
	// exactly 80 walkable nodes and 80 undirected edges (degree sum 160) — the
	// counts warren.flvl's 112 '#' walls leave, matching the producer-side
	// `nav maze 80 80` lead-line pin. Node 0 is the doe's cell center bit-exact
	// (row-major rank: (1,1) is the first walkable cell).
	program, ok := warren_nav_world(t)
	if !ok {
		return
	}
	testing.expect_value(t, len(program.navs), 1)
	testing.expect_value(t, program.navs[0].name, "maze")
	testing.expect_value(t, len(program.navs[0].centers), 80)
	degree := 0
	for neighbors in program.navs[0].adj {
		degree += len(neighbors)
	}
	testing.expect_value(t, degree, 160)
	testing.expect_value(t, program.navs[0].centers[0], warren_doe())
}

@(test)
test_warren_golden_path_unique_route_exact :: proc(t: ^testing.T) {
	// AC (exact route + cost): the den's column is a corridor — (14,1)→(14,2)→
	// (14,3) is the UNIQUE shortest route (the den's only neighbor is (14,2)),
	// so the steps pin bit-exact with no tie-break in play: three centers
	// straight down, cost two 8-unit edges = 16.
	program, ok := warren_nav_world(t)
	if !ok {
		return
	}
	result, eval_ok := warren_eval_nav(&program, "path", warren_den(), Vec2{x = to_fixed(116), y = to_fixed(68)})
	testing.expect(t, eval_ok)
	variant := result.(Variant_Value)
	testing.expect_value(t, variant.case_name, "Ok")
	route := variant.payload^.(Record_Value)
	steps := route.fields["steps"].(List_Value)
	testing.expect_value(t, len(steps.elements), 3)
	testing.expect_value(t, steps.elements[0].(Vec2), warren_den())
	testing.expect_value(t, steps.elements[1].(Vec2), Vec2{x = to_fixed(116), y = to_fixed(76)})
	testing.expect_value(t, steps.elements[2].(Vec2), Vec2{x = to_fixed(116), y = to_fixed(68)})
	testing.expect_value(t, route.fields["cost"].(Fixed), to_fixed(16))
}

@(test)
test_warren_golden_chase_route_exact_length :: proc(t: ^testing.T) {
	// AC (the chase distance): the ferret-to-doe route — the game's actual
	// chase query — is 27 edges through the maze (hand-BFS over warren.flvl:
	// down the east corridor, across row 7, up the west loop), so 28 steps and
	// cost 27·8 = 216 exactly. All maze edges are 8-unit orthogonal hops, so a
	// route's cost is always 8·(steps−1) — pinned here over the longest live
	// route rather than restated per test. Endpoints are the markers' centers.
	program, ok := warren_nav_world(t)
	if !ok {
		return
	}
	result, eval_ok := warren_eval_nav(&program, "path", warren_hob(), warren_doe())
	testing.expect(t, eval_ok)
	variant := result.(Variant_Value)
	testing.expect_value(t, variant.case_name, "Ok")
	route := variant.payload^.(Record_Value)
	steps := route.fields["steps"].(List_Value)
	testing.expect_value(t, len(steps.elements), 28)
	testing.expect_value(t, steps.elements[0].(Vec2), warren_hob())
	testing.expect_value(t, steps.elements[27].(Vec2), warren_doe())
	testing.expect_value(t, route.fields["cost"].(Fixed), to_fixed(216))
}

@(test)
test_warren_golden_sealed_burrow_unreachable :: proc(t: ^testing.T) {
	// AC (Unreachable): the sealed burrow is warren.flvl's own promise — "fully
	// walled: path() to it is Unreachable". S's cell is walkable (a marker sits
	// on the floor) so it RESOLVES to a node; the BFS then exhausts the doe's
	// component without reaching it. reachable() reads the same verdict as a
	// plain false.
	program, ok := warren_nav_world(t)
	if !ok {
		return
	}
	result, eval_ok := warren_eval_nav(&program, "path", warren_doe(), warren_sealed())
	testing.expect(t, eval_ok)
	variant := result.(Variant_Value)
	testing.expect_value(t, variant.case_name, "Err")
	testing.expect_value(t, variant.payload^.(Variant_Value).case_name, "Unreachable")
	reach, reach_ok := warren_eval_nav(&program, "reachable", warren_doe(), warren_sealed())
	testing.expect(t, reach_ok)
	testing.expect_value(t, reach.(bool), false)
	open, open_ok := warren_eval_nav(&program, "reachable", warren_doe(), warren_hob())
	testing.expect(t, open_ok)
	testing.expect_value(t, open.(bool), true)
}

@(test)
test_warren_golden_offnav_and_containing_cell :: proc(t: ^testing.T) {
	// AC (§12 §2 end-to-end): an endpoint inside a WALL cell — (4,92), the
	// (0,0) corner '#' center — is OffNav; an off-center point inside the den's
	// cell — (114,86), not the center (116,84) — resolves to the den's node and
	// reproduces the unique corridor route bit-exact. The containing-cell
	// ruling over producer-real bytes.
	program, ok := warren_nav_world(t)
	if !ok {
		return
	}
	walled, walled_ok := warren_eval_nav(&program, "path", Vec2{x = to_fixed(4), y = to_fixed(92)}, warren_doe())
	testing.expect(t, walled_ok)
	variant := walled.(Variant_Value)
	testing.expect_value(t, variant.case_name, "Err")
	testing.expect_value(t, variant.payload^.(Variant_Value).case_name, "OffNav")
	off_center, oc_ok := warren_eval_nav(&program, "path", Vec2{x = to_fixed(114), y = to_fixed(86)}, Vec2{x = to_fixed(116), y = to_fixed(68)})
	testing.expect(t, oc_ok)
	resolved := off_center.(Variant_Value)
	testing.expect_value(t, resolved.case_name, "Ok")
	route := resolved.payload^.(Record_Value)
	steps := route.fields["steps"].(List_Value)
	testing.expect_value(t, len(steps.elements), 3)
	testing.expect_value(t, steps.elements[0].(Vec2), warren_den()) // the route starts at the CONTAINING cell's center
	testing.expect_value(t, route.fields["cost"].(Fixed), to_fixed(16))
}

@(test)
test_warren_golden_startup_spawns_carried_schema :: proc(t: ^testing.T) {
	// AC (the v15 carry feeding run_startup over producer-real bytes): the
	// warren [setup 4] batch spawns the four named markers against the CARRIED
	// [things] schemas, and the Rabbit/Ferret composite `path: Path =
	// Path(steps=[],cost=0)` default decodes TYPED through the synthesized §8
	// [data] Path projection (the Settings mold): steps resolves [Vec2] → an
	// empty List_Value column, cost resolves Fixed → a Fixed(0) column — never
	// untyped tokens. Marker centers are hand-derived from warren.flvl (the
	// same anchors the nav pins use); hidden/repath_t fill from their carried
	// scalar defaults.
	program, ok := warren_nav_world(t)
	if !ok {
		return
	}
	world := new_world(program, context.temp_allocator)
	version := run_startup(&program, initial_version(world, context.temp_allocator), context.temp_allocator)

	rabbits := version_find_table(&version, "Rabbit")
	ferrets := version_find_table(&version, "Ferret")
	burrows := version_find_table(&version, "Burrow")
	if !testing.expect(t, rabbits != nil && ferrets != nil && burrows != nil) {
		return
	}
	testing.expect_value(t, len(rabbits.rows), 1)
	testing.expect_value(t, len(ferrets.rows), 1)
	testing.expect_value(t, len(burrows.rows), 2)

	doe := rabbits.rows[0]
	testing.expect_value(t, doe.fields["pos"].(Vec2), warren_doe())
	testing.expect_value(t, doe.fields["hidden"].(bool), false)
	doe_path, doe_path_is_record := doe.fields["path"].(Record_Value)
	testing.expect(t, doe_path_is_record)
	if doe_path_is_record {
		testing.expect_value(t, doe_path.type_name, "Path")
		steps, steps_is_list := doe_path.fields["steps"].(List_Value)
		testing.expect(t, steps_is_list)
		testing.expect_value(t, len(steps.elements), 0)
		testing.expect_value(t, doe_path.fields["cost"].(Fixed), Fixed(0))
	}

	hob := ferrets.rows[0]
	testing.expect_value(t, hob.fields["pos"].(Vec2), warren_hob())
	testing.expect_value(t, hob.fields["repath_t"].(Fixed), Fixed(0))
	hob_path, hob_path_is_record := hob.fields["path"].(Record_Value)
	testing.expect(t, hob_path_is_record)
	if hob_path_is_record {
		testing.expect_value(t, hob_path.type_name, "Path")
	}

	testing.expect_value(t, burrows.rows[0].fields["pos"].(Vec2), warren_den())
	testing.expect_value(t, burrows.rows[1].fields["pos"].(Vec2), warren_sealed())
}

@(test)
test_warren_golden_los_over_the_baked_maze :: proc(t: ^testing.T) {
	// AC (§12 §3 los over the emitted bake): along the doe's
	// top corridor — (12,84) to (44,84), cells (1..5, 1) all floor — sight is
	// clear; straight across to the den — (12,84) to (116,84) — the (6,1) '#'
	// wall stands in the segment, so sight is blocked. The occupancy verdict
	// over the same committed layer the graph baked from.
	program, ok := warren_nav_world(t)
	if !ok {
		return
	}
	clear, clear_ok := warren_eval_nav(&program, "los", warren_doe(), Vec2{x = to_fixed(44), y = to_fixed(84)})
	testing.expect(t, clear_ok)
	testing.expect_value(t, clear.(bool), true)
	blocked, blocked_ok := warren_eval_nav(&program, "los", warren_doe(), warren_den())
	testing.expect(t, blocked_ok)
	testing.expect_value(t, blocked.(bool), false)
}
