package funpack

import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:slice"
import "core:strings"

Warden_Command :: enum {
	Find,
	Holes,
	Probes,
	Debt,
	Graph,
	Tags,
	Pipeline,
}

run_warden_verb :: proc(cmd: Warden_Command, arg: string, find: Warden_Find_Query) -> int {
	return warden_verb_exit(".", cmd, arg, find)
}

warden_verb_exit :: proc(root: string, cmd: Warden_Command, arg := "", find := Warden_Find_Query{}) -> int {
	index, refusal := read_warden_index(root, context.temp_allocator)
	if refusal.err != .None {
		fmt.eprintfln("funpack warden: %s", warden_refusal_message(refusal, context.temp_allocator))
		return 2
	}
	fmt.print(warden_command_output(index, cmd, arg, find, context.temp_allocator))
	return 0
}

run_build_verb :: proc(mode: Build_Mode) -> int {
	if os.get_env("FUNPACK_REGEN_GOLDEN", context.temp_allocator) != "" {
		if regen_err, regen_detail := regen_asset_manifest("."); regen_err != .None {
			fmt.eprintfln("funpack build: %s", asset_bake_refusal_message(regen_err, regen_detail, context.temp_allocator))
			return 2
		}
	}
	product, verdict := stage_build(".", mode, context.temp_allocator)
	if verdict.err != .None {
		eprint_build_refusal("funpack build", verdict)
		return 2
	}
	if write_err := write_build_products(product, "."); write_err != .None {
		fmt.eprintfln("funpack build: %v", write_err)
		return 2
	}
	if product.artifact_path == "" {
		fmt.printfln("funpack build: wrote %s", product.index_path)
	} else {
		fmt.printfln("funpack build: wrote %s and %s", product.artifact_path, product.index_path)
		fmt.printfln("  run it with: funpack run   (or play this artifact: funpack live %s)", product.artifact_path)
	}
	return 0
}

run_check_verb :: proc(root: string, mode: Build_Mode) -> int {
	verdict := check_project_verdict(root, mode)
	if verdict.err != .None {
		eprint_build_refusal("funpack check", verdict)
		return 2
	}
	fmt.println("funpack check: clean")
	return 0
}

check_project_verdict :: proc(root: string, mode: Build_Mode) -> Build_Verdict {
	_, verdict := stage_build(root, mode, context.temp_allocator)
	return verdict
}

FUNPACK_RECURSIVE_PRUNE_DIRS :: []string{".git", FUNPACK_BUILD_DIR, VENDOR_DIR}

discover_project_roots :: proc(root: string, allocator := context.allocator) -> []string {
	roots := make([dynamic]string, 0, 8, allocator)
	if is_project_root(root) {
		append(&roots, strings.clone(root, allocator))
		return roots[:]
	}
	walker := os.walker_create(root)
	defer os.walker_destroy(&walker)
	for info in os.walker_walk(&walker) {
		if info.type != .Directory {
			continue
		}
		if slice.contains(FUNPACK_RECURSIVE_PRUNE_DIRS, info.name) {
			os.walker_skip_dir(&walker)
			continue
		}
		if is_project_root(info.fullpath) {
			append(&roots, strings.clone(info.fullpath, allocator))
			os.walker_skip_dir(&walker)
		}
	}
	sorted := roots[:]
	slice.sort(sorted)
	return sorted
}

is_project_root :: proc(dir: string) -> bool {
	configs, _ := filepath.join({dir, "funpack_configs"}, context.temp_allocator)
	return os.is_dir(configs)
}

run_check_recursive_verb :: proc(root: string, mode: Build_Mode) -> int {
	roots := discover_project_roots(root, context.temp_allocator)
	if len(roots) == 0 {
		fmt.eprintfln("funpack check: no funpack_configs project found under %s", root)
		return 2
	}
	output, failed := check_recursive_report(roots, mode, context.temp_allocator)
	fmt.print(output)
	return 2 if failed > 0 else 0
}

check_recursive_report :: proc(roots: []string, mode: Build_Mode, allocator := context.allocator) -> (output: string, failed: int) {
	b := strings.builder_make(allocator)
	for project_root in roots {
		verdict := check_project_verdict(project_root, mode)
		if verdict.err != .None {
			failed += 1
			fmt.sbprintfln(&b, "%s: failed — %s", project_root, build_refusal_message(verdict, allocator))
		} else {
			fmt.sbprintfln(&b, "%s: clean", project_root)
		}
	}
	clean := len(roots) - failed
	fmt.sbprintfln(&b, "funpack check: %d projects, %d clean, %d failed", len(roots), clean, failed)
	return strings.to_string(b), failed
}

eprint_build_refusal :: proc(verb: string, verdict: Build_Verdict) {
	if verdict.err == .Compile_Failed && verdict.diagnostic.rule != "" {
		source := ""
		if bytes, read_err := os.read_entire_file_from_path(verdict.diagnostic.path, context.temp_allocator); read_err == nil {
			source = string(bytes)
		}
		fmt.eprintfln("%s: %s", verb, render_diagnostic(verdict.diagnostic, source, context.temp_allocator))
		return
	}
	fmt.eprintfln("%s: %s", verb, build_refusal_message(verdict, context.temp_allocator))
}

run_test_verb :: proc() -> int {
	project, project_err, project_detail := read_project(".")
	if project_err != .None {
		fmt.eprintfln("funpack test: %s", project_refusal_message(project_err, project_detail, context.temp_allocator))
		return 2
	}
	report := run_project_pipeline(project_pipeline_sources(project))
	if report.index_err != .None {
		fmt.eprintfln("funpack test: %s: %v", report.failed_path, report.index_err)
		return 2
	}
	if report.module_err != .None {
		eprint_module_diagnostic("funpack test", report.failed_path, report.module_err, report.diagnostic)
		return 2
	}
	fmt.printfln("funpack test: %d passed, %d failed", report.passed, report.failed)
	eprint_assert_failures(report.failures)
	return project_test_exit_code(report)
}

eprint_assert_failures :: proc(failures: []Assert_Failure) {
	for failure in failures {
		source := ""
		if bytes, read_err := os.read_entire_file_from_path(failure.path, context.temp_allocator); read_err == nil {
			source = string(bytes)
		}
		fmt.eprintfln("funpack test: %s", render_assert_failure(failure, source, context.temp_allocator))
	}
}

eprint_module_diagnostic :: proc(verb: string, path: string, err: Pipeline_Error, diag: Diagnostic) {
	if diag.rule == "" {
		fmt.eprintfln("%s: %s: %v", verb, path, err)
		return
	}
	source := ""
	if bytes, read_err := os.read_entire_file_from_path(diag.path, context.temp_allocator); read_err == nil {
		source = string(bytes)
	}
	fmt.eprintfln("%s: %s", verb, render_diagnostic(diag, source, context.temp_allocator))
}

project_test_exit_code :: proc(report: Project_Report) -> int {
	if report.failed != 0 {
		return 1
	}
	return 0
}

test_exit_code :: proc(err: Pipeline_Error, report: Test_Report) -> int {
	if err != .None {
		return 2
	}
	if report.failed != 0 {
		return 1
	}
	return 0
}
