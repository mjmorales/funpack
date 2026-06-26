// funpack — the pure source → artifact compiler. No clock, no DB, no
// network in scope; emits the versioned Index Contract (spec §29).
//
// This is a LIBRARY package: it holds the compiler verb CORES (run_build_verb,
// run_check_verb, run_test_verb, run_warden_verb, run_version_verb, run_fmt_verb)
// the unified CLI binary dispatches into. The single `main` lives in cmd/funpack,
// which composes this package's compiler subtree (build_funpack_compiler_subtree,
// cli_funpack.odin) with the runtime verbs and drives cli.cli_dispatch. Each verb
// core owns its documented {0, 1, 2} exit contract (§29 §3); the framework (the
// cli package) owns only the argument plumbing.
package funpack

import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:slice"
import "core:strings"

// Warden_Command is the closed `funpack warden` subcommand set (§29 §1) — one
// member per index query the sub-toolchain answers. The set is closed under
// the usual enum discipline: a new query is a new member plus its command node
// and handler in the funpack tree (cli_funpack.odin), never a stringly
// dispatched extra. The CLI framework parses the subcommand; this enum is the
// projection key warden_command_output dispatches the decoded index on.
Warden_Command :: enum {
	Find,
	Holes,
	Probes,
	Debt,
	Graph,
	Tags,
	Pipeline,
}

// run_warden_verb drives a recognized warden subcommand at the working
// directory. The body lives in the root-parameterized warden_verb_exit (the
// project_test_exit_code precedent) so the exit contract is unit-tested
// against temp roots without the process exit; main always queries ".".
// arg is the command's positional ("" when absent — the handler reads it from
// the resolved invocation, cli_funpack.odin); find is find's filter set (the
// zero query on every other command).
run_warden_verb :: proc(cmd: Warden_Command, arg: string, find: Warden_Find_Query) -> int {
	return warden_verb_exit(".", cmd, arg, find)
}

// warden_verb_exit is the warden exit contract over one query: EVERY
// subcommand's substrate is the full read_warden_index acquisition + §29 §2
// exact-match decode of the emitted `.funpack/index.ndjson` — never a mere
// file-exists probe — so a refused index (missing, schema-mismatched,
// malformed) is the SAME closed refusal on every command: its
// warden_refusal_message fix-it eprinted + exit 2, mirroring the usage tier.
// A whole-stream decode is exit 0. The warden has NO exit-1 tier — counted
// assertion failures belong to the test verb (§29 §3) and a refusal is never
// a counted failure — so the contract is exactly {0, 2}.
warden_verb_exit :: proc(root: string, cmd: Warden_Command, arg := "", find := Warden_Find_Query{}) -> int {
	index, refusal := read_warden_index(root, context.temp_allocator)
	if refusal.err != .None {
		fmt.eprintfln("funpack warden: %s", warden_refusal_message(refusal, context.temp_allocator))
		return 2
	}
	// The projection seam: print the command's pure NDJSON projection of the
	// decoded `index` through the SINGLE renderer (warden_command_output,
	// warden_output.odin — the same function the golden determinism sweeps
	// assert over, so the dispatch cannot drift from what the tests prove)
	// and exit 0 — an empty projection prints zero lines and is still
	// success. The projected bytes are temp-allocated and printed before
	// this frame returns, so the temp arena that owns the decoded index owns
	// the whole projection.
	fmt.print(warden_command_output(index, cmd, arg, find, context.temp_allocator))
	return 0
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
// counted failure. A refusal eprints build_refusal_message's deterministic
// line — the closed arm plus the module-qualified offender on the release
// arms — but the wording is advisory: the machine contract is exclusively the
// exit code (§29 §3).
run_build_verb :: proc(mode: Build_Mode) -> int {
	// §19-literal manifest regen (the operator-gated dev-regenerate path): under
	// FUNPACK_REGEN_GOLDEN the build first REGENERATES the committed
	// assets/assets.manifest from real source bytes, so the staleness gate then
	// passes — this is how an asset-source edit (or an importer-version bump)
	// re-pins the generated manifest the operator commits as a diff (§19 §3). A
	// regen that cannot bake (a missing image, an importer reject) refuses the
	// build before any product, exit 2, naming the offending asset.
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
		// A package: the Index Contract is its single product. No artifact means
		// nothing to run, so no signpost line.
		fmt.printfln("funpack build: wrote %s", product.index_path)
	} else {
		fmt.printfln("funpack build: wrote %s and %s", product.artifact_path, product.index_path)
		// A game build is runnable — point the newcomer at the runner so a fresh
		// `funpack build` is self-documenting about how to play the result. The
		// one-command path (funpack run, which rebuilds then launches) leads; the
		// play-the-prebuilt-artifact path (funpack live <artifact>) follows.
		fmt.printfln("  run it with: funpack run   (or play this artifact: funpack live %s)", product.artifact_path)
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
// none is written. A refusal eprints the same build_refusal_message line the
// build verb prints (the closed arm plus the module-qualified offender on the
// release arms; advisory wording, §29 §3 — the machine contract is the exit
// code). There is deliberately NO exit-1 tier: counted assertion
// failures belong to the test verb, and a compile error is never a counted
// failure — check refuses, it does not tally. root is a parameter (unlike
// run_build_verb's fixed ".") so the side-effect-free verb body is unit-tested
// end-to-end against temp trees; main always passes ".".
run_check_verb :: proc(root: string, mode: Build_Mode) -> int {
	verdict := check_project_verdict(root, mode)
	if verdict.err != .None {
		eprint_build_refusal("funpack check", verdict)
		return 2
	}
	fmt.println("funpack check: clean")
	return 0
}

// check_project_verdict is the PURE single-project adjudication seam both the
// single-project (run_check_verb) and recursive (run_check_recursive_verb) check
// faces share: it runs stage_build over one tree at `root`, discards the computed
// product bytes (check writes nothing), and returns ONLY the Build_Verdict — the
// closed Build_Error arm plus the module-qualified offender on the release arms,
// or .None for a clean tree. Factoring the adjudication out of run_check_verb is
// what lets the recursive driver loop the SAME judgment over N discovered roots
// without duplicating the check logic or rendering twice.
check_project_verdict :: proc(root: string, mode: Build_Mode) -> Build_Verdict {
	_, verdict := stage_build(root, mode, context.temp_allocator)
	return verdict
}

// FUNPACK_RECURSIVE_PRUNE_DIRS is the closed set of directory NAMES the recursive
// discovery walk never descends into: VCS metadata (.git), the build-output dir
// (.funpack — a check writes nothing, but a prior build's output is not a project
// tree), and the vendored-dependency root (packages, VENDOR_DIR — a deps walk owns
// it, and each packages/<dep>/ tree is a vendored project, not one to re-adjudicate).
// Pruning these keeps the sweep fast and never mis-reads a build-output or a vendored
// subtree as a standalone project.
FUNPACK_RECURSIVE_PRUNE_DIRS :: []string{".git", FUNPACK_BUILD_DIR, VENDOR_DIR}

// discover_project_roots walks the directory tree at `root` with the core:os
// breadth-first walker (Odin-first — no shell-out, no `find`, no process spawn)
// and returns every §14 project root under it: a directory P is a project iff
// P/funpack_configs is itself a directory. The returned roots are SORTED by path
// so the recursive verdict stream is byte-stable regardless of the filesystem's
// walk order. Pruning keeps the sweep correct: a discovered project's own subtree
// is NOT descended (projects do not nest — the first project on a path wins), and
// the FUNPACK_RECURSIVE_PRUNE_DIRS names (.git, .funpack, vendor roots) are
// skipped wholesale. The root itself is tested separately because the walker
// yields a start directory's children, never the start directory.
discover_project_roots :: proc(root: string, allocator := context.allocator) -> []string {
	// The spine shares the elements' lifetime: each clone lands in `allocator`, so
	// backing the dynamic array in the same allocator keeps the returned slice and
	// its strings on one lifetime rather than splitting across temp + caller.
	roots := make([dynamic]string, 0, 8, allocator)
	// The walker yields `root`'s children but not `root` itself, so adjudicate the
	// root as a project up front. A root that is itself a project is the whole
	// answer — projects do not nest, so its subtree is not swept for more.
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
			// A project's own subtree is not swept for nested projects.
			os.walker_skip_dir(&walker)
		}
	}
	sorted := roots[:]
	slice.sort(sorted)
	return sorted
}

// is_project_root reports whether `dir` is a §14 project root by the same rule
// read_project rejects against: it owns a funpack_configs/ child directory. A pure
// filesystem predicate (os.is_dir over the joined path) — the recursive discovery's
// single project-membership test, kept distinct from read_project so discovery
// never recompiles a tree just to learn it exists.
is_project_root :: proc(dir: string) -> bool {
	configs, _ := filepath.join({dir, "funpack_configs"}, context.temp_allocator)
	return os.is_dir(configs)
}

// run_check_recursive_verb is the multi-project face of check: it discovers
// every §14 project under `root` with the pure Odin
// walker (no `find`, no shell-out), adjudicates EACH through the SAME
// check_project_verdict seam the single-project verb uses, prints one verdict line
// per project (path + clean/failed + the failing project's refusal body), then an
// aggregate summary line — ALWAYS non-empty output, never a silent stream. The
// exit contract extends check's: 0 IFF every discovered project is clean; 2 if any
// project refuses (the failing project(s) named on their verdict line), and 2 with
// a dedicated message when `root` contains NO project at all (a no-op sweep is a
// usage error, not a silent success). The per-project judgment and its {0, 2}
// tiers are byte-unchanged from the single-project verb — recursive only aggregates.
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

// check_recursive_report is the PURE renderer the recursive verb prints: given the
// already-discovered (sorted) project roots and the build mode, it adjudicates each
// through check_project_verdict and returns the FULL output block — one
// "<root>: clean" / "<root>: failed — <refusal>" line per project in the given
// order, then the "funpack check: N projects, M clean, K failed" aggregate — plus
// the failed count. Splitting the renderer from the verb (the warden_command_output
// precedent) is what lets a test byte-pin the multi-project output, including the
// NAMED failing project, as a deterministic function of (roots, mode).
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

// eprint_build_refusal eprints a Build_Verdict refusal: a Compile_Failed arm
// carrying an inner Diagnostic renders the fix-criteria block (re-reading the
// failing module's source so render_diagnostic excerpts the offending line),
// while every other arm (Malformed_Tree, Holed_Declaration, Debug_Directive,
// Index_Failed, Asset_Bake_Failed) keeps its build_refusal_message line — those
// arms name their offender on that line, only the compile floor has a per-stage
// diagnostic. A Compile_Failed with no captured diagnostic (rule == "") falls
// back to build_refusal_message too, so the exit-2 refusal always prints
// something. The exit code (2) and the `<verb>:` framing are unchanged — the
// machine contract holds; the rendered diagnostic is the added human body.
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

// run_test_verb runs every source of the §14 project tree at the working
// directory through the MULTI-MODULE pipeline: every module types against ONE
// project-wide index, so a project whose modules import each other (the arena
// example — arena_game imports arena_world + the arena seam) types end-to-end.
// Exit codes honor §29 §3: 2 for a malformed tree, a failed index build, or any
// module's compile error (never a counted failure); 1 when assertions failed; 0
// when every assertion passed.
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
		// A module's compile error: render the inner fix-criteria Diagnostic (the
		// per-stage rejection's file:line:col: rule: message block) instead of the
		// bare Pipeline_Error name, so an agent's write→check→fix loop sees the
		// offending construct and the fix direction. The `funpack test: <path>:`
		// framing and the exit code (2) are unchanged — the machine contract holds;
		// the rendered diagnostic is the added human body.
		eprint_module_diagnostic("funpack test", report.failed_path, report.module_err, report.diagnostic)
		return 2
	}
	fmt.printfln("funpack test: %d passed, %d failed", report.passed, report.failed)
	// A failed assertion is exit 1 (never a compile error): the count line above is
	// the machine contract; here each failure renders its localized fix-criteria
	// body (test name, file:line, the assert expression, and for a ==/!= the
	// evaluated operands) to stderr so an agent's write→check→fix loop sees what
	// each side reduced to. The exit code (project_test_exit_code) is unchanged.
	eprint_assert_failures(report.failures)
	return project_test_exit_code(report)
}

// eprint_assert_failures renders every failed assert as its localized
// fix-criteria block to stderr, re-reading each failure's owning source file so
// render_assert_failure excerpts the offending assert line. A failure whose
// source cannot be re-read renders header-only (the empty excerpt), the
// fail-open form so the failed-count contract never hangs on a missing file.
eprint_assert_failures :: proc(failures: []Assert_Failure) {
	for failure in failures {
		source := ""
		if bytes, read_err := os.read_entire_file_from_path(failure.path, context.temp_allocator); read_err == nil {
			source = string(bytes)
		}
		fmt.eprintfln("funpack test: %s", render_assert_failure(failure, source, context.temp_allocator))
	}
}

// eprint_module_diagnostic eprints a module compile error as its rendered
// fix-criteria Diagnostic, falling back to the bare `<path>: <err>` line when no
// diagnostic was captured (rule == "") or the source cannot be re-read — the
// fail-open form so a compile error always prints SOMETHING actionable and the
// exit-2 contract never hangs on a missing excerpt. The Diagnostic's `path` is
// already the failing module's source path (set by run_project_pipeline), so the
// re-read here is the file render_diagnostic excerpts the offending line from.
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
