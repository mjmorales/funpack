package funpack

import "core:testing"

@(test)
test_golden_imports_resolve_clean :: proc(t: ^testing.T) {
	// The golden file's three import forms, verbatim, ahead of a
	// passing assert: the whole pipeline accepts them.
	source := "import engine.prelude.Option\n" +
		"import engine.math.{Vec2, Vec3, Quat, clamp, lerp, dot, cross, length, sin, cos, to_fixed, trunc, floor, round, checked_div, pi}\n" +
		"import engine.list.fold\n" +
		"test \"x\" {\n\tassert to_fixed(2) == 2.0\n}\n"
	report, err := run_test_pipeline(source)
	testing.expect_value(t, err, Pipeline_Error.None)
	testing.expect_value(t, report.passed, 1)
	testing.expect_value(t, report.failed, 0)
}

@(test)
test_golden_imports_populate_bindings :: proc(t: ^testing.T) {
	source := "import engine.prelude.Option\n" +
		"import engine.math.{Vec2, pi}\n" +
		"import engine.list.fold\n"
	ast, parse_err := stage_parse(stage_lex(source))
	testing.expect_value(t, parse_err, Parse_Error.None)
	bindings, err := resolve_imports(ast)
	testing.expect_value(t, err, Type_Error.None)

	option, has_option := bindings.names["Option"]
	testing.expect(t, has_option)
	testing.expect_value(t, option.module, "engine.prelude")
	testing.expect_value(t, option.kind, Decl_Kind.Type_Name)

	vec2, has_vec2 := bindings.names["Vec2"]
	testing.expect(t, has_vec2)
	testing.expect_value(t, vec2.module, "engine.math")
	testing.expect_value(t, vec2.kind, Decl_Kind.Type_Name)

	pi_binding, has_pi := bindings.names["pi"]
	testing.expect(t, has_pi)
	testing.expect_value(t, pi_binding.module, "engine.math")
	testing.expect_value(t, pi_binding.kind, Decl_Kind.Value)

	fold_binding, has_fold := bindings.names["fold"]
	testing.expect(t, has_fold)
	testing.expect_value(t, fold_binding.module, "engine.list")
	testing.expect_value(t, fold_binding.kind, Decl_Kind.Func)
}

@(test)
test_pong_imports_populate_bindings :: proc(t: ^testing.T) {
	// The pong golden source's six engine.* import forms, verbatim
	// (engine.prelude is pre-bound, so the file omits it). Every member
	// must bind to its owning module with the expected Decl_Kind — the
	// boundary this story owns: imports resolve to bindings, no call site
	// is typed yet.
	source := "import engine.math.{Fixed, Vec2, abs, clamp}\n" +
		"import engine.world.{View, Spawn}\n" +
		"import engine.input.{Input, Key, PlayerId, Bindings, keys_axis, stick_y, Stick}\n" +
		"import engine.render.{Draw, Color}\n" +
		"import engine.core.Time\n" +
		"import engine.list.{fold, first}\n"
	ast, parse_err := stage_parse(stage_lex(source))
	testing.expect_value(t, parse_err, Parse_Error.None)
	bindings, err := resolve_imports(ast)
	testing.expect_value(t, err, Type_Error.None)

	// Each row is one imported member, the module it must resolve to, and
	// the Decl_Kind the surface table declares for it.
	Expectation :: struct {
		name:   string,
		module: string,
		kind:   Decl_Kind,
	}
	expectations := []Expectation{
		// Fixed binds to the OWNING prelude even when imported through
		// engine.math — the declared re-export (§26 §3) canonicalizes the
		// binding, so the meaning is route-independent.
		{"Fixed", "engine.prelude", .Type_Name},
		{"Vec2", "engine.math", .Type_Name},
		{"abs", "engine.math", .Func},
		{"clamp", "engine.math", .Func},
		{"View", "engine.world", .Type_Name},
		{"Spawn", "engine.world", .Type_Name},
		{"Input", "engine.input", .Type_Name},
		{"Key", "engine.input", .Type_Name},
		{"PlayerId", "engine.input", .Type_Name},
		{"Bindings", "engine.input", .Type_Name},
		{"Stick", "engine.input", .Type_Name},
		{"keys_axis", "engine.input", .Func},
		{"stick_y", "engine.input", .Func},
		{"Draw", "engine.render", .Type_Name},
		{"Color", "engine.render", .Type_Name},
		{"Time", "engine.core", .Type_Name},
		{"fold", "engine.list", .Func},
		{"first", "engine.list", .Func},
	}
	for want in expectations {
		binding, bound := bindings.names[want.name]
		testing.expectf(t, bound, "%s did not bind", want.name)
		testing.expect_value(t, binding.module, want.module)
		testing.expect_value(t, binding.kind, want.kind)
	}
}

@(test)
test_pong_unknown_world_member_rejected :: proc(t: ^testing.T) {
	// The closed-table proof: a name absent from the new engine.world
	// partition still rejects with Unknown_Member. Admitting View/Spawn
	// did not open the module to arbitrary names.
	ast, parse_err := stage_parse(stage_lex("import engine.world.{View, Despawn}\n"))
	testing.expect_value(t, parse_err, Parse_Error.None)
	_, err := resolve_imports(ast)
	testing.expect_value(t, err, Type_Error.Unknown_Member)
}

@(test)
test_prelude_is_always_in_scope :: proc(t: ^testing.T) {
	// The prelude needs no import (spec §26): Fixed and Option are
	// bound on an importless source.
	ast, parse_err := stage_parse(stage_lex("test \"x\" {\n\tassert 1 == 1\n}\n"))
	testing.expect_value(t, parse_err, Parse_Error.None)
	bindings, err := resolve_imports(ast)
	testing.expect_value(t, err, Type_Error.None)
	_, has_fixed := bindings.names["Fixed"]
	testing.expect(t, has_fixed)
	_, has_option := bindings.names["Option"]
	testing.expect(t, has_option)
}

@(test)
test_whole_module_import_binds_handle :: proc(t: ^testing.T) {
	ast, parse_err := stage_parse(stage_lex("import engine.list\n"))
	testing.expect_value(t, parse_err, Parse_Error.None)
	bindings, err := resolve_imports(ast)
	testing.expect_value(t, err, Type_Error.None)
	handle, has_handle := bindings.names["list"]
	testing.expect(t, has_handle)
	testing.expect_value(t, handle.module, "engine.list")
	testing.expect_value(t, handle.kind, Decl_Kind.Module)
}

@(test)
test_import_unknown_member_rejected :: proc(t: ^testing.T) {
	ast, parse_err := stage_parse(stage_lex("import engine.math.bogus\n"))
	testing.expect_value(t, parse_err, Parse_Error.None)
	_, err := resolve_imports(ast)
	testing.expect_value(t, err, Type_Error.Unknown_Member)
}

@(test)
test_import_unknown_member_in_group_rejected :: proc(t: ^testing.T) {
	ast, parse_err := stage_parse(stage_lex("import engine.math.{dot, bogus}\n"))
	testing.expect_value(t, parse_err, Parse_Error.None)
	_, err := resolve_imports(ast)
	testing.expect_value(t, err, Type_Error.Unknown_Member)
}

@(test)
test_import_unknown_module_rejected :: proc(t: ^testing.T) {
	ast, parse_err := stage_parse(stage_lex("import engine.bogus.x\n"))
	testing.expect_value(t, parse_err, Parse_Error.None)
	_, err := resolve_imports(ast)
	testing.expect_value(t, err, Type_Error.Unknown_Module)
}

@(test)
test_import_bare_unknown_module_rejected :: proc(t: ^testing.T) {
	ast, parse_err := stage_parse(stage_lex("import bogus\n"))
	testing.expect_value(t, parse_err, Parse_Error.None)
	_, err := resolve_imports(ast)
	testing.expect_value(t, err, Type_Error.Unknown_Module)
}

@(test)
test_pipeline_bad_import_is_typecheck_failed :: proc(t: ^testing.T) {
	// The compile-error contract at the pipeline seam: a bad import is
	// Typecheck_Failed (exit 2 at the CLI), never a counted failure.
	source := "import engine.math.bogus\n" +
		"test \"x\" {\n\tassert to_fixed(2) == 2.0\n}\n"
	_, err := run_test_pipeline(source)
	testing.expect_value(t, err, Pipeline_Error.Typecheck_Failed)
}

// ── §26 §3 re-exports and the resolver collision floor ─────────────────

@(test)
test_stdlib_surface_single_owner_per_name :: proc(t: ^testing.T) {
	// §02 one-name-one-meaning at the table layer: no name is owned by two
	// partitions — a cross-partition duplicate is legal only as a declared
	// STDLIB_REEXPORTS row. A future story admitting a name twice fails
	// here instead of resolving last-write-wins.
	for module, i in STDLIB_SURFACE {
		for decl in module.decls {
			for other in STDLIB_SURFACE[i + 1:] {
				_, dup := surface_lookup(other, decl.name)
				testing.expectf(
					t,
					!dup,
					"%s owned by both %s and %s — declare a re-export instead",
					decl.name,
					module.path,
					other.path,
				)
			}
		}
	}
	// Every declared re-export resolves: the owner exists and owns the
	// name, and the re-exporting partition does not ALSO own it (one
	// owning row per name).
	for row in STDLIB_REEXPORTS {
		owner, has_owner := surface_module(row.owner)
		testing.expectf(t, has_owner, "re-export %s.%s names unknown owner %s", row.module, row.name, row.owner)
		if has_owner {
			_, owned := surface_lookup(owner, row.name)
			testing.expectf(t, owned, "re-export %s.%s: owner %s does not declare it", row.module, row.name, row.owner)
		}
		re_module, has_partition := surface_module(row.module)
		testing.expectf(t, has_partition, "re-export row names unknown partition %s", row.module)
		if has_partition {
			_, also_owned := surface_lookup(re_module, row.name)
			testing.expectf(t, !also_owned, "%s both owns and re-exports %s", row.module, row.name)
		}
	}
}

@(test)
test_reexported_fixed_binds_identically_on_both_routes :: proc(t: ^testing.T) {
	// The §26 §3 exception in action: Fixed imported through engine.math
	// binds to the owning prelude — the identical binding the prelude
	// pre-bind already inserted — so the re-import is legal and the
	// meaning is route-independent.
	ast, parse_err := stage_parse(stage_lex("import engine.math.{Fixed, Vec2}\n"))
	testing.expect_value(t, parse_err, Parse_Error.None)
	bindings, err := resolve_imports(ast)
	testing.expect_value(t, err, Type_Error.None)
	fixed, bound := bindings.names["Fixed"]
	testing.expect(t, bound)
	testing.expect_value(t, fixed.module, "engine.prelude")
	testing.expect_value(t, fixed.kind, Decl_Kind.Type_Name)
}

@(test)
test_bind_name_rejects_conflicting_rebind :: proc(t: ^testing.T) {
	// The binding-layer floor behind the table test: re-binding the
	// identical declaration is legal (the prelude pre-bind + a golden
	// re-export import), but a DIFFERENT declaration under a bound name is
	// the §02 violation — rejected, never last-write-wins.
	bindings: Bindings
	bindings.names = make(map[string]Binding, context.temp_allocator)
	first := Binding{module = "engine.prelude", kind = .Type_Name}
	testing.expect_value(t, bind_name(&bindings, "Fixed", first), Type_Error.None)
	testing.expect_value(t, bind_name(&bindings, "Fixed", first), Type_Error.None)
	conflicting := Binding{module = "engine.math", kind = .Func}
	testing.expect_value(t, bind_name(&bindings, "Fixed", conflicting), Type_Error.Name_Collision)
	kept := bindings.names["Fixed"]
	testing.expect_value(t, kept.module, "engine.prelude")
}
