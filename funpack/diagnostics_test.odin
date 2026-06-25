// The fix-criteria diagnostic tests: render_diagnostic is a PURE function of
// (Diagnostic, source) (diagnostics.odin), so these pin its rendered bytes
// exactly — the rustc/gofmt block an agent's write→check→fix loop reads. Three
// renderer shapes (header-only, with-caret, with-declaration) plus one
// end-to-end per verb (test/check/build) asserting the new line shape over the
// live broken-source fixtures, so the CLI's rendered body is proven against the
// real pipeline, not a hand-built Diagnostic alone.
package funpack

import "core:fmt"
import "core:log"
import "core:os"
import "core:strings"
import "core:testing"

// test_render_diagnostic_header_only pins the no-position form: a line == 0
// Diagnostic (a declaration-anchored offender whose decl line was not captured)
// renders the one-line header with no excerpt and no `:0:0:` position noise.
@(test)
test_render_diagnostic_header_only :: proc(t: ^testing.T) {
	d := Diagnostic {
		stage   = .Gate,
		rule    = "Duplicate_Declaration",
		path    = "src/pong.fun",
		message = "two declarations normalize to the same body",
	}
	got := render_diagnostic(d, "", context.temp_allocator)
	testing.expect_value(t, got, "src/pong.fun: Duplicate_Declaration: two declarations normalize to the same body")
}

// test_render_diagnostic_with_caret pins the full rustc/gofmt block: a known
// line+col renders the header, the gutter-numbered excerpt line, and the caret
// line with `^` under the offending column. The gutter width tracks the line
// number's decimal width so both `|` rules align.
@(test)
test_render_diagnostic_with_caret :: proc(t: ^testing.T) {
	source := "fn bindings() -> Bindings {\n  return 5\n}\n"
	d := Diagnostic {
		stage   = .Typecheck,
		rule    = "Type_Mismatch",
		path    = "src/pong.fun",
		line    = 2,
		col     = 10,
		message = "the two sides here have different types",
	}
	got := render_diagnostic(d, source, context.temp_allocator)
	want := "src/pong.fun:2:10: Type_Mismatch: the two sides here have different types\n  2 |   return 5\n    |          ^"
	testing.expect_value(t, got, want)
}

// test_render_diagnostic_with_declaration pins the declaration-in-header form: a
// set `declaration` rides the header in parens (`<rule> (<declaration>):`), and
// a col == 0 line+declaration renders the excerpt with NO caret line (the
// declaration-anchored gate offender — the whole declaration overshot, no
// column).
@(test)
test_render_diagnostic_with_declaration :: proc(t: ^testing.T) {
	source := "fn big_fn() -> Int {\n  return 0\n}\n"
	d := Diagnostic {
		stage       = .Gate,
		rule        = "Fn_Size_Exceeded",
		path        = "src/pong.fun",
		line        = 1,
		declaration = "big_fn",
		message     = "this declaration's body holds more than the statement ceiling",
	}
	got := render_diagnostic(d, source, context.temp_allocator)
	want := "src/pong.fun:1: Fn_Size_Exceeded (big_fn): this declaration's body holds more than the statement ceiling\n  1 | fn big_fn() -> Int {"
	testing.expect_value(t, got, want)
}

// test_render_diagnostic_out_of_range_line is the fail-open coordinate: a line
// past the source (a stale span) renders the header and the gutter with an empty
// excerpt, never a crash — the renderer fails open on a bad coordinate.
@(test)
test_render_diagnostic_out_of_range_line :: proc(t: ^testing.T) {
	d := Diagnostic {
		stage   = .Parse,
		rule    = "Unexpected_Token",
		path    = "src/pong.fun",
		line    = 99,
		col     = 1,
		message = "unexpected token here",
	}
	got := render_diagnostic(d, "fn a() {}\n", context.temp_allocator)
	want := "src/pong.fun:99:1: Unexpected_Token: unexpected token here\n  99 | \n     | ^"
	testing.expect_value(t, got, want)
}

// test_type_diagnostic_maps_arm pins the typecheck mapping proc: a Type_Mismatch
// arm maps to its own name as `rule`, the threaded span/declaration, and the
// fix-criteria sentence — the single source of truth for the human wording.
@(test)
test_type_diagnostic_maps_arm :: proc(t: ^testing.T) {
	d := type_diagnostic(.Type_Mismatch, 7, 3, "step")
	testing.expect_value(t, d.stage, Diag_Stage.Typecheck)
	testing.expect_value(t, d.rule, "Type_Mismatch")
	testing.expect_value(t, d.line, 7)
	testing.expect_value(t, d.col, 3)
	testing.expect_value(t, d.declaration, "step")
	testing.expect(t, d.message != "")
}

// test_gate_diagnostic_maps_arm pins the gate mapping proc: a Cyclomatic_Exceeded
// arm names itself, anchors at the declaration line (col 0), and carries the
// ceiling in its sentence — declaration-anchored, no expression column.
@(test)
test_gate_diagnostic_maps_arm :: proc(t: ^testing.T) {
	d := gate_diagnostic(.Cyclomatic_Exceeded, 4, "tangled")
	testing.expect_value(t, d.stage, Diag_Stage.Gate)
	testing.expect_value(t, d.rule, "Cyclomatic_Exceeded")
	testing.expect_value(t, d.line, 4)
	testing.expect_value(t, d.col, 0)
	testing.expect_value(t, d.declaration, "tangled")
	testing.expect(t, strings.contains(d.message, "10")) // MAX_CYCLOMATIC in the sentence
}

// ── end-to-end CLI rendering (live broken-source fixtures) ──────────────────

// test_check_compile_error_renders_diagnostic asserts the check verb renders the
// inner fix-criteria block, not the bare `Compile_Failed`: stage_build over the
// broken pong tree (a parse-floor source) carries a Compile_Failed verdict whose
// inner Diagnostic has the Parse rule and the source path, and the CLI re-reads
// that source to render the located header. The exit tier (2) is unchanged — the
// machine contract holds.
@(test)
test_check_compile_error_renders_diagnostic :: proc(t: ^testing.T) {
	root, ok := write_broken_pong_tree(t)
	if !ok {
		return
	}
	defer remove_scratch_tree(root)

	_, verdict := stage_build(root, .Dev, context.temp_allocator)
	testing.expect_value(t, verdict.err, Build_Error.Compile_Failed)
	// The inner diagnostic is the Parse-stage rejection of the broken source,
	// with a non-empty rule (so the CLI renders it, not the bare arm) and the
	// failing module's source path.
	testing.expect_value(t, verdict.diagnostic.stage, Diag_Stage.Parse)
	testing.expect(t, verdict.diagnostic.rule != "")
	testing.expect(t, strings.has_suffix(verdict.diagnostic.path, "pong.fun"))
	// The rendered block leads with the path and names the rule — the fix-criteria
	// header an agent reads, never a bare `Compile_Failed`.
	source := ""
	if bytes, read_err := os.read_entire_file_from_path(verdict.diagnostic.path, context.temp_allocator); read_err == nil {
		source = string(bytes)
	}
	rendered := render_diagnostic(verdict.diagnostic, source, context.temp_allocator)
	testing.expect(t, strings.contains(rendered, verdict.diagnostic.rule))
	testing.expect(t, strings.contains(rendered, "pong.fun"))
	testing.expect(t, rendered != "Compile_Failed")
	log.infof("check diagnostic: the broken tree renders `%s`", rendered)
}

// test_test_verb_type_mismatch_renders_diagnostic drives the test verb's path
// over a hand-shaped tree whose source TYPECHECKS-fails (a return value of the
// wrong type), so run_project_pipeline surfaces a Typecheck-stage Diagnostic with
// an expression-precise span. It asserts the rendered block names Type_Mismatch,
// anchors at the offending expression's line, and carries the source excerpt —
// the expression-precise diagnostic the operator chose.
@(test)
test_test_verb_type_mismatch_renders_diagnostic :: proc(t: ^testing.T) {
	// A fn whose declared `-> Int` return is given a String — a Type_Mismatch on
	// the return expression. The body is otherwise minimal so the only fault is
	// the mismatch.
	source := "@doc(\"x\")\n\nfn wrong() -> Int {\n  return \"nope\"\n}\n"
	tokens := stage_lex(source)
	ast, parse_verdict := stage_parse_located(tokens)
	testing.expect_value(t, parse_verdict.err, Parse_Error.None)
	if parse_verdict.err != .None {
		return
	}
	_, verdict := stage_typecheck_located(ast, Module_Index{})
	testing.expect_value(t, verdict.err, Type_Error.Type_Mismatch)
	// The offending expression is the return value on line 4 — the string literal.
	testing.expect_value(t, verdict.line, 4)
	testing.expect_value(t, verdict.declaration, "wrong")
	d := type_diagnostic(verdict.err, verdict.line, verdict.col, verdict.declaration)
	d.path = "src/wrong.fun"
	rendered := render_diagnostic(d, source, context.temp_allocator)
	testing.expect(t, strings.contains(rendered, "Type_Mismatch"))
	testing.expect(t, strings.contains(rendered, "wrong")) // the declaration name
	testing.expect(t, strings.contains(rendered, "return \"nope\"")) // the excerpt
	log.infof("test diagnostic: a return-type mismatch renders\n%s", rendered)
}

// ── per-stage rendered-diagnostic byte pins (one arm per stage) ──────────────
//
// These pin the FULL rendered fix-criteria block byte-for-byte for one
// representative arm of each of the five pipeline stages — Parse, Gate,
// Typecheck, Contract, Closure — straight through the pipeline driver
// (run_module_pipeline_diag), the same path the CLI renders. render_diagnostic
// is a pure function of (Diagnostic, source), and the diag's offender coordinates
// are a pure function of the source, so identical source ⇒ identical bytes every
// run. The driver leaves `path` "" (the CLI's fact), so each fixture stamps the
// same fixed path before rendering — the only non-source input. Each source is a
// small self-contained snippet (no golden checkout), and each trips exactly its
// stage's FIRST offender, so the pinned offender is deterministic. The fixtures
// stop the rendered diagnostic quality from silently regressing: a wording edit,
// a span-anchor shift, or a gutter/caret-shape change moves these bytes and fails.

// diag_render_through_pipeline runs one source through the stage pipeline,
// stamps the fixed fixture path onto the resulting Diagnostic, and renders it —
// the byte-exact harness the per-stage pins share. It asserts the expected
// Pipeline_Error class first, so a fixture that stops failing (or fails at the
// wrong stage) is a loud miss, not a silently-wrong golden.
diag_render_through_pipeline :: proc(
	t: ^testing.T,
	source: string,
	want_err: Pipeline_Error,
) -> string {
	_, err, diag := run_module_pipeline_diag(source, Module_Index{}, nil, "")
	testing.expect_value(t, err, want_err)
	diag.path = "src/x.fun"
	return render_diagnostic(diag, source, context.temp_allocator)
}

// test_diag_pin_parse_wrong_case pins the Parse stage's rendered block: a thing
// named in lowercase rejects with Wrong_Case, rendering the header + excerpt +
// caret. The caret lands at col 7 — under the offending `widget`, the mis-cased
// identifier — NOT at the `{`. This is the tightened anchor: reject stamps the
// offending token's span at the rejection site (where the token is in hand), so a
// post-`advance` casing reject anchors on the identifier even though p.pos has
// moved one token past it. (Before the reject-span discipline this pin LOCKED the
// col-14 `{` off-by-one; that gap is now closed — the caret sits on the offender.)
@(test)
test_diag_pin_parse_wrong_case :: proc(t: ^testing.T) {
	source := "thing widget { x: Int }\n"
	got := diag_render_through_pipeline(t, source, .Parse_Failed)
	want := "src/x.fun:1:7: Wrong_Case: this identifier's casing is wrong for its grammar position (spec §02 §1): snake_case for fn/field names, UpperCamel for types, UPPER_SNAKE for constants\n  1 | thing widget { x: Int }\n    |       ^"
	testing.expect_value(t, got, want)
}

// ── column-exact parse-arm caret pins (the reject-span discipline) ───────────
//
// These pin the EXACT caret column for several parse arms, proving reject anchors
// the diagnostic on the true offender — the mis-cased identifier, the unexpected
// token, the missing-arm site — not on wherever p.pos stopped. Each is a
// post-`advance` reject (p.pos has moved past the offender), the precise case the
// reject-span discipline closes; the pinned column is the first-offender's, so
// identical source ⇒ identical caret every run.

// test_diag_pin_parse_wrong_case_type_name pins the caret under a mis-cased TYPE
// name (the `data NAME` declared-type position, expect_type_name): `data
// lowercase` rejects with the caret at col 6 — under `lowercase`, NOT at the `{`
// the prior post-hoc anchor reported. This is the canonical type-name arm,
// distinct from the field/binding-name snake_case arms.
@(test)
test_diag_pin_parse_wrong_case_type_name :: proc(t: ^testing.T) {
	source := "data lowercase { x: Int }\n"
	got := diag_render_through_pipeline(t, source, .Parse_Failed)
	want := "src/x.fun:1:6: Wrong_Case: this identifier's casing is wrong for its grammar position (spec §02 §1): snake_case for fn/field names, UpperCamel for types, UPPER_SNAKE for constants\n  1 | data lowercase { x: Int }\n    |      ^"
	testing.expect_value(t, got, want)
}

// test_diag_pin_parse_unexpected_token pins the caret on the offending token of an
// Unexpected_Token post-advance reject: a behavior header whose `on` separator is
// replaced by another identifier (`behavior move at Paddle …`) rejects on the
// stray `at` — the reject stamps the consumed separator token, so the caret sits
// under it.
@(test)
test_diag_pin_parse_unexpected_token :: proc(t: ^testing.T) {
	source := "behavior move at Paddle {\n  fn step() -> Int { return 1 }\n}\n"
	got := diag_render_through_pipeline(t, source, .Parse_Failed)
	want := "src/x.fun:1:15: Unexpected_Token: unexpected token here — the grammar expects a different construct at this position\n  1 | behavior move at Paddle {\n    |               ^"
	testing.expect_value(t, got, want)
}

// test_diag_pin_parse_missing_else pins the caret at the missing-arm site of a
// Missing_Else peek-reject: an `if` expression with a then-branch but no `else`
// arm rejects at the token standing where `else` belongs — the reject stamps the
// peeked token (the line terminator after the then-branch `}`), the missing-arm
// site an agent inserts `else` at.
@(test)
test_diag_pin_parse_missing_else :: proc(t: ^testing.T) {
	source := "fn pick() -> Int {\n  return if true { 1 }\n}\n"
	got := diag_render_through_pipeline(t, source, .Parse_Failed)
	want := "src/x.fun:2:23: Missing_Else: an `if` used as a value expression needs both arms — add the `else { … }` arm so the expression has a type to unify (spec §02 §5)\n  2 |   return if true { 1 }\n    |                       ^"
	testing.expect_value(t, got, want)
}

// test_diag_pin_gate_arity pins the Gate stage's rendered block: a 6-param
// lambda in a fn body overshoots the §01 P5 arity ceiling, rejecting with
// Arity_Exceeded. Gate offenders are declaration-anchored — line set, col 0,
// the declaration in the header, the excerpt shown with NO caret (the whole
// declaration overshot, not a column). The ceiling (5) rides the sentence.
@(test)
test_diag_pin_gate_arity :: proc(t: ^testing.T) {
	source := "fn build() -> Int {\n  let f = fn(a, b, c, d, e, g) { return a }\n  return 1\n}\n"
	got := diag_render_through_pipeline(t, source, .Gate_Failed)
	want := "src/x.fun:1: Arity_Exceeded (build): a parameter list here is longer than the arity ceiling (5) — group related parameters into a record (spec §01 P5)\n  1 | fn build() -> Int {"
	testing.expect_value(t, got, want)
}

// test_diag_pin_gate_nesting_expression pins the Nesting_Exceeded block for
// EXPRESSION-driven depth — the friction-report junction (174cbae9). Four nested
// non-method calls in one `return` reach compositional depth 4 over the budget of
// 3 with NO block and NO branch, so the gate's Nesting_Cause is .Expression and
// the rendered remedy says "extract a named helper or bind an intermediate `let`",
// NOT "flatten with early returns" (which does not fit pure call nesting). The
// gate offender is declaration-anchored — line set, col 0, the declaration in the
// header, no caret. Pins the wording byte-for-byte so the call-nesting remedy can
// never silently regress to the block remedy.
@(test)
test_diag_pin_gate_nesting_expression :: proc(t: ^testing.T) {
	source := "fn np_deep(x: Int) -> Int { return id(id(id(id(x)))) }\n"
	got := diag_render_through_pipeline(t, source, .Gate_Failed)
	want := "src/x.fun:1: Nesting_Exceeded (np_deep): an expression here nests deeper than the nesting ceiling (3) — extract a named helper or bind an intermediate `let` so no single expression nests past the ceiling (spec §01 P5)\n  1 | fn np_deep(x: Int) -> Int { return id(id(id(id(x)))) }"
	testing.expect_value(t, got, want)
}

// test_diag_pin_gate_nesting_block pins the Nesting_Exceeded block for
// BLOCK-driven depth — the other side of the cause discriminator. Four nested
// `if` early-return guards put the innermost `return` at block depth 4 over the
// budget of 3 with no over-deep expression, so the gate's Nesting_Cause is .Block
// and the remedy KEEPS "flatten the structure with early returns" — which DOES fit
// a guard ladder. Together with the expression pin this proves the diagnostic
// prescribes the remedy that fits the depth source, byte-for-byte.
@(test)
test_diag_pin_gate_nesting_block :: proc(t: ^testing.T) {
	source := "fn deep() -> Int {\n  if true {\n    if true {\n      if true {\n        if true {\n          return 1\n        }\n      }\n    }\n  }\n  return 0\n}\n"
	got := diag_render_through_pipeline(t, source, .Gate_Failed)
	want := "src/x.fun:1: Nesting_Exceeded (deep): a block here nests deeper than the nesting ceiling (3) — flatten the structure with early returns (spec §01 P5)\n  1 | fn deep() -> Int {"
	testing.expect_value(t, got, want)
}

// test_diag_pin_typecheck_mismatch pins the Typecheck stage's rendered block: a
// fn declared `-> Int` returning a String rejects with Type_Mismatch, the
// expression-precise span anchoring at the offending return value's column (the
// operator's EXPRESSION-PRECISE choice) — header + excerpt + caret under col 10.
@(test)
test_diag_pin_typecheck_mismatch :: proc(t: ^testing.T) {
	source := "fn wrong() -> Int {\n  return \"nope\"\n}\n"
	got := diag_render_through_pipeline(t, source, .Typecheck_Failed)
	want := "src/x.fun:2:10: Type_Mismatch (wrong): the two sides here have different types — funpack has no implicit promotion, so make the types match (spec §02)\n  2 |   return \"nope\"\n    |          ^"
	testing.expect_value(t, got, want)
}

// test_diag_pin_typecheck_unknown_method pins the Unknown_Method caret on the
// MEMBER NAME, not the receiver-anchored construct span: a list
// receiver typed clean but `bogus` is no method of it nor a UFCS-reachable free fn,
// so the caret sits under `bogus` (col 17), the offending member — NOT under the
// `[` the receiver-anchored expr_span would give. The hint lists the list's
// call-site-inferred combinators (surface.odin path 4), so the fix-sentence carries the
// available-methods suffix — the hint-rendering mechanics are pinned in
// test_render_diagnostic_unknown_method_hint.
@(test)
test_diag_pin_typecheck_unknown_method :: proc(t: ^testing.T) {
	source := "fn f() -> Int {\n  return [1, 2].bogus(3)\n}\n"
	got := diag_render_through_pipeline(t, source, .Typecheck_Failed)
	want := "src/x.fun:2:17: Unknown_Method (f): no such method on this type — `recv.NAME(…)` names neither a method of the receiver's type nor a stdlib free fn reachable through it (spec §02 §4) — available methods: append, concat, contains, filter, find, first, fold, get, init, is_empty, last, len, map, reverse\n  2 |   return [1, 2].bogus(3)\n    |                 ^"
	testing.expect_value(t, got, want)
}

// test_diag_pin_typecheck_unknown_method_call_receiver pins the SAME Unknown_Method
// caret-on-member shape when the receiver is a CALL EXPRESSION, not a simple binding
// — the exact `Rng.seed(1).bogus_method(0, 9)` repro. The static
// constructor `Rng.seed(1)` (§26 §1.10) types to an Rng, so the chained
// `.bogus_method` resolves against a KNOWN type and the unknown member is
// Unknown_Method (caret under `bogus_method` at col 28, the §26 rand hint) — NOT the
// Unsupported_Expr at col 16 an untypeable receiver yields. Pins that the diagnostic
// reaches a typed
// call-expression receiver identically to a typed identifier receiver.
@(test)
test_diag_pin_typecheck_unknown_method_call_receiver :: proc(t: ^testing.T) {
	source := "import engine.rand.{Rng}\n" + "fn roll() -> Int {\n" + "  let rolled = Rng.seed(1).bogus_method(0, 9)\n" + "  return 0\n" + "}\n"
	got := diag_render_through_pipeline(t, source, .Typecheck_Failed)
	want := "src/x.fun:3:28: Unknown_Method (roll): no such method on this type — `recv.NAME(…)` names neither a method of the receiver's type nor a stdlib free fn reachable through it (spec §02 §4) — available methods: chance, next, pick, range, split\n  3 |   let rolled = Rng.seed(1).bogus_method(0, 9)\n    |                            ^"
	testing.expect_value(t, got, want)
}

// test_render_diagnostic_unknown_method_hint pins the hint suffix: an Unknown_Method
// with the receiver type's real methods threaded as `hint` renders the static
// fix-sentence then ` — <hint>` before the excerpt, so an agent sees the available
// methods inline. The hint rides OFF the machine-stable
// header triple (rule/declaration), so it never disturbs the parsed identity.
@(test)
test_render_diagnostic_unknown_method_hint :: proc(t: ^testing.T) {
	d := Diagnostic {
		stage       = .Typecheck,
		rule        = "Unknown_Method",
		line        = 6,
		col         = 20,
		declaration = "setup",
		message     = "no such method on this type — `recv.NAME(…)` names neither a method of the receiver's type nor a stdlib free fn reachable through it (spec §02 §4)",
		hint        = "available methods: chance, next, pick, range, split",
		path        = "src/x.fun",
	}
	source := "@gtag(\"startup\")\nfn setup(rng: Rng) -> Int {\n  return 0\n}\n\n  let rolled = rng.bogus_method(0, 9)\n"
	got := render_diagnostic(d, source, context.temp_allocator)
	want := "src/x.fun:6:20: Unknown_Method (setup): no such method on this type — `recv.NAME(…)` names neither a method of the receiver's type nor a stdlib free fn reachable through it (spec §02 §4) — available methods: chance, next, pick, range, split\n  6 |   let rolled = rng.bogus_method(0, 9)\n    |                    ^"
	testing.expect_value(t, got, want)
}

// CONTRACT_PIN_SOURCE is a full self-contained source whose render-slot behavior
// returns a [Goal] signal list — the first contract offender (Render is
// output-only, only [Draw] may leave it, §06 §6). bad_render is the only
// pipeline occupant, so it is unambiguously the first offender.
CONTRACT_PIN_SOURCE :: "import engine.math.{Fixed, Vec2}\n" +
	"import engine.world.{View, Spawn}\n" +
	"import engine.render.{Draw, Color}\n" +
	"thing Paddle { x: Fixed, y: Fixed }\n" +
	"signal Goal { side: Fixed }\n" +
	"behavior bad_render on Paddle {\n" +
	"  fn step(self: Paddle) -> [Goal] {\n" +
	"    return [Goal{side: self.x}]\n" +
	"  }\n" +
	"}\n" +
	"pipeline Game {\n" +
	"  render: [bad_render]\n" +
	"}\n"

// test_diag_pin_contract_render_emits pins the Contract stage's rendered block:
// the render-slot behavior is anchored on its declaration line (col 0), naming
// the behavior in the header with the excerpt and no caret — the §06 §6
// behavior-level shape (the whole signature, not a column, violated).
@(test)
test_diag_pin_contract_render_emits :: proc(t: ^testing.T) {
	got := diag_render_through_pipeline(t, CONTRACT_PIN_SOURCE, .Contract_Failed)
	want := "src/x.fun:6: Render_Emits (bad_render): this render behavior returns a signal/command list — a render behavior may return only a [Draw] list (spec §06 §6)\n  6 | behavior bad_render on Paddle {"
	testing.expect_value(t, got, want)
}

// CLOSURE_PIN_SOURCE is a full self-contained source whose scoring stage emits a
// Goal signal with no downstream consumer — the effect-closure offender (§07
// §2: every emitted signal needs a consumer). score occupies the stage alone, so
// the unclosed Goal is the deterministic first offender.
CLOSURE_PIN_SOURCE :: "import engine.math.{Fixed, Vec2}\n" +
	"import engine.world.{View, Spawn}\n" +
	"import engine.render.{Draw, Color}\n" +
	"thing Ball { x: Fixed, y: Fixed }\n" +
	"signal Goal { side: Fixed }\n" +
	"behavior score on Ball {\n" +
	"  fn step(self: Ball) -> [Goal] {\n" +
	"    return [Goal{side: self.x}]\n" +
	"  }\n" +
	"}\n" +
	"pipeline Game {\n" +
	"  scoring: [score]\n" +
	"}\n"

// test_diag_pin_closure_unclosed_signal pins the Closure stage's rendered block:
// the unclosed Goal signal is anchored on its `signal` declaration line (col 0),
// naming the signal in the header with the excerpt and no caret — the
// signal-level edge shape.
@(test)
test_diag_pin_closure_unclosed_signal :: proc(t: ^testing.T) {
	got := diag_render_through_pipeline(t, CLOSURE_PIN_SOURCE, .Closure_Failed)
	want := "src/x.fun:5: Unclosed_Signal (Goal): this signal is emitted but no downstream stage consumes it — every emitted signal needs a consumer (effect closure, spec §07 §2)\n  5 | signal Goal { side: Fixed }"
	testing.expect_value(t, got, want)
}

// test_diag_pin_membership_expose_closure_anchors_decl_line pins the membership
// decl-line anchoring (the diag-membership-decl-line fix): a §30 §6 expose-closure
// violation — an @expose'd `data Public` whose field references a non-@expose'd
// `Secret` — now anchors on the @expose'd declaration's line (col 0), naming it
// in the header with the excerpt, the SAME decl-line shape a gate offender
// carries. Before the fix these membership-class faults rendered header-only at
// line 0 (no excerpt). It drives stage_typecheck_located directly because the
// full pipeline front-runs the pre-typecheck gate; the located typecheck pass is
// the seam that threads the decl-line sink through the membership checks.
@(test)
test_diag_pin_membership_expose_closure_anchors_decl_line :: proc(t: ^testing.T) {
	source := "import engine.math.{Fixed}\n" +
		"data Secret { code: Fixed }\n" +
		"@expose\n" +
		"data Public { s: Secret }\n"
	ast, parse_verdict := stage_parse_located(stage_lex(source))
	testing.expect_value(t, parse_verdict.err, Parse_Error.None)
	if parse_verdict.err != .None {
		return
	}
	_, verdict := stage_typecheck_located(ast, Module_Index{})
	testing.expect_value(t, verdict.err, Type_Error.Expose_Closure_Violation)
	// The fix: the offender anchors at the @expose'd decl line (4), not line 0.
	testing.expect_value(t, verdict.line, 4)
	testing.expect_value(t, verdict.declaration, "Public")
	d := type_diagnostic(verdict.err, verdict.line, verdict.col, verdict.declaration)
	d.path = "src/x.fun"
	got := render_diagnostic(d, source, context.temp_allocator)
	want := "src/x.fun:4: Expose_Closure_Violation (Public): this @expose'd declaration's public signature references a non-@expose'd user type — expose that type too, or drop it from the signature (spec §30 §6)\n  4 | data Public { s: Secret }"
	testing.expect_value(t, got, want)
}

// ── arm-coverage table: EVERY stage arm anchors a located diagnostic ─────────
//
// This is the LOCATEDNESS PROOF: every reachable arm of all five stage error
// enums (Parse_Error, Gate_Error, Type_Error, Contract_Error, Flatten_Error)
// produces a Diagnostic with a NON-ZERO line, its own arm name as `rule`, and a
// non-empty fix-criteria message — never a header-only line-0 refusal. Each row
// drives the arm through its OWN located stage proc (the same proc the pipeline
// driver maps through, diagnostics.odin), bypassing the front-running an earlier
// stage's first-offender would impose, so each row trips PRECISELY its arm. The
// source per arm is a minimal self-contained snippet (no golden checkout), and
// the assertion (line >= 1 && rule == arm && message != "") is the regression
// floor: if any future change drops an arm back to header-only, its row fails.
//
// Provenance per arm class (where the non-zero line comes from):
//   - Parse: the offending token's span (parser_stop_span / reject-stamped).
//   - Gate: the offending declaration's line (col 0 — the whole decl overshot).
//   - Type (expression faults): the innermost offending expr span (expr_span).
//   - Type (membership/name/import faults): the offending declaration's decl
//     line, or the offending `import` keyword's line (no expression to anchor).
//   - Contract/Flatten: the offending behavior/signal/pipeline declaration line.
//
// COVERAGE NOTE — one arm is engine-unreachable from a parsed single-module
// source and is covered through a synthetic AST instead: Flatten_Error.
// Recursive_Pipeline. A pipeline-stage member is snake_case ONLY
// (parse_behavior_list), while a pipeline NAME is UpperCamel (parse_pipeline),
// so find_pipeline_decl can never resolve a stage member to a sub-pipeline from
// parsed source — a sub-pipeline cycle is reachable only by constructing the AST
// directly (the same path the flatten test exercises). Its row builds a cyclic
// Typed_Ast with a real root-pipeline line and asserts the same locatedness
// invariant. Every other arm is reachable from a single-module source.

// diag_arm_case is one coverage row: a minimal source and the arm it must trip.
// The probe procs below drive `source` through the stage that owns `arm` and
// assert the located invariant (line >= 1, rule == arm, message != "").
Diag_Arm_Case :: struct {
	source: string,
	arm:    string,
}

// expect_located_arm is the shared assertion every coverage row makes: the
// mapped Diagnostic anchors a real line, names its own arm, and carries a fix
// sentence. A miss names the arm so a regression points at the offending row.
expect_located_arm :: proc(t: ^testing.T, d: Diagnostic, arm: string) {
	testing.expectf(t, d.line >= 1, "%s: expected a located line >= 1, got %d", arm, d.line)
	testing.expect_value(t, d.rule, arm)
	testing.expectf(t, d.message != "", "%s: expected a non-empty fix-criteria message", arm)
}

// test_arm_coverage_parse drives every Parse_Error arm through stage_parse_located
// + parse_diagnostic and asserts each anchors a located diagnostic. The parser
// stamps the offending token's span (or the stop token), so every arm carries a
// non-zero line. Covers all 21 fault arms of Parse_Error (excluding .None).
@(test)
test_arm_coverage_parse :: proc(t: ^testing.T) {
	cases := []Diag_Arm_Case {
		{"fn a() -> Int { return @ }\n", "Unexpected_Token"},
		{"fn a() -> Int {\n", "Unexpected_End"},
		{"thing widget { x: Int }\n", "Wrong_Case"},
		{"fn pick() -> Int {\n  return if true { 1 }\n}\n", "Missing_Else"},
		{"data D {\n  @watch\n  x: Int\n}\n", "Probe_Missing_Arg"},
		{"@trace(x)\nfn a() -> Int { return 1 }\n", "Probe_Unexpected_Arg"},
		{"data D {\n  @break(x)\n  y: Int\n}\n", "Probe_Wrong_Target"},
		{"@todo(\"q\")\nfn a() -> Int { return 1 }\n", "Malformed_Todo_Window"},
		{"@migrate(bogus: x)\ndata D { x: Int }\n", "Malformed_Migrate"},
		{"thing T {\n  @migrate(from: old)\n  x: Int\n}\n", "Migrate_Wrong_Target"},
		{"@index(Thing)\nquery q() -> Int { return 1 }\n", "Malformed_Index_Path"},
		{"@index(Thing.field)\nfn a() -> Int { return 1 }\n", "Index_Wrong_Target"},
		{"@expose(x)\nfn a() -> Int { return 1 }\n", "Expose_Unexpected_Arg"},
		{"extern let x: Int\n", "Malformed_Extern"},
		{"data D[T U] { x: Int }\n", "Malformed_Type_Params"},
		{"fn a(f: fn[Int]) -> Int { return 1 }\n", "Malformed_Fn_Type"},
		{"fn a() -> String {\n  return \"bad \\q\"\n}\n", "Malformed_String_Escape"},
		{"enum E {\n  @gtag(x)\n  A,\n}\n", "Variant_Directive_Wrong_Target"},
		// F6: a bool literal in a match-arm pattern position. `true`/`false` lex as
		// snake_case Idents, so without the dedicated branch this would mis-trip
		// Wrong_Case; the dedicated arm steers the author to if/else.
		{"fn pick() -> Int {\n  return match hit {\n    true => 1\n    false => 0\n  }\n}\n", "Bool_Pattern_Unsupported"},
		// F5: a binary operator opening a fresh line — the §02 §1 newline already
		// ended `return a < b`, so the dangling `and` is the named verdict, not a
		// bare Unexpected_Token. Caught at the fn-body statement boundary.
		{"fn keep() -> Bool {\n  return a < b\n  and c < d\n}\n", "Newline_Before_Binary_Op"},
	}
	for c in cases {
		_, verdict := stage_parse_located(stage_lex(c.source))
		d := parse_diagnostic(verdict.err, verdict.line, verdict.col)
		expect_located_arm(t, d, c.arm)
	}
}

// test_arm_coverage_gate drives every Gate_Error arm through gate_verdict +
// gate_diagnostic. Gate offenders are declaration-anchored (line set, col 0), so
// each carries the offending declaration's line. Duplicate_Declaration — the arm
// this task newly anchored (it rendered header-only at line 0 before) — anchors
// on the SECOND-in-source duplicate's decl line. Covers all 9 fault arms.
@(test)
test_arm_coverage_gate :: proc(t: ^testing.T) {
	// Fn_Size_Exceeded needs > MAX_FN_STATEMENTS (40) statements — built so the
	// body length, not a hand-counted literal, carries the overshoot.
	fn_size := strings.builder_make(context.temp_allocator)
	strings.write_string(&fn_size, "fn big() -> Int {\n")
	for i in 0 ..< 41 {
		fmt.sbprintf(&fn_size, "  let v%d = %d\n", i, i)
	}
	strings.write_string(&fn_size, "  return 1\n}\n")

	cases := []Diag_Arm_Case {
		// Cyclomatic_Exceeded: 11 branch guards overshoot MAX_CYCLOMATIC (10).
		{"fn tangled(a: Int) -> Int {\n  if a == 1 { return 1 }\n  if a == 2 { return 2 }\n  if a == 3 { return 3 }\n  if a == 4 { return 4 }\n  if a == 5 { return 5 }\n  if a == 6 { return 6 }\n  if a == 7 { return 7 }\n  if a == 8 { return 8 }\n  if a == 9 { return 9 }\n  if a == 10 { return 10 }\n  if a == 11 { return 11 }\n  return 0\n}\n", "Cyclomatic_Exceeded"},
		{"fn deep() -> Int {\n  if true {\n    if true {\n      if true {\n        if true {\n          return 1\n        }\n      }\n    }\n  }\n  return 0\n}\n", "Nesting_Exceeded"},
		{strings.to_string(fn_size), "Fn_Size_Exceeded"},
		{"fn build() -> Int {\n  let f = fn(a, b, c, d, e, g) { return a }\n  return 1\n}\n", "Arity_Exceeded"},
		{"enum Side { Left, Right }\nfn pick(s: Side) -> Int {\n  return match s {\n    Side::Left => 1,\n  }\n}\n", "Non_Exhaustive_Match"},
		{"fn a() -> Int {\n  return 1\n}\nfn b() -> Int {\n  return 1\n}\n", "Duplicate_Declaration"},
		{"query enemies_near(origin: Vec2, r: Fixed) -> [Enemy] {\n  return within(all[Enemy], origin, r)\n}\n", "Query_Missing_Index"},
		{"@spatial(Enemy.cell)\nquery enemy_count() -> Int {\n  return fold(all[Enemy], 0, fn(acc, e) { return acc + 1 })\n}\n", "Query_Unused_Index"},
		{"@break(true)\ndata D { x: Int }\n", "Probe_Wrong_Placement"},
	}
	for c in cases {
		ast, parse_verdict := stage_parse_located(stage_lex(c.source))
		testing.expectf(t, parse_verdict.err == .None, "%s: source must parse, got %v", c.arm, parse_verdict.err)
		verdict := gate_verdict(ast)
		d := gate_diagnostic(verdict.err, verdict.line, verdict.declaration, verdict.nesting_cause)
		expect_located_arm(t, d, c.arm)
	}
}

// test_arm_coverage_typecheck_single drives every single-module-reachable
// Type_Error arm through stage_typecheck_located + type_diagnostic. The four
// import-resolution arms (Unknown_Module / Unknown_Member) and the two
// name-collection arms (Name_Collision / Reserved_Signal_Name) — all anchored by
// THIS task on the offending `import` keyword / declaration line — sit alongside
// the expression and membership arms, each carrying a non-zero line. The four
// Package_* arms need a project index and are covered separately
// (test_arm_coverage_typecheck_package). Driving the located typecheck DIRECTLY
// (not the full pipeline) bypasses the pre-typecheck gate so a membership-class
// fixture trips its own arm, the same seam the membership pin uses.
@(test)
test_arm_coverage_typecheck_single :: proc(t: ^testing.T) {
	cases := []Diag_Arm_Case {
		{"test \"x\" {\n  assert 5\n}\n", "Assert_Not_Bool"},
		{"fn wrong() -> Int {\n  return \"nope\"\n}\n", "Type_Mismatch"},
		{"data D { x: Int }\nfn f() -> Int {\n  return D\n}\n", "Unsupported_Expr"},
		{"import engine.nope.{X}\n", "Unknown_Module"},
		{"import engine.math.{NotAThing}\n", "Unknown_Member"},
		{"import engine.math.{Vec2}\ndata Vec2 { x: Fixed }\n", "Name_Collision"},
		{"signal Trigger { x: Fixed }\n", "Reserved_Signal_Name"},
		{"fn f() -> Int {\n  return undefined_thing\n}\n", "Unresolved_Name"},
		{"fn f(p: (Int, Int)) -> Int {\n  return match p {\n    (a, b, c) => a,\n  }\n}\n", "Tuple_Pattern_Arity"},
		{"import engine.math.{Fixed}\ndata Secret { code: Fixed }\n@expose\ndata Public { s: Secret }\n", "Expose_Closure_Violation"},
		{"import engine.math.{Fixed, Vec2}\nimport engine.physics.{Body, BodyKind, Shape2}\nenum Layer: CollisionLayer { Wall, Player }\nfn make() -> Body {\n  return Body{ kind: BodyKind::Static, shape: Shape2::Box{size: Vec2{x: 4.0, y: 4.0}}, layer: Layer::Ghost, mask: [Layer::Player] }\n}\n", "Unregistered_Layer"},
		{"data Player {\n  @migrate(from: \"hp\")\n  hp: Int\n}\n", "Migrate_From_Collision"},
		{"data Player {\n  @migrate(with: missing_lift)\n  hp: Int\n}\n", "Migrate_Convert_Unknown"},
		{"data Player {\n  @migrate(with: lift)\n  hp: Int\n}\nfn lift(old: Fixed, scale: Fixed) -> Int {\n  return 1\n}\n", "Migrate_Convert_Arity"},
		{"data Player {\n  @migrate(with: lift)\n  hp: Int\n}\nfn lift(old: Int) -> Fixed {\n  return 1.0\n}\n", "Migrate_Convert_Return"},
		{"@index(Ghost.cell)\nquery q(origin: Vec2) -> Vec2 {\n  return origin\n}\n", "Index_Unknown_Thing"},
		{"thing Enemy { cell: Vec2 }\n@index(Enemy.speed)\nquery q(origin: Vec2) -> Vec2 {\n  return origin\n}\n", "Index_Unknown_Field"},
		{"import engine.list.len\nthing Enemy { hp: Fixed }\nfn snoop() -> Int {\n  return len(all[Enemy])\n}\n", "All_Outside_Query"},
		{"import engine.list.len\nquery q() -> Int {\n  return len(all[Ghost])\n}\n", "All_Unknown_Thing"},
		{"import engine.world.{View}\nthing Mob { hp: Fixed }\nquery q(v: View[Mob]) -> Int {\n  return 1\n}\n", "Query_Param_Not_Value"},
	}
	for c in cases {
		ast, parse_verdict := stage_parse_located(stage_lex(c.source))
		testing.expectf(t, parse_verdict.err == .None, "%s: source must parse, got %v", c.arm, parse_verdict.err)
		_, verdict := stage_typecheck_located(ast, Module_Index{})
		d := type_diagnostic(verdict.err, verdict.line, verdict.col, verdict.declaration)
		expect_located_arm(t, d, c.arm)
	}
}

// test_arm_coverage_typecheck_package covers the two Type_Error arms reachable
// ONLY across a §30 package edge — Package_Private (a non-@expose'd member
// imported across the edge) and Package_Imports_Package (a package module
// reaching beyond engine + itself). Both fire inside resolve_imports_indexed
// before any body sweep, so THIS task anchors them on the offending `import`
// keyword's line/col (stamp_import). A package edge needs a Module_Index with a
// prefixed package entry, so each is driven through stage_typecheck_located over
// a hand-built two-module index (the smallest project fixture — build_module_index_from_asts,
// the unit-test seam), not a single-module source.
@(test)
test_arm_coverage_typecheck_package :: proc(t: ^testing.T) {
	// Package_Private: the consuming project ("" vantage) imports a member the
	// dependency package "hexgrid" exports but does NOT @expose — across the edge
	// an item is importable iff @expose'd (spec §30 §6).
	dep_ast, dep_pv := stage_parse_located(stage_lex("data Cell { x: Fixed }\n"))
	testing.expect_value(t, dep_pv.err, Parse_Error.None)
	private_index := build_module_index_from_asts({"hexgrid.layout"}, {dep_ast}, {"hexgrid"})
	cons_ast, cons_pv := stage_parse_located(stage_lex("import hexgrid.layout.{Cell}\n"))
	testing.expect_value(t, cons_pv.err, Parse_Error.None)
	_, private_verdict := stage_typecheck_located(cons_ast, private_index)
	private_diag := type_diagnostic(private_verdict.err, private_verdict.line, private_verdict.col, private_verdict.declaration)
	expect_located_arm(t, private_diag, "Package_Private")

	// Package_Imports_Package: a PACKAGE module (importer_root "hexgrid") imports
	// a module of a DIFFERENT package ("other") — the §30 §2 star-graph refusal
	// (a package depends only on engine and itself).
	other_ast, other_pv := stage_parse_located(stage_lex("data Far { x: Fixed }\n"))
	testing.expect_value(t, other_pv.err, Parse_Error.None)
	star_index := build_module_index_from_asts({"other.mod"}, {other_ast}, {"other"})
	pkg_ast, pkg_pv := stage_parse_located(stage_lex("import other.mod.{Far}\n"))
	testing.expect_value(t, pkg_pv.err, Parse_Error.None)
	_, star_verdict := stage_typecheck_located(pkg_ast, star_index, "hexgrid")
	star_diag := type_diagnostic(star_verdict.err, star_verdict.line, star_verdict.col, star_verdict.declaration)
	expect_located_arm(t, star_diag, "Package_Imports_Package")
}

// ARM_COVERAGE_CONTRACT_HEADER declares the §06 surface the contract-arm
// fixtures share — a Paddle thing the slot occupants write/read, a Goal signal a
// render emitter returns, the engine.render Draw/Color, engine.world Spawn, and
// engine.rand Rng. It is scoped to exactly the names the fixtures reference, so a
// missing golden checkout never silences the contract-arm proofs.
ARM_COVERAGE_CONTRACT_HEADER :: "import engine.math.{Fixed, Vec2}\n" +
	"import engine.world.{View, Spawn}\n" +
	"import engine.render.{Draw, Color}\n" +
	"import engine.rand.{Rng}\n" +
	"thing Paddle { x: Fixed, y: Fixed }\n" +
	"signal Goal { side: Fixed }\n"

// test_arm_coverage_contract drives every Contract_Error arm through
// stage_contracts and the pipeline driver's line resolution (behavior_decl_line,
// or the verdict's own line for Unknown_Battery — the arm THIS task newly
// anchored on the enclosing pipeline line, since a battery name is no
// declaration). Each behavior arm anchors on its behavior's decl line; the
// battery arm anchors on its `pipeline` keyword line. Covers all 8 fault arms.
@(test)
test_arm_coverage_contract :: proc(t: ^testing.T) {
	cases := []Diag_Arm_Case {
		{"behavior bad on Paddle {\n  fn step(self: Paddle) -> [Goal] {\n    return [Goal{side: self.x}]\n  }\n}\npipeline Game {\n  render: [bad]\n}\n", "Render_Emits"},
		{"behavior bad on Paddle {\n  fn step(self: Paddle, goals: [Goal]) -> [Draw] {\n    return [Draw::Rect{at: Vec2{x: self.x, y: self.y}, size: Vec2{x: 4.0, y: 16.0}, color: Color::White}]\n  }\n}\npipeline Game {\n  render: [bad]\n}\n", "Render_Takes_Signal"},
		{"behavior bad on Paddle {\n  fn step(self: Paddle, rng: Rng) -> [Draw] {\n    return [Draw::Rect{at: Vec2{x: 0.0, y: 0.0}, size: Vec2{x: 4.0, y: 4.0}, color: Color::White}]\n  }\n}\npipeline Game {\n  render: [bad]\n}\n", "Render_Takes_Rng"},
		{"behavior bad on Paddle {\n  fn step(self: Paddle) -> Int {\n    return 1\n  }\n}\npipeline Game {\n  render: [bad]\n}\n", "Render_No_Draw"},
		{"behavior bad on Paddle {\n  fn step(self: Paddle) -> [Spawn] {\n    return [Spawn(Paddle{x: 0.0, y: 0.0})]\n  }\n}\npipeline Game {\n  startup: [bad]\n}\n", "Startup_Reads_Thing"},
		{"behavior bad on Paddle {\n  fn step(rng: Rng) -> [Draw] {\n    return [Draw::Rect{at: Vec2{x: 0.0, y: 0.0}, size: Vec2{x: 1.0, y: 1.0}, color: Color::White}]\n  }\n}\npipeline Game {\n  startup: [bad]\n}\n", "Startup_No_Spawn"},
		{"behavior bad on Paddle {\n  fn step(self: Paddle, rng: Rng) -> (Rng, Int) {\n    return (rng, 0)\n  }\n}\npipeline Game {\n  eat: [bad]\n}\n", "Update_Dead"},
		{"pipeline Game {\n  step: notabattery\n}\n", "Unknown_Battery"},
	}
	for c in cases {
		source := strings.concatenate({ARM_COVERAGE_CONTRACT_HEADER, c.source}, context.temp_allocator)
		ast, parse_verdict := stage_parse_located(stage_lex(source))
		testing.expectf(t, parse_verdict.err == .None, "%s: source must parse, got %v", c.arm, parse_verdict.err)
		typed, type_verdict := stage_typecheck_located(ast, Module_Index{})
		testing.expectf(t, type_verdict.err == .None, "%s: source must typecheck, got %v", c.arm, type_verdict.err)
		verdict := stage_contracts(typed)
		// Mirror the pipeline driver: the battery arm carries its pipeline line
		// directly; a behavior arm resolves its line from the behavior name.
		line := verdict.line if verdict.line != 0 else behavior_decl_line(typed.ast, verdict.behavior)
		d := contract_diagnostic(verdict.err, line, verdict.behavior)
		expect_located_arm(t, d, c.arm)
	}
}

// test_arm_coverage_flatten covers every Flatten_Error arm. Unknown_Member (a
// stage naming no behavior/sub-pipeline) and Unclosed_Signal (an emitted signal
// with no consumer) are reachable from a single-module source; Unknown_Member —
// a structural fault carrying no offender name — is the arm THIS task newly
// anchored on the root pipeline's line (it rendered header-only at line 0
// before). Recursive_Pipeline is engine-unreachable from parsed source (a stage
// member is snake_case, a pipeline name UpperCamel, so a member never resolves to
// a sub-pipeline), so it is covered through a synthetic cyclic Typed_Ast with a
// real root-pipeline line — the same path the flatten test reaches it through.
@(test)
test_arm_coverage_flatten :: proc(t: ^testing.T) {
	cases := []Diag_Arm_Case {
		{"behavior score on Paddle {\n  fn step(self: Paddle) -> [Goal] {\n    return [Goal{side: self.x}]\n  }\n}\npipeline Game {\n  emit: [score, ghost]\n}\n", "Unknown_Member"},
		{"behavior score on Paddle {\n  fn step(self: Paddle) -> [Goal] {\n    return [Goal{side: self.x}]\n  }\n}\npipeline Game {\n  scoring: [score]\n}\n", "Unclosed_Signal"},
	}
	for c in cases {
		source := strings.concatenate({ARM_COVERAGE_CONTRACT_HEADER, c.source}, context.temp_allocator)
		ast, parse_verdict := stage_parse_located(stage_lex(source))
		testing.expectf(t, parse_verdict.err == .None, "%s: source must parse, got %v", c.arm, parse_verdict.err)
		typed, type_verdict := stage_typecheck_located(ast, Module_Index{})
		testing.expectf(t, type_verdict.err == .None, "%s: source must typecheck, got %v", c.arm, type_verdict.err)
		contract_verdict := stage_contracts(typed)
		testing.expectf(t, contract_verdict.err == .None, "%s: source must clear contracts, got %v", c.arm, contract_verdict.err)
		verdict := stage_flatten(typed)
		offender := flatten_offender_name(verdict)
		line := flatten_offender_line(typed.ast, verdict)
		d := flatten_diagnostic(verdict.err, line, offender)
		expect_located_arm(t, d, c.arm)
	}

	// Recursive_Pipeline (engine-unreachable from parsed source — see proc doc):
	// a Game→Loop→Game cycle built directly, the root pipeline carrying a real
	// source line so the structural-fault anchor (flatten_offender_line → root
	// pipeline line) lands non-zero.
	pipelines := make([]Pipeline_Node, 2, context.temp_allocator)
	pipelines[0] = Pipeline_Node {
		name   = "Game",
		line   = 7,
		stages = {Pipeline_Stage{name = "emit", behaviors = {"Loop"}}},
	}
	pipelines[1] = Pipeline_Node {
		name   = "Loop",
		line   = 10,
		stages = {Pipeline_Stage{name = "back", behaviors = {"Game"}}},
	}
	env: Type_Env
	env.records = make(map[string]Record_Schema, context.temp_allocator)
	env.enums = make(map[string]Enum_Schema, context.temp_allocator)
	env.terms = make(map[string]Term_Schema, context.temp_allocator)
	cyclic := Typed_Ast{ast = Ast{pipelines = pipelines}, env = env}
	rec_verdict := stage_flatten(cyclic)
	rec_line := flatten_offender_line(cyclic.ast, rec_verdict)
	rec_diag := flatten_diagnostic(rec_verdict.err, rec_line, flatten_offender_name(rec_verdict))
	expect_located_arm(t, rec_diag, "Recursive_Pipeline")
}

// ── assert-failure rendered byte pins ────────────────────────────────────────
//
// render_assert_failure is the EXIT-1 sibling of render_diagnostic: a PURE
// function of (Assert_Failure, source), so these pin its rendered bytes
// byte-for-byte. The machine contract (a failed assert is exit 1, never a
// compile error) is unchanged; the rendered block is the added human body the
// CLI prints beside the failed count. A wording/gutter/operand-shape change moves
// these bytes and fails — the regression floor for the test verb's localization.

// test_render_assert_failure_with_operands pins the full ==/!= block: the
// `<path>:<line>: assertion failed (<test>): <expr>` header, the gutter-numbered
// excerpt, and the left/right operand lines aligned under the excerpt gutter.
@(test)
test_render_assert_failure_with_operands :: proc(t: ^testing.T) {
	source := "test \"len fails correctly\" {\n  assert len([1, 2]) == 3\n}\n"
	f := Assert_Failure {
		test_name    = "len fails correctly",
		line         = 2,
		expr_text    = "len([1, 2]) == 3",
		op           = "==",
		lhs_display  = "2",
		rhs_display  = "3",
		has_operands = true,
		path         = "src/main.fun",
	}
	got := render_assert_failure(f, source, context.temp_allocator)
	want := "src/main.fun:2: assertion failed (len fails correctly): len([1, 2]) == 3\n  2 |   assert len([1, 2]) == 3\n    | left:  2\n    | right: 3"
	testing.expect_value(t, got, want)
}

// test_render_assert_failure_bare_predicate pins the no-operand form: a
// bare-Bool assert (or one whose operands did not both evaluate) renders the
// header and excerpt alone, no left/right lines.
@(test)
test_render_assert_failure_bare_predicate :: proc(t: ^testing.T) {
	source := "test \"flag is set\" {\n  assert active\n}\n"
	f := Assert_Failure {
		test_name = "flag is set",
		line      = 2,
		expr_text = "active",
		path      = "src/main.fun",
	}
	got := render_assert_failure(f, source, context.temp_allocator)
	want := "src/main.fun:2: assertion failed (flag is set): active\n  2 |   assert active"
	testing.expect_value(t, got, want)
}

// test_render_assert_failure_list_operands pins the composite-operand form: a
// list ==/!= renders each side's full element display, so the agent sees which
// element diverged.
@(test)
test_render_assert_failure_list_operands :: proc(t: ^testing.T) {
	source := "test \"lists differ\" {\n  assert [1, 2, 3] == [1, 2, 4]\n}\n"
	f := Assert_Failure {
		test_name    = "lists differ",
		line         = 2,
		expr_text    = "[1, 2, 3] == [1, 2, 4]",
		op           = "==",
		lhs_display  = "[1, 2, 3]",
		rhs_display  = "[1, 2, 4]",
		has_operands = true,
		path         = "src/main.fun",
	}
	got := render_assert_failure(f, source, context.temp_allocator)
	want := "src/main.fun:2: assertion failed (lists differ): [1, 2, 3] == [1, 2, 4]\n  2 |   assert [1, 2, 3] == [1, 2, 4]\n    | left:  [1, 2, 3]\n    | right: [1, 2, 4]"
	testing.expect_value(t, got, want)
}

// test_render_assert_failure_header_only is the fail-open coordinate: a line == 0
// (a synthetic assert span) collapses to the one-line header, no excerpt and no
// `:0:` position noise — the render_diagnostic header-only discipline.
@(test)
test_render_assert_failure_header_only :: proc(t: ^testing.T) {
	f := Assert_Failure {
		test_name = "synthetic",
		expr_text = "x == y",
		path      = "src/main.fun",
	}
	got := render_assert_failure(f, "", context.temp_allocator)
	testing.expect_value(t, got, "src/main.fun: assertion failed (synthetic): x == y")
}
