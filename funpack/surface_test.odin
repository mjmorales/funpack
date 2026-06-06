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
test_snake_imports_populate_bindings :: proc(t: ^testing.T) {
	// snake.fun's seven engine.* import forms, verbatim (engine.prelude is
	// pre-bound, so the file omits it). Every member must bind to its owning
	// module with the expected Decl_Kind — the new engine.rand surface, the
	// engine.world Despawn command, the engine.grid helper, and the engine.list
	// combinators snake adds beyond the existing fold/map/filter set.
	source := "import engine.math.{Vec2, to_fixed}\n" +
		"import engine.world.{View, Spawn, Despawn}\n" +
		"import engine.input.{Input, Key, PlayerId, Bindings}\n" +
		"import engine.render.{Draw, Color}\n" +
		"import engine.rand.{Rng, pick}\n" +
		"import engine.grid.grid_cells\n" +
		"import engine.list.{prepend, init, contains, map, filter, concat, is_empty}\n"
	ast, parse_err := stage_parse(stage_lex(source))
	testing.expect_value(t, parse_err, Parse_Error.None)
	bindings, err := resolve_imports(ast)
	testing.expect_value(t, err, Type_Error.None)

	expectations := []Surface_Expectation {
		{"Vec2", "engine.math", .Type_Name},
		{"to_fixed", "engine.math", .Func},
		{"View", "engine.world", .Type_Name},
		{"Spawn", "engine.world", .Type_Name},
		{"Despawn", "engine.world", .Type_Name},
		{"Input", "engine.input", .Type_Name},
		{"Key", "engine.input", .Type_Name},
		{"PlayerId", "engine.input", .Type_Name},
		{"Bindings", "engine.input", .Type_Name},
		{"Draw", "engine.render", .Type_Name},
		{"Color", "engine.render", .Type_Name},
		{"Rng", "engine.rand", .Type_Name},
		{"pick", "engine.rand", .Func},
		{"grid_cells", "engine.grid", .Func},
		{"prepend", "engine.list", .Func},
		{"init", "engine.list", .Func},
		{"contains", "engine.list", .Func},
		{"map", "engine.list", .Func},
		{"filter", "engine.list", .Func},
		{"concat", "engine.list", .Func},
		{"is_empty", "engine.list", .Func},
	}
	expect_bindings(t, bindings, expectations)
}

@(test)
test_hunt_imports_populate_bindings :: proc(t: ^testing.T) {
	// hunt.fun's seven engine.* import forms, verbatim. Every member binds to
	// its owning module: Fixed re-exports through engine.math to the OWNING
	// prelude (§26 §3), the engine.input Stick enum and wasd/stick axis-source
	// helpers, and the engine.list.first combinator imported as a dotted single
	// member.
	source := "import engine.math.{Fixed, Vec2, length}\n" +
		"import engine.world.{Spawn, View}\n" +
		"import engine.input.{Input, PlayerId, Bindings, Stick, wasd, stick}\n" +
		"import engine.core.Time\n" +
		"import engine.render.{Draw, Color}\n" +
		"import engine.list.first\n"
	ast, parse_err := stage_parse(stage_lex(source))
	testing.expect_value(t, parse_err, Parse_Error.None)
	bindings, err := resolve_imports(ast)
	testing.expect_value(t, err, Type_Error.None)

	expectations := []Surface_Expectation {
		// Fixed canonicalizes to the owning prelude even through engine.math.
		{"Fixed", "engine.prelude", .Type_Name},
		{"Vec2", "engine.math", .Type_Name},
		{"length", "engine.math", .Func},
		{"Spawn", "engine.world", .Type_Name},
		{"View", "engine.world", .Type_Name},
		{"Input", "engine.input", .Type_Name},
		{"PlayerId", "engine.input", .Type_Name},
		{"Bindings", "engine.input", .Type_Name},
		{"Stick", "engine.input", .Type_Name},
		{"wasd", "engine.input", .Func},
		{"stick", "engine.input", .Func},
		{"Time", "engine.core", .Type_Name},
		{"Draw", "engine.render", .Type_Name},
		{"Color", "engine.render", .Type_Name},
		{"first", "engine.list", .Func},
	}
	expect_bindings(t, bindings, expectations)
}

@(test)
test_snake_hunt_import_lines_compile_clean :: proc(t: ^testing.T) {
	// The whole pipeline accepts the snake and hunt import lines ahead of a
	// passing assert — no unknown-module / unknown-member halts typecheck, so
	// the example surfaces resolve clean through run_test_pipeline. Body typing
	// of the call sites is the next story; this pins import admission alone.
	source := "import engine.math.{Vec2, to_fixed, length, Fixed}\n" +
		"import engine.world.{View, Spawn, Despawn}\n" +
		"import engine.input.{Input, Key, PlayerId, Bindings, Stick, wasd, stick}\n" +
		"import engine.render.{Draw, Color}\n" +
		"import engine.rand.{Rng, pick}\n" +
		"import engine.grid.grid_cells\n" +
		"import engine.list.{prepend, init, contains, map, filter, concat, is_empty, first}\n" +
		"import engine.core.Time\n" +
		"test \"x\" {\n\tassert to_fixed(2) == 2.0\n}\n"
	report, err := run_test_pipeline(source)
	testing.expect_value(t, err, Pipeline_Error.None)
	testing.expect_value(t, report.passed, 1)
	testing.expect_value(t, report.failed, 0)
}

@(test)
test_engine_rand_despawn_resolve_to_handles :: proc(t: ^testing.T) {
	// AC: engine_type_name maps Rng and Despawn to their nominal Engine_Type
	// handles, so an `rng: Rng` param and a `[Despawn]` return resolve. The
	// existing Spawn handle is unchanged; the two new spellings join it.
	rng, has_rng := engine_type_name("Rng")
	testing.expect(t, has_rng)
	testing.expect(t, is_engine(rng, .Rng))

	despawn, has_despawn := engine_type_name("Despawn")
	testing.expect(t, has_despawn)
	testing.expect(t, is_engine(despawn, .Despawn))
}

@(test)
test_despawn_types_as_command :: proc(t: ^testing.T) {
	// AC: surface_command types Despawn() as a §04 command (mirroring Spawn) —
	// a no-argument constructor whose result is the Despawn command handle, so
	// snake's despawn_eaten `[Despawn()]` is a recognized command list.
	signature, found := surface_command("Despawn")
	testing.expect(t, found)
	command, is_func := signature.(^Func_Type)
	testing.expect(t, is_func)
	if is_func {
		testing.expect_value(t, len(command.params), 0)
		testing.expect(t, is_engine(command.result, .Despawn))
	}
}

@(test)
test_input_test_producers_resolve :: proc(t: ^testing.T) {
	// AC: the §23 inline-test producers resolve to their engine-value
	// signatures — Input.empty() and Time.at(dt) as static builders, View.of()
	// as a §08 read-table static builder, Input.with_pressed and Bindings.button
	// as chained engine methods returning the resource/builder. Deep call typing
	// is the next story; this pins the table rows the producers resolve through.
	empty, has_empty := surface_static_method("Input", "empty")
	testing.expect(t, has_empty)
	testing.expect(t, returns_engine(empty, .Input))

	at, has_at := surface_static_method("Time", "at")
	testing.expect(t, has_at)
	testing.expect(t, returns_engine(at, .Time))

	of, has_of := surface_static_method("View", "of")
	testing.expect(t, has_of)
	testing.expect(t, returns_engine(of, .View))

	input := engine_type_of(.Input).(^Engine_Type)
	with_pressed, has_with_pressed := surface_engine_method(input, "with_pressed")
	testing.expect(t, has_with_pressed)
	testing.expect(t, returns_engine(with_pressed, .Input))

	bindings_recv := engine_type_of(.Bindings).(^Engine_Type)
	button, has_button := surface_engine_method(bindings_recv, "button")
	testing.expect(t, has_button)
	testing.expect(t, returns_engine(button, .Bindings))
}

// Surface_Expectation is one imported member, the module it must resolve to,
// and the Decl_Kind the surface table declares for it — the row shape the
// snake/hunt import fixtures and the pong import fixture assert against.
Surface_Expectation :: struct {
	name:   string,
	module: string,
	kind:   Decl_Kind,
}

// expect_bindings asserts each expectation row binds to its owning module with
// the declared kind — the shared check the import-line fixtures run.
expect_bindings :: proc(t: ^testing.T, bindings: Bindings, expectations: []Surface_Expectation) {
	for want in expectations {
		binding, bound := bindings.names[want.name]
		testing.expectf(t, bound, "%s did not bind", want.name)
		testing.expect_value(t, binding.module, want.module)
		testing.expect_value(t, binding.kind, want.kind)
	}
}

// returns_engine reports whether a func signature's result is an engine type of
// the given kind — the producer fixtures assert a static builder / engine method
// yields the expected engine value without depending on its parameter shape.
returns_engine :: proc(signature: Type, kind: Engine_Kind) -> bool {
	command, is_func := signature.(^Func_Type)
	if !is_func {
		return false
	}
	return is_engine(command.result, kind)
}

@(test)
test_pong_unknown_world_member_rejected :: proc(t: ^testing.T) {
	// The closed-table proof: a name absent from the engine.world partition
	// still rejects with Unknown_Member. Admitting View/Spawn/Despawn did not
	// open the module to arbitrary names — `Reap` is owned by no module.
	ast, parse_err := stage_parse(stage_lex("import engine.world.{View, Reap}\n"))
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
