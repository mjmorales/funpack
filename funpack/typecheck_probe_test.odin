// The §05 §5 / §28 §4 debug-probe ARGUMENT typing fixtures (check_probe_args): a
// probe arg is ordinary funpack evaluated against its carrying declaration's scope
// at debug time, so an ill-typed arg is a dev COMPILE error here, never a latent
// debugger crash at honor time (§28 §4 folds the body against the behavior's bound
// env). Two placements carry a value argument and are covered both ways: a
// behavior-prefix probe (@break/@log/@watch over the step's `self`/params) and a
// @watch on a `data` field (over `self` bound to the carrying data). A @trace
// carries no argument, so it never reaches the arg check. The negative fixtures
// pin that an out-of-scope name or a type-mismatched predicate rejects with
// expr_check's own precise verdict (Unresolved_Name / Type_Mismatch) — the named
// error the agent's write→check→fix loop reads — and the positive fixtures pin a
// well-typed arg passes clean. Self-contained sources per test, so no golden
// checkout gates the proofs.
package funpack

import "core:testing"

// typecheck_probe runs the single-module lex → parse → typecheck path over a
// source and returns the typecheck verdict, asserting parse succeeds — these
// fixtures probe check_probe_args, never the parser (a probe's PLACEMENT and
// argument SHAPE are the parser's/gate's concern, already covered there). It
// mirrors typecheck_migrate's helper exactly.
typecheck_probe :: proc(t: ^testing.T, source: string) -> Type_Error {
	ast, parse_err := stage_parse(stage_lex(source))
	testing.expect_value(t, parse_err, Parse_Error.None)
	if parse_err != .None {
		return .None
	}
	_, err := stage_typecheck(ast)
	return err
}

// PROBE_UNIT_HEADER seeds a minimal Vec2-carrying thing and its imports — the
// behavior-probe fixtures attach probes to a `step(self: Ball)` over it, so the
// probe scope is the step's `self: Ball` (its reads, spec §06 §3).
PROBE_UNIT_HEADER :: "import engine.math.{Fixed, Vec2}\n" +
	"thing Ball { pos: Vec2, vel: Vec2 }\n"

@(test)
test_probe_behavior_watch_self_field_typechecks :: proc(t: ^testing.T) {
	// AC (behavior-prefix probe, positive): a @watch(self.pos) prefixing a
	// behavior types clean — `self` binds to the step's `self: Ball` (the
	// behavior's read), so `self.pos` resolves to the thing's Vec2 field exactly
	// as the step body would resolve it.
	err := typecheck_probe(t,
		PROBE_UNIT_HEADER +
		"@watch(self.pos)\n" +
		"behavior watched on Ball {\n" +
		"  fn step(self: Ball) -> Ball { return self }\n" +
		"}\n")
	testing.expect_value(t, err, Type_Error.None)
}

@(test)
test_probe_behavior_break_predicate_typechecks :: proc(t: ^testing.T) {
	// AC (behavior-prefix @break, positive): a @break(self.pos.x > 70.0)
	// predicate types clean — `self.pos.x` is Fixed and `> 70.0` (Fixed) lands a
	// Bool, the ordinary predicate the runtime folds. The arg need not BE a Bool
	// for the typing pass (the runtime's as_bool tolerates a non-bool fold), so
	// this check is that the predicate GROUNDS in the scope, the same contract a
	// @log/@watch value gets.
	err := typecheck_probe(t,
		PROBE_UNIT_HEADER +
		"@break(self.pos.x > 70.0)\n" +
		"behavior breaker on Ball {\n" +
		"  fn step(self: Ball) -> Ball { return self }\n" +
		"}\n")
	testing.expect_value(t, err, Type_Error.None)
}

@(test)
test_probe_behavior_watch_out_of_scope_name_rejected :: proc(t: ^testing.T) {
	// AC (behavior-prefix probe, negative — the task's headline case): a
	// @watch(self.missing) over a field the step's `self: Ball` does not declare
	// is a typecheck error, NOT a green dev-build that crashes the debugger at
	// honor time. `self` resolves to Ball, but Ball has no `missing` field, so the
	// member read is the precise Type_Mismatch verdict — the named error the
	// agent's fix loop reads, surfaced as Typecheck_Failed by the pipeline.
	err := typecheck_probe(t,
		PROBE_UNIT_HEADER +
		"@watch(self.missing)\n" +
		"behavior watched on Ball {\n" +
		"  fn step(self: Ball) -> Ball { return self }\n" +
		"}\n")
	testing.expect_value(t, err, Type_Error.Type_Mismatch)
}

@(test)
test_probe_behavior_log_unresolved_name_rejected :: proc(t: ^testing.T) {
	// AC (behavior-prefix probe, negative — a free name with no binding): a
	// @log(ghost) over a name in NO partition of the step scope (no param, no
	// let, no declaration, no import) is Unresolved_Name — the precise verdict a
	// bare unbound name gets anywhere, proving the probe arg resolves names
	// exactly as a body expression does rather than silently passing.
	err := typecheck_probe(t,
		PROBE_UNIT_HEADER +
		"@log(ghost)\n" +
		"behavior logger on Ball {\n" +
		"  fn step(self: Ball) -> Ball { return self }\n" +
		"}\n")
	testing.expect_value(t, err, Type_Error.Unresolved_Name)
}

@(test)
test_probe_data_field_watch_self_field_typechecks :: proc(t: ^testing.T) {
	// AC (field @watch, positive): a @watch(self.bias) on a `data` field types
	// clean — `self` binds to the carrying `data` value (Board), so `self.bias`
	// reads Board's own `bias` field, the §28 §4 runtime contract's bound-env
	// reach in the type domain. This is the spelling every committed field-@watch
	// fixture uses, so the field-probe scope blesses exactly what the runtime can
	// fold.
	err := typecheck_probe(t,
		"data Board {\n" +
		"  @watch(self.bias)\n" +
		"  bias: Fixed\n" +
		"}\n")
	testing.expect_value(t, err, Type_Error.None)
}

@(test)
test_probe_data_field_watch_unknown_field_rejected :: proc(t: ^testing.T) {
	// AC (field @watch, negative — sibling field misnamed): a @watch(self.drift)
	// on a `data` whose only field is `bias` is a typecheck error — `self` binds
	// to Board but Board has no `drift` field, so the member read is the precise
	// Type_Mismatch. A field @watch is no more exempt from typing than a behavior
	// probe.
	err := typecheck_probe(t,
		"data Board {\n" +
		"  @watch(self.drift)\n" +
		"  bias: Fixed\n" +
		"}\n")
	testing.expect_value(t, err, Type_Error.Type_Mismatch)
}

@(test)
test_probe_data_field_watch_bare_name_rejected :: proc(t: ^testing.T) {
	// AC (field @watch, negative — the bare-field spelling): a @watch(bias) (a
	// BARE field name, no `self.`) is Unresolved_Name — the field-probe scope
	// binds `self`, not bare sibling fields, because the §28 §4 runtime folds the
	// body against a `self`-bound env where a bare field name never resolves.
	// Typing rejects the bare spelling here so the typecheck gate blesses ONLY the
	// form the runtime can honor — the fail-closed reading w.r.t. a honor-time
	// crash.
	err := typecheck_probe(t,
		"data Board {\n" +
		"  @watch(bias)\n" +
		"  bias: Fixed\n" +
		"}\n")
	testing.expect_value(t, err, Type_Error.Unresolved_Name)
}

@(test)
test_probe_trace_no_argument_typechecks :: proc(t: ^testing.T) {
	// AC (@trace, no argument): a @trace prefixing a behavior carries no value
	// argument (Debug_Probe.arg is nil), so the arg check has nothing to type and
	// passes clean — "check consistently" means the argument-less probe rides the
	// same walk with nothing to verify, never a special-cased skip that could mask
	// a future argument-bearing form.
	err := typecheck_probe(t,
		PROBE_UNIT_HEADER +
		"@trace\n" +
		"behavior traced on Ball {\n" +
		"  fn step(self: Ball) -> Ball { return self }\n" +
		"}\n")
	testing.expect_value(t, err, Type_Error.None)
}
