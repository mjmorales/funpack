package funpack

import "core:testing"

// check_expr_source lexes and parses a single expression, then types
// it against an empty scope under the golden import bindings.
check_expr_source :: proc(source: string) -> (type: Type, err: Type_Error) {
	p := Parser{tokens = stage_lex(source)}
	expr, parse_err := parse_expression(&p)
	if parse_err != .None {
		return nil, .Unsupported_Expr
	}
	ctx := Check_Ctx{
		bindings = golden_import_bindings(),
		scope    = make(Scope, context.temp_allocator),
	}
	return expr_check(ctx, expr)
}

// golden_import_bindings resolves the golden import header, so
// expression fixtures bind the same surface numerics.fun does.
golden_import_bindings :: proc() -> Bindings {
	ast, _ := stage_parse(stage_lex(GOLDEN_IMPORT_HEADER))
	bindings, _ := resolve_imports(ast)
	return bindings
}

@(test)
test_match_expr_types_unified_arm_type :: proc(t: ^testing.T) {
	// A match over an Option[Fixed] scrutinee types each arm and unifies
	// them: Some(v) binds v to the element (Fixed), both arm bodies are
	// Fixed, so the match's type is Fixed. The scrutinee is itself a typed
	// expression — checked_div returns Option[Fixed] (§10).
	type, err := check_expr_source(
		"match checked_div(6.0, 2.0) {\n  Option::Some(v) => v\n  Option::None => 0.0\n}\n")
	testing.expect_value(t, err, Type_Error.None)
	testing.expect(t, is_ground(type, .Fixed))
}

@(test)
test_match_arms_disagreeing_rejected :: proc(t: ^testing.T) {
	// Arm bodies must agree: a Fixed arm and an Int arm over the same match
	// is a Type_Mismatch — no implicit promotion across arms (§10).
	_, err := check_expr_source(
		"match checked_div(6.0, 2.0) {\n  Option::Some(v) => v\n  Option::None => 0\n}\n")
	testing.expect_value(t, err, Type_Error.Type_Mismatch)
}

@(test)
test_option_payload_types_are_distinct :: proc(t: ^testing.T) {
	// Option[Fixed] and Option[Int] are different types; Option's
	// unknown (the None element) unifies with either.
	testing.expect(t, !types_compatible(option_of(Ground_Type.Fixed), option_of(Ground_Type.Int)))
	testing.expect(t, types_compatible(option_of(Ground_Type.Fixed), option_of(Ground_Type.Fixed)))
	testing.expect(t, types_compatible(option_of(nil), option_of(Ground_Type.Fixed)))
	testing.expect(t, types_compatible(option_of(nil), option_of(Ground_Type.Int)))
}

@(test)
test_option_heads_do_not_cross :: proc(t: ^testing.T) {
	testing.expect(t, !types_compatible(option_of(Ground_Type.Fixed), list_of(Ground_Type.Fixed)))
	testing.expect(t, !types_compatible(option_of(Ground_Type.Fixed), Ground_Type.Fixed))
}

@(test)
test_tuple_type_node_in_union :: proc(t: ^testing.T) {
	// AC: the Type union carries a tuple node — tuple_of builds it, and a value
	// of that type variant-matches as ^Tuple_Type carrying its positional
	// elements in order. This is the §04 §1 `(value, next_rng)` return pair's
	// checker type.
	pair := tuple_of({option_of(Ground_Type.Fixed), engine_type_of(.Rng)})
	tuple, is_tuple := pair.(^Tuple_Type)
	testing.expect(t, is_tuple)
	if is_tuple {
		testing.expect_value(t, len(tuple.elements), 2)
		testing.expect(t, types_compatible(tuple.elements[0], option_of(Ground_Type.Fixed)))
		testing.expect(t, is_engine(tuple.elements[1], .Rng))
	}
}

@(test)
test_tuple_compatibility_is_structural :: proc(t: ^testing.T) {
	// AC: types_compatible's tuple arm is structural over positions — same arity
	// and each position unifies, with a nil position unifying like List/Option.
	// So (Option[Fixed], Rng) matches itself, a position swap does not, an arity
	// mismatch does not, and a nil position unifies against a concrete one.
	rng_pair := tuple_of({option_of(Ground_Type.Fixed), engine_type_of(.Rng)})
	same := tuple_of({option_of(Ground_Type.Fixed), engine_type_of(.Rng)})
	swapped := tuple_of({engine_type_of(.Rng), option_of(Ground_Type.Fixed)})
	shorter := tuple_of({engine_type_of(.Rng)})
	nil_first := tuple_of({nil, engine_type_of(.Rng)})
	testing.expect(t, types_compatible(rng_pair, same))
	testing.expect(t, !types_compatible(rng_pair, swapped))
	testing.expect(t, !types_compatible(rng_pair, shorter))
	testing.expect(t, types_compatible(rng_pair, nil_first))
	// A tuple head never crosses with a list or an option of the same elements.
	testing.expect(t, !types_compatible(rng_pair, list_of(engine_type_of(.Rng))))
}

@(test)
test_if_expr_types_unified_arm_type :: proc(t: ^testing.T) {
	// AC: a value-producing if-expression types its condition as Bool and unifies
	// the two arms — a Fixed condition comparison with two Fixed arms types the
	// whole if-expression as Fixed, exactly like a two-armed match (spec §02 §5).
	type, err := check_expr_source("if 6.0 < 2.0 { 0.0 } else { 1.0 }")
	testing.expect_value(t, err, Type_Error.None)
	testing.expect(t, is_ground(type, .Fixed))
}

@(test)
test_if_expr_disagreeing_arms_rejected :: proc(t: ^testing.T) {
	// AC: the two arms must agree — a Fixed then-arm and an Int else-arm is a
	// Type_Mismatch, no implicit promotion across arms (the same rule the match
	// arm unification enforces).
	_, err := check_expr_source("if 6.0 < 2.0 { 0.0 } else { 1 }")
	testing.expect_value(t, err, Type_Error.Type_Mismatch)
}

@(test)
test_if_expr_non_bool_condition_rejected :: proc(t: ^testing.T) {
	// AC: a non-Bool condition is a Type_Mismatch — the guard must be Bool-typed
	// (spec §02 §5). Here the condition is a bare Fixed literal, not a predicate.
	_, err := check_expr_source("if 1.0 { 0.0 } else { 1.0 }")
	testing.expect_value(t, err, Type_Error.Type_Mismatch)
}

@(test)
test_tuple_pattern_arity_mismatch_rejected :: proc(t: ^testing.T) {
	// AC: a tuple match pattern whose positional arity disagrees with its
	// Tuple-typed scrutinee is the precise error .Tuple_Pattern_Arity (spec §02
	// §5) — a 2-binder pattern over a 3-tuple can never bind coherently, so it is
	// a compile error rather than a silent nil-bound position.
	scrutinee := tuple_of({Ground_Type.Int, Ground_Type.Fixed, engine_type_of(.Rng)})
	two_position := Pattern {
		kind = .Tuple,
		elements = {
			Pattern{kind = .Bare_Binder, binders = {"a"}},
			Pattern{kind = .Bare_Binder, binders = {"b"}},
		},
	}
	testing.expect_value(t, check_pattern_arity(two_position, scrutinee), Type_Error.Tuple_Pattern_Arity)
}

@(test)
test_tuple_pattern_arity_match_accepted :: proc(t: ^testing.T) {
	// AC: a tuple pattern whose arity AGREES with the scrutinee tuple type passes
	// the arity check — the `(Option::Some(wp), rest)` 2-position shape over a
	// 2-tuple is .None, and a nested tuple is checked at every level.
	scrutinee := tuple_of({option_of(Ground_Type.Fixed), engine_type_of(.Rng)})
	matching := Pattern {
		kind = .Tuple,
		elements = {
			Pattern {
				kind = .Variant_Binds,
				type_name = "Option",
				variant = "Some",
				elements = {Pattern{kind = .Bare_Binder, binders = {"wp"}}},
			},
			Pattern{kind = .Bare_Binder, binders = {"rest"}},
		},
	}
	testing.expect_value(t, check_pattern_arity(matching, scrutinee), Type_Error.None)
}

@(test)
test_pattern_binders_destructure_tuple_scrutinee :: proc(t: ^testing.T) {
	// AC: pattern_binders destructures a tuple scrutinee against a tuple pattern —
	// the `(Option::Some(cell), next)` arm binds `cell` to the option's element
	// (a Cell) and `next` to the second tuple position (an Rng), in left-to-right
	// position order.
	cell := user_type_of("Cell", .Data)
	scrutinee := tuple_of({option_of(cell), engine_type_of(.Rng)})
	pattern := Pattern {
		kind = .Tuple,
		elements = {
			Pattern {
				kind = .Variant_Binds,
				type_name = "Option",
				variant = "Some",
				elements = {Pattern{kind = .Bare_Binder, binders = {"cell"}}},
			},
			Pattern{kind = .Bare_Binder, binders = {"next"}},
		},
	}
	names, types := pattern_binders(Type_Env{}, pattern, scrutinee)
	testing.expect_value(t, len(names), 2)
	testing.expect_value(t, len(types), 2)
	if len(names) == 2 {
		testing.expect_value(t, names[0], "cell")
		testing.expect_value(t, names[1], "next")
		bound_cell, is_cell := types[0].(^User_Type)
		testing.expect(t, is_cell)
		if is_cell {
			testing.expect_value(t, bound_cell.name, "Cell")
		}
		testing.expect(t, is_engine(types[1], .Rng))
	}
}

@(test)
test_bool_literals_type_as_bool :: proc(t: ^testing.T) {
	// §02 §2: `true`/`false` are Bool literals riding as Ident tokens, so a
	// Bool-returning expression compares against them (snake's `== true`,
	// pong's overlaps rail test).
	for literal in ([]string{"true", "false"}) {
		type, err := check_expr_source(literal)
		testing.expect_value(t, err, Type_Error.None)
		testing.expect(t, is_ground(type, .Bool))
	}
	cmp, cmp_err := check_expr_source("(1.0 < 2.0) == true")
	testing.expect_value(t, cmp_err, Type_Error.None)
	testing.expect(t, is_ground(cmp, .Bool))
}

@(test)
test_variant_expr_types_carry_payload :: proc(t: ^testing.T) {
	some, err := check_expr_source("Option::Some(1.0)")
	testing.expect_value(t, err, Type_Error.None)
	some_option, is_option := some.(^Option_Type)
	testing.expect(t, is_option)
	testing.expect(t, is_ground(some_option.elem, .Fixed))

	none, none_err := check_expr_source("Option::None")
	testing.expect_value(t, none_err, Type_Error.None)
	none_option, none_is_option := none.(^Option_Type)
	testing.expect(t, none_is_option)
	testing.expect(t, none_option.elem == nil)
	testing.expect(t, types_compatible(some, none))
}

@(test)
test_list_expr_carries_element_type :: proc(t: ^testing.T) {
	type, err := check_expr_source("[1.0, 2.0]")
	testing.expect_value(t, err, Type_Error.None)
	list, is_list := type.(^List_Type)
	testing.expect(t, is_list)
	testing.expect(t, is_ground(list.elem, .Fixed))
}

@(test)
test_empty_list_element_is_unknown :: proc(t: ^testing.T) {
	type, err := check_expr_source("[]")
	testing.expect_value(t, err, Type_Error.None)
	list, is_list := type.(^List_Type)
	testing.expect(t, is_list)
	testing.expect(t, list.elem == nil)
	testing.expect(t, types_compatible(type, list_of(Ground_Type.Fixed)))
}

@(test)
test_heterogeneous_list_rejected :: proc(t: ^testing.T) {
	_, err := check_expr_source("[1.0, 2]")
	testing.expect_value(t, err, Type_Error.Type_Mismatch)
}

@(test)
test_checked_div_types_as_option_of_fixed :: proc(t: ^testing.T) {
	type, err := check_expr_source("checked_div(6.0, 2.0)")
	testing.expect_value(t, err, Type_Error.None)
	option, is_option := type.(^Option_Type)
	testing.expect(t, is_option)
	testing.expect(t, is_ground(option.elem, .Fixed))
}

@(test)
test_lambda_types_as_placeholder_func :: proc(t: ^testing.T) {
	type, err := check_expr_source("fn(acc, x) { return acc + x }")
	testing.expect_value(t, err, Type_Error.None)
	func, is_func := type.(^Func_Type)
	testing.expect(t, is_func)
	testing.expect(t, func.params == nil)
}

@(test)
test_fold_infers_lambda_params_and_types_body :: proc(t: ^testing.T) {
	// acc and x infer as Fixed from the init and the list element; the
	// body types statically and the whole fold comes back as A.
	type, err := check_expr_source("fold([1.0, -1.0], 2.0, fn(acc, x) { return acc + x })")
	testing.expect_value(t, err, Type_Error.None)
	testing.expect(t, is_ground(type, .Fixed))
}

@(test)
test_fold_over_empty_list_types_via_unknown_element :: proc(t: ^testing.T) {
	// The empty list's element is the nil unknown: x unifies with the
	// Fixed accumulator on the body's right-hand side.
	type, err := check_expr_source("fold([], 2.0, fn(acc, x) { return acc + x })")
	testing.expect_value(t, err, Type_Error.None)
	testing.expect(t, is_ground(type, .Fixed))
}

@(test)
test_surface_signature_checked_div :: proc(t: ^testing.T) {
	overloads, found := surface_signatures("checked_div")
	testing.expect(t, found)
	testing.expect_value(t, len(overloads), 1)
	sig, is_func := overloads[0].(^Func_Type)
	testing.expect(t, is_func)
	testing.expect_value(t, len(sig.params), 2)
	testing.expect(t, is_ground(sig.params[0], .Fixed))
	result, is_option := sig.result.(^Option_Type)
	testing.expect(t, is_option)
	testing.expect(t, is_ground(result.elem, .Fixed))
}

@(test)
test_surface_signature_width_overloads :: proc(t: ^testing.T) {
	dot_overloads, dot_found := surface_signatures("dot")
	testing.expect(t, dot_found)
	testing.expect_value(t, len(dot_overloads), 2)
	length_overloads, length_found := surface_signatures("length")
	testing.expect(t, length_found)
	testing.expect_value(t, len(length_overloads), 2)
}

@(test)
test_surface_generic_combinators_have_no_table_signature :: proc(t: ^testing.T) {
	_, found := surface_signatures("fold")
	testing.expect(t, !found)
}

@(test)
test_surface_value_type_pi :: proc(t: ^testing.T) {
	type, found := surface_value_type("pi")
	testing.expect(t, found)
	testing.expect(t, is_ground(type, .Fixed))
}

@(test)
test_expr_pi_types_fixed_via_binding :: proc(t: ^testing.T) {
	// pi reaches Fixed through the import binding, not a special case.
	type, err := check_expr_source("pi")
	testing.expect_value(t, err, Type_Error.None)
	testing.expect(t, is_ground(type, .Fixed))
}

@(test)
test_expr_unbound_surface_name_is_unresolved :: proc(t: ^testing.T) {
	// tau exists on the surface but the golden header does not import
	// it; a known spelling without a binding is an unresolved name.
	_, err := check_expr_source("tau")
	testing.expect_value(t, err, Type_Error.Unresolved_Name)
}

@(test)
test_expr_typo_name_is_unresolved :: proc(t: ^testing.T) {
	_, err := check_expr_source("lenght")
	testing.expect_value(t, err, Type_Error.Unresolved_Name)
}

@(test)
test_surface_associated_members :: proc(t: ^testing.T) {
	max_type, max_found := surface_associated("Fixed", "MAX")
	testing.expect(t, max_found)
	testing.expect(t, is_ground(max_type, .Fixed))

	ctor, ctor_found := surface_associated("Quat", "axis_angle")
	testing.expect(t, ctor_found)
	signature, is_func := ctor.(^Func_Type)
	testing.expect(t, is_func)
	testing.expect_value(t, len(signature.params), 2)
	testing.expect(t, is_ground(signature.result, .Quat))

	_, bogus_found := surface_associated("Quat", "bogus")
	testing.expect(t, !bogus_found)
}

@(test)
test_surface_method_quat_only :: proc(t: ^testing.T) {
	rotate, rotate_found := surface_method(Ground_Type.Quat, "rotate")
	testing.expect(t, rotate_found)
	signature, is_func := rotate.(^Func_Type)
	testing.expect(t, is_func)
	testing.expect(t, is_ground(signature.result, .Vec3))

	_, fixed_found := surface_method(Ground_Type.Fixed, "rotate")
	testing.expect(t, !fixed_found)
}

// ── Unknown method on a known type ─────────────────────────────────────
// A `recv.NAME(…)` whose receiver typed CLEAN but exposes no method NAME and
// no §02 §4 UFCS-reachable free fn is the distinct Unknown_Method arm, NOT
// the Unsupported_Expr catch-all. These pin the SPLIT at the typecheck-arm
// junction (the rendered member-name caret + hint are pinned through the
// pipeline in diagnostics_test.odin).

@(test)
test_unknown_method_on_list_is_unknown_method :: proc(t: ^testing.T) {
	// A list receiver typed clean (List[Int]); `bogus` is neither a list method
	// nor a stdlib free fn reachable via UFCS — so the arm is Unknown_Method, not
	// the Unsupported_Expr that read as "this expression form is illegal".
	_, err := check_expr_source("[1, 2].bogus(3)\n")
	testing.expect_value(t, err, Type_Error.Unknown_Method)
}

@(test)
test_real_list_method_still_types :: proc(t: ^testing.T) {
	// The split must not break a REAL UFCS method: `[1,2].len()` lowers to
	// `len([1,2])` (Int) exactly as before — Unknown_Method fires only when no
	// method resolves. Driven through the full pipeline so `len` is imported (the
	// golden expr bindings carry only math + fold, so the lowering would otherwise
	// hit Unresolved_Name on the bare `len`).
	source := "import engine.list.len\n" +
		"test \"list len method types and runs\" {\n" +
		"  assert [1, 2, 3].len() == 3\n" +
		"}\n"
	report, err := run_test_pipeline(source)
	testing.expect_value(t, err, Pipeline_Error.None)
	testing.expect_value(t, report.passed, 1)
	testing.expect_value(t, report.failed, 0)
}

@(test)
test_surface_methods_for_receiver_lists_rng_draws :: proc(t: ^testing.T) {
	// The Unknown_Method hint enumerates a receiver's real methods from the
	// closed surface tables. An Rng's self-first signature methods are the
	// available list: chance/next/range/split (pick is a call-site-inferred
	// combinator, tracked separately). The hint is deterministic + sorted.
	hint := surface_methods_for_receiver(engine_type_of(.Rng))
	testing.expect_value(t, hint, "available methods: chance, next, range, split")

	// A Quat's ground methods come through surface_method (the rotate/mul/slerp
	// set), sorted into the same hint shape.
	quat_hint := surface_methods_for_receiver(Ground_Type.Quat)
	testing.expect_value(t, quat_hint, "available methods: mul, rotate, slerp")
}
