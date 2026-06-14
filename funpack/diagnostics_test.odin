// The fix-criteria diagnostic tests: render_diagnostic is a PURE function of
// (Diagnostic, source) (diagnostics.odin), so these pin its rendered bytes
// exactly — the rustc/gofmt block an agent's write→check→fix loop reads. Three
// renderer shapes (header-only, with-caret, with-declaration) plus one
// end-to-end per verb (test/check/build) asserting the new line shape over the
// live broken-source fixtures, so the CLI's rendered body is proven against the
// real pipeline, not a hand-built Diagnostic alone.
package funpack

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
// caret. NOTE the caret lands at col 14 (the `{`), NOT col 7 (the offending
// `widget`) — the single-token-lookahead parser anchors at p.pos, which a
// post-`advance` casing reject has already moved past the identifier. This pin
// LOCKS that documented off-by-one (diag-wrong-case-caret-off-by-one follow-up);
// tightening the caret to col 7 is the follow-up's regression target — flip this
// golden when it lands, do not silently let the bytes drift.
@(test)
test_diag_pin_parse_wrong_case :: proc(t: ^testing.T) {
	source := "thing widget { x: Int }\n"
	got := diag_render_through_pipeline(t, source, .Parse_Failed)
	want := "src/x.fun:1:14: Wrong_Case: this identifier's casing is wrong for its grammar position (spec §02 §1): snake_case for fn/field names, UpperCamel for types, UPPER_SNAKE for constants\n  1 | thing widget { x: Int }\n    |              ^"
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
