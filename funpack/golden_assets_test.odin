// The §26 engine.assets surface + §19 examples/assets golden: the shared asset
// sink admitted to STDLIB_SURFACE (the four typed handle types + the six string/
// cell constructors, surface.odin), proven against the live golden tree exactly
// like the yard/seam goldens. This story LANDS LAST in the §19 pipeline because
// the generated gen/assets.gen.fun seam and src/pickups.fun must typecheck their
// handle expressions against this partition.
//
// THREE obligations, mirroring the lore-pinned scope:
//   (surface) the engine.assets partition resolves every §26 name — the closed
//     table is complete, no member is an Unknown_Member.
//   (a) the committed gen/assets.gen.fun seam stage_parses + stage_typechecks to
//     Type_Error.None — the three typed handle constants (coin/pickups/coin_sfx)
//     type against the new partition + the handle record schemas.
//   (b) the asset-specific obligation: assert <handle> == sound("name") evaluates
//     true — the typed constant equals the manifest-checked string form, the §19
//     golden's assets.coin_sfx == sound("coin_sfx").
//
// CRITICAL SCOPE (lore #13): examples/assets/src/pickups.fun ALSO imports
// engine.render.{Draw, Color, Flip} (Draw::Sprite) and engine.audio.{Sound, Bus}
// (Sound.sfx(...).bus(...)) — surface the §19 asset epic did NOT own. Those
// cross-epic surfaces have since LANDED on this branch (engine.render Flip +
// Draw::Sprite, the §22 [Sound] Update emit, and the cross-module const route via
// let-export), so the whole-example pickups.fun NOW typechecks + evaluates end to
// end — pinned by test_golden_assets_pickups_compiles_whole_example below. The
// parse-shape pin (test_golden_assets_pickups_parses) and the focused asset-equality
// obligations remain as their own proofs.
//
// WHY THE ASSERTION RIDES A FOCUSED MODULE: src/pickups.fun reaches its handle
// constant through the module-qualified `assets.coin_sfx` (a whole-module
// `import assets` of the seam). Cross-module-qualified const access + cross-module
// test evaluation are NOT this story's scope (this is "a TYPING concern riding the
// existing import grammar" — the surface partition + the golden, lore #13). The
// asset-equality obligation is orthogonal to the name-resolution route: the typed
// handle constant equals the string-constructor handle of the same name. (b) proves
// that substance directly in a single self-contained module — the seam's three
// handle constants as module lets plus the assertion — referencing the constant by
// its bare name, the same constant src/pickups.fun reaches as assets.coin_sfx.
package funpack

import "core:log"
import "core:os"
import "core:path/filepath"
import "core:testing"

// ── (surface) the engine.assets partition resolves all §26 names ─────────

// test_engine_assets_surface_resolves_all_names is the partition-completeness
// proof: a source importing the full §26 engine.assets member set binds every name
// to engine.assets, and the partition exposes EXACTLY the §26 line-78 names — the
// four typed handle types and the six string/cell constructors. A member outside
// the set would be an Unknown_Member; a missing one would not bind. Self-contained
// (no checkout): the surface table is the source of truth here.
@(test)
test_engine_assets_surface_resolves_all_names :: proc(t: ^testing.T) {
	source := "import engine.assets.{MeshHandle, TextureHandle, SoundHandle, AtlasHandle, mesh, texture, sound, atlas, cell, frame}\n"
	ast, parse_err := stage_parse(stage_lex(source))
	testing.expect_value(t, parse_err, Parse_Error.None)
	bindings, err := resolve_imports(ast)
	testing.expect_value(t, err, Type_Error.None)
	if err != .None {
		return
	}

	// Every §26 name binds to engine.assets, with the type names as .Type_Name and
	// the constructors as .Func — the closed two-kind shape the partition declares.
	type_names := []string{"MeshHandle", "TextureHandle", "SoundHandle", "AtlasHandle"}
	for name in type_names {
		binding, bound := bindings.names[name]
		testing.expectf(t, bound, "%s must bind", name)
		if bound {
			testing.expect_value(t, binding.module, "engine.assets")
			testing.expect_value(t, binding.kind, Decl_Kind.Type_Name)
		}
	}
	constructors := []string{"mesh", "texture", "sound", "atlas", "cell", "frame"}
	for name in constructors {
		binding, bound := bindings.names[name]
		testing.expectf(t, bound, "%s must bind", name)
		if bound {
			testing.expect_value(t, binding.module, "engine.assets")
			testing.expect_value(t, binding.kind, Decl_Kind.Func)
		}
	}

	// The partition is CLOSED: a member it does not export is an Unknown_Member,
	// not a silent bind — the same rejection every stdlib partition enforces.
	bogus, bogus_err := stage_parse(stage_lex("import engine.assets.{shader}\n"))
	testing.expect_value(t, bogus_err, Parse_Error.None)
	_, reject := resolve_imports(bogus)
	testing.expect_value(t, reject, Type_Error.Unknown_Member)
}

// ── (a) the committed gen/assets.gen.fun seam typechecks ─────────────────

// test_golden_assets_gen_fun_seam_typechecks is the load-bearing surface
// acceptance for the seam: the committed examples/assets/gen/assets.gen.fun parses
// and typechecks end-to-end to Type_Error.None — the three typed handle constants
// (coin: MeshHandle, pickups: AtlasHandle, coin_sfx: SoundHandle) type against the
// new engine.assets partition (their import members resolve) and the handle record
// schemas (their `KINDHandle{name: "NAME"}` literals carry the schema's String
// `name` field). The seam imports engine.assets ALONE (a stdlib partition), so the
// single-source stage_typecheck resolves it — no project-wide index needed. It
// resolves the sibling funpack-spec checkout (or FUNPACK_ASSETS_DIR) and SKIPs
// loudly when absent, so a missing checkout never silently passes.
@(test)
test_golden_assets_gen_fun_seam_typechecks :: proc(t: ^testing.T) {
	seam, ok := assets_gen_fun_source()
	if !ok {
		return
	}
	ast, parse_err := stage_parse(stage_lex(seam))
	testing.expect_value(t, parse_err, Parse_Error.None)
	if parse_err != .None {
		return
	}

	// The seam's three typed handle constants — the §19 §3 registry rendered as
	// module-level let bindings, one per registered asset.
	testing.expect_value(t, len(ast.lets), 3)
	testing.expect_value(t, len(ast.imports), 1)

	// Gates, then the single-source typecheck: the imports resolve against the new
	// engine.assets partition and the handle literals record-check against the
	// surface schemas — all to None.
	testing.expect_value(t, stage_gates(ast), Gate_Error.None)
	_, type_err := stage_typecheck(ast)
	testing.expect_value(t, type_err, Type_Error.None)
	if type_err == .None {
		log.infof("golden assets: committed gen/assets.gen.fun typechecks to None (3 typed handle constants against engine.assets)")
	}
}

// ── (b) the typed constant equals the manifest-checked string form ───────

// test_golden_assets_typed_constant_equals_checked_string is the §19 asset-specific
// obligation: a typed handle constant compares EQUAL to the string-constructor
// handle of the same name (the golden's assets.coin_sfx == sound("coin_sfx")). The
// focused module carries the seam's three handle constants as module lets (the same
// constants the seam emits) plus a test asserting each constant equals its
// string-constructor form, and runs the whole compile+evaluate pipeline. passed = 3,
// failed = 0 proves all three handle kinds (mesh/atlas/sound) round-trip: the typed
// constant's `KINDHandle{name: "N"}` value equals the constructor's kind("N") value.
//
// Self-contained: the obligation is the asset-equality semantics, not the
// cross-module name route (see the file header), so the constants are referenced by
// bare name in one module — the same handle values src/pickups.fun reaches through
// assets.coin_sfx and the seam emits.
@(test)
test_golden_assets_typed_constant_equals_checked_string :: proc(t: ^testing.T) {
	// The seam's three handle constants (verbatim handle types/names) plus a test
	// pinning the typed-constant == string-form equality for each registered kind.
	source := "@doc(\"focused engine.assets equality obligation\")\n" +
		"import engine.assets.{MeshHandle, AtlasHandle, SoundHandle, mesh, atlas, sound}\n" +
		"let coin: MeshHandle = MeshHandle{name: \"coin\"}\n" +
		"let pickups: AtlasHandle = AtlasHandle{name: \"pickups\"}\n" +
		"let coin_sfx: SoundHandle = SoundHandle{name: \"coin_sfx\"}\n" +
		"test \"typed constant equals the checked-string handle\" {\n" +
		"  assert coin_sfx == sound(\"coin_sfx\")\n" +
		"  assert coin == mesh(\"coin\")\n" +
		"  assert pickups == atlas(\"pickups\")\n" +
		"}\n"

	report, err := run_test_pipeline(source)
	testing.expect_value(t, err, Pipeline_Error.None)
	if err != .None {
		return
	}
	testing.expect_value(t, report.passed, 3)
	testing.expect_value(t, report.failed, 0)
	testing.expect_value(t, report.exit_code, 0)
	if report.passed == 3 && report.failed == 0 {
		log.infof("golden assets: typed handle constant == string-constructor handle for all three kinds (mesh/atlas/sound)")
	}
}

// ── (b-real) the equality rides the REAL cross-module const route ─────────

// test_golden_assets_cross_module_const_route_live proves the multi-module
// let-export seam end to end against the LIVE assets seam: a focused consumer
// whole-module imports the real gen/assets.gen.fun (`import assets`), references its
// exported handle const as `assets.coin_sfx`, and the equality
// `assets.coin_sfx == sound("coin_sfx")` evaluates true — the SAME reference
// src/pickups.fun reaches, now resolvable cross-module. It rides the production
// path: run_project_pipeline reads the real seam bytes off disk, builds the typed
// index (the const surface) AND the eval surface (the const's value in its owning
// module), and evaluates the consumer's assert against them. The let const is
// referenced CROSS-MODULE (not by bare name), so it exercises exactly the
// multi-module let-export seam this story lands — the const exports, types as
// SoundHandle, and grounds to the seam's emitted handle value. SKIPs loudly when
// the sibling checkout is absent so a missing checkout never silently passes.
//
// NOTE this focused consumer isolates the cross-module const route alone (the route
// src/pickups.fun rides to reach assets.coin_sfx). The full src/pickups.fun
// end-to-end typecheck — which also exercises the engine.render Sprite/Flip and
// engine.audio surfaces — is pinned separately by
// test_golden_assets_pickups_compiles_whole_example, now that those surfaces have
// landed. Keeping the const-route proof focused here means a regression in the route
// fails independently of the render/audio surfaces.
@(test)
test_golden_assets_cross_module_const_route_live :: proc(t: ^testing.T) {
	// Resolve-or-SKIP off the same reader the seam-typecheck golden uses, so a
	// missing checkout warns loudly rather than silently passing.
	if _, ok := assets_gen_fun_source(); !ok {
		return
	}
	seam_path := resolve_assets_gen_path()

	// A focused consumer that whole-module imports the REAL seam and rides the
	// cross-module const route through the equality the §19 golden pins. Written to
	// a scratch file so run_project_pipeline reads it off disk alongside the live seam.
	consumer := "@doc(\"focused cross-module const-route consumer\")\n" +
		"import engine.assets.{SoundHandle, MeshHandle, AtlasHandle, sound, mesh, atlas}\n" +
		"import assets\n" +
		"test \"the seam's handle const equals the checked-string handle, reached cross-module\" {\n" +
		"  assert assets.coin_sfx == sound(\"coin_sfx\")\n" +
		"  assert assets.coin == mesh(\"coin\")\n" +
		"  assert assets.pickups == atlas(\"pickups\")\n" +
		"}\n"
	consumer_path := write_cross_module_consumer(t, consumer)
	if consumer_path == "" {
		return
	}
	defer os.remove(consumer_path)

	// The two sources of the focused project: the LIVE seam (module `assets`, the
	// §15 name gen/assets.gen.fun derives) and the focused consumer. run_project_pipeline
	// reads both, builds the typed index + eval surface, and evaluates cross-module.
	sources := []Source{
		{path = seam_path, module = "assets"},
		{path = consumer_path, module = "pickups_focus"},
	}
	report := run_project_pipeline(sources)

	// The project compiles clean — the index built, both modules typed (the seam
	// against engine.assets, the consumer's `assets.coin_sfx` against the seam's const
	// surface), and neither hit a compile error.
	testing.expect_value(t, report.index_err, Project_Pipeline_Error.None)
	testing.expect_value(t, report.module_err, Pipeline_Error.None)
	if report.module_err != .None {
		log.errorf("golden assets cross-module route: %s did not compile (%v)", report.failed_path, report.module_err)
		return
	}

	// All three cross-module equalities pass: the seam's emitted handle value
	// (assets.coin_sfx) equals the string-constructor handle of the same name,
	// reached through the whole-module import — the route src/pickups.fun rides.
	testing.expect_value(t, report.passed, 3)
	testing.expect_value(t, report.failed, 0)
	if report.passed == 3 && report.failed == 0 {
		log.infof(
			"golden assets: assets.coin_sfx == sound(\"coin_sfx\") (and coin/pickups) ride the REAL cross-module const route through run_project_pipeline against the live seam",
		)
	}
}

// write_cross_module_consumer writes the focused consumer .fun to a unique scratch
// path so run_project_pipeline can read it off disk alongside the live seam; it
// returns "" (failing the test) when the write fails. The path is removed by the
// caller's defer.
write_cross_module_consumer :: proc(t: ^testing.T, source: string) -> string {
	base := scratch_base()
	path, _ := filepath.join({base, "funpack_assets_cross_module_consumer.fun"}, context.temp_allocator)
	if write_err := os.write_entire_file(path, transmute([]u8)source); write_err != nil {
		testing.expect(t, false, "could not write the cross-module consumer scratch source")
		return ""
	}
	return path
}

// test_golden_assets_string_constructor_distinguishes_names pins the negative half
// of the equality: a handle constructor naming a DIFFERENT asset does not compare
// equal — sound("coin_sfx") != sound("other"). The handle value carries its `name`
// field, so two handles of the same kind but different names are distinct, which is
// the whole point of the typed registry (a typo names a different — and, against the
// real manifest, a non-existent — asset). Self-contained.
@(test)
test_golden_assets_string_constructor_distinguishes_names :: proc(t: ^testing.T) {
	source := "import engine.assets.{SoundHandle, sound}\n" +
		"let coin_sfx: SoundHandle = SoundHandle{name: \"coin_sfx\"}\n" +
		"test \"a different name is a different handle\" {\n" +
		"  assert coin_sfx != sound(\"not_coin_sfx\")\n" +
		"  assert sound(\"coin_sfx\") != sound(\"gem_sfx\")\n" +
		"}\n"

	report, err := run_test_pipeline(source)
	testing.expect_value(t, err, Pipeline_Error.None)
	if err != .None {
		return
	}
	testing.expect_value(t, report.passed, 2)
	testing.expect_value(t, report.failed, 0)
}

// ── (proof) the closed registry rejects an unregistered name end-to-end ──

// test_assets_closed_registry_rejects_unregistered_name is the P7 closed-registry
// proof against the LIVE golden manifest: a string constructor naming an asset NOT
// in the manifest is Unregistered_Name, and one naming a registered asset with the
// WRONG kind is Wrong_Kind — both compile errors (the reference cannot stand),
// while the three registered names with their correct kinds pass. This is the
// registry gate (asset_registry.odin) exercised over the real examples/assets
// registry, end to end through the constructor surface — the §19 §3 / P7 guarantee
// that a name not in the manifest is a build error, not a silent miss. SKIPs loudly
// when the sibling checkout is absent.
@(test)
test_assets_closed_registry_rejects_unregistered_name :: proc(t: ^testing.T) {
	content, ok := golden_manifest()
	if !ok {
		return
	}
	manifest, read_err := read_asset_manifest(content)
	testing.expect_value(t, read_err, Asset_Manifest_Error.None)
	if read_err != .None {
		return
	}

	// The three registered names resolve with their correct kinds — the registry's
	// passing arm (the golden manifest is coin/model, pickups/atlas, coin_sfx/audio).
	testing.expect_value(t, check_asset_reference(manifest, .Mesh, "coin"), Asset_Registry_Error.None)
	testing.expect_value(t, check_asset_reference(manifest, .Atlas, "pickups"), Asset_Registry_Error.None)
	testing.expect_value(t, check_asset_reference(manifest, .Sound, "coin_sfx"), Asset_Registry_Error.None)

	// An unregistered name is a compile error — the P7 reject (`mesh("krognid_torso")`
	// against this registry has no asset).
	testing.expect_value(
		t,
		check_asset_reference(manifest, .Mesh, "krognid_torso"),
		Asset_Registry_Error.Unregistered_Name,
	)
	// A registered name reached with the wrong constructor kind is a Wrong_Kind
	// reject — coin IS registered, but as a model, so sound("coin") cannot stand.
	testing.expect_value(t, check_asset_reference(manifest, .Sound, "coin"), Asset_Registry_Error.Wrong_Kind)
	if check_asset_reference(manifest, .Mesh, "krognid_torso") == .Unregistered_Name {
		log.infof("golden assets: the closed registry rejects an unregistered name (Unregistered_Name) and a wrong-kind reference (Wrong_Kind) end-to-end")
	}
}

// ── (whole-example) src/pickups.fun FULLY typechecks + evaluates ─────────

// test_golden_assets_pickups_compiles_whole_example is the cross-epic leaf this
// bake-pipeline-seams run lands: the live src/pickups.fun compiles end to end against
// the live assets seam through run_project_pipeline — every previously-gated site now
// types. The two formerly-missing surfaces are admitted: engine.render.Flip + the
// Draw::Sprite struct-payload variant (this story) and engine.audio.{Sound, Bus} (the
// 5.2 merge on this branch), and the cross-module const route (`import assets`, then
// `assets.coin_sfx`/`assets.pickups`) resolves via let-export (also merged here). So
// draw_coin's `Draw::Sprite{atlas: assets.pickups, cell: assets.pickups.frame("spin",
// self.spin_t), …, flip: Flip::None, layer: 5}` and on_pickup's `Sound.sfx(
// assets.coin_sfx).bus(Bus::Sfx)` both typecheck, and the test block's `assert
// assets.coin_sfx == sound("coin_sfx")` evaluates true.
//
// It rides the production path against the real §14 tree's two sources — the seam
// (module `assets`) and pickups.fun (module `pickups`, the §15 name src/pickups.fun
// derives) — so a regression in any of the three landed surfaces fails the whole
// example, not a focused stand-in. SKIPs loudly when the sibling checkout is absent.
@(test)
test_golden_assets_pickups_compiles_whole_example :: proc(t: ^testing.T) {
	// Resolve-or-SKIP both live sources off the same readers the other goldens use,
	// so a missing checkout warns loudly rather than silently passing.
	if _, ok := assets_gen_fun_source(); !ok {
		return
	}
	pickups_file, pickups_ok := pickups_path()
	if !pickups_ok {
		return
	}
	seam_path := resolve_assets_gen_path()

	// The two live sources of the §14 assets project: the seam (module `assets`) and
	// the consumer src/pickups.fun (module `pickups`). run_project_pipeline reads both
	// off disk, builds the typed index + eval surface, and types/evaluates the project.
	sources := []Source{
		{path = seam_path, module = "assets"},
		{path = pickups_file, module = "pickups"},
	}
	report := run_project_pipeline(sources)

	// The whole example compiles clean: the index built, both modules typed — the
	// seam against engine.assets, pickups.fun against engine.render (Flip/Draw::Sprite),
	// engine.audio (Sound/Bus), the atlas accessors (assets.pickups.frame), AND the
	// cross-module const route (assets.coin_sfx/assets.pickups) — and neither hit a
	// compile error.
	testing.expect_value(t, report.index_err, Project_Pipeline_Error.None)
	testing.expect_value(t, report.module_err, Pipeline_Error.None)
	if report.module_err != .None {
		log.errorf("golden assets pickups whole-example: %s did not compile (%v)", report.failed_path, report.module_err)
		return
	}

	// pickups.fun carries one test block (the typed-constant equality), which passes;
	// no module fails. The count is pinned to the live source on purpose.
	testing.expect_value(t, report.passed, 1)
	testing.expect_value(t, report.failed, 0)
	if report.passed == 1 && report.failed == 0 {
		log.infof("golden assets: src/pickups.fun compiles + evaluates end-to-end against the live seam (render Flip/Sprite + audio Sound/Bus + cross-module const route all landed)")
	}
}

// ── (scope) src/pickups.fun PARSES — the structural fingerprint ──────────

// test_golden_assets_pickups_parses pins the live src/pickups.fun's structural
// fingerprint: it PARSES through the §06/§07 grammar — a well-formed module — and the
// declaration inventory counts hold exactly. Full end-to-end typecheck is proven
// separately by test_golden_assets_pickups_compiles_whole_example (now that the
// render Sprite/Flip and engine.audio surfaces have landed); this test keeps the
// parse-shape pin (the structural fingerprint the §19 bake reads) as its own focused
// proof. SKIPs loudly when the sibling checkout is absent.
@(test)
test_golden_assets_pickups_parses :: proc(t: ^testing.T) {
	source, ok := pickups_source()
	if !ok {
		return
	}
	ast, parse_err := stage_parse(stage_lex(source))
	testing.expect_value(t, parse_err, Parse_Error.None)
	if parse_err != .None {
		return
	}

	// pickups.fun's declaration inventory: ten imports (prelude, input, math, core,
	// world, render, audio, assets, list, and the whole-module `import assets` seam
	// handle — engine.input is the §14 §4 bindings fn's), one thing (Coin), one signal
	// (Taken), three behaviors (advance_spin, on_pickup, draw_coin), two fns (the §14
	// §4 empty bindings fn + setup), one pipeline (Pickups), one test. The counts are
	// pinned to the live source on purpose — when the spec evolves (the a522568 fix
	// added the engine.input import and the bindings fn, moving imports 9→10 and fns
	// 1→2), the counts change in lockstep; never loosen them to ranges.
	testing.expect_value(t, len(ast.imports), 10)
	testing.expect_value(t, len(ast.things), 1)
	testing.expect_value(t, len(ast.signals), 1)
	testing.expect_value(t, len(ast.behaviors), 3)
	testing.expect_value(t, len(ast.fns), 2)
	testing.expect_value(t, len(ast.pipelines), 1)
	testing.expect_value(t, len(ast.tests), 1)
	if parse_err == .None {
		log.infof("golden assets: src/pickups.fun parses (the structural fingerprint; whole-example typecheck is pinned by test_golden_assets_pickups_compiles_whole_example)")
	}
}

// ── golden-tree source readers (resolve-or-SKIP) ─────────────────────────

// assets_gen_fun_source reads the committed gen/assets.gen.fun seam bytes; ok =
// false (with a SKIP warning) when the sibling checkout is absent, matching the
// other goldens' resolve-or-skip discipline so a missing checkout warns loudly
// instead of silently testing nothing. It resolves through resolve_assets_gen_path
// (FUNPACK_ASSETS_GEN override, else the sibling default) — the same path the
// gen-emit byte-match golden reads.
assets_gen_fun_source :: proc() -> (source: string, ok: bool) {
	path := resolve_assets_gen_path()
	bytes, read_err := os.read_entire_file_from_path(path, context.temp_allocator)
	if read_err != nil {
		log.warnf(
			"SKIP golden assets seam: %s not found — set FUNPACK_ASSETS_GEN or check out funpack-spec as a sibling of the repo",
			path,
		)
		return "", false
	}
	return string(bytes), true
}

// pickups_source reads the live src/pickups.fun via the resolved assets tree; ok =
// false (with a SKIP warning) when the sibling checkout is absent. It joins
// src/pickups.fun under the assets-tree root (resolve_assets_dir) rather than going
// through read_project, because read_project walks the WHOLE §14 tree (the seam, the
// configs) — this test wants the single pickups source's parse, not the project read.
pickups_source :: proc() -> (source: string, ok: bool) {
	dir := resolve_assets_dir()
	if !os.is_dir(dir) {
		log.warnf(
			"SKIP golden assets pickups: %s not found — set FUNPACK_ASSETS_DIR or check out funpack-spec as a sibling of the repo",
			dir,
		)
		return "", false
	}
	path, _ := filepath.join({dir, "src", "pickups.fun"}, context.temp_allocator)
	bytes, read_err := os.read_entire_file_from_path(path, context.temp_allocator)
	if read_err != nil {
		log.warnf("SKIP golden assets pickups: %s unreadable", path)
		return "", false
	}
	return string(bytes), true
}

// pickups_path resolves the live src/pickups.fun DISK PATH (not its bytes) so
// run_project_pipeline can read it off disk alongside the live seam; ok = false (with
// a SKIP warning) when the sibling checkout is absent, matching pickups_source's
// resolve-or-skip discipline. It joins src/pickups.fun under the resolved assets-tree
// root — the path the §15 module name `pickups` derives from.
pickups_path :: proc() -> (path: string, ok: bool) {
	dir := resolve_assets_dir()
	if !os.is_dir(dir) {
		log.warnf(
			"SKIP golden assets pickups: %s not found — set FUNPACK_ASSETS_DIR or check out funpack-spec as a sibling of the repo",
			dir,
		)
		return "", false
	}
	joined, _ := filepath.join({dir, "src", "pickups.fun"}, context.temp_allocator)
	if !os.is_file(joined) {
		log.warnf("SKIP golden assets pickups: %s not found", joined)
		return "", false
	}
	return joined, true
}
