package funpack

import "base:intrinsics"
import "core:fmt"
import "core:log"
import "core:os"
import "core:path/filepath"
import "core:testing"

@(test)
test_parse_project_fcfg_happy :: proc(t: ^testing.T) {
	identity, err, _ := parse_project_fcfg("project numerics {\n  version = \"0.1.0\"\n}\n")
	testing.expect_value(t, err, Project_Error.None)
	testing.expect_value(t, identity.name, "numerics")
	testing.expect_value(t, identity.version, "0.1.0")
}

@(test)
test_parse_project_fcfg_leading_doc :: proc(t: ^testing.T) {
	content := "@doc(\"the numeric kernel\")\nproject numerics {\n  version = \"0.1.0\"\n}\n"
	identity, err, _ := parse_project_fcfg(content)
	testing.expect_value(t, err, Project_Error.None)
	testing.expect_value(t, identity.name, "numerics")
	testing.expect_value(t, identity.version, "0.1.0")
}

@(test)
test_parse_project_fcfg_extra_doc_and_key_same_identity :: proc(t: ^testing.T) {
	content := "project numerics {\n  @doc(\"version pin\")\n  version = \"0.1.0\"\n  edition = \"2026\"\n}\n"
	identity, err, _ := parse_project_fcfg(content)
	testing.expect_value(t, err, Project_Error.None)
	testing.expect_value(t, identity.name, "numerics")
	testing.expect_value(t, identity.version, "0.1.0")
}

@(test)
test_parse_project_fcfg_missing_label_rejected :: proc(t: ^testing.T) {
	_, err, _ := parse_project_fcfg("project {\n  version = \"0.1.0\"\n}\n")
	testing.expect_value(t, err, Project_Error.Malformed_Project_Fcfg)
}

@(test)
test_parse_project_fcfg_missing_version_rejected :: proc(t: ^testing.T) {
	_, err, _ := parse_project_fcfg("project numerics {\n}\n")
	testing.expect_value(t, err, Project_Error.Missing_Project_Version)
}

@(test)
test_parse_project_fcfg_key_without_eq_rejected :: proc(t: ^testing.T) {
	_, err, _ := parse_project_fcfg("project numerics {\n  version \"0.1.0\"\n}\n")
	testing.expect_value(t, err, Project_Error.Malformed_Project_Fcfg)
}

@(test)
test_parse_project_fcfg_control_flow_rejected :: proc(t: ^testing.T) {
	_, err, _ := parse_project_fcfg("project numerics {\n  version = \"0.1.0\"\n  if active { }\n}\n")
	testing.expect_value(t, err, Project_Error.Malformed_Project_Fcfg)
}

@(test)
test_parse_project_fcfg_expression_value_rejected :: proc(t: ^testing.T) {
	_, err, _ := parse_project_fcfg("project numerics {\n  version = 1 + 1\n}\n")
	testing.expect_value(t, err, Project_Error.Malformed_Project_Fcfg)
}

@(test)
test_parse_project_fcfg_use_reference_rejected :: proc(t: ^testing.T) {
	_, err, _ := parse_project_fcfg("use numerics.{X}\nproject numerics {\n  version = \"0.1.0\"\n}\n")
	testing.expect_value(t, err, Project_Error.Malformed_Project_Fcfg)
}

@(test)
test_parse_project_fcfg_empty_rejected :: proc(t: ^testing.T) {
	_, err, _ := parse_project_fcfg("")
	testing.expect_value(t, err, Project_Error.Malformed_Project_Fcfg)
}

@(test)
test_parse_project_fcfg_hyphen_label_detail :: proc(t: ^testing.T) {
	_, err, detail := parse_project_fcfg("project colony-sim {\n  version = \"0.1.0\"\n}\n")
	testing.expect_value(t, err, Project_Error.Malformed_Project_Fcfg)
	testing.expect_value(
		t,
		detail,
		"project.fcfg:1: project name must be a bare identifier (a lower-case or '_' start, then letters, digits, or '_'); the '-' after 'colony' is not allowed (spec §14 §4, §15)",
	)
}

@(test)
test_parse_project_fcfg_uppercase_label_detail :: proc(t: ^testing.T) {
	_, err, detail := parse_project_fcfg("project Colony {\n  version = \"0.1.0\"\n}\n")
	testing.expect_value(t, err, Project_Error.Malformed_Project_Fcfg)
	testing.expect_value(
		t,
		detail,
		"project.fcfg:1: project name must be a bare identifier (a lower-case or '_' start, then letters, digits, or '_') — 'Colony' is not (spec §14 §4, §15)",
	)
}

@(test)
test_parse_project_fcfg_dotted_label_detail :: proc(t: ^testing.T) {
	_, err, detail := parse_project_fcfg("project my.game {\n  version = \"0.1.0\"\n}\n")
	testing.expect_value(t, err, Project_Error.Malformed_Project_Fcfg)
	testing.expect_value(
		t,
		detail,
		"project.fcfg:1: project name must be a bare identifier (a lower-case or '_' start, then letters, digits, or '_'); the '.' after 'my' is not allowed (spec §14 §4, §15)",
	)
}

@(test)
test_parse_project_fcfg_underscore_label_accepted :: proc(t: ^testing.T) {
	identity, err, detail := parse_project_fcfg("project _scratch {\n  version = \"0.1.0\"\n}\n")
	testing.expect_value(t, err, Project_Error.None)
	testing.expect_value(t, identity.name, "_scratch")
	testing.expect_value(t, detail, "")
}

@(test)
test_is_lower_ident_charset :: proc(t: ^testing.T) {
	testing.expect(t, is_lower_ident("colony"))
	testing.expect(t, is_lower_ident("_scratch"))
	testing.expect(t, is_lower_ident("combat_melee2"))
	testing.expect(t, !is_lower_ident("Colony"))
	testing.expect(t, !is_lower_ident("2d"))
	testing.expect(t, !is_lower_ident(""))
}

@(test)
test_parse_project_fcfg_toml_section_detail :: proc(t: ^testing.T) {
	_, err, detail := parse_project_fcfg("[project]\nname = \"deepseed\"\nversion = \"0.1.0\"\n")
	testing.expect_value(t, err, Project_Error.Malformed_Project_Fcfg)
	testing.expect_value(
		t,
		detail,
		"project.fcfg:1:1: expected project <name> { version = \"...\" }, found '[' — a project.fcfg is one `project <name> { ... }` brace block, not a `[section]` header (spec §14 §1, §14 §2)",
	)
}

@(test)
test_parse_project_fcfg_bare_name_key_detail :: proc(t: ^testing.T) {
	_, err, detail := parse_project_fcfg("name = \"deepseed\"\nversion = \"0.1.0\"\n")
	testing.expect_value(t, err, Project_Error.Malformed_Project_Fcfg)
	testing.expect_value(
		t,
		detail,
		"project.fcfg:1:1: expected project <name> { version = \"...\" }, found 'name' — a project.fcfg is one `project <name> { ... }` block — the block label IS the package name (there is no `name =` key, and identity is not a TOML/INI section) (spec §14 §1, §14 §2)",
	)
}

@(test)
test_parse_project_fcfg_colon_assignment_detail :: proc(t: ^testing.T) {
	_, err, detail := parse_project_fcfg("project deepseed {\n  version: \"0.1.0\"\n}\n")
	testing.expect_value(t, err, Project_Error.Malformed_Project_Fcfg)
	testing.expect_value(
		t,
		detail,
		"project.fcfg:2:10: expected project <name> { version = \"...\" }, found ':' — an assignment binds with `=`, not `:` — write `version = \"...\"` (spec §14 §1, §14 §2)",
	)
}

@(test)
test_parse_project_fcfg_labelless_block_detail :: proc(t: ^testing.T) {
	_, err, detail := parse_project_fcfg("project { name = \"deepseed\" }\n")
	testing.expect_value(t, err, Project_Error.Malformed_Project_Fcfg)
	testing.expect_value(
		t,
		detail,
		"project.fcfg:1:9: expected project <name> { version = \"...\" }, found '{' — the block label is the package name — write `project <name> { ... }`, not a labelless `project { ... }` (spec §14 §1, §14 §2)",
	)
}

@(test)
test_parse_project_fcfg_empty_file_detail :: proc(t: ^testing.T) {
	_, err, detail := parse_project_fcfg("")
	testing.expect_value(t, err, Project_Error.Malformed_Project_Fcfg)
	testing.expect_value(
		t,
		detail,
		"project.fcfg:1:1: expected project <name> { version = \"...\" }, found end of input — a project.fcfg must declare exactly one `project <name> { ... }` block (spec §14 §1, §14 §2)",
	)
}

@(test)
test_parse_project_fcfg_missing_version_detail :: proc(t: ^testing.T) {
	_, err, detail := parse_project_fcfg("project deepseed {\n}\n")
	testing.expect_value(t, err, Project_Error.Missing_Project_Version)
	testing.expect_value(
		t,
		detail,
		"project.fcfg:1: project 'deepseed' is missing the required `version = \"...\"` key (spec §14 §1)",
	)
}

@(test)
test_parse_project_fcfg_non_string_value_detail :: proc(t: ^testing.T) {
	_, err, detail := parse_project_fcfg("project deepseed {\n  version = 1\n}\n")
	testing.expect_value(t, err, Project_Error.Malformed_Project_Fcfg)
	testing.expect_value(
		t,
		detail,
		"project.fcfg:2:13: expected project <name> { version = \"...\" }, found '1' — an assignment value is a double-quoted string literal (`version = \"0.1.0\"`) (spec §14 §1, §14 §2)",
	)
}

@(test)
test_cfg_token_col_recovers_column :: proc(t: ^testing.T) {
	content := "ab\ncde"
	testing.expect_value(t, cfg_token_col(content, 0), 1)
	testing.expect_value(t, cfg_token_col(content, 1), 2)
	testing.expect_value(t, cfg_token_col(content, 3), 1)
	testing.expect_value(t, cfg_token_col(content, 5), 3)
	testing.expect_value(t, cfg_token_col(content, 99), len(content) - 3 + 1)
}

@(test)
test_read_project_valid_tree :: proc(t: ^testing.T) {
	root, ok := write_scratch_tree(t, "project numerics {\n  version = \"0.1.0\"\n}\n")
	if !ok {
		return
	}
	defer remove_scratch_tree(root)

	project, err, _ := read_project(root)
	testing.expect_value(t, err, Project_Error.None)
	testing.expect_value(t, project.name, "numerics")
	testing.expect_value(t, project.version, "0.1.0")
	testing.expect(t, len(project.sources) > 0)
}

@(test)
test_read_project_malformed_tree_rejected :: proc(t: ^testing.T) {
	root, ok := write_scratch_tree(t, "project numerics {\n  version = \"0.1.0\"\n  while go { }\n}\n")
	if !ok {
		return
	}
	defer remove_scratch_tree(root)

	_, err, _ := read_project(root)
	testing.expect_value(t, err, Project_Error.Malformed_Project_Fcfg)
}

@(test)
test_read_project_missing_version_tree_rejected :: proc(t: ^testing.T) {
	root, ok := write_scratch_tree(t, "project numerics {\n}\n")
	if !ok {
		return
	}
	defer remove_scratch_tree(root)

	_, err, _ := read_project(root)
	testing.expect_value(t, err, Project_Error.Missing_Project_Version)
}

@(test)
test_read_project_missing_tree :: proc(t: ^testing.T) {
	_, err, _ := read_project("/nonexistent-funpack-project-root")
	testing.expect_value(t, err, Project_Error.Missing_Configs_Dir)
}

@(test)
test_derive_module_name_flat :: proc(t: ^testing.T) {
	module := derive_module_name("/proj/src", "/proj/src/numerics.fun")
	testing.expect_value(t, module, "numerics")
}

@(test)
test_derive_module_name_nested :: proc(t: ^testing.T) {
	module := derive_module_name("/proj/src", "/proj/src/combat/melee.fun")
	testing.expect_value(t, module, "combat.melee")
}

@(test)
test_read_project_nested_source_module :: proc(t: ^testing.T) {
	root, ok := write_scratch_tree_at(t, "project numerics {\n  version = \"0.1.0\"\n}\n", "combat/melee.fun")
	if !ok {
		return
	}
	defer remove_scratch_tree(root)

	project, err, _ := read_project(root)
	testing.expect_value(t, err, Project_Error.None)
	testing.expect_value(t, len(project.sources), 1)
	testing.expect_value(t, project.sources[0].module, "combat.melee")
}

@(test)
test_read_project_reserved_engine_root_rejected :: proc(t: ^testing.T) {
	root, ok := write_scratch_tree_at(t, "project numerics {\n  version = \"0.1.0\"\n}\n", "engine/math.fun")
	if !ok {
		return
	}
	defer remove_scratch_tree(root)

	_, err, _ := read_project(root)
	testing.expect_value(t, err, Project_Error.Reserved_Engine_Root)
}

@(test)
test_read_project_duplicate_module_rejected :: proc(t: ^testing.T) {
	root, ok := write_scratch_tree_multi(t, "project numerics {\n  version = \"0.1.0\"\n}\n", {"a.b.fun", "a/b.fun"})
	if !ok {
		return
	}
	defer remove_scratch_tree(root)

	_, err, _ := read_project(root)
	testing.expect_value(t, err, Project_Error.Duplicate_Module)
}

@(test)
test_read_project_distinct_modules_accepted :: proc(t: ^testing.T) {
	root, ok := write_scratch_tree_multi(t, "project numerics {\n  version = \"0.1.0\"\n}\n", {"a.fun", "b/a.fun"})
	if !ok {
		return
	}
	defer remove_scratch_tree(root)

	project, err, _ := read_project(root)
	testing.expect_value(t, err, Project_Error.None)
	testing.expect_value(t, len(project.sources), 2)
	if len(project.sources) == 2 {
		testing.expect_value(t, project.sources[0].module, "a")
		testing.expect_value(t, project.sources[1].module, "b.a")
	}
}

@(test)
test_read_project_reserved_engine_bare_root_rejected :: proc(t: ^testing.T) {
	root, ok := write_scratch_tree_at(t, "project numerics {\n  version = \"0.1.0\"\n}\n", "engine.fun")
	if !ok {
		return
	}
	defer remove_scratch_tree(root)

	_, err, _ := read_project(root)
	testing.expect_value(t, err, Project_Error.Reserved_Engine_Root)
}

PONG_ENTRYPOINTS :: "use pong.{Pong, bindings}\n\nentrypoint main {\n  pipeline = Pong\n  tick     = 60hz\n  logical  = 160x120\n  bindings = bindings\n}\n"

@(test)
test_parse_entrypoints_fcfg_happy :: proc(t: ^testing.T) {
	entrypoints, err := parse_entrypoints_fcfg(PONG_ENTRYPOINTS)
	testing.expect_value(t, err, Entrypoints_Error.None)
	testing.expect_value(t, entrypoints.use_module, "pong")
	testing.expect_value(t, len(entrypoints.use_members), 2)
	testing.expect_value(t, entrypoints.use_members[0], "Pong")
	testing.expect_value(t, entrypoints.use_members[1], "bindings")
	testing.expect_value(t, len(entrypoints.entrypoints), 1)
	if len(entrypoints.entrypoints) == 1 {
		block := entrypoints.entrypoints[0]
		testing.expect_value(t, block.name, "main")
		testing.expect_value(t, block.pipeline, "Pong")
		testing.expect_value(t, block.tick, "60hz")
		testing.expect_value(t, block.logical, "160x120")
		testing.expect_value(t, block.bindings, "bindings")
	}
}

@(test)
test_parse_entrypoints_fcfg_missing_key_rejected :: proc(t: ^testing.T) {
	content := "use pong.{Pong, bindings}\nentrypoint main {\n  pipeline = Pong\n  logical = 160x120\n  bindings = bindings\n}\n"
	_, err := parse_entrypoints_fcfg(content)
	testing.expect_value(t, err, Entrypoints_Error.Malformed_Entrypoints_Fcfg)
}

@(test)
test_parse_entrypoints_fcfg_missing_logical_rejected :: proc(t: ^testing.T) {
	content := "use pong.{Pong, bindings}\nentrypoint main {\n  pipeline = Pong\n  tick = 60hz\n  bindings = bindings\n}\n"
	_, err := parse_entrypoints_fcfg(content)
	testing.expect_value(t, err, Entrypoints_Error.Malformed_Entrypoints_Fcfg)
}

@(test)
test_parse_entrypoints_fcfg_no_use_rejected :: proc(t: ^testing.T) {
	content := "entrypoint main {\n  pipeline = Pong\n  tick = 60hz\n  bindings = bindings\n}\n"
	_, err := parse_entrypoints_fcfg(content)
	testing.expect_value(t, err, Entrypoints_Error.Malformed_Entrypoints_Fcfg)
}

@(test)
test_parse_entrypoints_fcfg_bad_tick_rejected :: proc(t: ^testing.T) {
	content := "use pong.{Pong, bindings}\nentrypoint main {\n  pipeline = Pong\n  tick = 60\n  bindings = bindings\n}\n"
	_, err := parse_entrypoints_fcfg(content)
	testing.expect_value(t, err, Entrypoints_Error.Malformed_Entrypoints_Fcfg)
}

@(test)
test_validate_entrypoints_pong_resolves :: proc(t: ^testing.T) {
	source, ok := pong_source()
	if !ok {
		return
	}
	ast, parse_err := stage_parse(stage_lex(source))
	testing.expect_value(t, parse_err, Parse_Error.None)

	entrypoints, cfg_err := parse_entrypoints_fcfg(pong_entrypoints_source())
	testing.expect_value(t, cfg_err, Entrypoints_Error.None)
	testing.expect_value(t, validate_entrypoints(entrypoints, ast), Entrypoints_Error.None)
}

@(test)
test_validate_entrypoints_dangling_pipeline_rejected :: proc(t: ^testing.T) {
	source, ok := pong_source()
	if !ok {
		return
	}
	ast, parse_err := stage_parse(stage_lex(source))
	testing.expect_value(t, parse_err, Parse_Error.None)

	content := "use pong.{Missing, bindings}\nentrypoint main {\n  pipeline = Missing\n  tick = 60hz\n  logical = 160x120\n  bindings = bindings\n}\n"
	entrypoints, cfg_err := parse_entrypoints_fcfg(content)
	testing.expect_value(t, cfg_err, Entrypoints_Error.None)
	testing.expect_value(t, validate_entrypoints(entrypoints, ast), Entrypoints_Error.Dangling_Reference)
}

@(test)
test_validate_entrypoints_dangling_bindings_rejected :: proc(t: ^testing.T) {
	source, ok := pong_source()
	if !ok {
		return
	}
	ast, parse_err := stage_parse(stage_lex(source))
	testing.expect_value(t, parse_err, Parse_Error.None)

	content := "use pong.{Pong, missing_bindings}\nentrypoint main {\n  pipeline = Pong\n  tick = 60hz\n  logical = 160x120\n  bindings = missing_bindings\n}\n"
	entrypoints, cfg_err := parse_entrypoints_fcfg(content)
	testing.expect_value(t, cfg_err, Entrypoints_Error.None)
	testing.expect_value(t, validate_entrypoints(entrypoints, ast), Entrypoints_Error.Dangling_Reference)
}

pong_entrypoints_source :: proc() -> string {
	dir := resolve_pong_dir()
	fcfg_path, _ := filepath.join({dir, "funpack_configs", "entrypoints.fcfg"}, context.temp_allocator)
	bytes, read_err := os.read_entire_file_from_path(fcfg_path, context.temp_allocator)
	if read_err != nil {
		return PONG_ENTRYPOINTS
	}
	return string(bytes)
}

@(test)
test_parse_builds_fcfg_happy :: proc(t: ^testing.T) {
	builds, err := parse_builds_fcfg("build native {\n  platform = desktop\n}\n")
	testing.expect_value(t, err, Project_Error.None)
	testing.expect_value(t, len(builds.targets), 1)
	if len(builds.targets) == 1 {
		testing.expect_value(t, builds.targets[0].name, "native")
		testing.expect_value(t, builds.targets[0].platform, Build_Platform.Desktop)
	}
}

@(test)
test_parse_builds_fcfg_wasm_and_multiple :: proc(t: ^testing.T) {
	content := "build native {\n  platform = desktop\n}\nbuild web {\n  platform = wasm\n}\n"
	builds, err := parse_builds_fcfg(content)
	testing.expect_value(t, err, Project_Error.None)
	testing.expect_value(t, len(builds.targets), 2)
	if len(builds.targets) == 2 {
		testing.expect_value(t, builds.targets[0].platform, Build_Platform.Desktop)
		testing.expect_value(t, builds.targets[1].name, "web")
		testing.expect_value(t, builds.targets[1].platform, Build_Platform.Wasm)
	}
}

@(test)
test_parse_builds_fcfg_empty_is_no_targets :: proc(t: ^testing.T) {
	builds, err := parse_builds_fcfg("")
	testing.expect_value(t, err, Project_Error.None)
	testing.expect_value(t, len(builds.targets), 0)
}

@(test)
test_parse_builds_fcfg_unknown_platform_rejected :: proc(t: ^testing.T) {
	_, err := parse_builds_fcfg("build native {\n  platform = console\n}\n")
	testing.expect_value(t, err, Project_Error.Malformed_Builds_Fcfg)
}

@(test)
test_parse_builds_fcfg_missing_label_rejected :: proc(t: ^testing.T) {
	_, err := parse_builds_fcfg("build {\n  platform = desktop\n}\n")
	testing.expect_value(t, err, Project_Error.Malformed_Builds_Fcfg)
}

@(test)
test_parse_builds_fcfg_missing_platform_rejected :: proc(t: ^testing.T) {
	_, err := parse_builds_fcfg("build native {\n}\n")
	testing.expect_value(t, err, Project_Error.Malformed_Builds_Fcfg)
}

@(test)
test_parse_builds_fcfg_non_grammar_construct_rejected :: proc(t: ^testing.T) {
	_, err := parse_builds_fcfg("use pong.{X}\nbuild native {\n  platform = desktop\n}\n")
	testing.expect_value(t, err, Project_Error.Malformed_Builds_Fcfg)
}

@(test)
test_parse_builds_fcfg_string_value_rejected :: proc(t: ^testing.T) {
	_, err := parse_builds_fcfg("build native {\n  platform = \"desktop\"\n}\n")
	testing.expect_value(t, err, Project_Error.Malformed_Builds_Fcfg)
}

@(test)
test_derive_tree_capabilities_all_off_no_subsystem_dirs :: proc(t: ^testing.T) {
	root, ok := write_scratch_tree(t, "project numerics {\n  version = \"0.1.0\"\n}\n")
	if !ok {
		return
	}
	defer remove_scratch_tree(root)

	caps := derive_tree_capabilities(root)
	testing.expect(t, !caps.levels)
	testing.expect(t, !caps.models)
	testing.expect(t, !caps.ui)
	testing.expect(t, !caps.assets)
	testing.expect_value(t, len(caps.expected_gen_out), 0)
}

@(test)
test_derive_tree_capabilities_present_empty_is_off :: proc(t: ^testing.T) {
	root, ok := write_scratch_tree(t, "project numerics {\n  version = \"0.1.0\"\n}\n")
	if !ok {
		return
	}
	defer remove_scratch_tree(root)
	levels_dir := scratch_join({root, "levels"})
	if os.make_directory_all(levels_dir) != nil {
		log.warnf("SKIP present-empty levels: cannot create %s", levels_dir)
		return
	}

	caps := derive_tree_capabilities(root)
	testing.expect(t, !caps.levels)
	testing.expect_value(t, len(caps.expected_gen_out), 0)
}

@(test)
test_derive_tree_capabilities_non_empty_levels_on :: proc(t: ^testing.T) {
	root, ok := write_scratch_tree(t, "project numerics {\n  version = \"0.1.0\"\n}\n")
	if !ok {
		return
	}
	defer remove_scratch_tree(root)
	levels_dir := scratch_join({root, "levels"})
	if os.make_directory_all(levels_dir) != nil ||
	   os.write_entire_file(scratch_join({levels_dir, "arena.flvl"}), "level Arena 2d {\n}\n") != nil {
		log.warnf("SKIP non-empty levels: cannot write under %s", levels_dir)
		return
	}

	caps := derive_tree_capabilities(root)
	testing.expect(t, caps.levels)
	testing.expect(t, !caps.models)
	testing.expect(t, !caps.ui)
	testing.expect(t, !caps.assets)
	testing.expect_value(t, len(caps.expected_gen_out), 1)
	if len(caps.expected_gen_out) == 1 {
		testing.expect_value(t, caps.expected_gen_out[0], "gen/arena.gen.fun")
	}
}

@(test)
test_arena_builds_and_capabilities :: proc(t: ^testing.T) {
	dir := resolve_arena_dir()
	if !os.is_dir(dir) {
		log.warnf(
			"SKIP arena builds+capabilities: %s not found — set FUNPACK_ARENA_DIR or ensure the in-repo fixture exists",
			dir,
		)
		return
	}

	project, err, _ := read_project(dir)
	testing.expect_value(t, err, Project_Error.None)
	if err != .None {
		return
	}

	testing.expect_value(t, len(project.builds.targets), 1)
	if len(project.builds.targets) == 1 {
		testing.expect_value(t, project.builds.targets[0].platform, Build_Platform.Desktop)
	}

	caps := project.capabilities
	testing.expect(t, caps.levels)
	testing.expect(t, !caps.models)
	testing.expect(t, !caps.ui)
	testing.expect(t, !caps.assets)
	testing.expect_value(t, len(caps.expected_gen_out), 1)
	if len(caps.expected_gen_out) == 1 {
		testing.expect_value(t, caps.expected_gen_out[0], "gen/arena.gen.fun")
	}
	log.infof(
		"arena §14.4: builds.fcfg → 1 desktop target; levels ON ⇒ gen/arena.gen.fun; models/ui/assets OFF",
	)
}

write_scratch_tree :: proc(t: ^testing.T, fcfg: string) -> (root: string, ok: bool) {
	return write_scratch_tree_at(t, fcfg, "x.fun")
}

write_scratch_tree_at :: proc(t: ^testing.T, fcfg: string, src_rel: string) -> (root: string, ok: bool) {
	return write_scratch_tree_multi(t, fcfg, {src_rel})
}

write_scratch_tree_multi :: proc(t: ^testing.T, fcfg: string, src_rels: []string) -> (root: string, ok: bool) {
	root = scratch_join({scratch_base(), fmt.tprintf("funpack-scratch-%d", scratch_seq())})
	remove_scratch_tree(root)
	configs := scratch_join({root, "funpack_configs"})
	if os.make_directory_all(configs) != nil {
		log.warnf("SKIP scratch tree: cannot create dirs under %s", root)
		return "", false
	}
	fcfg_path := scratch_join({configs, "project.fcfg"})
	if os.write_entire_file(fcfg_path, fcfg) != nil {
		remove_scratch_tree(root)
		log.warnf("SKIP scratch tree: cannot write files under %s", root)
		return "", false
	}
	for src_rel in src_rels {
		src_path := scratch_join({root, "src", src_rel})
		if os.make_directory_all(filepath.dir(src_path)) != nil ||
		   os.write_entire_file(src_path, "@doc(\"scratch\")\n") != nil {
			remove_scratch_tree(root)
			log.warnf("SKIP scratch tree: cannot write files under %s", root)
			return "", false
		}
	}
	return root, true
}

remove_scratch_tree :: proc(root: string) {
	os.remove_all(root)
}

scratch_join :: proc(elems: []string) -> string {
	joined, _ := filepath.join(elems, context.temp_allocator)
	return joined
}

scratch_base :: proc() -> string {
	dir, has := os.lookup_env("TMPDIR", context.temp_allocator)
	if has && dir != "" {
		return dir
	}
	return "/tmp"
}

@(private = "file")
scratch_counter: int

scratch_seq :: proc() -> int {
	return intrinsics.atomic_add(&scratch_counter, 1) + 1
}
