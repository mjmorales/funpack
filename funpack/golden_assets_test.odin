package funpack

import "core:log"
import "core:os"
import "core:path/filepath"
import "core:testing"

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

	bogus, bogus_err := stage_parse(stage_lex("import engine.assets.{shader}\n"))
	testing.expect_value(t, bogus_err, Parse_Error.None)
	_, reject := resolve_imports(bogus)
	testing.expect_value(t, reject, Type_Error.Unknown_Member)
}

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

	testing.expect_value(t, len(ast.lets), 3)
	testing.expect_value(t, len(ast.imports), 1)

	testing.expect_value(t, stage_gates(ast), Gate_Error.None)
	_, type_err := stage_typecheck(ast)
	testing.expect_value(t, type_err, Type_Error.None)
	if type_err == .None {
		log.infof("golden assets: committed gen/assets.gen.fun typechecks to None (3 typed handle constants against engine.assets)")
	}
}

@(test)
test_golden_assets_typed_constant_equals_checked_string :: proc(t: ^testing.T) {
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

@(test)
test_golden_assets_cross_module_const_route_live :: proc(t: ^testing.T) {
	if _, ok := assets_gen_fun_source(); !ok {
		return
	}
	seam_path := resolve_assets_gen_path()

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

	sources := []Source{
		{path = seam_path, module = "assets"},
		{path = consumer_path, module = "pickups_focus"},
	}
	report := run_project_pipeline(sources)

	testing.expect_value(t, report.index_err, Project_Pipeline_Error.None)
	testing.expect_value(t, report.module_err, Pipeline_Error.None)
	if report.module_err != .None {
		log.errorf("golden assets cross-module route: %s did not compile (%v)", report.failed_path, report.module_err)
		return
	}

	testing.expect_value(t, report.passed, 3)
	testing.expect_value(t, report.failed, 0)
	if report.passed == 3 && report.failed == 0 {
		log.infof(
			"golden assets: assets.coin_sfx == sound(\"coin_sfx\") (and coin/pickups) ride the REAL cross-module const route through run_project_pipeline against the live seam",
		)
	}
}

write_cross_module_consumer :: proc(t: ^testing.T, source: string) -> string {
	base := scratch_base()
	path, _ := filepath.join({base, "funpack_assets_cross_module_consumer.fun"}, context.temp_allocator)
	if write_err := os.write_entire_file(path, transmute([]u8)source); write_err != nil {
		testing.expect(t, false, "could not write the cross-module consumer scratch source")
		return ""
	}
	return path
}

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

	testing.expect_value(t, check_asset_reference(manifest, .Mesh, "coin"), Asset_Registry_Error.None)
	testing.expect_value(t, check_asset_reference(manifest, .Atlas, "pickups"), Asset_Registry_Error.None)
	testing.expect_value(t, check_asset_reference(manifest, .Sound, "coin_sfx"), Asset_Registry_Error.None)

	testing.expect_value(
		t,
		check_asset_reference(manifest, .Mesh, "krognid_torso"),
		Asset_Registry_Error.Unregistered_Name,
	)
	testing.expect_value(t, check_asset_reference(manifest, .Sound, "coin"), Asset_Registry_Error.Wrong_Kind)
	if check_asset_reference(manifest, .Mesh, "krognid_torso") == .Unregistered_Name {
		log.infof("golden assets: the closed registry rejects an unregistered name (Unregistered_Name) and a wrong-kind reference (Wrong_Kind) end-to-end")
	}
}

@(test)
test_golden_assets_pickups_compiles_whole_example :: proc(t: ^testing.T) {
	if _, ok := assets_gen_fun_source(); !ok {
		return
	}
	pickups_file, pickups_ok := pickups_path()
	if !pickups_ok {
		return
	}
	seam_path := resolve_assets_gen_path()

	sources := []Source{
		{path = seam_path, module = "assets"},
		{path = pickups_file, module = "pickups"},
	}
	report := run_project_pipeline(sources)

	testing.expect_value(t, report.index_err, Project_Pipeline_Error.None)
	testing.expect_value(t, report.module_err, Pipeline_Error.None)
	if report.module_err != .None {
		log.errorf("golden assets pickups whole-example: %s did not compile (%v)", report.failed_path, report.module_err)
		return
	}

	testing.expect_value(t, report.passed, 1)
	testing.expect_value(t, report.failed, 0)
	if report.passed == 1 && report.failed == 0 {
		log.infof("golden assets: src/pickups.fun compiles + evaluates end-to-end against the live seam (render Flip/Sprite + audio Sound/Bus + cross-module const route all landed)")
	}
}

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

assets_gen_fun_source :: proc() -> (source: string, ok: bool) {
	path := resolve_assets_gen_path()
	bytes, read_err := os.read_entire_file_from_path(path, context.temp_allocator)
	if read_err != nil {
		log.warnf(
			"SKIP golden assets seam: %s not found — set FUNPACK_ASSETS_GEN or ensure the in-repo fixture exists",
			path,
		)
		return "", false
	}
	return string(bytes), true
}

pickups_source :: proc() -> (source: string, ok: bool) {
	dir := resolve_assets_dir()
	if !os.is_dir(dir) {
		log.warnf(
			"SKIP golden assets pickups: %s not found — set FUNPACK_ASSETS_DIR or ensure the in-repo fixture exists",
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

pickups_path :: proc() -> (path: string, ok: bool) {
	dir := resolve_assets_dir()
	if !os.is_dir(dir) {
		log.warnf(
			"SKIP golden assets pickups: %s not found — set FUNPACK_ASSETS_DIR or ensure the in-repo fixture exists",
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
