package funpack

import "core:strings"
import "core:testing"

resolved_pong :: proc() -> (env: Type_Env, bindings: Bindings, ok: bool) {
	source, has_source := pong_source()
	if !has_source {
		return Type_Env{}, Bindings{}, false
	}
	ast, parse_err := stage_parse(stage_lex(source))
	if parse_err != .None {
		return Type_Env{}, Bindings{}, false
	}
	b, import_err := resolve_imports(ast)
	if import_err != .None {
		return Type_Env{}, Bindings{}, false
	}
	e, env_err := resolve_env(ast, b)
	if env_err != .None {
		return Type_Env{}, Bindings{}, false
	}
	return e, b, true
}

term_result :: proc(env: Type_Env, name: string) -> (result: Type, found: bool) {
	term, has := env_term_name(env, name)
	if !has || term.signature == nil {
		return nil, false
	}
	return term.signature.result, true
}

@(test)
test_setup_returns_spawn_command_list :: proc(t: ^testing.T) {
	env, _, ok := resolved_pong()
	if !ok {
		return
	}
	result, found := term_result(env, "setup")
	testing.expect(t, found)
	list, is_list := result.(^List_Type)
	testing.expect(t, is_list)
	if is_list {
		testing.expect(t, is_engine(list.elem, .Spawn))
	}
}

@(test)
test_draw_ball_step_returns_draw_command_list :: proc(t: ^testing.T) {
	env, _, ok := resolved_pong()
	if !ok {
		return
	}
	result, found := term_result(env, "draw_ball")
	testing.expect(t, found)
	list, is_list := result.(^List_Type)
	testing.expect(t, is_list)
	if is_list {
		testing.expect(t, is_engine(list.elem, .Draw))
	}
}

@(test)
test_score_step_returns_goal_signal_list :: proc(t: ^testing.T) {
	env, _, ok := resolved_pong()
	if !ok {
		return
	}
	result, found := term_result(env, "score")
	testing.expect(t, found)
	list, is_list := result.(^List_Type)
	testing.expect(t, is_list)
	if is_list {
		goal, is_user := list.elem.(^User_Type)
		testing.expect(t, is_user)
		if is_user {
			testing.expect_value(t, goal.name, "Goal")
			testing.expect_value(t, goal.kind, User_Kind.Signal)
		}
	}
}

@(test)
test_paddle_move_step_returns_paddle_blackboard :: proc(t: ^testing.T) {
	env, _, ok := resolved_pong()
	if !ok {
		return
	}
	result, found := term_result(env, "paddle_move")
	testing.expect(t, found)
	paddle, is_user := result.(^User_Type)
	testing.expect(t, is_user)
	if is_user {
		testing.expect_value(t, paddle.name, "Paddle")
		testing.expect_value(t, paddle.kind, User_Kind.Thing)
	}
}

PONG_UNIT_HEADER :: "import engine.math.{Fixed, Vec2, clamp}\n" +
	"import engine.world.{View, Spawn}\n" +
	"thing Paddle { x: Fixed, y: Fixed }\n" +
	"thing Ball { pos: Vec2, vel: Vec2 }\n"

typecheck_pong_unit :: proc(body: string) -> Type_Error {
	source := strings.concatenate({PONG_UNIT_HEADER, body}, context.temp_allocator)
	ast, parse_err := stage_parse(stage_lex(source))
	if parse_err != .None {
		return .Unsupported_Expr
	}
	_, err := stage_typecheck(ast)
	return err
}

INPUT_QUERY_HEADER :: "import engine.math.{Fixed, Vec2}\n" +
	"import engine.input.{Input, PlayerId}\n" +
	"thing Walker { pos: Vec2 }\n" +
	"enum Act: Button { Jump }\n" +
	"enum Steer: Axis { Move }\n"

typecheck_input_query_unit :: proc(body: string) -> Type_Error {
	source := strings.concatenate({INPUT_QUERY_HEADER, body}, context.temp_allocator)
	ast, parse_err := stage_parse(stage_lex(source))
	if parse_err != .None {
		return .Unsupported_Expr
	}
	_, err := stage_typecheck(ast)
	return err
}

@(test)
test_input_query_surface_typechecks :: proc(t: ^testing.T) {
	err := typecheck_input_query_unit(
		"behavior probe on Walker {\n" +
		"  fn step(self: Walker, input: Input) -> Walker {\n" +
		"    if input.pressed(PlayerId::P1, Act::Jump) { return self }\n" +
		"    if input.released(PlayerId::P1, Act::Jump) { return self }\n" +
		"    if input.held(PlayerId::P1, Act::Jump) { return self }\n" +
		"    return self with { pos: input.axis(PlayerId::P1, Steer::Move) }\n" +
		"  }\n" +
		"}\n" +
		"behavior scale on Walker {\n" +
		"  fn step(self: Walker, input: Input) -> Walker {\n" +
		"    return self with { pos: Vec2{x: input.value(PlayerId::P1, Steer::Move), y: 0.0} }\n" +
		"  }\n" +
		"}\n")
	testing.expect_value(t, err, Type_Error.None)
}

@(test)
test_input_query_arity_mismatch_rejected :: proc(t: ^testing.T) {
	err := typecheck_input_query_unit(
		"behavior probe on Walker {\n" +
		"  fn step(self: Walker, input: Input) -> Walker {\n" +
		"    if input.pressed(PlayerId::P1) { return self }\n" +
		"    return self\n" +
		"  }\n" +
		"}\n")
	testing.expect_value(t, err, Type_Error.Type_Mismatch)
}

@(test)
test_input_query_result_misuse_rejected :: proc(t: ^testing.T) {
	err := typecheck_input_query_unit(
		"behavior probe on Walker {\n" +
		"  fn step(self: Walker, input: Input) -> Walker {\n" +
		"    return self with { pos: input.pressed(PlayerId::P1, Act::Jump) }\n" +
		"  }\n" +
		"}\n")
	testing.expect_value(t, err, Type_Error.Type_Mismatch)
}

@(test)
test_pong_unit_positive_control_typechecks :: proc(t: ^testing.T) {
	err := typecheck_pong_unit(
		"behavior nudge on Paddle {\n" +
		"  fn step(self: Paddle) -> Paddle {\n" +
		"    return self with { y: clamp(self.y, 0.0, 10.0) }\n" +
		"  }\n" +
		"}\n")
	testing.expect_value(t, err, Type_Error.None)
}

@(test)
test_behavior_returning_wrong_thing_rejected :: proc(t: ^testing.T) {
	err := typecheck_pong_unit(
		"behavior stray on Paddle {\n" +
		"  fn step(self: Paddle) -> Paddle {\n" +
		"    return Ball{pos: Vec2{x: 0.0, y: 0.0}, vel: Vec2{x: 0.0, y: 0.0}}\n" +
		"  }\n" +
		"}\n")
	testing.expect_value(t, err, Type_Error.Type_Mismatch)
}

@(test)
test_with_on_unknown_field_rejected :: proc(t: ^testing.T) {
	err := typecheck_pong_unit(
		"behavior nudge on Paddle {\n" +
		"  fn step(self: Paddle) -> Paddle {\n" +
		"    return self with { z: 1.0 }\n" +
		"  }\n" +
		"}\n")
	testing.expect_value(t, err, Type_Error.Type_Mismatch)
}

@(test)
test_with_on_wrong_typed_field_rejected :: proc(t: ^testing.T) {
	err := typecheck_pong_unit(
		"behavior nudge on Paddle {\n" +
		"  fn step(self: Paddle) -> Paddle {\n" +
		"    return self with { y: Vec2{x: 0.0, y: 0.0} }\n" +
		"  }\n" +
		"}\n")
	testing.expect_value(t, err, Type_Error.Type_Mismatch)
}

@(test)
test_bare_int_meeting_fixed_param_rejected :: proc(t: ^testing.T) {
	err := typecheck_pong_unit(
		"behavior nudge on Paddle {\n" +
		"  fn step(self: Paddle) -> Paddle {\n" +
		"    return self with { y: clamp(2, 0.0, 10.0) }\n" +
		"  }\n" +
		"}\n")
	testing.expect_value(t, err, Type_Error.Type_Mismatch)
}
