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
	case "build":
		os.exit(run_build_verb())
	case:
		print_usage()
		os.exit(2)
	}
}

// run_build_verb builds the §14 project tree at the working directory: it reads
// the tree, runs the source through the full checked pipeline, and on success
// writes BOTH the runtime artifact and the Index Contract NDJSON under
// `.funpack/` (build.odin). Exit codes honor the spec §29 §3 contract: a
// malformed tree or ANY compile/gate failure is 2 and writes NEITHER product (a
// compile error is never a counted failure); a host IO failure writing the
// products is also 2; a clean build that writes both products is 0. The build
// verb has no assertion-failure tier — that is the test verb's — so it never
// returns 1.
run_build_verb :: proc() -> int {
	product, build_err := stage_build(".", context.temp_allocator)
	if build_err != .None {
		fmt.eprintfln("funpack build: %v", build_err)
		return 2
	}
	if write_err := write_build_products(product, "."); write_err != .None {
		fmt.eprintfln("funpack build: %v", write_err)
		return 2
	}
	fmt.printfln("funpack build: wrote %s and %s", product.artifact_path, product.index_path)
	return 0
}

// run_test_verb runs every source of the §14 project tree at the working
// directory through the MULTI-MODULE pipeline: every module types against ONE
// project-wide index, so a project whose modules import each other (the arena
// example — arena_game imports arena_world + the arena seam) types end-to-end.
// Exit codes honor §29 §3: 2 for a malformed tree, a failed index build, or any
// module's compile error (never a counted failure); 1 when assertions failed; 0
// when every assertion passed.
run_test_verb :: proc() -> int {
	project, project_err := read_project(".")
	if project_err != .None {
		fmt.eprintfln("funpack test: %v", project_err)
		return 2
	}
	report := run_project_pipeline(project.sources)
	if report.index_err != .None {
		fmt.eprintfln("funpack test: %s: %v", report.failed_path, report.index_err)
		return 2
	}
	if report.module_err != .None {
		fmt.eprintfln("funpack test: %s: %v", report.failed_path, report.module_err)
		return 2
	}
	fmt.printfln("funpack test: %d passed, %d failed", report.passed, report.failed)
	return project_test_exit_code(report)
}

// project_test_exit_code is the CLI exit contract over a project run: a compile
// error (index or module) was already returned as 2 by the caller, so here a
// nonzero failed count is 1 and an all-pass is 0.
project_test_exit_code :: proc(report: Project_Report) -> int {
	if report.failed != 0 {
		return 1
	}
	return 0
}

// test_exit_code is the single-source exit contract: a compile error is 2 — never
// a counted failure — failed assertions are 1, all-pass is 0. It is the per-module
// projection of project_test_exit_code, kept as the unit the single-source
// pipeline maps a (Pipeline_Error, Test_Report) pair through.
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
	fmt.eprintln("usage: funpack <test|build>")
}
