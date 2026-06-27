package funpack

import "core:strings"
import "core:testing"

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

golden_import_bindings :: proc() -> Bindings {
	ast, _ := stage_parse(stage_lex(GOLDEN_IMPORT_HEADER))
	bindings, _ := resolve_imports(ast)
	return bindings
}

@(test)
test_match_expr_types_unified_arm_type :: proc(t: ^testing.T) {
	type, err := check_expr_source(
		"match checked_div(6.0, 2.0) {\n  Option::Some(v) => v\n  Option::None => 0.0\n}\n")
	testing.expect_value(t, err, Type_Error.None)
	testing.expect(t, is_ground(type, .Fixed))
}

@(test)
test_match_arms_disagreeing_rejected :: proc(t: ^testing.T) {
	_, err := check_expr_source(
		"match checked_div(6.0, 2.0) {\n  Option::Some(v) => v\n  Option::None => 0\n}\n")
	testing.expect_value(t, err, Type_Error.Type_Mismatch)
}

@(test)
test_option_payload_types_are_distinct :: proc(t: ^testing.T) {
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
	rng_pair := tuple_of({option_of(Ground_Type.Fixed), engine_type_of(.Rng)})
	same := tuple_of({option_of(Ground_Type.Fixed), engine_type_of(.Rng)})
	swapped := tuple_of({engine_type_of(.Rng), option_of(Ground_Type.Fixed)})
	shorter := tuple_of({engine_type_of(.Rng)})
	nil_first := tuple_of({nil, engine_type_of(.Rng)})
	testing.expect(t, types_compatible(rng_pair, same))
	testing.expect(t, !types_compatible(rng_pair, swapped))
	testing.expect(t, !types_compatible(rng_pair, shorter))
	testing.expect(t, types_compatible(rng_pair, nil_first))
	testing.expect(t, !types_compatible(rng_pair, list_of(engine_type_of(.Rng))))
}

@(test)
test_if_expr_types_unified_arm_type :: proc(t: ^testing.T) {
	type, err := check_expr_source("if 6.0 < 2.0 { 0.0 } else { 1.0 }")
	testing.expect_value(t, err, Type_Error.None)
	testing.expect(t, is_ground(type, .Fixed))
}

@(test)
test_if_expr_disagreeing_arms_rejected :: proc(t: ^testing.T) {
	_, err := check_expr_source("if 6.0 < 2.0 { 0.0 } else { 1 }")
	testing.expect_value(t, err, Type_Error.Type_Mismatch)
}

@(test)
test_if_expr_non_bool_condition_rejected :: proc(t: ^testing.T) {
	_, err := check_expr_source("if 1.0 { 0.0 } else { 1.0 }")
	testing.expect_value(t, err, Type_Error.Type_Mismatch)
}

@(test)
test_tuple_pattern_arity_mismatch_rejected :: proc(t: ^testing.T) {
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
	type, err := check_expr_source("fold([1.0, -1.0], 2.0, fn(acc, x) { return acc + x })")
	testing.expect_value(t, err, Type_Error.None)
	testing.expect(t, is_ground(type, .Fixed))
}

@(test)
test_fold_over_empty_list_types_via_unknown_element :: proc(t: ^testing.T) {
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
	type, err := check_expr_source("pi")
	testing.expect_value(t, err, Type_Error.None)
	testing.expect(t, is_ground(type, .Fixed))
}

@(test)
test_expr_unbound_surface_name_is_unresolved :: proc(t: ^testing.T) {
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

@(test)
test_unknown_method_on_list_is_unknown_method :: proc(t: ^testing.T) {
	_, err := check_expr_source("[1, 2].bogus(3)\n")
	testing.expect_value(t, err, Type_Error.Unknown_Method)
}

check_let_module :: proc(import_header: string, expr: string) -> Type_Error {
	source := strings.concatenate(
		{import_header, "fn roll() -> Int {\n  let rolled = ", expr, "\n  return 0\n}\n"},
		context.temp_allocator,
	)
	ast, parse_verdict := stage_parse_located(stage_lex(source))
	if parse_verdict.err != .None {
		return .Unsupported_Expr
	}
	_, verdict := stage_typecheck_located(ast, Module_Index{})
	return verdict.err
}

@(test)
test_unknown_method_on_call_receiver_is_unknown_method :: proc(t: ^testing.T) {
	err := check_let_module("import engine.rand.{Rng}\n", "Rng.seed(1).bogus_method(0, 9)")
	testing.expect_value(t, err, Type_Error.Unknown_Method)
}

@(test)
test_rng_seed_static_constructor_types_to_rng :: proc(t: ^testing.T) {
	ok_err := check_let_module("import engine.rand.{Rng}\n", "Rng.seed(1)")
	testing.expect_value(t, ok_err, Type_Error.None)
	bad_err := check_let_module("import engine.rand.{Rng}\n", "Rng.seed(1.0)")
	testing.expect_value(t, bad_err, Type_Error.Type_Mismatch)
}

@(test)
test_rng_seed_static_constructor_equals_free_seed :: proc(t: ^testing.T) {
	source := "import engine.rand.{Rng, seed}\n" +
		"test \"static seed equals free seed\" {\n" +
		"  assert Rng.seed(7) == seed(7)\n" +
		"}\n"
	report, err := run_test_pipeline(source)
	testing.expect_value(t, err, Pipeline_Error.None)
	testing.expect_value(t, report.passed, 1)
	testing.expect_value(t, report.failed, 0)
}

@(test)
test_real_list_method_still_types :: proc(t: ^testing.T) {
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
	hint := surface_methods_for_receiver(engine_type_of(.Rng))
	testing.expect_value(t, hint, "available methods: chance, next, pick, range, split")

	list_hint := surface_methods_for_receiver(list_of(Ground_Type.Int))
	testing.expect_value(
		t,
		list_hint,
		"available methods: append, concat, contains, filter, find, first, fold, get, init, is_empty, last, len, map, reverse",
	)

	option_hint := surface_methods_for_receiver(option_of(Ground_Type.Int))
	testing.expect_value(t, option_hint, "available methods: or_else")

	quat_hint := surface_methods_for_receiver(Ground_Type.Quat)
	testing.expect_value(t, quat_hint, "available methods: mul, rotate, slerp")
}

@(test)
test_surface_combinator_probes_drift_gate :: proc(t: ^testing.T) {
	for probe in SURFACE_COMBINATOR_PROBES {
		testing.expectf(
			t,
			is_stdlib_free_fn(probe.name),
			"combinator probe %q is a live stdlib free fn",
			probe.name,
		)
		repr := surface_combinator_probe_receiver(probe.receiver)
		testing.expectf(
			t,
			surface_receiver_matches_combinator(repr, probe.receiver),
			"combinator probe %q accepts a %v receiver at its self position",
			probe.name,
			probe.receiver,
		)
		testing.expectf(
			t,
			!surface_receiver_matches_combinator(Ground_Type.Int, probe.receiver),
			"combinator probe %q does not list on a bare Int receiver",
			probe.name,
		)
	}
	view := engine_type_of(.View, user_type_of("T", .Data))
	testing.expect(t, surface_receiver_matches_combinator(view, .List))
	testing.expect(t, !surface_receiver_matches_combinator(view, .List_Only))
}

surface_combinator_probe_receiver :: proc(kind: Surface_Combinator_Receiver) -> Type {
	switch kind {
	case .List, .List_Only:
		return list_of(Ground_Type.Int)
	case .Rng:
		return engine_type_of(.Rng)
	case .Option:
		return option_of(Ground_Type.Int)
	case .Map:
		return map_of(Ground_Type.Int, Ground_Type.Bool)
	}
	return nil
}
