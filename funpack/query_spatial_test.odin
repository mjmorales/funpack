// The §08 §3 spatial combinators within/nearest_first over the compiler's
// test interpreter, pinned to MIRROR THE RUNTIME KERNEL EXACTLY
// (runtime/index.odin spatial_within + spatial_hit_less; vectors copied from
// runtime/query_eval_test.odin): fixed-point kernel distance (vec2_length/
// vec3_length over the component difference), the inclusive `<= r` bound, and
// nearest-first with the stable Id tiebreak — here the source's spawn (= Id)
// order under a stable sort. Typing rides spatial_combinator_check: the
// measured field resolves from the ENCLOSING query's @spatial declaration,
// with named missing/ambiguous verdicts. Self-contained sources per test.
package funpack

import "core:testing"

// typecheck_spatial runs lex → parse → typecheck and returns the verdict —
// the typecheck_query idiom; parse must succeed.
typecheck_spatial :: proc(t: ^testing.T, source: string) -> Type_Error {
	ast, parse_err := stage_parse(stage_lex(source))
	testing.expect_value(t, parse_err, Parse_Error.None)
	if parse_err != .None {
		return .None
	}
	_, err := stage_typecheck(ast)
	return err
}

@(test)
test_spatial_combinators_typecheck_against_declared_requirement :: proc(t: ^testing.T) {
	// AC (typecheck): the §08 §3 exemplar shape — nearest_first(within(
	// all[T], origin, r), origin) under a declared @spatial(T.field) — types
	// to the declared [T] result.
	err := typecheck_spatial(t,
		"import engine.list.{within, nearest_first}\n" +
		"thing Enemy { pos: Vec2 }\n" +
		"@spatial(Enemy.pos)\n" +
		"query enemies_near(origin: Vec2, r: Fixed) -> [Enemy] {\n" +
		"  return nearest_first(within(all[Enemy], origin, r), origin)\n" +
		"}\n")
	testing.expect_value(t, err, Type_Error.None)
}

@(test)
test_spatial_requirement_missing_named_verdict :: proc(t: ^testing.T) {
	// AC (named diagnostic): a spatial combinator whose element thing has no
	// @spatial on the ENCLOSING query — including any non-query position,
	// which can declare none — is Spatial_Requirement_Missing.
	undeclared := typecheck_spatial(t,
		"import engine.list.within\n" +
		"thing Enemy { pos: Vec2 }\n" +
		"query enemies_near(origin: Vec2, r: Fixed) -> [Enemy] {\n" +
		"  return within(all[Enemy], origin, r)\n" +
		"}\n")
	testing.expect_value(t, undeclared, Type_Error.Spatial_Requirement_Missing)
	outside := typecheck_spatial(t,
		"import engine.world.View\n" +
		"import engine.list.within\n" +
		"thing Enemy { pos: Vec2 }\n" +
		"fn snoop(enemies: View[Enemy], origin: Vec2) -> [Enemy] {\n" +
		"  return within(enemies, origin, 1.0)\n" +
		"}\n")
	testing.expect_value(t, outside, Type_Error.Spatial_Requirement_Missing)
}

@(test)
test_spatial_requirement_ambiguous_named_verdict :: proc(t: ^testing.T) {
	// AC (named diagnostic): SEVERAL @spatial declarations over one thing on
	// one query leave the combinator no single field to measure.
	err := typecheck_spatial(t,
		"import engine.list.within\n" +
		"thing Enemy { pos: Vec2, vel: Vec2 }\n" +
		"@spatial(Enemy.pos)\n" +
		"@spatial(Enemy.vel)\n" +
		"query enemies_near(origin: Vec2, r: Fixed) -> [Enemy] {\n" +
		"  return within(all[Enemy], origin, r)\n" +
		"}\n")
	testing.expect_value(t, err, Type_Error.Spatial_Requirement_Ambiguous)
}

@(test)
test_spatial_value_shape_mismatches :: proc(t: ^testing.T) {
	// AC: the origin must carry the declared field's type, the radius is
	// Fixed, and a non-vector @spatial field has no kernel distance — each is
	// the same-typed-sides Type_Mismatch.
	wrong_origin := typecheck_spatial(t,
		"import engine.list.within\n" +
		"thing Enemy { pos: Vec2 }\n" +
		"@spatial(Enemy.pos)\n" +
		"query enemies_near(origin: Fixed, r: Fixed) -> [Enemy] {\n" +
		"  return within(all[Enemy], origin, r)\n" +
		"}\n")
	testing.expect_value(t, wrong_origin, Type_Error.Type_Mismatch)
	wrong_radius := typecheck_spatial(t,
		"import engine.list.within\n" +
		"thing Enemy { pos: Vec2 }\n" +
		"@spatial(Enemy.pos)\n" +
		"query enemies_near(origin: Vec2, r: Int) -> [Enemy] {\n" +
		"  return within(all[Enemy], origin, r)\n" +
		"}\n")
	testing.expect_value(t, wrong_radius, Type_Error.Type_Mismatch)
	non_vector := typecheck_spatial(t,
		"import engine.list.within\n" +
		"enum Side { Left, Right }\n" +
		"thing Paddle { side: Side }\n" +
		"@spatial(Paddle.side)\n" +
		"query paddles_near(origin: Side, r: Fixed) -> [Paddle] {\n" +
		"  return within(all[Paddle], origin, r)\n" +
		"}\n")
	testing.expect_value(t, non_vector, Type_Error.Type_Mismatch)
}

@(test)
test_within_nearest_first_mirror_kernel_vectors :: proc(t: ^testing.T) {
	// AC (evaluation, the runtime kernel's pinned vectors — copied from
	// runtime/query_eval_test.odin test_spatial_within_nearest_first_id_tiebreak):
	// from origin (0,0) with r = 10, (3,4) and (0,5) both measure exactly 5
	// and TIE — they answer in spawn (= Id) order — (6,8) measures exactly 10
	// and rides the INCLUSIVE bound, (20,0) is outside. The digit fold pins
	// the full nearest-first order [3, 0, 6] (Ids 0, 2, 1) in one exact value,
	// and the count pins the radius read.
	report, err := run_test_pipeline(
		"import engine.world.{Spawn}\n" +
		"import engine.math.{Vec2}\n" +
		"import engine.list.{fold, within, nearest_first}\n" +
		"thing Ball { pos: Vec2 }\n" +
		"fn setup() -> [Spawn] {\n" +
		"  return [\n" +
		"    Spawn(Ball{pos: Vec2{x: 3.0, y: 4.0}})\n" +
		"    Spawn(Ball{pos: Vec2{x: 6.0, y: 8.0}})\n" +
		"    Spawn(Ball{pos: Vec2{x: 0.0, y: 5.0}})\n" +
		"    Spawn(Ball{pos: Vec2{x: 20.0, y: 0.0}})\n" +
		"  ]\n" +
		"}\n" +
		"@spatial(Ball.pos)\n" +
		"query balls_within(origin: Vec2, r: Fixed) -> Int {\n" +
		"  return fold(within(all[Ball], origin, r), 0, fn(acc, b) { return acc + 1 })\n" +
		"}\n" +
		"@spatial(Ball.pos)\n" +
		"query nearest_x_digits(origin: Vec2, r: Fixed) -> Fixed {\n" +
		"  return fold(nearest_first(within(all[Ball], origin, r), origin), 0.0, fn(acc, b) { return acc * 100.0 + b.pos.x })\n" +
		"}\n" +
		"test \"kernel radius and nearest-first order\" {\n" +
		"  assert balls_within(Vec2{x: 0.0, y: 0.0}, 10.0) == 3\n" +
		"  assert balls_within(Vec2{x: 0.0, y: 0.0}, 4.0) == 0\n" +
		"  assert nearest_x_digits(Vec2{x: 0.0, y: 0.0}, 10.0) == 30006.0\n" +
		"}\n")
	testing.expect_value(t, err, Pipeline_Error.None)
	testing.expect_value(t, report.passed, 3)
	testing.expect_value(t, report.failed, 0)
	testing.expect_value(t, report.exit_code, 0)
}

@(test)
test_within_measures_vec3_lanes :: proc(t: ^testing.T) {
	// AC (evaluation, the kernel's Vec3 vector — copied from
	// test_spatial_vec3_keys_measure_in_three_lanes): (1,2,2) from the origin
	// measures exactly 3 through vec3_length and rides the inclusive bound;
	// (9,0,0) is outside.
	report, err := run_test_pipeline(
		"import engine.world.{Spawn}\n" +
		"import engine.math.{Vec3}\n" +
		"import engine.list.{fold, within}\n" +
		"thing Probe { pos: Vec3 }\n" +
		"fn setup() -> [Spawn] {\n" +
		"  return [\n" +
		"    Spawn(Probe{pos: Vec3{x: 1.0, y: 2.0, z: 2.0}})\n" +
		"    Spawn(Probe{pos: Vec3{x: 9.0, y: 0.0, z: 0.0}})\n" +
		"  ]\n" +
		"}\n" +
		"@spatial(Probe.pos)\n" +
		"query probes_within(origin: Vec3, r: Fixed) -> Int {\n" +
		"  return fold(within(all[Probe], origin, r), 0, fn(acc, p) { return acc + 1 })\n" +
		"}\n" +
		"test \"three-lane kernel distance\" {\n" +
		"  assert probes_within(Vec3{x: 0.0, y: 0.0, z: 0.0}, 3.0) == 1\n" +
		"}\n")
	testing.expect_value(t, err, Pipeline_Error.None)
	testing.expect_value(t, report.passed, 1)
	testing.expect_value(t, report.failed, 0)
}
