// funpack — the pure source → artifact compiler. No clock, no DB, no
// network in scope; emits the versioned Index Contract (spec §29).
package funpack

import "core:fmt"
import "core:os"

// main builds the funpack command tree and hands the argument vector to the
// framework's dispatch (cli_dispatch, cli_parse.odin): a usage error prints to
// stderr and exits 2, `--help` prints to stdout and exits 0, and a resolved verb
// runs and exits with ITS code. The dispatch never decides an exit number — each
// verb's run_X_verb core owns its {0, 1, 2} contract (§29 §3). The tree is built
// in the process allocator (lives until exit); transient parse state rides the
// temp arena.
main :: proc() {
	os.exit(cli_dispatch(build_funpack_cli(), os.args[1:]))
}

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
		// one-command path (funpack run) leads; the direct funpack-live invocation
		// (the runner the dist also ships) follows for when funpack is unavailable.
		fmt.printfln("  run it with: funpack run   (or directly: %s %s)", FUNPACK_LIVE_BIN, product.artifact_path)
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
	_, verdict := stage_build(root, mode, context.temp_allocator)
	if verdict.err != .None {
		eprint_build_refusal("funpack check", verdict)
		return 2
	}
	fmt.println("funpack check: clean")
	return 0
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
