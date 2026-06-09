// The §05 §2 typed-hole typing fixtures (P8): a holed declaration typechecks
// against its DECLARED type — the hole's T must unify with the `-> R`
// ascription, the optional `@stub(T, fallback)` approximation must produce T,
// and a caller invoking the holed decl types against the intact signature,
// never against the missing body. Each fixture is a small self-contained
// source, so no golden checkout gates the proofs; the negative fixtures pin
// that a disagreeing hole type or a wrong-typed fallback is a Type_Mismatch,
// never silently accepted.
package funpack

import "core:testing"

typecheck_stub :: proc(source: string) -> Type_Error {
	ast, parse_err := stage_parse(stage_lex(source))
	if parse_err != .None {
		return .Unsupported_Expr
	}
	_, err := stage_typecheck(ast)
	return err
}

@(test)
test_stub_hole_matching_declared_return_typechecks :: proc(t: ^testing.T) {
	// AC (holed decl clean): `@stub(T)` whose declared return type is the same
	// T typechecks clean — the hole stands for the body, so there is no
	// statement sequence to walk and the unification of T against `-> R` is
	// the whole body check.
	err := typecheck_stub("fn speed() -> Fixed @stub(Fixed)\n")
	testing.expect_value(t, err, Type_Error.None)
}

@(test)
test_stub_caller_typechecks_against_hole_type :: proc(t: ^testing.T) {
	// AC (caller-against-hole): a caller invoking the holed decl typechecks
	// against the declared T — the call site resolves the intact signature
	// (call_check over the recorded Func_Type), so `speed()` types as Fixed and
	// satisfies the caller's own `-> Fixed` return.
	err := typecheck_stub(
		"fn speed() -> Fixed @stub(Fixed)\n" +
		"fn use_speed() -> Fixed { return speed() }\n")
	testing.expect_value(t, err, Type_Error.None)
}

@(test)
test_stub_caller_sees_declared_signature_not_missing_body :: proc(t: ^testing.T) {
	// AC (caller-against-hole, negative side): the call site sees the declared
	// signature, never the missing body — a caller returning the Fixed-holed
	// `speed()` against its own `-> Int` is the ordinary Type_Mismatch, proving
	// the call typed against T rather than against an absent (unknowable) body.
	err := typecheck_stub(
		"fn speed() -> Fixed @stub(Fixed)\n" +
		"fn use_speed() -> Int { return speed() }\n")
	testing.expect_value(t, err, Type_Error.Type_Mismatch)
}

@(test)
test_stub_fallback_producing_hole_type_typechecks :: proc(t: ^testing.T) {
	// AC (fallback positive): the `@stub(T, fallback)` approximation expression
	// checks against the hole's declared T — a Fixed literal fallback over a
	// Fixed hole is clean.
	err := typecheck_stub("fn speed() -> Fixed @stub(Fixed, 1.5)\n")
	testing.expect_value(t, err, Type_Error.None)
}

@(test)
test_stub_fallback_wrong_type_rejected :: proc(t: ^testing.T) {
	// AC (fallback negative): a fallback that does not produce T is a
	// Type_Mismatch — the Int literal `1` over a Fixed hole rejects, since
	// there is no implicit Int → Fixed promotion (spec §10). This is the
	// compile error the pipeline surfaces as Typecheck_Failed.
	err := typecheck_stub("fn speed() -> Fixed @stub(Fixed, 1)\n")
	testing.expect_value(t, err, Type_Error.Type_Mismatch)
}

@(test)
test_stub_hole_disagreeing_with_return_ascription_rejected :: proc(t: ^testing.T) {
	// AC (hole-vs-ascription): a `@stub(T)` whose declared T disagrees with the
	// declaration's own `-> R` ascription is a typecheck error, not silently
	// accepted — the signature callers see and the hole standing for the body
	// must be the same type.
	err := typecheck_stub("fn speed() -> Fixed @stub(Int)\n")
	testing.expect_value(t, err, Type_Error.Type_Mismatch)
}

@(test)
test_stub_fallback_checks_in_decl_param_scope :: proc(t: ^testing.T) {
	// AC (fallback environment): the fallback expression types in the decl's
	// own environment — the param-seeded scope — so a fallback referencing a
	// declared parameter (`b: Ball` returned as the Ball approximation) grounds
	// and unifies with the hole's T.
	err := typecheck_stub(
		"thing Ball { x: Int = 0 }\n" +
		"fn serve(b: Ball) -> Ball @stub(Ball, b)\n")
	testing.expect_value(t, err, Type_Error.None)
}

@(test)
test_stub_behavior_step_holed_typechecks :: proc(t: ^testing.T) {
	// AC (behavior parity): a behavior's reserved step entry point may be holed
	// exactly like a fn (Behavior_Node.step shares Fn_Node) — the holed step
	// short-circuits the same body walk and unifies its T against the step's
	// declared return.
	err := typecheck_stub(
		"thing Ball { x: Int = 0 }\n" +
		"behavior serve on Ball {\n" +
		"  fn step(self: Ball) -> Ball @stub(Ball)\n" +
		"}\n")
	testing.expect_value(t, err, Type_Error.None)
}
