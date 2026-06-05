// funpack — the pure source → artifact compiler. No clock, no DB, no
// network in scope; emits the versioned Index Contract (spec §29).
package funpack

import "core:fmt"
import "core:os"

main :: proc() {
	if len(os.args) < 2 {
		print_usage()
		os.exit(2)
	}
	switch os.args[1] {
	case "test":
		os.exit(run_test_verb())
	case:
		print_usage()
		os.exit(2)
	}
}

// run_test_verb runs every source of the §14 project tree at the
// working directory through the pipeline. Exit codes: 2 for a
// malformed tree or a compile error, 1 when assertions failed, 0 when
// every assertion passed.
run_test_verb :: proc() -> int {
	project, project_err := read_project(".")
	if project_err != .None {
		fmt.eprintfln("funpack test: %v", project_err)
		return 2
	}
	total := Test_Report{}
	for source_path in project.sources {
		source_bytes, read_err := os.read_entire_file_from_path(source_path, context.temp_allocator)
		if read_err != nil {
			fmt.eprintfln("funpack test: cannot read %s", source_path)
			return 2
		}
		report, err := run_test_pipeline(string(source_bytes))
		if err != .None {
			fmt.eprintfln("funpack test: %s: %v", source_path, err)
			return test_exit_code(err, report)
		}
		total.passed += report.passed
		total.failed += report.failed
	}
	fmt.printfln("funpack test: %d passed, %d failed", total.passed, total.failed)
	return test_exit_code(.None, total)
}

// test_exit_code is the CLI exit contract: a compile error is 2 — never
// a counted failure — failed assertions are 1, all-pass is 0.
test_exit_code :: proc(err: Pipeline_Error, report: Test_Report) -> int {
	if err != .None {
		return 2
	}
	if report.failed != 0 {
		return 1
	}
	return 0
}

print_usage :: proc() {
	fmt.eprintln("usage: funpack test")
}
