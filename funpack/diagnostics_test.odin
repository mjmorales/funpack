package funpack

import "core:fmt"
import "core:log"
import "core:os"
import "core:strings"
import "core:testing"

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

@(test)
test_gate_diagnostic_maps_arm :: proc(t: ^testing.T) {
	d := gate_diagnostic(.Cyclomatic_Exceeded, 4, "tangled")
	testing.expect_value(t, d.stage, Diag_Stage.Gate)
	testing.expect_value(t, d.rule, "Cyclomatic_Exceeded")
	testing.expect_value(t, d.line, 4)
	testing.expect_value(t, d.col, 0)
	testing.expect_value(t, d.declaration, "tangled")
	testing.expect(t, strings.contains(d.message, "10"))
}

@(test)
test_check_compile_error_renders_diagnostic :: proc(t: ^testing.T) {
	root, ok := write_broken_pong_tree(t)
	if !ok {
		return
	}
	defer remove_scratch_tree(root)

	_, verdict := stage_build(root, .Dev, context.temp_allocator)
	testing.expect_value(t, verdict.err, Build_Error.Compile_Failed)
	testing.expect_value(t, verdict.diagnostic.stage, Diag_Stage.Parse)
	testing.expect(t, verdict.diagnostic.rule != "")
	testing.expect(t, strings.has_suffix(verdict.diagnostic.path, "pong.fun"))
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

@(test)
test_test_verb_type_mismatch_renders_diagnostic :: proc(t: ^testing.T) {
	source := "@doc(\"x\")\n\nfn wrong() -> Int {\n  return \"nope\"\n}\n"
	tokens := stage_lex(source)
	ast, parse_verdict := stage_parse_located(tokens)
	testing.expect_value(t, parse_verdict.err, Parse_Error.None)
	if parse_verdict.err != .None {
		return
	}
	_, verdict := stage_typecheck_located(ast, Module_Index{})
	testing.expect_value(t, verdict.err, Type_Error.Type_Mismatch)
	testing.expect_value(t, verdict.line, 4)
	testing.expect_value(t, verdict.declaration, "wrong")
	d := type_diagnostic(verdict.err, verdict.line, verdict.col, verdict.declaration)
	d.path = "src/wrong.fun"
	rendered := render_diagnostic(d, source, context.temp_allocator)
	testing.expect(t, strings.contains(rendered, "Type_Mismatch"))
	testing.expect(t, strings.contains(rendered, "wrong"))
	testing.expect(t, strings.contains(rendered, "return \"nope\""))
	log.infof("test diagnostic: a return-type mismatch renders\n%s", rendered)
}

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

@(test)
test_diag_pin_parse_wrong_case :: proc(t: ^testing.T) {
	source := "thing widget { x: Int }\n"
	got := diag_render_through_pipeline(t, source, .Parse_Failed)
	want := "src/x.fun:1:7: Wrong_Case: this identifier's casing is wrong for its grammar position (spec §02 §1): snake_case for fn/field names, UpperCamel for types, UPPER_SNAKE for constants\n  1 | thing widget { x: Int }\n    |       ^"
	testing.expect_value(t, got, want)
}

@(test)
test_diag_pin_parse_wrong_case_type_name :: proc(t: ^testing.T) {
	source := "data lowercase { x: Int }\n"
	got := diag_render_through_pipeline(t, source, .Parse_Failed)
	want := "src/x.fun:1:6: Wrong_Case: this identifier's casing is wrong for its grammar position (spec §02 §1): snake_case for fn/field names, UpperCamel for types, UPPER_SNAKE for constants\n  1 | data lowercase { x: Int }\n    |      ^"
	testing.expect_value(t, got, want)
}

@(test)
test_diag_pin_parse_unexpected_token :: proc(t: ^testing.T) {
	source := "behavior move at Paddle {\n  fn step() -> Int { return 1 }\n}\n"
	got := diag_render_through_pipeline(t, source, .Parse_Failed)
	want := "src/x.fun:1:15: Unexpected_Token: unexpected token here — the grammar expects a different construct at this position\n  1 | behavior move at Paddle {\n    |               ^"
	testing.expect_value(t, got, want)
}

@(test)
test_diag_pin_parse_missing_else :: proc(t: ^testing.T) {
	source := "fn pick() -> Int {\n  return if true { 1 }\n}\n"
	got := diag_render_through_pipeline(t, source, .Parse_Failed)
	want := "src/x.fun:2:23: Missing_Else: an `if` used as a value expression needs both arms — add the `else { … }` arm so the expression has a type to unify (spec §02 §5)\n  2 |   return if true { 1 }\n    |                       ^"
	testing.expect_value(t, got, want)
}

@(test)
test_diag_pin_gate_arity :: proc(t: ^testing.T) {
	source := "fn build() -> Int {\n  let f = fn(a, b, c, d, e, g) { return a }\n  return 1\n}\n"
	got := diag_render_through_pipeline(t, source, .Gate_Failed)
	want := "src/x.fun:1: Arity_Exceeded (build): a parameter list here is longer than the arity ceiling (5) — group related parameters into a record (spec §01 P5)\n  1 | fn build() -> Int {"
	testing.expect_value(t, got, want)
}

@(test)
test_diag_pin_gate_nesting_expression :: proc(t: ^testing.T) {
	source := "fn np_deep(x: Int) -> Int { return id(id(id(id(x)))) }\n"
	got := diag_render_through_pipeline(t, source, .Gate_Failed)
	want := "src/x.fun:1: Nesting_Exceeded (np_deep): an expression here nests deeper than the nesting ceiling (3) — extract a named helper or bind an intermediate `let` so no single expression nests past the ceiling (spec §01 P5)\n  1 | fn np_deep(x: Int) -> Int { return id(id(id(id(x)))) }"
	testing.expect_value(t, got, want)
}

@(test)
test_diag_pin_gate_nesting_block :: proc(t: ^testing.T) {
	source := "fn deep() -> Int {\n  if true {\n    if true {\n      if true {\n        if true {\n          return 1\n        }\n      }\n    }\n  }\n  return 0\n}\n"
	got := diag_render_through_pipeline(t, source, .Gate_Failed)
	want := "src/x.fun:1: Nesting_Exceeded (deep): a block here nests deeper than the nesting ceiling (3) — flatten the structure with early returns (spec §01 P5)\n  1 | fn deep() -> Int {"
	testing.expect_value(t, got, want)
}

@(test)
test_diag_pin_typecheck_mismatch :: proc(t: ^testing.T) {
	source := "fn wrong() -> Int {\n  return \"nope\"\n}\n"
	got := diag_render_through_pipeline(t, source, .Typecheck_Failed)
	want := "src/x.fun:2:10: Type_Mismatch (wrong): the two sides here have different types — funpack has no implicit promotion, so make the types match (spec §02)\n  2 |   return \"nope\"\n    |          ^"
	testing.expect_value(t, got, want)
}

@(test)
test_diag_pin_typecheck_unknown_method :: proc(t: ^testing.T) {
	source := "fn f() -> Int {\n  return [1, 2].bogus(3)\n}\n"
	got := diag_render_through_pipeline(t, source, .Typecheck_Failed)
	want := "src/x.fun:2:17: Unknown_Method (f): no such method on this type — `recv.NAME(…)` names neither a method of the receiver's type nor a stdlib free fn reachable through it (spec §02 §4) — available methods: append, concat, contains, filter, find, first, fold, get, init, is_empty, last, len, map, reverse\n  2 |   return [1, 2].bogus(3)\n    |                 ^"
	testing.expect_value(t, got, want)
}

@(test)
test_diag_pin_typecheck_unknown_method_call_receiver :: proc(t: ^testing.T) {
	source := "import engine.rand.{Rng}\n" + "fn roll() -> Int {\n" + "  let rolled = Rng.seed(1).bogus_method(0, 9)\n" + "  return 0\n" + "}\n"
	got := diag_render_through_pipeline(t, source, .Typecheck_Failed)
	want := "src/x.fun:3:28: Unknown_Method (roll): no such method on this type — `recv.NAME(…)` names neither a method of the receiver's type nor a stdlib free fn reachable through it (spec §02 §4) — available methods: chance, next, pick, range, split\n  3 |   let rolled = Rng.seed(1).bogus_method(0, 9)\n    |                            ^"
	testing.expect_value(t, got, want)
}

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

@(test)
test_diag_pin_contract_render_emits :: proc(t: ^testing.T) {
	got := diag_render_through_pipeline(t, CONTRACT_PIN_SOURCE, .Contract_Failed)
	want := "src/x.fun:6: Render_Emits (bad_render): this render behavior returns a signal/command list — a render behavior may return only a [Draw] list (spec §06 §6)\n  6 | behavior bad_render on Paddle {"
	testing.expect_value(t, got, want)
}

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

@(test)
test_diag_pin_closure_unclosed_signal :: proc(t: ^testing.T) {
	got := diag_render_through_pipeline(t, CLOSURE_PIN_SOURCE, .Closure_Failed)
	want := "src/x.fun:5: Unclosed_Signal (Goal): this signal is emitted but no downstream stage consumes it — every emitted signal needs a consumer (effect closure, spec §07 §2)\n  5 | signal Goal { side: Fixed }"
	testing.expect_value(t, got, want)
}

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
	testing.expect_value(t, verdict.line, 4)
	testing.expect_value(t, verdict.declaration, "Public")
	d := type_diagnostic(verdict.err, verdict.line, verdict.col, verdict.declaration)
	d.path = "src/x.fun"
	got := render_diagnostic(d, source, context.temp_allocator)
	want := "src/x.fun:4: Expose_Closure_Violation (Public): this @expose'd declaration's public signature references a non-@expose'd user type — expose that type too, or drop it from the signature (spec §30 §6)\n  4 | data Public { s: Secret }"
	testing.expect_value(t, got, want)
}

Diag_Arm_Case :: struct {
	source: string,
	arm:    string,
}

expect_located_arm :: proc(t: ^testing.T, d: Diagnostic, arm: string) {
	testing.expectf(t, d.line >= 1, "%s: expected a located line >= 1, got %d", arm, d.line)
	testing.expect_value(t, d.rule, arm)
	testing.expectf(t, d.message != "", "%s: expected a non-empty fix-criteria message", arm)
}

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
		{"fn pick() -> Int {\n  return match hit {\n    true => 1\n    false => 0\n  }\n}\n", "Bool_Pattern_Unsupported"},
		{"fn keep() -> Bool {\n  return a < b\n  and c < d\n}\n", "Newline_Before_Binary_Op"},
	}
	for c in cases {
		_, verdict := stage_parse_located(stage_lex(c.source))
		d := parse_diagnostic(verdict.err, verdict.line, verdict.col)
		expect_located_arm(t, d, c.arm)
	}
}

@(test)
test_arm_coverage_gate :: proc(t: ^testing.T) {
	fn_size := strings.builder_make(context.temp_allocator)
	strings.write_string(&fn_size, "fn big() -> Int {\n")
	for i in 0 ..< 41 {
		fmt.sbprintf(&fn_size, "  let v%d = %d\n", i, i)
	}
	strings.write_string(&fn_size, "  return 1\n}\n")

	cases := []Diag_Arm_Case {
		{"fn tangled(a: Int) -> Int {\n  if a == 1 { return 1 }\n  if a == 2 { return 2 }\n  if a == 3 { return 3 }\n  if a == 4 { return 4 }\n  if a == 5 { return 5 }\n  if a == 6 { return 6 }\n  if a == 7 { return 7 }\n  if a == 8 { return 8 }\n  if a == 9 { return 9 }\n  if a == 10 { return 10 }\n  if a == 11 { return 11 }\n  return 0\n}\n", "Cyclomatic_Exceeded"},
		{"fn deep() -> Int {\n  if true {\n    if true {\n      if true {\n        if true {\n          return 1\n        }\n      }\n    }\n  }\n  return 0\n}\n", "Nesting_Exceeded"},
		{strings.to_string(fn_size), "Fn_Size_Exceeded"},
		{"fn build() -> Int {\n  let f = fn(a, b, c, d, e, g) { return a }\n  return 1\n}\n", "Arity_Exceeded"},
		{"enum Side { Left, Right }\nfn pick(s: Side) -> Int {\n  return match s {\n    Side::Left => 1,\n  }\n}\n", "Non_Exhaustive_Match"},
		{"fn a(x: Int) -> Int {\n  return x + 1\n}\nfn b(x: Int) -> Int {\n  return x + 1\n}\n", "Duplicate_Declaration"},
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

@(test)
test_arm_coverage_typecheck_package :: proc(t: ^testing.T) {
	dep_ast, dep_pv := stage_parse_located(stage_lex("data Cell { x: Fixed }\n"))
	testing.expect_value(t, dep_pv.err, Parse_Error.None)
	private_index := build_module_index_from_asts({"hexgrid.layout"}, {dep_ast}, {"hexgrid"})
	cons_ast, cons_pv := stage_parse_located(stage_lex("import hexgrid.layout.{Cell}\n"))
	testing.expect_value(t, cons_pv.err, Parse_Error.None)
	_, private_verdict := stage_typecheck_located(cons_ast, private_index)
	private_diag := type_diagnostic(private_verdict.err, private_verdict.line, private_verdict.col, private_verdict.declaration)
	expect_located_arm(t, private_diag, "Package_Private")

	other_ast, other_pv := stage_parse_located(stage_lex("data Far { x: Fixed }\n"))
	testing.expect_value(t, other_pv.err, Parse_Error.None)
	star_index := build_module_index_from_asts({"other.mod"}, {other_ast}, {"other"})
	pkg_ast, pkg_pv := stage_parse_located(stage_lex("import other.mod.{Far}\n"))
	testing.expect_value(t, pkg_pv.err, Parse_Error.None)
	_, star_verdict := stage_typecheck_located(pkg_ast, star_index, "hexgrid")
	star_diag := type_diagnostic(star_verdict.err, star_verdict.line, star_verdict.col, star_verdict.declaration)
	expect_located_arm(t, star_diag, "Package_Imports_Package")
}

ARM_COVERAGE_CONTRACT_HEADER :: "import engine.math.{Fixed, Vec2}\n" +
	"import engine.world.{View, Spawn}\n" +
	"import engine.render.{Draw, Color}\n" +
	"import engine.rand.{Rng}\n" +
	"thing Paddle { x: Fixed, y: Fixed }\n" +
	"signal Goal { side: Fixed }\n"

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
		line := verdict.line if verdict.line != 0 else behavior_decl_line(typed.ast, verdict.behavior)
		d := contract_diagnostic(verdict.err, line, verdict.behavior)
		expect_located_arm(t, d, c.arm)
	}
}

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
