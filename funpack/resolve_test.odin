// The user-declaration resolver's fixtures: the live pong golden source's
// declarations must lift into the Type_Env (every thing/data/enum/signal/
// fn/behavior name and module-let constant binds, variant sets and record
// field schemas readable), and the §02 one-name-one-meaning rule must
// reject a colliding user name while a genuinely free name still rejects as
// Unresolved_Name through the extended resolver.
package funpack

import "core:testing"

// resolve_source lexes, parses, and resolves a complete source's user
// environment under its own imports — the resolver entry point the fixtures
// exercise. A parse failure surfaces as an empty env with the parse mapped
// to Unsupported_Expr so a malformed fixture fails loudly rather than
// silently resolving nothing.
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
	// AC: the pong golden source's declarations resolve into the
	// environment — every thing/singleton/data/enum/signal/fn/behavior name
	// and the module-let constant bind, the enum variant sets are recorded,
	// and the record field schemas are readable. The fixture resolves the
	// live golden source (or FUNPACK_PONG_DIR) and SKIPs loudly when absent.
	source, ok := pong_source()
	if !ok {
		return
	}
	env, err := resolve_source(source)
	testing.expect_value(t, err, Type_Error.None)

	// The full declared inventory binds: 3 things + 1 data + 1 signal =
	// 5 record schemas; 2 enums; 1 let + 9 fns + 10 behaviors = 20 terms.
	testing.expect_value(t, len(env.records), 5)
	testing.expect_value(t, len(env.enums), 2)
	testing.expect_value(t, len(env.terms), 20)

	// Every type-position name binds to its handle.
	type_names := []string{"Paddle", "Ball", "Scoreboard", "Board", "Goal"}
	for name in type_names {
		_, found := env_type_name(env, name)
		testing.expectf(t, found, "%s did not bind as a type", name)
	}
	// Every term-position name binds (the §04 name.step form reaches a
	// behavior through its own name key).
	term_names := []string{"BOARD", "advance", "goal_side", "setup", "paddle_move", "score", "tally", "draw_ball"}
	for name in term_names {
		_, found := env_term_name(env, name)
		testing.expectf(t, found, "%s did not bind as a term", name)
	}

	// The enum variant sets are recorded: Side::Left/Right and Steer::Move,
	// with Steer carrying its §03 §4 role kind `Axis`.
	side := env.enums["Side"]
	testing.expect_value(t, side.role, "")
	testing.expect_value(t, len(side.variants), 2)
	testing.expect_value(t, side.variants[0], "Left")
	testing.expect_value(t, side.variants[1], "Right")

	steer := env.enums["Steer"]
	testing.expect_value(t, steer.role, "Axis")
	testing.expect_value(t, len(steer.variants), 1)
	testing.expect_value(t, steer.variants[0], "Move")

	// The record field schemas are readable: Paddle.x:Fixed (a ground
	// type), Ball.pos:Vec2 (an engine-record ground), Goal.side:Side (a user
	// enum nominal handle).
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

	// A singleton-or-thing record keeps its declared kind and defaulted
	// fields: Scoreboard's Int fields carry `= 0` (§03 §1).
	scoreboard := env.records["Scoreboard"]
	testing.expect_value(t, scoreboard.kind, User_Kind.Thing)
	left_type, has_left := field_type(scoreboard, "left")
	testing.expect(t, has_left)
	testing.expect(t, is_ground(left_type, .Int))
	testing.expect(t, scoreboard.fields[0].has_default)
}

// field_type reads a record schema's field type by name — a linear lookup
// the fixtures use so a schema assertion does not depend on field order.
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
	// AC: one-name-one-meaning across user and imported names. A user `data`
	// named Vec2 collides with the imported engine.math Vec2 — a resolution
	// error, never silent last-wins.
	source := "import engine.math.{Vec2}\n" + "data Vec2 { x: Fixed }\n"
	_, err := resolve_source(source)
	testing.expect_value(t, err, Type_Error.Name_Collision)
}

@(test)
test_two_user_decls_same_name_rejected :: proc(t: ^testing.T) {
	// AC: one-name-one-meaning within the user namespace. Two user
	// declarations claiming Score — one a thing, one a data — collide; the
	// resolver rejects rather than letting the second silently win.
	source := "thing Score { points: Int }\n" + "data Score { total: Int }\n"
	_, err := resolve_source(source)
	testing.expect_value(t, err, Type_Error.Name_Collision)
}

@(test)
test_user_type_colliding_with_prelude_rejected :: proc(t: ^testing.T) {
	// The prelude is always in scope (no import), so a user enum named
	// Option collides with it just as it would with an explicit import.
	source := "enum Option { Yes, No }\n"
	_, err := resolve_source(source)
	testing.expect_value(t, err, Type_Error.Name_Collision)
}

@(test)
test_free_name_with_no_decl_and_no_import_unresolved :: proc(t: ^testing.T) {
	// AC: a free name with no user decl and no import still rejects as
	// Unresolved_Name through the extended resolver — the resolver widened
	// the bound set but did not weaken the unresolved verdict.
	source := "test \"x\" {\n\tassert nonexistent == 1\n}\n"
	typed, err := stage_typecheck_source(source)
	_ = typed
	testing.expect_value(t, err, Type_Error.Unresolved_Name)
}

@(test)
test_user_declared_name_binds_as_function_value :: proc(t: ^testing.T) {
	// A name a user fn declares binds through the resolver and now types as a
	// function value (its recorded signature), never Unresolved_Name. Comparing
	// that function value to an Int is a Type_Mismatch — proof the resolver
	// widened the bound set AND the typing pass grounds a bare fn name as its
	// signature (the form fold's accumulator argument takes).
	source := "fn helper(n: Int) -> Int {\n\treturn n\n}\n" +
		"test \"x\" {\n\tassert helper == 1\n}\n"
	_, err := stage_typecheck_source(source)
	testing.expect_value(t, err, Type_Error.Type_Mismatch)
}

@(test)
test_user_name_in_fold_lambda_body_types_as_function :: proc(t: ^testing.T) {
	// The fold lambda body checks under a child context that inherits the
	// enclosing scope and the env; a user-declared name referenced there
	// types as its function-value signature, never a mis-reported
	// Unresolved_Name from a context that dropped the env. The body returns a
	// function while the accumulator is Int, so the fold rejects as
	// Type_Mismatch.
	source := "import engine.list.fold\n" +
		"fn helper(n: Int) -> Int {\n\treturn n\n}\n" +
		"test \"x\" {\n\tassert fold([1, 2], 0, fn(acc, x) { return helper }) == 0\n}\n"
	_, err := stage_typecheck_source(source)
	testing.expect_value(t, err, Type_Error.Type_Mismatch)
}

// stage_typecheck_source runs lex → parse → typecheck on a full source,
// returning the typecheck verdict — the resolver fixtures' window onto the
// extended name-resolution path the test blocks exercise.
stage_typecheck_source :: proc(source: string) -> (typed: Typed_Ast, err: Type_Error) {
	ast, parse_err := stage_parse(stage_lex(source))
	if parse_err != .None {
		return Typed_Ast{}, .Unsupported_Expr
	}
	return stage_typecheck(ast)
}
