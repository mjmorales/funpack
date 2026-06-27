package funpack

import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:testing"

@(test)
test_const_cycle_intra_module_fails_closed :: proc(t: ^testing.T) {
	source := "let a: Int = b\n" + "let b: Int = a\n" + "test \"a const cycle fails closed\" {\n" + "  assert a == 0\n" + "}\n"

	report, err := run_test_pipeline(source)
	testing.expect_value(t, err, Pipeline_Error.None)
	if err != .None {
		return
	}
	testing.expect_value(t, report.passed, 0)
	testing.expect_value(t, report.failed, 1)
	testing.expect_value(t, report.exit_code, 1)
}

@(test)
test_const_cycle_self_reference_fails_closed :: proc(t: ^testing.T) {
	source := "let a: Int = a\n" + "test \"a self-referential const fails closed\" {\n" + "  assert a == 0\n" + "}\n"

	report, err := run_test_pipeline(source)
	testing.expect_value(t, err, Pipeline_Error.None)
	if err != .None {
		return
	}
	testing.expect_value(t, report.passed, 0)
	testing.expect_value(t, report.failed, 1)
}

@(test)
test_const_cycle_cross_module_fails_closed :: proc(t: ^testing.T) {
	mod_a := "@doc(\"cross-module const cycle, side A\")\n" + "import cyc_b\n" + "let a: Int = cyc_b.b\n" + "test \"a cross-module const cycle fails closed\" {\n" + "  assert cyc_b.b == 0\n" + "}\n"
	mod_b := "@doc(\"cross-module const cycle, side B\")\n" + "import cyc_a\n" + "let b: Int = cyc_a.a\n"

	path_a := write_cycle_scratch(t, "funpack_const_cycle_a.fun", mod_a)
	path_b := write_cycle_scratch(t, "funpack_const_cycle_b.fun", mod_b)
	if path_a == "" || path_b == "" {
		return
	}
	defer os.remove(path_a)
	defer os.remove(path_b)

	sources := []Source{{path = path_a, module = "cyc_a"}, {path = path_b, module = "cyc_b"}}
	report := run_project_pipeline(sources)

	testing.expect_value(t, report.index_err, Project_Pipeline_Error.None)
	testing.expect_value(t, report.module_err, Pipeline_Error.None)
	if report.module_err != .None {
		return
	}
	testing.expect_value(t, report.passed, 0)
	testing.expect_value(t, report.failed, 1)
}

@(test)
test_const_diamond_non_cycle_evaluates :: proc(t: ^testing.T) {
	mod_b := "@doc(\"diamond base\")\n" + "let y: Int = 7\n"
	mod_c := "@doc(\"diamond side C\")\n" + "import dia_b\n" + "let z: Int = dia_b.y\n"
	mod_a := "@doc(\"diamond side A\")\n" + "import dia_b\n" + "import dia_c\n" + "let x: Int = dia_b.y\n" + "test \"a shared const reached on two chains evaluates fine\" {\n" + "  assert x == 7\n" + "  assert dia_b.y == 7\n" + "  assert dia_c.z == 7\n" + "}\n"

	path_a := write_cycle_scratch(t, "funpack_const_diamond_a.fun", mod_a)
	path_b := write_cycle_scratch(t, "funpack_const_diamond_b.fun", mod_b)
	path_c := write_cycle_scratch(t, "funpack_const_diamond_c.fun", mod_c)
	if path_a == "" || path_b == "" || path_c == "" {
		return
	}
	defer os.remove(path_a)
	defer os.remove(path_b)
	defer os.remove(path_c)

	sources := []Source {
		{path = path_a, module = "dia_a"},
		{path = path_b, module = "dia_b"},
		{path = path_c, module = "dia_c"},
	}
	report := run_project_pipeline(sources)

	testing.expect_value(t, report.index_err, Project_Pipeline_Error.None)
	testing.expect_value(t, report.module_err, Pipeline_Error.None)
	if report.module_err != .None {
		return
	}
	testing.expect_value(t, report.passed, 3)
	testing.expect_value(t, report.failed, 0)
}

write_cycle_scratch :: proc(t: ^testing.T, basename: string, source: string) -> string {
	base := scratch_base()
	uniq := fmt.tprintf("%d_%s", scratch_seq(), basename)
	path, _ := filepath.join({base, uniq}, context.temp_allocator)
	if write_err := os.write_entire_file(path, transmute([]u8)source); write_err != nil {
		testing.expect(t, false, "could not write the const-cycle scratch source")
		return ""
	}
	return path
}
