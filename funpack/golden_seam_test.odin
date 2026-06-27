package funpack

import "core:log"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:testing"

arena_committed_seam_path :: proc(t: ^testing.T) -> (path: string, ok: bool) {
	dir := resolve_arena_dir()
	if !os.is_dir(dir) {
		log.warnf(
			"SKIP seam compare: %s not found — set FUNPACK_ARENA_DIR or ensure the in-repo fixture exists",
			dir,
		)
		return "", false
	}
	project, read_err, _ := read_project(dir)
	if read_err != .None {
		log.warnf("SKIP seam compare: arena tree at %s did not read (%v)", dir, read_err)
		return "", false
	}
	if !project.capabilities.levels || len(project.capabilities.expected_gen_out) != 1 {
		log.warnf(
			"SKIP seam compare: arena capabilities unexpected (levels=%v, %d expected gen outputs)",
			project.capabilities.levels,
			len(project.capabilities.expected_gen_out),
		)
		return "", false
	}
	committed, _ := filepath.join({dir, project.capabilities.expected_gen_out[0]}, context.temp_allocator)
	return committed, true
}

@(test)
test_seam_compare_none :: proc(t: ^testing.T) {
	committed_path, ok := arena_committed_seam_path(t)
	if !ok {
		return
	}
	emitted := emit_gen_fun(arena_seam(context.temp_allocator), context.temp_allocator)
	result := compare_seam(emitted, committed_path)
	testing.expect_value(t, result, Seam_Compare_Error.None)
	if result != .None {
		committed_bytes, read_err := os.read_entire_file_from_path(committed_path, context.temp_allocator)
		if read_err == nil {
			report_first_byte_diff(emitted, string(committed_bytes))
		}
		return
	}
	log.infof("seam compare: committed arena.gen.fun matches the fresh bake byte-for-byte (None, %d bytes)", len(emitted))
}

@(test)
test_seam_compare_stale :: proc(t: ^testing.T) {
	committed_path, ok := arena_committed_seam_path(t)
	if !ok {
		return
	}
	emitted := emit_gen_fun(arena_seam(context.temp_allocator), context.temp_allocator)
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
		log.infof("seam compare: byte-mutated emission diverges from committed arena.gen.fun at byte 0 (Stale_Seam)")
	}
}

@(test)
test_seam_compare_missing :: proc(t: ^testing.T) {
	root, ok := write_scratch_tree(t, "project numerics {\n  version = \"0.1.0\"\n}\n")
	if !ok {
		return
	}
	defer remove_scratch_tree(root)
	levels_dir := scratch_join({root, "levels"})
	if os.make_directory_all(levels_dir) != nil ||
	   os.write_entire_file(scratch_join({levels_dir, "arena.flvl"}), "level Arena 2d {\n}\n") != nil {
		log.warnf("SKIP seam compare missing: cannot write under %s", levels_dir)
		return
	}

	project, read_err, _ := read_project(root)
	testing.expect_value(t, read_err, Project_Error.None)
	if read_err != .None {
		return
	}
	testing.expect(t, project.capabilities.levels)
	testing.expect_value(t, len(project.capabilities.expected_gen_out), 1)
	if len(project.capabilities.expected_gen_out) != 1 {
		return
	}

	committed_path, _ := filepath.join({root, project.capabilities.expected_gen_out[0]}, context.temp_allocator)
	emitted := emit_gen_fun(arena_seam(context.temp_allocator), context.temp_allocator)
	result := compare_seam(emitted, committed_path)
	testing.expect_value(t, result, Seam_Compare_Error.Missing_Seam)
	if result == .Missing_Seam {
		log.infof("seam compare: capability-ON levels with absent gen/arena.gen.fun (Missing_Seam)")
	}
}

mutate_first_byte :: proc(s: string, allocator := context.allocator) -> string {
	if len(s) == 0 {
		return s
	}
	bytes := make([]u8, len(s), allocator)
	copy(bytes, transmute([]u8)s)
	bytes[0] = bytes[0] + 1
	return strings.string_from_ptr(raw_data(bytes), len(bytes))
}
