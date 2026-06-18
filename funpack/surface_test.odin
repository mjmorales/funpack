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
		// to_fixed canonicalizes to the owning prelude even through engine.math —
		// the spec-03 Prelude function re-exported by engine.math (the Fixed pattern).
		{"to_fixed", "engine.prelude", .Func},
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
test_input_device_button_helpers_bind :: proc(t: ^testing.T) {
	// The §23 §3 device-button surface (ADR
	// 2026-06-15-engine-input-source-helpers-split): pad/mouse/arrows/dpad are funcs
	// and PadButton/MouseButton are type names, each owned by engine.input. pad/mouse
	// close the gamepad/mouse digital-button gap the keyboard-only [Key::…] list
	// cannot reach; arrows is the only arrow-key 2D source; dpad is the only d-pad 2D
	// source. Each member binds to engine.input with the expected Decl_Kind — the
	// closed-table admission this surface owns.
	source := "import engine.input.{Bindings, PlayerId, Key, PadButton, MouseButton, pad, mouse, arrows, dpad, wasd, stick, Stick}\n"
	ast, parse_err := stage_parse(stage_lex(source))
	testing.expect_value(t, parse_err, Parse_Error.None)
	bindings, err := resolve_imports(ast)
	testing.expect_value(t, err, Type_Error.None)

	expectations := []Surface_Expectation {
		{"Bindings", "engine.input", .Type_Name},
		{"PlayerId", "engine.input", .Type_Name},
		{"Key", "engine.input", .Type_Name},
		{"PadButton", "engine.input", .Type_Name},
		{"MouseButton", "engine.input", .Type_Name},
		{"Stick", "engine.input", .Type_Name},
		{"pad", "engine.input", .Func},
		{"mouse", "engine.input", .Func},
		{"arrows", "engine.input", .Func},
		{"dpad", "engine.input", .Func},
		{"wasd", "engine.input", .Func},
		{"stick", "engine.input", .Func},
	}
	expect_bindings(t, bindings, expectations)
}

@(test)
test_input_device_button_bindings_body_typechecks :: proc(t: ^testing.T) {
	// End-to-end surface admission: a bindings() body binding pad(PadButton::A) and
	// mouse(MouseButton::Left) to a Button action and arrows()/dpad() to an Axis
	// action typechecks clean through the whole pipeline (ADR
	// 2026-06-15-engine-input-source-helpers-split). pad/mouse type as the nil
	// unknown Bindings.button's source slot consumes (the same slot the [Key::…]
	// list feeds); arrows/dpad type like wasd into Bindings.axis (dpad stacks the
	// d-pad 2D source onto the same action). The trailing passing test pins a clean
	// run (Pipeline_Error.None, one passed assert) — a missing helper would halt at
	// Typecheck_Failed (Unknown_Member) before the assert.
	source := "import engine.input.{Bindings, PlayerId, PadButton, MouseButton, pad, mouse, arrows, dpad}\n" +
		"import engine.math.to_fixed\n" +
		"enum Fire: Button { Shoot, Jump }\n" +
		"enum Drive: Axis { Move }\n" +
		"fn bindings() -> Bindings {\n" +
		"  return Bindings.empty()\n" +
		"    .button(PlayerId::P1, Fire::Shoot, pad(PadButton::A))\n" +
		"    .button(PlayerId::P1, Fire::Jump,  mouse(MouseButton::Left))\n" +
		"    .axis(PlayerId::P1, Drive::Move, arrows())\n" +
		"    .axis(PlayerId::P1, Drive::Move, dpad())\n" +
		"}\n" +
		"test \"x\" {\n\tassert to_fixed(2) == 2.0\n}\n"
	report, err := run_test_pipeline(source)
	testing.expect_value(t, err, Pipeline_Error.None)
	testing.expect_value(t, report.passed, 1)
	testing.expect_value(t, report.failed, 0)
}

@(test)
test_input_device_button_unknown_variant_rejected :: proc(t: ^testing.T) {
	// The closed-enum guard on the new device enums: a variant outside the admitted
	// PadButton set is not a value, mirroring how a Key/Stick variant outside its
	// set rejects. `PadButton::Triangle` is no §23 pad button (the set is the SDL→§23
	// face/shoulder/dpad map), so the call site fails typecheck rather than binding a
	// phantom device code the runtime could never resolve.
	source := "import engine.input.{Bindings, PlayerId, PadButton, pad}\n" +
		"enum Fire: Button { Shoot }\n" +
		"fn bindings() -> Bindings {\n" +
		"  return Bindings.empty()\n" +
		"    .button(PlayerId::P1, Fire::Shoot, pad(PadButton::Triangle))\n" +
		"}\n" +
		"test \"x\" {\n\tassert 1 == 1\n}\n"
	_, err := run_test_pipeline(source)
	testing.expect_value(t, err, Pipeline_Error.Typecheck_Failed)
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
test_yard_physics_save_imports_populate_bindings :: proc(t: ^testing.T) {
	// yard.fun's engine.physics and engine.save import forms, verbatim. Every
	// member binds to its owning module with the expected Decl_Kind — the new
	// §11 physics surface (Body/BodyKind/Shape2/Trigger type names + the solve
	// battery func) and the §24 persistence surface (the Save/Restore/
	// ApplySettings command constructors, the Saved/Restored/SettingsApplied
	// outcome signals, and the Settings record — all type names).
	source := "import engine.physics.{Body, BodyKind, Shape2, Trigger, solve}\n" +
		"import engine.save.{Save, Restore, ApplySettings, Saved, Restored, SettingsApplied, Settings}\n"
	ast, parse_err := stage_parse(stage_lex(source))
	testing.expect_value(t, parse_err, Parse_Error.None)
	bindings, err := resolve_imports(ast)
	testing.expect_value(t, err, Type_Error.None)

	expectations := []Surface_Expectation {
		{"Body", "engine.physics", .Type_Name},
		{"BodyKind", "engine.physics", .Type_Name},
		{"Shape2", "engine.physics", .Type_Name},
		{"Trigger", "engine.physics", .Type_Name},
		{"solve", "engine.physics", .Func},
		{"Save", "engine.save", .Type_Name},
		{"Restore", "engine.save", .Type_Name},
		{"ApplySettings", "engine.save", .Type_Name},
		{"Saved", "engine.save", .Type_Name},
		{"Restored", "engine.save", .Type_Name},
		{"SettingsApplied", "engine.save", .Type_Name},
		{"Settings", "engine.save", .Type_Name},
	}
	for want in expectations {
		binding, bound := bindings.names[want.name]
		testing.expectf(t, bound, "%s did not bind", want.name)
		testing.expect_value(t, binding.module, want.module)
		testing.expect_value(t, binding.kind, want.kind)
	}
}

// ── §08 engine.world.Ref + engine.nav surface admission ────────────────

@(test)
test_surface_admits_world_ref :: proc(t: ^testing.T) {
	// AC: `import engine.world.{Ref}` resolves to .None and Ref binds to the
	// engine.world partition as a Type_Name — the §08 typed reference joins
	// View/Spawn/Despawn without opening the module to arbitrary names.
	source := "import engine.world.{View, Ref, Spawn, Despawn}\n"
	ast, parse_err := stage_parse(stage_lex(source))
	testing.expect_value(t, parse_err, Parse_Error.None)
	bindings, err := resolve_imports(ast)
	testing.expect_value(t, err, Type_Error.None)

	ref, has_ref := bindings.names["Ref"]
	testing.expect(t, has_ref)
	testing.expect_value(t, ref.module, "engine.world")
	testing.expect_value(t, ref.kind, Decl_Kind.Type_Name)
}

@(test)
test_surface_admits_engine_nav :: proc(t: ^testing.T) {
	// AC: `import engine.nav.{Nav, Path, NavError}` resolves to .None — the new
	// §08 navigation partition the chase AI imports. Each member binds to the
	// engine.nav partition as a Type_Name.
	source := "import engine.nav.{Nav, Path, NavError}\n"
	ast, parse_err := stage_parse(stage_lex(source))
	testing.expect_value(t, parse_err, Parse_Error.None)
	bindings, err := resolve_imports(ast)
	testing.expect_value(t, err, Type_Error.None)

	expectations := []Surface_Expectation {
		{"Nav", "engine.nav", .Type_Name},
		{"Path", "engine.nav", .Type_Name},
		{"NavError", "engine.nav", .Type_Name},
	}
	expect_bindings(t, bindings, expectations)
}

@(test)
test_surface_engine_nav_unknown_member_rejected :: proc(t: ^testing.T) {
	// The closed-table proof for the new partition: a name absent from
	// engine.nav rejects with Unknown_Member. Admitting Nav/Path/NavError did
	// not open the module to arbitrary names — `Route` is owned by no module.
	ast, parse_err := stage_parse(stage_lex("import engine.nav.{Nav, Route}\n"))
	testing.expect_value(t, parse_err, Parse_Error.None)
	_, err := resolve_imports(ast)
	testing.expect_value(t, err, Type_Error.Unknown_Member)
}

@(test)
test_typecheck_nav_path_advance :: proc(t: ^testing.T) {
	// AC: a small fixture exercising the nav surface methods over a Nav/Path
	// pair typechecks to .None — `nav.path(from, to)` queries a Result[Path]
	// route, and `route.advance(from, arrive)` walks one waypoint returning the
	// (Option[Vec2], Path) pair, destructured into the next waypoint and the
	// remaining route. Both methods resolve through their engine-kind receivers
	// and type clean; deep Result-unwrap typing is a downstream story.
	source := "import engine.math.{Vec2, Fixed}\n" +
		"import engine.nav.{Nav, Path, NavError}\n" +
		"fn step(nav: Nav, route: Path, from: Vec2, to: Vec2) -> Path {\n" +
		"  let queried = nav.path(from, to)\n" +
		"  return match route.advance(from, 0.5) {\n" +
		"    (next, remaining) => remaining\n" +
		"  }\n" +
		"}\n"
	ast, parse_err := stage_parse(stage_lex(source))
	testing.expect_value(t, parse_err, Parse_Error.None)
	_, err := stage_typecheck(ast)
	testing.expect_value(t, err, Type_Error.None)
}

// ── §16 anim / §20 render3 / §22 audio surface admission ───────────────

@(test)
test_surface_admits_engine_anim :: proc(t: ^testing.T) {
	// AC: `import engine.anim.{…}` resolves to .None — the new §16 §7 rig/animation
	// partition the gen rig seam and the pose generators import. The seven type
	// names bind as Type_Name; rot_x/up as Func. Skeleton/PartSet/Slot/Side are the
	// gen-seam imports; Pose/Bone + rot_x/up the pose-generator imports.
	source := "import engine.anim.{Skeleton, PartSet, Slot, Side, Pose, Bone, Transform, rot_x, up}\n"
	ast, parse_err := stage_parse(stage_lex(source))
	testing.expect_value(t, parse_err, Parse_Error.None)
	bindings, err := resolve_imports(ast)
	testing.expect_value(t, err, Type_Error.None)

	expectations := []Surface_Expectation {
		{"Skeleton", "engine.anim", .Type_Name},
		{"PartSet", "engine.anim", .Type_Name},
		{"Slot", "engine.anim", .Type_Name},
		{"Side", "engine.anim", .Type_Name},
		{"Pose", "engine.anim", .Type_Name},
		{"Bone", "engine.anim", .Type_Name},
		{"Transform", "engine.anim", .Type_Name},
		{"rot_x", "engine.anim", .Func},
		{"up", "engine.anim", .Func},
	}
	expect_bindings(t, bindings, expectations)
}

@(test)
test_surface_engine_anim_unknown_member_rejected :: proc(t: ^testing.T) {
	// The closed-table proof for engine.anim: a name absent from the partition
	// rejects with Unknown_Member. Admitting the rig names did not open the module
	// to arbitrary names — `Joint` is owned by no module.
	ast, parse_err := stage_parse(stage_lex("import engine.anim.{Pose, Joint}\n"))
	testing.expect_value(t, parse_err, Parse_Error.None)
	_, err := resolve_imports(ast)
	testing.expect_value(t, err, Type_Error.Unknown_Member)
}

@(test)
test_surface_admits_engine_render3 :: proc(t: ^testing.T) {
	// AC: `import engine.render3.{Draw3, Color}` resolves to .None — Draw3 binds to
	// the engine.render3 partition (a NEW engine type, NOT the §20 2D Draw), and
	// Color resolves through the §26 §3 re-export to its OWNING engine.render, so the
	// palette meaning is route-independent. Material binds to render3 too.
	source := "import engine.render3.{Draw3, Material, Color}\n"
	ast, parse_err := stage_parse(stage_lex(source))
	testing.expect_value(t, parse_err, Parse_Error.None)
	bindings, err := resolve_imports(ast)
	testing.expect_value(t, err, Type_Error.None)

	expectations := []Surface_Expectation {
		{"Draw3", "engine.render3", .Type_Name},
		{"Material", "engine.render3", .Type_Name},
		// Color canonicalizes to its owning engine.render even through render3.
		{"Color", "engine.render", .Type_Name},
	}
	expect_bindings(t, bindings, expectations)
}

@(test)
test_surface_engine_render3_unknown_member_rejected :: proc(t: ^testing.T) {
	// The closed-table proof for engine.render3: a name neither owned nor
	// re-exported rejects with Unknown_Member. `Shader` is owned by no module
	// (engine PBR has no user-authored shaders, §20 §1).
	ast, parse_err := stage_parse(stage_lex("import engine.render3.{Draw3, Shader}\n"))
	testing.expect_value(t, parse_err, Parse_Error.None)
	_, err := resolve_imports(ast)
	testing.expect_value(t, err, Type_Error.Unknown_Member)
}

@(test)
test_surface_admits_engine_audio :: proc(t: ^testing.T) {
	// AC: `import engine.audio.{Audio, Bus}` resolves to .None — the §22 §2
	// sustained-audio partition this task owns. Audio and Bus bind as Type_Name.
	// (Sibling 5.2 adds the §22 §1 one-shot Sound into this same partition.)
	source := "import engine.audio.{Audio, Bus}\n"
	ast, parse_err := stage_parse(stage_lex(source))
	testing.expect_value(t, parse_err, Parse_Error.None)
	bindings, err := resolve_imports(ast)
	testing.expect_value(t, err, Type_Error.None)

	expectations := []Surface_Expectation {
		{"Audio", "engine.audio", .Type_Name},
		{"Bus", "engine.audio", .Type_Name},
	}
	expect_bindings(t, bindings, expectations)
}

@(test)
test_surface_engine_audio_unknown_member_rejected :: proc(t: ^testing.T) {
	// The closed-table proof for engine.audio: a name absent from the partition
	// rejects with Unknown_Member. `Reverb` is owned by no module (there is no
	// DSP-effect-chain authoring surface, §22 §4).
	ast, parse_err := stage_parse(stage_lex("import engine.audio.{Audio, Reverb}\n"))
	testing.expect_value(t, parse_err, Parse_Error.None)
	_, err := resolve_imports(ast)
	testing.expect_value(t, err, Type_Error.Unknown_Member)
}

@(test)
test_surface_admits_input_stick_x :: proc(t: ^testing.T) {
	// AC: stick_x joins engine.input as the horizontal axis-source twin of stick_y
	// (krognid binds the left stick's x to Strafe). It binds to engine.input as a
	// Func, and its signature is (Stick) -> the nil axis-source unknown.
	source := "import engine.input.{stick_x, stick_y, Stick}\n"
	ast, parse_err := stage_parse(stage_lex(source))
	testing.expect_value(t, parse_err, Parse_Error.None)
	bindings, err := resolve_imports(ast)
	testing.expect_value(t, err, Type_Error.None)

	stick_x_binding, has_stick_x := bindings.names["stick_x"]
	testing.expect(t, has_stick_x)
	testing.expect_value(t, stick_x_binding.module, "engine.input")
	testing.expect_value(t, stick_x_binding.kind, Decl_Kind.Func)

	overloads, found := surface_signatures("stick_x")
	testing.expect(t, found)
	testing.expect_value(t, len(overloads), 1)
}

@(test)
test_anim_render3_audio_typecheck_fixture :: proc(t: ^testing.T) {
	// PROOF (the task's hand-built fixture): every new anim/render3/audio name,
	// plus stick_x and the Drive: Axis role, typechecks clean over the existing
	// expression grammar. Mirrors stroll.fun's usage but stays inside this task's
	// scope — the skeleton/parts are produced locally (user-module resolution is a
	// separate seam) and the Time read uses dt (Time.t is a render/time concern).
	source := KROGNID_SURFACE_FIXTURE
	ast, parse_err := stage_parse(stage_lex(source))
	testing.expect_value(t, parse_err, Parse_Error.None)
	_, err := stage_typecheck(ast)
	testing.expect_value(t, err, Type_Error.None)
}

// KROGNID_SURFACE_FIXTURE is the self-contained .fun source the typecheck PROOF
// runs: it imports every new surface name and exercises each construct — the
// static builders (Skeleton.humanoid(), Pose.empty(), Pose.blend, PartSet.empty(),
// Audio.track), the value-method chains (.set/.bind/.mirror/.pitch/.gain/.bus/.get),
// the struct-payload Draw3 variants (Camera/Light/Plane/Rigged/Mesh), the enum
// variants (Slot/Side/Bone/Color::Gray/Bus::Sfx), stick_x, and the Drive: Axis
// role read via input.value(self.player, Drive::Strafe).
KROGNID_SURFACE_FIXTURE :: "import engine.math.{Fixed, Vec2, Vec3, sin, abs, length, clamp}\n" +
	"import engine.anim.{Skeleton, PartSet, Slot, Side, Pose, Bone, Transform, rot_x, up}\n" +
	"import engine.render3.{Draw3, Material, Color}\n" +
	"import engine.input.{Input, Key, PlayerId, Bindings, keys_axis, stick_x, stick_y, Stick}\n" +
	"import engine.core.Time\n" +
	"import engine.audio.{Audio, Bus}\n" +
	"import engine.assets.{MeshHandle, sound}\n" +
	"enum Drive: Axis { Strafe, Forward }\n" +
	"thing Krognid { player: PlayerId  pos: Vec3  intent: Vec2 = Vec2{x: 0.0, y: 0.0}  phase: Fixed = 0.0  speed: Fixed = 0.0 }\n" +
	"thing Field {}\n" +
	"fn walk_weight(speed: Fixed) -> Fixed { return clamp(speed * 2.0, 0.0, 1.0) }\n" +
	"fn pose_idle(t: Fixed) -> Pose { return Pose.empty().set(Bone::Torso, up(sin(t * 2.0) * 0.2)) }\n" +
	"fn pose_walk(phase: Fixed, speed: Fixed) -> Pose {\n" +
	"  let s = sin(phase) * 0.5\n" +
	"  return Pose.empty()\n" +
	"    .set(Bone::LUpperLeg, rot_x(s))\n" +
	"    .set(Bone::RUpperLeg, rot_x(-s))\n" +
	"    .set(Bone::LUpperArm, rot_x(-s * 0.6))\n" +
	"    .set(Bone::RUpperArm, rot_x(s * 0.6))\n" +
	"    .set(Bone::Torso, up(abs(sin(phase * 2.0)) * 0.3))\n" +
	"}\n" +
	"fn krognid_skeleton() -> Skeleton { return Skeleton.humanoid() }\n" +
	"fn krognid_parts() -> PartSet {\n" +
	"  return PartSet.empty()\n" +
	"    .bind(Slot::Torso, sound_mesh())\n" +
	"    .bind(Slot::Head, sound_mesh())\n" +
	"    .bind(Slot::LUpperArm, sound_mesh())\n" +
	"    .mirror(Side::L, Side::R)\n" +
	"}\n" +
	"fn sound_mesh() -> MeshHandle { return MeshHandle{name: \"krognid_torso\"} }\n" +
	"behavior read_drive on Krognid {\n" +
	"  fn step(self: Krognid, input: Input) -> Krognid {\n" +
	"    return self with { intent: Vec2{x: input.value(self.player, Drive::Strafe), y: input.value(self.player, Drive::Forward)} }\n" +
	"  }\n" +
	"}\n" +
	"behavior draw_scene on Field {\n" +
	"  fn step(self: Field) -> [Draw3] {\n" +
	"    return [\n" +
	"      Draw3::Camera{ eye: Vec3{x: 25.0, y: 40.0, z: -30.0}, at: Vec3{x: 25.0, y: 0.0, z: 25.0}, fov: 60.0 },\n" +
	"      Draw3::Light{ dir: Vec3{x: -0.3, y: -1.0, z: -0.2}, color: Color::White },\n" +
	"      Draw3::Plane{ at: Vec3{x: 25.0, y: 0.0, z: 25.0}, size: Vec2{x: 50.0, y: 50.0}, color: Color::Gray },\n" +
	"    ]\n" +
	"  }\n" +
	"}\n" +
	"behavior draw_krognid on Krognid {\n" +
	"  fn step(self: Krognid, time: Time) -> [Draw3] {\n" +
	"    let pose = Pose.blend(pose_idle(time.dt), pose_walk(self.phase, self.speed), walk_weight(self.speed))\n" +
	"    return [Draw3::Rigged{ skeleton: krognid_skeleton(), parts: krognid_parts(), pose: pose, at: self.pos }]\n" +
	"  }\n" +
	"}\n" +
	"behavior locomotion on Krognid {\n" +
	"  fn step(self: Krognid) -> [Audio] {\n" +
	"    if self.speed == 0.0 { return [] }\n" +
	"    return [Audio.track(\"stride\", sound(\"krognid_step\")).pitch(0.6 + self.speed * 0.2).gain(clamp(self.speed, 0.0, 1.0)).bus(Bus::Sfx)]\n" +
	"  }\n" +
	"}\n" +
	"fn bindings() -> Bindings {\n" +
	"  return Bindings.empty()\n" +
	"    .axis(PlayerId::P1, Drive::Strafe, keys_axis(Key::A, Key::D))\n" +
	"    .axis(PlayerId::P1, Drive::Forward, keys_axis(Key::S, Key::W))\n" +
	"    .axis(PlayerId::P1, Drive::Strafe, stick_x(Stick::Left))\n" +
	"    .axis(PlayerId::P1, Drive::Forward, stick_y(Stick::Left))\n" +
	"}\n" +
	"test \"pose_walk holds the legs at rest on the zero crossing\" {\n" +
	"  assert pose_walk(0.0, 1.0).get(Bone::LUpperLeg) == rot_x(0.0)\n" +
	"}\n"

@(test)
test_anim_unknown_pose_member_is_compile_error :: proc(t: ^testing.T) {
	// PROOF (the reject side): an unknown anim member is a compile error, not a
	// counted failure. Pose has no `Nope` value method — the closed surface rejects
	// it with Unsupported_Expr, the typecheck-fail verdict the pipeline maps to a
	// compile error (exit 2).
	source := "import engine.anim.{Pose, Bone, Transform}\n" +
		"fn bad(p: Pose) -> Transform { return p.nope(Bone::Torso) }\n"
	ast, parse_err := stage_parse(stage_lex(source))
	testing.expect_value(t, parse_err, Parse_Error.None)
	_, err := stage_typecheck(ast)
	testing.expect(t, err != .None)
}

@(test)
test_audio_unknown_method_is_compile_error :: proc(t: ^testing.T) {
	// PROOF (the reject side): an unknown sustained-audio builder is a compile
	// error. Audio has no `.badmethod` — the closed chain rejects it.
	source := "import engine.audio.{Audio, Bus}\n" +
		"import engine.assets.sound\n" +
		"fn bad() -> Audio { return Audio.track(\"k\", sound(\"krognid_step\")).badmethod(0.5) }\n"
	ast, parse_err := stage_parse(stage_lex(source))
	testing.expect_value(t, parse_err, Parse_Error.None)
	_, err := stage_typecheck(ast)
	testing.expect(t, err != .None)
}

@(test)
test_draw3_unknown_field_is_compile_error :: proc(t: ^testing.T) {
	// PROOF (the reject side): an unknown field on a Draw3 struct-payload variant
	// is a compile error. Draw3::Camera has no `tilt` field — the closed schema
	// rejects it with Type_Mismatch.
	source := "import engine.math.{Fixed, Vec3}\n" +
		"import engine.render3.Draw3\n" +
		"fn bad() -> Draw3 { return Draw3::Camera{ eye: Vec3{x: 0.0, y: 0.0, z: 0.0}, tilt: 1.0 } }\n"
	ast, parse_err := stage_parse(stage_lex(source))
	testing.expect_value(t, parse_err, Parse_Error.None)
	_, err := stage_typecheck(ast)
	testing.expect(t, err != .None)
}

@(test)
test_color_gray_variant_is_a_value :: proc(t: ^testing.T) {
	// AC: Color::Gray joins the closed palette (stroll.fun's ground-plane shade) and
	// types as the Color engine value; an unknown palette entry rejects. The palette
	// is the one §20 §1 closed set shared by 2D render and 3D render3.
	gray, has_gray := surface_enum_variant("Color", "Gray")
	testing.expect(t, has_gray)
	testing.expect(t, is_engine(gray, .Color))

	_, has_unknown := surface_enum_variant("Color", "Chartreuse")
	testing.expect(t, !has_unknown)
}

@(test)
test_anim_enum_variants_type_to_handles :: proc(t: ^testing.T) {
	// AC: the anim enum variants (Slot/Side/Bone) and Bus::Sfx type to their engine
	// handles, and an unknown variant of each rejects — the closed enum surface.
	slot, has_slot := surface_enum_variant("Slot", "LUpperLeg")
	testing.expect(t, has_slot)
	testing.expect(t, is_engine(slot, .Slot))

	side, has_side := surface_enum_variant("Side", "L")
	testing.expect(t, has_side)
	testing.expect(t, is_engine(side, .Side))

	bone, has_bone := surface_enum_variant("Bone", "Torso")
	testing.expect(t, has_bone)
	testing.expect(t, is_engine(bone, .Bone))

	bus, has_bus := surface_enum_variant("Bus", "Sfx")
	testing.expect(t, has_bus)
	testing.expect(t, is_engine(bus, .Bus))

	_, has_unknown_slot := surface_enum_variant("Slot", "Wing")
	testing.expect(t, !has_unknown_slot)
	_, has_unknown_bus := surface_enum_variant("Bus", "Subwoofer")
	testing.expect(t, !has_unknown_bus)
}

@(test)
test_anim_audio_static_and_method_builders_resolve :: proc(t: ^testing.T) {
	// AC: the anim/audio static builders and value methods resolve to engine-value
	// signatures — Skeleton.humanoid()/PartSet.empty()/Pose.empty()/Pose.blend and
	// Audio.track as statics, PartSet.bind/Pose.set/Audio.bus as value methods. Deep
	// arg typing is exercised by the fixture; this pins the table rows.
	humanoid, has_humanoid := surface_static_method("Skeleton", "humanoid")
	testing.expect(t, has_humanoid)
	testing.expect(t, returns_engine(humanoid, .Skeleton))

	part_empty, has_part_empty := surface_static_method("PartSet", "empty")
	testing.expect(t, has_part_empty)
	testing.expect(t, returns_engine(part_empty, .PartSet))

	blend, has_blend := surface_static_method("Pose", "blend")
	testing.expect(t, has_blend)
	testing.expect(t, returns_engine(blend, .Pose))

	track, has_track := surface_static_method("Audio", "track")
	testing.expect(t, has_track)
	testing.expect(t, returns_engine(track, .Audio))

	part_recv := engine_type_of(.PartSet).(^Engine_Type)
	bind, has_bind := surface_engine_method(part_recv, "bind")
	testing.expect(t, has_bind)
	testing.expect(t, returns_engine(bind, .PartSet))

	pose_recv := engine_type_of(.Pose).(^Engine_Type)
	get, has_get := surface_engine_method(pose_recv, "get")
	testing.expect(t, has_get)
	testing.expect(t, returns_engine(get, .Transform))

	audio_recv := engine_type_of(.Audio).(^Engine_Type)
	bus, has_bus := surface_engine_method(audio_recv, "bus")
	testing.expect(t, has_bus)
	testing.expect(t, returns_engine(bus, .Audio))
}

// ── §20 engine.render Flip + Draw::Sprite surface admission ────────────

@(test)
test_surface_admits_engine_render_flip :: proc(t: ^testing.T) {
	// AC: `import engine.render.{Draw, Color, Flip}` resolves to .None — Flip is the
	// §20 sprite-mirroring enum (None | X | Y | XY) joining the engine.render
	// partition without opening it to arbitrary names. Each member binds to
	// engine.render as a Type_Name.
	source := "import engine.render.{Draw, Color, Flip}\n"
	ast, parse_err := stage_parse(stage_lex(source))
	testing.expect_value(t, parse_err, Parse_Error.None)
	bindings, err := resolve_imports(ast)
	testing.expect_value(t, err, Type_Error.None)

	expectations := []Surface_Expectation {
		{"Draw", "engine.render", .Type_Name},
		{"Color", "engine.render", .Type_Name},
		{"Flip", "engine.render", .Type_Name},
	}
	expect_bindings(t, bindings, expectations)
}

@(test)
test_surface_engine_render_unknown_member_rejected :: proc(t: ^testing.T) {
	// The closed-table proof for engine.render: a name absent from the partition
	// rejects with Unknown_Member. Admitting Flip did not open the module to
	// arbitrary names — `Mirror` is owned by no module (Flip is the only
	// mirroring spelling, §20).
	ast, parse_err := stage_parse(stage_lex("import engine.render.{Draw, Mirror}\n"))
	testing.expect_value(t, parse_err, Parse_Error.None)
	_, err := resolve_imports(ast)
	testing.expect_value(t, err, Type_Error.Unknown_Member)
}

@(test)
test_draw_sprite_typecheck_fixture :: proc(t: ^testing.T) {
	// PROOF (the admit side): a Draw::Sprite struct-payload construction typechecks
	// clean over the §20 field schema — `atlas` an AtlasHandle (built from an
	// AtlasHandle{name:…} literal), `cell` a String, `at`/`size` Vec2, `tint` a
	// Color palette value, `flip` a Flip mirroring value, `layer` an Int z-key. This
	// is the CI-executing, sibling-independent twin of the whole-example pickups
	// golden, mirroring the Draw3 fixture pattern.
	source := "import engine.math.Vec2\n" +
		"import engine.render.{Draw, Color, Flip}\n" +
		"import engine.assets.AtlasHandle\n" +
		"fn draw_coin(atlas: AtlasHandle) -> Draw {\n" +
		"  return Draw::Sprite{ atlas: atlas, cell: atlas.cell(0, 0), at: Vec2{x: 1.0, y: 2.0}, size: Vec2{x: 8.0, y: 8.0}, tint: Color::White, flip: Flip::None, layer: 5 }\n" +
		"}\n" +
		"fn draw_coin_literal() -> Draw {\n" +
		"  return Draw::Sprite{ atlas: AtlasHandle{name: \"pickups\"}, cell: \"coin\", at: Vec2{x: 0.0, y: 0.0}, size: Vec2{x: 8.0, y: 8.0}, tint: Color::White, flip: Flip::X, layer: 0 }\n" +
		"}\n"
	ast, parse_err := stage_parse(stage_lex(source))
	testing.expect_value(t, parse_err, Parse_Error.None)
	_, err := stage_typecheck(ast)
	testing.expect_value(t, err, Type_Error.None)
}

@(test)
test_draw_sprite_unknown_field_is_compile_error :: proc(t: ^testing.T) {
	// PROOF (the reject side): an unknown field on Draw::Sprite is a compile error.
	// Draw::Sprite has no `opacity` field — the closed §20 schema rejects it with
	// Type_Mismatch (the typecheck-fail verdict the pipeline maps to a compile error,
	// exit 2). Mirrors test_draw3_unknown_field_is_compile_error.
	source := "import engine.math.Vec2\n" +
		"import engine.render.{Draw, Color, Flip}\n" +
		"import engine.assets.AtlasHandle\n" +
		"fn bad(atlas: AtlasHandle) -> Draw {\n" +
		"  return Draw::Sprite{ atlas: atlas, cell: \"coin\", at: Vec2{x: 0.0, y: 0.0}, size: Vec2{x: 8.0, y: 8.0}, tint: Color::White, flip: Flip::None, layer: 0, opacity: 0.5 }\n" +
		"}\n"
	ast, parse_err := stage_parse(stage_lex(source))
	testing.expect_value(t, parse_err, Parse_Error.None)
	_, err := stage_typecheck(ast)
	testing.expect(t, err != .None)
}

@(test)
test_flip_unknown_variant_is_compile_error :: proc(t: ^testing.T) {
	// PROOF (the reject side): an unknown Flip variant is a compile error. The closed
	// §20 mirroring set is {None, X, Y, XY} — `Diagonal` is owned by no variant, so
	// surface_enum_variant rejects it and the field typecheck fails.
	source := "import engine.math.Vec2\n" +
		"import engine.render.{Draw, Color, Flip}\n" +
		"import engine.assets.AtlasHandle\n" +
		"fn bad(atlas: AtlasHandle) -> Draw {\n" +
		"  return Draw::Sprite{ atlas: atlas, cell: \"coin\", at: Vec2{x: 0.0, y: 0.0}, size: Vec2{x: 8.0, y: 8.0}, tint: Color::White, flip: Flip::Diagonal, layer: 0 }\n" +
		"}\n"
	ast, parse_err := stage_parse(stage_lex(source))
	testing.expect_value(t, parse_err, Parse_Error.None)
	_, err := stage_typecheck(ast)
	testing.expect(t, err != .None)
}

// ── §26 prelude compare/Ordering + §20 Color palette/Rgb parity restore ──
// (ADR stdlib-surface-source-of-truth-parity-restore — the spec + .fun signature
// files are source of truth; these constructs are spec-declared and restored to
// the surface they regressed below.)

@(test)
test_compare_returns_ordering_and_matches :: proc(t: ^testing.T) {
	// The whole junction for §26/spec-03 `compare(a: T, b: T) -> Ordering`
	// (prelude.fun:50): compare yields the Ordering enum value a three-way match
	// destructures, and the kernel orders both Int and Fixed (the Ord grounds).
	// Run through run_test_pipeline so typecheck (the Fixed/Int overload set), the
	// exhaustiveness gate (the CLOSED_VARIANT_SETS Ordering entry), AND eval
	// (eval_compare → ordering_value) all hold on one fixture. Less/Equal/Greater
	// each evaluate to the correct arm.
	source := "import engine.prelude.{Int, Fixed, Ordering}\n" +
		"fn rank(o: Ordering) -> Int {\n" +
		"  return match o {\n" +
		"    Ordering::Less    => 0\n" +
		"    Ordering::Equal   => 1\n" +
		"    Ordering::Greater => 2\n" +
		"  }\n" +
		"}\n" +
		"test \"compare orders ints and fixeds three ways\" {\n" +
		"  assert rank(compare(1, 2)) == 0\n" +
		"  assert rank(compare(2, 2)) == 1\n" +
		"  assert rank(compare(3, 2)) == 2\n" +
		"  assert rank(compare(0.5, 1.5)) == 0\n" +
		"  assert rank(compare(1.5, 1.5)) == 1\n" +
		"  assert rank(compare(2.5, 1.5)) == 2\n" +
		"  assert compare(1, 2) == Ordering::Less\n" +
		"}\n"
	report, err := run_test_pipeline(source)
	testing.expect_value(t, err, Pipeline_Error.None)
	testing.expect_value(t, report.passed, 7)
	testing.expect_value(t, report.failed, 0)
}

@(test)
test_compare_overload_set_and_ordering_variants :: proc(t: ^testing.T) {
	// The surface-table rows behind the fixture: compare is the prelude
	// {(Fixed,Fixed)->Ordering, (Int,Int)->Ordering} closed overload set (the Ord
	// bound realized over the kernel ordered grounds, mirroring max), and the three
	// Ordering variants type to the Ordering engine handle. An entry outside the
	// declared set is not a value — the closed-enum guard.
	overloads, found := surface_signatures("compare")
	testing.expect(t, found)
	testing.expect_value(t, len(overloads), 2)
	for overload in overloads {
		testing.expect(t, returns_engine(overload, .Ordering))
	}

	for variant in ([]string{"Less", "Equal", "Greater"}) {
		v, has := surface_enum_variant("Ordering", variant)
		testing.expectf(t, has, "Ordering::%s did not type", variant)
		testing.expect(t, is_engine(v, .Ordering))
	}
	_, has_unknown := surface_enum_variant("Ordering", "Greatest")
	testing.expect(t, !has_unknown)

	// The bare `Ordering` type-name grounds for a param/return position.
	ordering, has_ordering := engine_type_name("Ordering")
	testing.expect(t, has_ordering)
	testing.expect(t, is_engine(ordering, .Ordering))
}

@(test)
test_compare_mixed_kind_pair_rejected :: proc(t: ^testing.T) {
	// The `a, b: T` same-type constraint: the closed overload set has no
	// (Int, Fixed) arm, so a mixed-kind pair matches neither and is Type_Mismatch
	// (no implicit Int→Fixed promotion, spec §10). A compile error, never a counted
	// failure.
	source := "import engine.prelude.{Int, Fixed, Ordering}\n" +
		"fn bad() -> Ordering { return compare(1, 2.0) }\n"
	ast, parse_err := stage_parse(stage_lex(source))
	testing.expect_value(t, parse_err, Parse_Error.None)
	_, err := stage_typecheck(ast)
	testing.expect_value(t, err, Type_Error.Type_Mismatch)
}

@(test)
test_incomplete_ordering_match_is_non_exhaustive :: proc(t: ^testing.T) {
	// The load-bearing exhaustiveness floor (the reason Ordering joins
	// CLOSED_VARIANT_SETS): the prelude doc "forces a match", so a match leaving
	// Greater unhandled is Non_Exhaustive_Match (spec §02 §5), not a silent pass.
	// Without the closed-set entry the gate would leave the match "for a later
	// stage" and admit the hole.
	source := "import engine.prelude.{Int, Ordering}\n" +
		"fn bad(o: Ordering) -> Int {\n" +
		"  return match o {\n" +
		"    Ordering::Less  => 0\n" +
		"    Ordering::Equal => 1\n" +
		"  }\n" +
		"}\n"
	ast, parse_err := stage_parse(stage_lex(source))
	testing.expect_value(t, parse_err, Parse_Error.None)
	_, type_err := stage_typecheck(ast)
	testing.expect_value(t, type_err, Type_Error.None)
	gate_err := stage_gates(ast)
	testing.expect_value(t, gate_err, Gate_Error.Non_Exhaustive_Match)
}

@(test)
test_color_palette_full_set_and_rgb_are_values :: proc(t: ^testing.T) {
	// The §20 §1 palette parity restore (render.fun:12-15): the full named set
	// White/Black/Red/Green/Blue/Yellow/Cyan/Magenta/Gray types to the Color engine
	// value, and the struct-payload escape Color::Rgb{r,g,b} yields the same Color
	// type — so a `tint`/`color` field accepts either form. The secondary/CMY trio
	// (Yellow/Cyan/Magenta) is the restored portion; the rest pin the closed set.
	for variant in ([]string{
		"White", "Black", "Red", "Green", "Blue",
		"Yellow", "Cyan", "Magenta", "Gray",
	}) {
		v, has := surface_enum_variant("Color", variant)
		testing.expectf(t, has, "Color::%s did not type", variant)
		testing.expect(t, is_engine(v, .Color))
	}
	_, has_unknown := surface_enum_variant("Color", "Chartreuse")
	testing.expect(t, !has_unknown)

	result, fields, has_rgb := surface_struct_variant("Color", "Rgb")
	testing.expect(t, has_rgb)
	testing.expect(t, is_engine(result, .Color))
	testing.expect_value(t, len(fields), 3)
	want_fields := []string{"r", "g", "b"}
	for field, i in fields {
		testing.expect_value(t, field.name, want_fields[i])
		testing.expect(t, is_ground(field.type, .Fixed))
	}
}

@(test)
test_color_palette_and_rgb_typecheck_and_eval :: proc(t: ^testing.T) {
	// The end-to-end junction: the restored palette entries and Color::Rgb
	// construct as values through the whole pipeline (typecheck + eval). Rgb built
	// from to_fixed(...) compares equal to the literal-channel form (the generic
	// eval_struct_variant builds a structural Record_Value value_equal compares).
	source := "import engine.render.Color\n" +
		"import engine.math.to_fixed\n" +
		"fn yellow() -> Color { return Color::Yellow }\n" +
		"fn cyan() -> Color { return Color::Cyan }\n" +
		"fn magenta() -> Color { return Color::Magenta }\n" +
		"fn red() -> Color { return Color::Rgb{ r: to_fixed(1), g: to_fixed(0), b: to_fixed(0) } }\n" +
		"test \"palette and rgb construct as values\" {\n" +
		"  assert yellow() == Color::Yellow\n" +
		"  assert cyan() == Color::Cyan\n" +
		"  assert magenta() == Color::Magenta\n" +
		"  assert red() == Color::Rgb{ r: 1.0, g: 0.0, b: 0.0 }\n" +
		"}\n"
	report, err := run_test_pipeline(source)
	testing.expect_value(t, err, Pipeline_Error.None)
	testing.expect_value(t, report.passed, 4)
	testing.expect_value(t, report.failed, 0)
}

@(test)
test_color_rgb_unknown_field_is_compile_error :: proc(t: ^testing.T) {
	// The closed-schema guard on the struct-payload escape: Color::Rgb carries
	// exactly r/g/b, so an `a` channel is Type_Mismatch (a compile error, exit 2) —
	// the Shape2::Box / Draw::Sprite mold.
	source := "import engine.render.Color\n" +
		"fn bad() -> Color { return Color::Rgb{ r: 1.0, g: 0.0, b: 0.0, a: 1.0 } }\n"
	ast, parse_err := stage_parse(stage_lex(source))
	testing.expect_value(t, parse_err, Parse_Error.None)
	_, err := stage_typecheck(ast)
	testing.expect(t, err != .None)
}

@(test)
test_view_count_and_at_typecheck :: proc(t: ^testing.T) {
	// The §08 read-table iteration surface (world.fun:24/:27): count() reads an Int
	// and at(i) reads the element T off a View[T] receiver — restored beside the
	// existing ref/resolve reference surface. Typechecks clean over a View[T] param.
	source := "import engine.prelude.Int\n" +
		"import engine.world.View\n" +
		"data Switch { on: Bool }\n" +
		"fn how_many(v: View[Switch]) -> Int { return v.count() }\n" +
		"fn first_one(v: View[Switch]) -> Switch { return v.at(0) }\n"
	ast, parse_err := stage_parse(stage_lex(source))
	testing.expect_value(t, parse_err, Parse_Error.None)
	_, err := stage_typecheck(ast)
	testing.expect_value(t, err, Type_Error.None)

	// The surface rows behind it: count is ()->Int, at is (Int)->T (the receiver's
	// element), both off the .View engine method surface.
	view := engine_type_of(.View, user_type_of("Switch", .Data)).(^Engine_Type)
	count, has_count := surface_engine_method(view, "count")
	testing.expect(t, has_count)
	count_fn, count_is_func := count.(^Func_Type)
	testing.expect(t, count_is_func)
	if count_is_func {
		testing.expect_value(t, len(count_fn.params), 0)
		testing.expect(t, is_ground(count_fn.result, .Int))
	}
	at, has_at := surface_engine_method(view, "at")
	testing.expect(t, has_at)
	at_fn, at_is_func := at.(^Func_Type)
	testing.expect(t, at_is_func)
	if at_is_func {
		testing.expect_value(t, len(at_fn.params), 1)
		testing.expect(t, is_ground(at_fn.params[0], .Int))
	}
}

@(test)
test_view_unknown_method_is_compile_error :: proc(t: ^testing.T) {
	// The closed-surface proof: restoring count/at did not open View to arbitrary
	// methods — `tail` is no View method, so the call is Unsupported_Expr (the
	// typecheck-fail verdict the pipeline maps to a compile error).
	source := "import engine.prelude.Int\n" +
		"import engine.world.View\n" +
		"fn bad(v: View[Int]) -> Int { return v.tail() }\n"
	ast, parse_err := stage_parse(stage_lex(source))
	testing.expect_value(t, parse_err, Parse_Error.None)
	_, err := stage_typecheck(ast)
	testing.expect(t, err != .None)
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
