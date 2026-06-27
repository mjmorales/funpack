package funpack

import "core:log"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:testing"

KROGNID_DIR_DEFAULT_REL :: "examples/krognid"

KROGNID_MODULE :: "krognid"

KROGNID_FILE_DOC :: "Generated rig seam for Krognid, baked from models/krognid.fpm: the bone skeleton and the part-to-slot mesh bindings the gameplay imports as the krognid module. Edit the .fpm script and re-bake, not this file."
KROGNID_SKELETON_DOC :: "Bone topology for Krognid: a standard humanoid skeleton. Generated from krognid.fpm — edit the script, not this file. Digest: 16 bones, 6 parts (10 after mirror), pivots verified, rest-bbox 24x20x68."
KROGNID_PARTS_DOC :: "Part meshes bound to bone slots. Left limbs are mirrored to the right at attach time. Generated from krognid.fpm."

krognid_fresh_bake :: proc(t: ^testing.T, allocator := context.allocator) -> Rig_Seam {
	unit, parse_err := fpm_parse(fpm_lex(KROGNID_RIG))
	testing.expect_value(t, parse_err, Fpm_Parse_Error.None)
	verdict := fpm_rig_verdict(unit)
	testing.expect_value(t, verdict.err, Fpm_Rig_Error.None)
	return rig_seam_of_unit(unit, KROGNID_MODULE, KROGNID_FILE_DOC, KROGNID_SKELETON_DOC, KROGNID_PARTS_DOC, allocator)
}

resolve_krognid_dir :: proc() -> string {
	return resolve_spec_dir("FUNPACK_KROGNID_DIR", KROGNID_DIR_DEFAULT_REL)
}

krognid_committed_seam_path :: proc(t: ^testing.T) -> (path: string, ok: bool) {
	dir := resolve_krognid_dir()
	if !os.is_dir(dir) {
		log.warnf(
			"SKIP krognid golden: %s not found — set FUNPACK_KROGNID_DIR or ensure the in-repo fixture exists",
			dir,
		)
		return "", false
	}
	project, read_err, _ := read_project(dir)
	if read_err != .None {
		log.warnf("SKIP krognid golden: krognid tree at %s did not read (%v)", dir, read_err)
		return "", false
	}
	if !project.capabilities.models || len(project.capabilities.expected_gen_out) != 1 {
		log.warnf(
			"SKIP krognid golden: krognid capabilities unexpected (models=%v, %d expected gen outputs)",
			project.capabilities.models,
			len(project.capabilities.expected_gen_out),
		)
		return "", false
	}
	committed, _ := filepath.join({dir, project.capabilities.expected_gen_out[0]}, context.temp_allocator)
	return committed, true
}

@(test)
test_krognid_golden_byte_exact :: proc(t: ^testing.T) {
	committed_path, ok := krognid_committed_seam_path(t)
	if !ok {
		return
	}
	golden_bytes, read_err := os.read_entire_file_from_path(committed_path, context.temp_allocator)
	if read_err != nil {
		log.warnf("SKIP krognid golden: committed seam %s unreadable", committed_path)
		return
	}
	golden := string(golden_bytes)

	emitted := emit_rig_seam(krognid_fresh_bake(t, context.temp_allocator), context.temp_allocator)

	testing.expect_value(t, len(emitted), len(golden))
	testing.expect(t, emitted == golden)
	if emitted != golden {
		report_first_byte_diff(emitted, golden)
		return
	}
	log.infof("krognid golden: krognid.gen.fun reproduces the exemplar byte-for-byte (%d bytes)", len(emitted))
}

@(test)
test_krognid_seam_compare_stale :: proc(t: ^testing.T) {
	committed_path, ok := krognid_committed_seam_path(t)
	if !ok {
		return
	}
	emitted := emit_rig_seam(krognid_fresh_bake(t, context.temp_allocator), context.temp_allocator)
	mutated := mutate_first_byte(emitted, context.temp_allocator)
	testing.expect(t, mutated != emitted)

	result := compare_seam(mutated, committed_path)
	testing.expect_value(t, result, Seam_Compare_Error.Stale_Seam)

	committed_bytes, read_err := os.read_entire_file_from_path(committed_path, context.temp_allocator)
	testing.expect(t, read_err == nil)
	if read_err == nil {
		testing.expect_value(t, first_byte_diff_index(mutated, string(committed_bytes)), 0)
	}
	if result == .Stale_Seam {
		log.infof("krognid seam compare: byte-mutated bake diverges from committed krognid.gen.fun at byte 0 (Stale_Seam)")
	}
}

@(test)
test_krognid_seam_compare_none :: proc(t: ^testing.T) {
	committed_path, ok := krognid_committed_seam_path(t)
	if !ok {
		return
	}
	emitted := emit_rig_seam(krognid_fresh_bake(t, context.temp_allocator), context.temp_allocator)
	result := compare_seam(emitted, committed_path)
	testing.expect_value(t, result, Seam_Compare_Error.None)
	if result != .None {
		committed_bytes, cerr := os.read_entire_file_from_path(committed_path, context.temp_allocator)
		if cerr == nil {
			report_first_byte_diff(emitted, string(committed_bytes))
		}
	}
}

@(test)
test_krognid_double_emit_identical :: proc(t: ^testing.T) {
	first := emit_rig_seam(krognid_fresh_bake(t, context.temp_allocator), context.temp_allocator)
	second := emit_rig_seam(krognid_fresh_bake(t, context.temp_allocator), context.temp_allocator)
	testing.expect(t, first == second)
	testing.expect_value(t, len(first), len(second))
	if first == second {
		log.infof("krognid double emit: two krognid bakes are byte-identical (deterministic emit, %d bytes)", len(first))
	}
}

@(test)
test_krognid_seam_projection_derives_slots :: proc(t: ^testing.T) {
	seam := krognid_fresh_bake(t, context.temp_allocator)
	testing.expect_value(t, seam.skeleton.name, "krognid_skeleton")
	testing.expect_value(t, seam.skeleton.factory, "humanoid")
	testing.expect_value(t, seam.parts.name, "krognid_parts")
	testing.expect_value(t, len(seam.parts.binds), 6)
	expected := [6]Rig_Slot_Bind {
		{slot = "Torso", mesh = "krognid_torso"},
		{slot = "Head", mesh = "krognid_head"},
		{slot = "LUpperArm", mesh = "krognid_upper_arm"},
		{slot = "LLowerArm", mesh = "krognid_lower_arm"},
		{slot = "LUpperLeg", mesh = "krognid_upper_leg"},
		{slot = "LLowerLeg", mesh = "krognid_lower_leg"},
	}
	for want, i in expected {
		if i >= len(seam.parts.binds) {
			break
		}
		testing.expect_value(t, seam.parts.binds[i].slot, want.slot)
		testing.expect_value(t, seam.parts.binds[i].mesh, want.mesh)
	}
	testing.expect(t, seam.parts.has_mirror, "krognid binds end in a mirror")
	testing.expect_value(t, seam.parts.mirror.from, "L")
	testing.expect_value(t, seam.parts.mirror.to, "R")
}

KROGNID_EVALUABLE_ASSERTS :: 6

@(test)
test_krognid_project_reads_and_joins_seam :: proc(t: ^testing.T) {
	dir := resolve_krognid_dir()
	if !os.is_dir(dir) {
		log.warnf(
			"SKIP krognid project: %s not found — set FUNPACK_KROGNID_DIR or ensure the in-repo fixture exists",
			dir,
		)
		return
	}
	project, read_err, _ := read_project(dir)
	testing.expect_value(t, read_err, Project_Error.None)
	if read_err != .None {
		return
	}

	testing.expect(t, project.capabilities.models, "krognid models capability is ON")

	seam_source, has_seam := find_source_module(project.sources, "krognid")
	_, has_stroll := find_source_module(project.sources, "stroll")
	testing.expect(t, has_seam, "the gen/krognid.gen.fun seam joined as module `krognid`")
	testing.expect(t, has_stroll, "src/stroll.fun discovered as module `stroll`")

	modules := make([]string, len(project.sources), context.temp_allocator)
	asts := make([]Ast, len(project.sources), context.temp_allocator)
	for src, i in project.sources {
		bytes, _ := os.read_entire_file_from_path(src.path, context.temp_allocator)
		ast, _ := stage_parse(stage_lex(string(bytes)))
		modules[i] = src.module
		asts[i] = ast
	}
	index := build_module_index_typed(modules, asts)

	for module, i in modules {
		if module == "stroll" {
			testing.expect(t, asts[i].module_doc != "", "stroll module doc lands")
			testing.expect(
				t,
				strings.has_prefix(asts[i].module_doc, "Walk a rigged Krognid around a field"),
			)
		}
	}

	seam_bytes, seam_read := os.read_entire_file_from_path(seam_source.path, context.temp_allocator)
	testing.expect(t, seam_read == nil, "the committed seam is readable")
	if seam_read != nil {
		return
	}
	seam_report, seam_err := run_module_pipeline(string(seam_bytes), index)
	testing.expect_value(t, seam_err, Pipeline_Error.None)
	testing.expect_value(t, seam_report.failed, 0)
	if seam_err == .None {
		log.infof(
			"krognid project: gen/krognid.gen.fun joined the source set as module `krognid` and clears the compile pipeline against engine.anim + engine.assets",
		)
	}
}

@(test)
test_krognid_whole_tree_green :: proc(t: ^testing.T) {
	dir := resolve_krognid_dir()
	if !os.is_dir(dir) {
		log.warnf(
			"SKIP krognid whole-tree: %s not found — set FUNPACK_KROGNID_DIR or ensure the in-repo fixture exists",
			dir,
		)
		return
	}
	project, read_err, _ := read_project(dir)
	testing.expect_value(t, read_err, Project_Error.None)
	if read_err != .None {
		return
	}

	report := run_project_pipeline(project.sources)

	testing.expect_value(t, report.index_err, Project_Pipeline_Error.None)
	testing.expect_value(t, report.module_err, Pipeline_Error.None)
	if report.module_err != .None {
		log.errorf("krognid whole-tree: %s did not compile (%v)", report.failed_path, report.module_err)
		return
	}

	testing.expect_value(t, report.passed, KROGNID_EVALUABLE_ASSERTS)
	log.infof(
		"krognid whole-tree: the full krognid project (gen/krognid.gen.fun seam + stroll) types and clears end-to-end; the %d funpack-evaluable inline asserts pass (the read_drive engine-value assert is the runtime's, per the arena/yard split)",
		report.passed,
	)
}

@(test)
test_resolve_krognid_dir_is_absolute :: proc(t: ^testing.T) {
	testing.expect(t, filepath.is_abs(resolve_krognid_dir()))
}
