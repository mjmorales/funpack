package funpack

import "core:testing"

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
