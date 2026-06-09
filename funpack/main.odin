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
		mode, mode_ok := parse_build_mode(os.args[2:])
		if !mode_ok {
			print_usage()
			os.exit(2)
		}
		os.exit(run_build_verb(mode))
	case "check":
		mode, mode_ok := parse_build_mode(os.args[2:])
		if !mode_ok {
			print_usage()
			os.exit(2)
		}
		os.exit(run_check_verb(".", mode))
	case:
		print_usage()
		os.exit(2)
	}
}

// parse_build_mode maps the build verb's arguments to its Build_Mode: no
// argument is Dev (the default — holes compile, §05), exactly `--release` is
// Release (the §29 §4 hole-ban mode). Any other argument is a usage error
// (ok = false → usage + exit 2), so a misspelled flag never silently builds in
// the wrong mode. The mode is a pure flag — argument text in, enum out — with
// no host state read.
parse_build_mode :: proc(args: []string) -> (mode: Build_Mode, ok: bool) {
	if len(args) == 0 {
		return .Dev, true
	}
	if len(args) == 1 && args[0] == "--release" {
		return .Release, true
	}
	return .Dev, false
}

// run_build_verb builds the §14 project tree at the working directory: it reads
// the tree, runs every module through the full checked pipeline against ONE
// project-wide module index, and on success writes the kind's products under
// `.funpack/` (build.odin) — a GAME writes BOTH the runtime artifact and the
// Index Contract NDJSON; a PACKAGE (no entrypoints.fcfg, §30 §7) writes the Index
// Contract NDJSON ONLY (no entrypoint ⇒ no runtime artifact). Exit codes honor
// the spec §29 §3 / §30 §7 contract: a malformed tree or ANY compile/gate failure
// is 2 and writes NO product (a compile error is never a counted failure); a host
// IO failure writing the products is also 2; a clean build that writes the kind's
// products is 0. The build verb has no assertion-failure tier — that is the test
// verb's — so it never returns 1. mode is the Dev/Release flag (`--release`):
// under Release a §05 typed hole anywhere in the tree is one more exit-2
// compile error (Holed_Declaration, §29 §4 — you cannot ship a hole), never a
// counted failure.
run_build_verb :: proc(mode: Build_Mode) -> int {
	product, build_err := stage_build(".", mode, context.temp_allocator)
	if build_err != .None {
		fmt.eprintfln("funpack build: %v", build_err)
		return 2
	}
	if write_err := write_build_products(product, "."); write_err != .None {
		fmt.eprintfln("funpack build: %v", write_err)
		return 2
	}
	if product.artifact_path == "" {
		// A package: the Index Contract is its single product.
		fmt.printfln("funpack build: wrote %s", product.index_path)
	} else {
		fmt.printfln("funpack build: wrote %s and %s", product.artifact_path, product.index_path)
	}
	return 0
}

// run_check_verb is the §29 §3 verdict-only verb: it adjudicates the §14
// project tree at `root` through the SAME pure seam the build verb compiles —
// stage_build, the full checked pipeline against one project-wide module index
// — and deletes the write half: the computed product bytes are discarded,
// write_build_products is never called, and NOTHING touches disk (no write, no
// directory, no deletion on any path — a pre-existing `.funpack/` stays
// byte-untouched). check recompiles; it never reads the emitted index, so a
// stale or absent index changes nothing about the verdict (`funpack warden` is
// the index projection; check is the source adjudication). The exit contract
// mirrors build's two tiers exactly: ANY Build_Error arm (Malformed_Tree,
// Compile_Failed, Index_Failed, or Holed_Declaration under --release, §29 §4)
// is 2; a clean tree is 0 with a one-line verdict naming no product path —
// none is written. There is deliberately NO exit-1 tier: counted assertion
// failures belong to the test verb, and a compile error is never a counted
// failure — check refuses, it does not tally. root is a parameter (unlike
// run_build_verb's fixed ".") so the side-effect-free verb body is unit-tested
// end-to-end against temp trees; main always passes ".".
run_check_verb :: proc(root: string, mode: Build_Mode) -> int {
	_, check_err := stage_build(root, mode, context.temp_allocator)
	if check_err != .None {
		fmt.eprintfln("funpack check: %v", check_err)
		return 2
	}
	fmt.println("funpack check: clean")
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
	fmt.eprintln("usage: funpack <test|build [--release]|check [--release]>")
}
