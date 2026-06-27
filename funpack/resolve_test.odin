package funpack

import "core:testing"

resolve_source :: proc(source: string) -> (env: Type_Env, err: Type_Error) {
	ast, parse_err := stage_parse(stage_lex(source))
	if parse_err != .None {
		return Type_Env{}, .Unsupported_Expr
	}
	bindings := resolve_imports(ast) or_return
	return resolve_env(ast, bindings)
}

@(test)
test_resolve_pong_declarations_into_environment :: proc(t: ^testing.T) {
	source, ok := pong_source()
	if !ok {
		return
	}
	env, err := resolve_source(source)
	testing.expect_value(t, err, Type_Error.None)

	testing.expect_value(t, len(env.records), 5)
	testing.expect_value(t, len(env.enums), 2)
	testing.expect_value(t, len(env.terms), 20)

	type_names := []string{"Paddle", "Ball", "Scoreboard", "Board", "Goal"}
	for name in type_names {
		_, found := env_type_name(env, name)
		testing.expectf(t, found, "%s did not bind as a type", name)
	}
	term_names := []string{"BOARD", "advance", "goal_side", "setup", "paddle_move", "score", "tally", "draw_ball"}
	for name in term_names {
		_, found := env_term_name(env, name)
		testing.expectf(t, found, "%s did not bind as a term", name)
	}

	side := env.enums["Side"]
	testing.expect_value(t, side.role, "")
	testing.expect_value(t, len(side.variants), 2)
	testing.expect_value(t, side.variants[0], "Left")
	testing.expect_value(t, side.variants[1], "Right")

	steer := env.enums["Steer"]
	testing.expect_value(t, steer.role, "Axis")
	testing.expect_value(t, len(steer.variants), 1)
	testing.expect_value(t, steer.variants[0], "Move")

	paddle := env.records["Paddle"]
	x_type, has_x := field_type(paddle, "x")
	testing.expect(t, has_x)
	testing.expect(t, is_ground(x_type, .Fixed))

	ball := env.records["Ball"]
	pos_type, has_pos := field_type(ball, "pos")
	testing.expect(t, has_pos)
	testing.expect(t, is_ground(pos_type, .Vec2))

	goal := env.records["Goal"]
	testing.expect_value(t, goal.kind, User_Kind.Signal)
	side_type, has_side := field_type(goal, "side")
	testing.expect(t, has_side)
	side_user, is_user := side_type.(^User_Type)
	testing.expect(t, is_user)
	if is_user {
		testing.expect_value(t, side_user.name, "Side")
		testing.expect_value(t, side_user.kind, User_Kind.Enum)
	}

	scoreboard := env.records["Scoreboard"]
	testing.expect_value(t, scoreboard.kind, User_Kind.Thing)
	left_type, has_left := field_type(scoreboard, "left")
	testing.expect(t, has_left)
	testing.expect(t, is_ground(left_type, .Int))
	testing.expect(t, scoreboard.fields[0].has_default)
}

field_type :: proc(schema: Record_Schema, name: string) -> (type: Type, found: bool) {
	for field in schema.fields {
		if field.name == name {
			return field.type, true
		}
	}
	return nil, false
}

@(test)
test_user_type_colliding_with_import_rejected :: proc(t: ^testing.T) {
	source := "import engine.math.{Vec2}\n" + "data Vec2 { x: Fixed }\n"
	_, err := resolve_source(source)
	testing.expect_value(t, err, Type_Error.Name_Collision)
}

@(test)
test_two_user_decls_same_name_rejected :: proc(t: ^testing.T) {
	source := "thing Score { points: Int }\n" + "data Score { total: Int }\n"
	_, err := resolve_source(source)
	testing.expect_value(t, err, Type_Error.Name_Collision)
}

@(test)
test_user_type_colliding_with_prelude_rejected :: proc(t: ^testing.T) {
	source := "enum Option { Yes, No }\n"
	_, err := resolve_source(source)
	testing.expect_value(t, err, Type_Error.Name_Collision)
}

@(test)
test_free_name_with_no_decl_and_no_import_unresolved :: proc(t: ^testing.T) {
	source := "test \"x\" {\n\tassert nonexistent == 1\n}\n"
	typed, err := stage_typecheck_source(source)
	_ = typed
	testing.expect_value(t, err, Type_Error.Unresolved_Name)
}

@(test)
test_user_declared_name_binds_as_function_value :: proc(t: ^testing.T) {
	source := "fn helper(n: Int) -> Int {\n\treturn n\n}\n" +
		"test \"x\" {\n\tassert helper == 1\n}\n"
	_, err := stage_typecheck_source(source)
	testing.expect_value(t, err, Type_Error.Type_Mismatch)
}

@(test)
test_user_name_in_fold_lambda_body_types_as_function :: proc(t: ^testing.T) {
	source := "import engine.list.fold\n" +
		"fn helper(n: Int) -> Int {\n\treturn n\n}\n" +
		"test \"x\" {\n\tassert fold([1, 2], 0, fn(acc, x) { return helper }) == 0\n}\n"
	_, err := stage_typecheck_source(source)
	testing.expect_value(t, err, Type_Error.Type_Mismatch)
}

stage_typecheck_source :: proc(source: string) -> (typed: Typed_Ast, err: Type_Error) {
	ast, parse_err := stage_parse(stage_lex(source))
	if parse_err != .None {
		return Typed_Ast{}, .Unsupported_Expr
	}
	return stage_typecheck(ast)
}

@(test)
test_fn_typed_param_signature_resolves_and_checks_lambda :: proc(t: ^testing.T) {
	source := "extern fn apply(x: Int, f: fn(Int) -> Int) -> Int\n" +
		"test \"x\" {\n\tassert apply(1, fn(n) { return n + 1 }) == 2\n}\n"
	_, err := stage_typecheck_source(source)
	testing.expect_value(t, err, Type_Error.None)
}

@(test)
test_fn_typed_param_rejects_wrong_lambda :: proc(t: ^testing.T) {
	wrong_result := "extern fn apply(x: Int, f: fn(Int) -> Int) -> Int\n" +
		"test \"x\" {\n\tassert apply(1, fn(n) { return n == 1 }) == 2\n}\n"
	_, result_err := stage_typecheck_source(wrong_result)
	testing.expect_value(t, result_err, Type_Error.Type_Mismatch)
	wrong_arity := "extern fn apply(x: Int, f: fn(Int) -> Int) -> Int\n" +
		"test \"x\" {\n\tassert apply(1, fn(a, b) { return a }) == 2\n}\n"
	_, arity_err := stage_typecheck_source(wrong_arity)
	testing.expect_value(t, arity_err, Type_Error.Type_Mismatch)
}

@(test)
test_fn_typed_param_accepts_bare_fn_value :: proc(t: ^testing.T) {
	matching := "extern fn apply(x: Int, f: fn(Int) -> Int) -> Int\n" +
		"fn helper(n: Int) -> Int {\n\treturn n\n}\n" +
		"test \"x\" {\n\tassert apply(1, helper) == 1\n}\n"
	_, match_err := stage_typecheck_source(matching)
	testing.expect_value(t, match_err, Type_Error.None)
	mismatched := "extern fn apply(x: Int, f: fn(Int) -> Int) -> Int\n" +
		"fn is_one(n: Int) -> Bool {\n\treturn n == 1\n}\n" +
		"test \"x\" {\n\tassert apply(1, is_one) == 1\n}\n"
	_, mismatch_err := stage_typecheck_source(mismatched)
	testing.expect_value(t, mismatch_err, Type_Error.Type_Mismatch)
}

@(test)
test_fn_typed_param_invocation_stays_fail_closed :: proc(t: ^testing.T) {
	source := "fn twice(x: Int, f: fn(Int) -> Int) -> Int {\n\treturn f(x)\n}\n"
	_, err := stage_typecheck_source(source)
	testing.expect_value(t, err, Type_Error.Unsupported_Expr)
}

@(test)
test_fn_typed_query_param_rejected_by_value_domain :: proc(t: ^testing.T) {
	source := "query bad(pred: fn(Int) -> Bool) -> Int {\n\treturn 1\n}\n"
	_, err := stage_typecheck_source(source)
	testing.expect_value(t, err, Type_Error.Query_Param_Not_Value)
}
