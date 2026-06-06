// The §06/§07 typing fixtures: the closed §04 command/signal return forms
// type correctly, and the writes-only-own-thing and §10 no-implicit-promotion
// rules reject over the new surface. The positive closed-return-form fixtures
// read the live pong golden source (the load-bearing surface); the negative
// fixtures are small self-contained sources, so a missing golden checkout
// never silences the rejection proofs.
package funpack

import "core:strings"
import "core:testing"

// resolved_pong builds the pong golden source's resolved environment — lex,
// parse, resolve_imports, resolve_env — the window the closed-return-form
// fixtures read a term's signature through. ok = false (SKIP) when the
// sibling checkout is absent, matching the other pong fixtures.
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

// term_result reads a resolved term's signature result type by name — the
// closed-return-form fixtures' window onto setup/behavior step `-> R` types.
term_result :: proc(env: Type_Env, name: string) -> (result: Type, found: bool) {
	term, has := env_term_name(env, name)
	if !has || term.signature == nil {
		return nil, false
	}
	return term.signature.result, true
}

@(test)
test_setup_returns_spawn_command_list :: proc(t: ^testing.T) {
	// AC: setup() types as returning [Spawn] — the closed §04 startup command
	// list. The body (a list of Spawn(thing) calls) typechecks against that
	// declared return.
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
	// AC: draw_ball.step types as [Draw] — the closed §20 render command list.
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
	// AC: score.step types as [Goal] — an emitted signal list. The element is
	// the user-declared Goal signal's nominal handle.
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
	// AC: paddle_move.step returns the Paddle blackboard (a plain
	// writes-as-return of the behavior's own thing), not a command list.
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

// typecheck_pong_unit lex/parses and typechecks a self-contained source that
// declares the minimal pong surface a negative fixture needs, returning the
// typecheck verdict. The header imports the engine modules and declares the
// Paddle/Ball things, the Side enum, and the Goal signal, so a fixture body
// can construct and return them.
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

// INPUT_QUERY_HEADER is the self-contained surface for the §23 §2 query
// fixtures: a Button-kinded and an Axis-kinded action enum over a thing whose
// behavior takes the Input resource — the snake/hunt shape, independent of the
// pong golden checkout.
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
	// AC (§23 §2): all five queries type off the Input resource — the three
	// button queries land Bool (consumed as if-conditions), axis lands Vec2
	// (consumed as the Vec2 field write), value lands Fixed (consumed as a
	// Vec2 component). The action args are the user Button/Axis enums the nil
	// unknown unifies with.
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
	// AC: a query call missing its action argument rejects — the signatures
	// are two-parameter (PlayerId, action), not variadic.
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
	// AC: the button queries land Bool, not a numeric — writing a pressed
	// result into the Vec2 field rejects, so the Bool ground is real, not a
	// wildcard.
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
	// The control for the negative fixtures below: a behavior on Paddle that
	// returns `self with { y: clamp(self.y, 0.0, 10.0) }` types clean over the
	// same unit header — so each negative fixture rejects for its named reason,
	// not an incidental resolution gap in the header.
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
	// AC (writes-only-own-thing): a behavior on Paddle returning a Ball value
	// rejects — a behavior writes its own blackboard type, not another's. The
	// returned Ball record is a different nominal type than the declared
	// Paddle return.
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
	// AC (with on an unknown field): a `with`-update naming a field outside
	// the record's schema rejects — Paddle has no `z` field.
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
	// AC (with on a wrong-typed field): a `with`-update whose value type
	// disagrees with the field's declared type rejects — Paddle.y is Fixed,
	// not a Vec2.
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
	// AC (no-implicit-promotion): a bare Int argument meeting a Fixed
	// parameter rejects — the Int → Fixed lift is the explicit to_fixed call,
	// never an implicit promotion (§10). clamp's first param is Fixed; `2` is
	// an Int.
	err := typecheck_pong_unit(
		"behavior nudge on Paddle {\n" +
		"  fn step(self: Paddle) -> Paddle {\n" +
		"    return self with { y: clamp(2, 0.0, 10.0) }\n" +
		"  }\n" +
		"}\n")
	testing.expect_value(t, err, Type_Error.Type_Mismatch)
}
