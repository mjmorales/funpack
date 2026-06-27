package funpack

import "core:testing"

crossmod_index :: proc(seam_src: string, app_src: string) -> (index: Module_Index, app_ast: Ast, ok: bool) {
	seam_ast, seam_err := stage_parse(stage_lex(seam_src))
	if seam_err != .None {
		return {}, {}, false
	}
	parsed_app, app_err := stage_parse(stage_lex(app_src))
	if app_err != .None {
		return {}, {}, false
	}
	idx := build_module_index_typed({"seam", "app"}, {seam_ast, parsed_app})
	return idx, parsed_app, true
}

@(test)
test_crossmod_enum_variant_value_typechecks :: proc(t: ^testing.T) {
	seam := "enum Screen { Hud, Pause, Settings }\n"
	app := `import seam.Screen
thing App { screen: Screen = Screen::Hud }
fn pause(self: App) -> App {
  return self with { screen: Screen::Pause }
}`
	index, app_ast, ok := crossmod_index(seam, app)
	testing.expect(t, ok)
	_, err := stage_typecheck_indexed(app_ast, index)
	testing.expect_value(t, err, Type_Error.None)
}

@(test)
test_crossmod_tagged_union_variant_constructs :: proc(t: ^testing.T) {
	seam := `enum HudMsg { Coin, Pause }
enum AppMsg { Hud(HudMsg) }`
	app := `import seam.{HudMsg, AppMsg}
fn tag(m: HudMsg) -> AppMsg {
  return AppMsg::Hud(m)
}`
	index, app_ast, ok := crossmod_index(seam, app)
	testing.expect(t, ok)
	_, err := stage_typecheck_indexed(app_ast, index)
	testing.expect_value(t, err, Type_Error.None)
}

@(test)
test_crossmod_enum_unknown_variant_rejects :: proc(t: ^testing.T) {
	seam := "enum Screen { Hud, Pause, Settings }\n"
	app := `import seam.Screen
thing App { screen: Screen = Screen::Hud }
fn bad(self: App) -> App {
  return self with { screen: Screen::Bogus }
}`
	index, app_ast, ok := crossmod_index(seam, app)
	testing.expect(t, ok)
	_, err := stage_typecheck_indexed(app_ast, index)
	testing.expect_value(t, err, Type_Error.Type_Mismatch)
}

@(test)
test_crossmod_record_literal_evaluates :: proc(t: ^testing.T) {
	seam := `data Row { value: Int }
data Empty {}`
	app := `import seam.{Row, Empty}
test "cross-module records construct and compare" {
  assert Row{value: 50} == Row{value: 50}
  assert Empty{} == Empty{}
}`
	seam_ast, _ := stage_parse(stage_lex(seam))
	app_ast, _ := stage_parse(stage_lex(app))
	index := build_module_index_typed({"seam", "app"}, {seam_ast, app_ast})
	eval_modules := build_module_eval_surface({"seam", "app"}, {seam_ast, app_ast}, index)
	report, err := run_module_pipeline_named(app, index, eval_modules, "app")
	testing.expect_value(t, err, Pipeline_Error.None)
	testing.expect_value(t, report.passed, 2)
	testing.expect_value(t, report.failed, 0)
}

@(test)
test_crossmod_record_with_default_evaluates :: proc(t: ^testing.T) {
	seam := "data Row { value: Int = 7 }\n"
	app := `import seam.Row
test "owner default fills an omitted cross-module field" {
  assert Row{} == Row{value: 7}
}`
	seam_ast, _ := stage_parse(stage_lex(seam))
	app_ast, _ := stage_parse(stage_lex(app))
	index := build_module_index_typed({"seam", "app"}, {seam_ast, app_ast})
	eval_modules := build_module_eval_surface({"seam", "app"}, {seam_ast, app_ast}, index)
	report, err := run_module_pipeline_named(app, index, eval_modules, "app")
	testing.expect_value(t, err, Pipeline_Error.None)
	testing.expect_value(t, report.passed, 1)
	testing.expect_value(t, report.failed, 0)
}

@(test)
test_crossmod_imported_let_const_evaluates :: proc(t: ^testing.T) {
	world := `let MAP_W: Int = 32
let MAP_H: Int = 24`
	app := `import world.{MAP_W, MAP_H}
let ROOM_ATTEMPTS: Int = 40
test "imported and local consts both hold their values" {
  assert MAP_W == 32
  assert MAP_H == 24
  assert ROOM_ATTEMPTS == 40
}`
	world_ast, _ := stage_parse(stage_lex(world))
	app_ast, _ := stage_parse(stage_lex(app))
	index := build_module_index_typed({"world", "app"}, {world_ast, app_ast})
	eval_modules := build_module_eval_surface({"world", "app"}, {world_ast, app_ast}, index)
	report, err := run_module_pipeline_named(app, index, eval_modules, "app")
	testing.expect_value(t, err, Pipeline_Error.None)
	testing.expect_value(t, report.passed, 3)
	testing.expect_value(t, report.failed, 0)
}

@(test)
test_to_fixed_resolves_via_prelude_and_math :: proc(t: ^testing.T) {
	prelude_src := "import engine.prelude.to_fixed\n"
	math_src := "import engine.math.to_fixed\n"

	prelude_ast, prelude_perr := stage_parse(stage_lex(prelude_src))
	testing.expect_value(t, prelude_perr, Parse_Error.None)
	prelude_bindings, prelude_err := resolve_imports(prelude_ast)
	testing.expect_value(t, prelude_err, Type_Error.None)
	prelude_binding, prelude_bound := prelude_bindings.names["to_fixed"]
	testing.expect(t, prelude_bound)
	testing.expect_value(t, prelude_binding.module, "engine.prelude")
	testing.expect_value(t, prelude_binding.kind, Decl_Kind.Func)

	math_ast, math_perr := stage_parse(stage_lex(math_src))
	testing.expect_value(t, math_perr, Parse_Error.None)
	math_bindings, math_err := resolve_imports(math_ast)
	testing.expect_value(t, math_err, Type_Error.None)
	math_binding, math_bound := math_bindings.names["to_fixed"]
	testing.expect(t, math_bound)
	testing.expect_value(t, math_binding.module, "engine.prelude")
	testing.expect_value(t, math_binding.kind, Decl_Kind.Func)
}

@(test)
test_crossmod_fn_value_in_combinator_slot :: proc(t: ^testing.T) {
	seam := "fn double(x: Int) -> Int {\n  return x + x\n}\n"
	app := `import engine.list.map
import seam.{double}
fn run(xs: [Int]) -> [Int] {
  return map(xs, double)
}`
	index, app_ast, ok := crossmod_index(seam, app)
	testing.expect(t, ok)
	_, err := stage_typecheck_indexed(app_ast, index)
	testing.expect_value(t, err, Type_Error.None)
}
