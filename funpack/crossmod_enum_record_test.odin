// The cross-module ENUM-VARIANT-VALUE and RECORD-LITERAL surfaces the §21/§22 hud
// integration admitted (spec §15: every top-level declaration is importable, so a
// declaration's module of origin is invisible at the use site). The multi-module
// project pipeline already typed cross-module CALLS, CONSTS, and FIELDS; the hud
// example was the first to use a sibling-module enum's VARIANT as a value
// (Screen::Pause in a `with`, AppMsg::Hud as a .map fn-value) and to construct a
// sibling-module RECORD in test position (SettingsPresetRow{value: 50}, PauseView{}).
// These fixtures pin those two surfaces directly — happy paths AND the rejection
// arms — over hand-built (module, Ast) pairs, with NO sibling-checkout dependency.
package funpack

import "core:testing"

// crossmod_index builds a two-module typed index over a seam module (`seam`) and a
// consumer module (`app`) from their sources — the in-memory analogue of the
// project pipeline's index, so a fixture exercises the cross-module path without a
// project tree. Returns the index plus the parsed consumer Ast.
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

// ── (typecheck) a cross-module enum variant used as a VALUE ───────────────────

@(test)
test_crossmod_enum_variant_value_typechecks :: proc(t: ^testing.T) {
	// A consumer imports a seam enum and uses its variant as a value in a `with`
	// update — Screen::Pause, the form a router's `self with { screen: Screen::Pause
	// }` builds. Before the hud integration this was Unsupported_Expr (the variant
	// set was unreachable across the module edge); now it resolves the imported
	// enum's variant set through the index and types as the enum.
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
	// The §21 §3 tagged-union construction across a module edge: an imported
	// AppMsg::Hud(m) checks its payload against the imported variant's declared
	// payload type (HudMsg, itself imported), and the variant-as-function value
	// AppMsg::Hud passed to .map types as fn(HudMsg) -> AppMsg. Both forms read the
	// cross-module enum schema's per-variant payloads.
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
	// The rejection arm: a variant NOT in the imported enum's set is Type_Mismatch,
	// not a silent fallback — the cross-module variant check is closed exactly like
	// the local-env one (the same enum_variant_value_check body). `Screen::Bogus`
	// names no variant of the imported Screen, so it rejects.
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

// ── (eval) a cross-module record literal materializes ─────────────────────────

@(test)
test_crossmod_record_literal_evaluates :: proc(t: ^testing.T) {
	// A consumer constructs a sibling-module `data` in test position and compares it
	// — the eval_module_record arm: the literal's named fields evaluate in the
	// consumer ctx, the record resolves its schema through the owning module's eval
	// surface, and the resulting Record_Value compares structurally equal to the
	// same construction (PauseView{}-style empty record + a fielded one). Run through
	// the whole project pipeline so the eval surface is the real one.
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
	// A sibling-module record's DECLARED DEFAULT fills an omitted field — the
	// default is an owner-module expression, so eval_module_record evaluates it in
	// the OWNER ctx. The consumer omits `value`, the owner's `= 7` default fills it,
	// and the result equals the explicitly-fielded construction.
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

// ── (surface) to_fixed resolves through both prelude and math routes ───────────

@(test)
test_to_fixed_resolves_via_prelude_and_math :: proc(t: ^testing.T) {
	// to_fixed is OWNED by engine.prelude (spec-03 Prelude functions) and re-exported
	// by engine.math: hud_demo imports it from engine.prelude, numerics/snake from
	// engine.math. Both routes must bind to the OWNING prelude (the Fixed precedent
	// applied to a function), so one name has one meaning whichever route named it.
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
	// The re-export binds to the OWNER, so the engine.math route resolves to
	// engine.prelude — identical to the direct prelude import.
	testing.expect_value(t, math_binding.module, "engine.prelude")
	testing.expect_value(t, math_binding.kind, Decl_Kind.Func)
}

// ── (typecheck) a cross-module fn used as a combinator-slot VALUE ─────────────

@(test)
test_crossmod_fn_value_in_combinator_slot :: proc(t: ^testing.T) {
	// An imported fn passed BARE-NAME into a combinator slot (map's mapper)
	// types as a function value off its cross-module signature — the
	// name_check sibling of call_check's module_call_signature arm.
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
