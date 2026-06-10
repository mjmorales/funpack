// Exposure-closure fixtures (spec §30 §6, §27 §2): an @expose'd declaration
// whose public signature references a non-@expose'd user type is a compile
// error naming BOTH ends — the exposed declaration and the unexposed type —
// while a fully-exposed (transitive) signature chain passes. All fixtures are
// deterministic in-memory sources (the module_index_test package-edge fixtures'
// template); no spec checkout needed. The same check gates a package's api
// seam and a game's modapi surface, so the fixtures run plain within-project
// modules — the closure keys off the @expose flags, never the package edge.
package funpack

import "core:testing"

// closure_module_verdict parses one module source, resolves its imports
// against an index, and returns the exposure-closure verdict — the unit seam
// the named-both-ends fixtures pin. The source is fixed and well-formed; a
// parse or resolve failure is a test-authoring bug, surfaced by the expects.
closure_module_verdict :: proc(t: ^testing.T, source: string, index: Module_Index) -> Expose_Closure_Verdict {
	ast, parse_err := stage_parse(stage_lex(source))
	testing.expect_value(t, parse_err, Parse_Error.None)
	bindings, bind_err := resolve_imports_indexed(ast, index)
	testing.expect_value(t, bind_err, Type_Error.None)
	return expose_closure_verdict(ast, bindings, index)
}

@(test)
test_expose_closure_open_signature_refused_named_both_ends :: proc(t: ^testing.T) {
	// AC: an @expose'd fn whose param references an unexposed local type is a
	// compile error (.Expose_Closure_Violation through the typecheck seam), and
	// the verdict names BOTH ends — the exposed declaration AND the unexposed
	// type — so the refusal tells the author exactly which edge to close.
	source := "data Cube { x: Int }\n" +
		"@expose\n" +
		"fn cube_volume(c: Cube) -> Int {\n" +
		"  return c.x\n" +
		"}\n"
	ast, parse_err := stage_parse(stage_lex(source))
	testing.expect_value(t, parse_err, Parse_Error.None)
	_, err := stage_typecheck_indexed(ast, Module_Index{})
	testing.expect_value(t, err, Type_Error.Expose_Closure_Violation)

	verdict := closure_module_verdict(t, source, Module_Index{})
	testing.expect(t, verdict.violation)
	testing.expect_value(t, verdict.declaration, "cube_volume")
	testing.expect_value(t, verdict.type_name, "Cube")
}

@(test)
test_expose_closure_fully_exposed_chain_passes :: proc(t: ^testing.T) {
	// AC: a transitively-exposed signature chain compiles clean — an exposed
	// fn over an exposed type whose own field references another exposed type
	// (Hex → Layout → fn), plus builtin params (Int/Fixed), a structural tuple
	// return over builtins, and an exposed let of a builtin type. Every type
	// reachable from the exposed surface is itself exposed or primitive, so the
	// closure holds (spec §27 §2).
	source := "@expose\ndata Hex { q: Int, r: Int }\n" +
		"@expose\ndata Layout { origin: Hex }\n" +
		"@expose\n" +
		"fn axial_to_pixel(cell: Hex, size: Fixed) -> Fixed {\n" +
		"  return size\n" +
		"}\n" +
		"@expose\n" +
		"fn split(n: Int, x: Fixed) -> (Int, Fixed) {\n" +
		"  return (n, x)\n" +
		"}\n" +
		"@expose\nlet ORIGIN: Int = 0\n"
	ast, parse_err := stage_parse(stage_lex(source))
	testing.expect_value(t, parse_err, Parse_Error.None)
	_, err := stage_typecheck_indexed(ast, Module_Index{})
	testing.expect_value(t, err, Type_Error.None)

	verdict := closure_module_verdict(t, source, Module_Index{})
	testing.expect(t, !verdict.violation)
	testing.expect_value(t, verdict.declaration, "")
	testing.expect_value(t, verdict.type_name, "")
}

@(test)
test_expose_closure_every_signature_surface_gated :: proc(t: ^testing.T) {
	// The closure spans every public signature surface (the §27 §2 contract
	// kinds): data/thing/signal field types, enum tuple AND struct payload
	// types, fn/query params and returns (a list return reaches its element
	// type), and a let's declared type. Each fixture references the same
	// unexposed Cube from a different surface; every one refuses through the
	// typecheck seam AND names both ends.
	Closure_Case :: struct {
		source:      string,
		declaration: string,
	}
	cube :: "data Cube { x: Int }\n"
	cases := []Closure_Case {
		{cube + "@expose\ndata Box { shape: Cube }\n", "Box"},
		{cube + "@expose\nthing Crate { shape: Cube }\n", "Crate"},
		{cube + "@expose\nsignal Hit { what: Cube }\n", "Hit"},
		{cube + "@expose\nenum Msg { Move(Cube) }\n", "Msg"},
		{cube + "@expose\nenum Cmd { Spawn{ at: Cube } }\n", "Cmd"},
		{cube + "@expose\nfn make() -> [Cube] {\n  return [Cube{x: 0}]\n}\n", "make"},
		{cube + "@expose\nquery count_cubes(c: Cube) -> Int {\n  return c.x\n}\n", "count_cubes"},
		{cube + "@expose\nlet DEFAULT: Cube = Cube{x: 0}\n", "DEFAULT"},
	}
	for closure_case in cases {
		ast, parse_err := stage_parse(stage_lex(closure_case.source))
		testing.expect_value(t, parse_err, Parse_Error.None)
		_, err := stage_typecheck_indexed(ast, Module_Index{})
		testing.expect_value(t, err, Type_Error.Expose_Closure_Violation)

		verdict := closure_module_verdict(t, closure_case.source, Module_Index{})
		testing.expect(t, verdict.violation)
		testing.expect_value(t, verdict.declaration, closure_case.declaration)
		testing.expect_value(t, verdict.type_name, "Cube")
	}
}

@(test)
test_expose_closure_unexposed_decl_unconstrained :: proc(t: ^testing.T) {
	// The closure is over the EXPOSED set only: an unmarked (package-private)
	// declaration referencing another unmarked type is no violation — privacy
	// composes freely inside the package; only the contract surface must close.
	source := "data Cube { x: Int }\n" +
		"fn cube_volume(c: Cube) -> Int {\n" +
		"  return c.x\n" +
		"}\n"
	ast, parse_err := stage_parse(stage_lex(source))
	testing.expect_value(t, parse_err, Parse_Error.None)
	_, err := stage_typecheck_indexed(ast, Module_Index{})
	testing.expect_value(t, err, Type_Error.None)
}

@(test)
test_expose_closure_first_offender_deterministic :: proc(t: ^testing.T) {
	// Determinism: a multi-violation module always names the FIRST offender in
	// the Ast's source-ordered declaration sequence (the release_holed_decl
	// discipline), and within one signature the params walk before the return —
	// so the named edge is reproducible from the source alone and matches
	// index order.
	source := "data Cube { x: Int }\n" +
		"data Slab { y: Int }\n" +
		"@expose\nsignal Tick { what: Slab }\n" +
		"@expose\nfn first_param(c: Cube) -> Slab {\n" +
		"  return Slab{y: c.x}\n" +
		"}\n"
	verdict := closure_module_verdict(t, source, Module_Index{})
	testing.expect(t, verdict.violation)
	// The signal declares before the fn, so it is the named offender even
	// though the fn violates twice; its referenced type is Slab.
	testing.expect_value(t, verdict.declaration, "Tick")
	testing.expect_value(t, verdict.type_name, "Slab")

	// Drop the signal: the fn is now first, and its PARAM (Cube) names before
	// its return (Slab).
	fn_only := "data Cube { x: Int }\n" +
		"data Slab { y: Int }\n" +
		"@expose\nfn first_param(c: Cube) -> Slab {\n" +
		"  return Slab{y: c.x}\n" +
		"}\n"
	fn_verdict := closure_module_verdict(t, fn_only, Module_Index{})
	testing.expect(t, fn_verdict.violation)
	testing.expect_value(t, fn_verdict.declaration, "first_param")
	testing.expect_value(t, fn_verdict.type_name, "Cube")
}

@(test)
test_expose_closure_cross_module_reference_gated :: proc(t: ^testing.T) {
	// The closure spans the whole project's exposed set: an exposed fn whose
	// param type is IMPORTED from a sibling module violates when that type is
	// unexposed and passes when it is exposed. The import itself resolves clean
	// either way (within-project entries are public-by-default, §15 §4) —
	// pinning that contract membership (the exposure flag) and import
	// visibility (module_export_importable) are different predicates: the
	// closure consults the flag even where the import gate never would.
	geo := "data Cube { x: Int }\n" +
		"@expose\ndata Hex { q: Int }\n"
	geo_ast, geo_parse := stage_parse(stage_lex(geo))
	testing.expect_value(t, geo_parse, Parse_Error.None)
	index := build_module_index_typed({"geo"}, {geo_ast})

	open_consumer := "import geo.{Cube}\n" +
		"@expose\nfn cube_volume(c: Cube) -> Int {\n" +
		"  return c.x\n" +
		"}\n"
	open_ast, open_parse := stage_parse(stage_lex(open_consumer))
	testing.expect_value(t, open_parse, Parse_Error.None)
	_, open_err := stage_typecheck_indexed(open_ast, index)
	testing.expect_value(t, open_err, Type_Error.Expose_Closure_Violation)
	verdict := closure_module_verdict(t, open_consumer, index)
	testing.expect(t, verdict.violation)
	testing.expect_value(t, verdict.declaration, "cube_volume")
	testing.expect_value(t, verdict.type_name, "Cube")

	closed_consumer := "import geo.{Hex}\n" +
		"@expose\nfn hex_area(h: Hex) -> Int {\n" +
		"  return h.q\n" +
		"}\n"
	closed_ast, closed_parse := stage_parse(stage_lex(closed_consumer))
	testing.expect_value(t, closed_parse, Parse_Error.None)
	_, closed_err := stage_typecheck_indexed(closed_ast, index)
	testing.expect_value(t, closed_err, Type_Error.None)
}

@(test)
test_expose_closure_behavior_outside_closure :: proc(t: ^testing.T) {
	// Boundary pin: a behavior does not participate in the closure — it is
	// unexportable at the resolution layer (collect_module_exports lifts no
	// behaviors; a behavior is reached through its pipeline, never an
	// importable name), and the §27 §2 pipeline-SLOT exposure is the modapi
	// generator's concern over stage names, which carry no type references. So
	// an @expose'd behavior over an unexposed thing is no closure violation
	// HERE; when the modapi seam generator lands, slot exposure rides the same
	// closure mechanism and this pin flips in lockstep with that story.
	source := "thing Crate { weight: Int }\n" +
		"@expose\nbehavior settle on Crate {\n" +
		"  fn step(self: Crate) -> Crate {\n" +
		"    return self\n" +
		"  }\n" +
		"}\n"
	ast, parse_err := stage_parse(stage_lex(source))
	testing.expect_value(t, parse_err, Parse_Error.None)
	_, err := stage_typecheck_indexed(ast, Module_Index{})
	testing.expect_value(t, err, Type_Error.None)
}
