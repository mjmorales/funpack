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
	case "warden":
		cmd, arg, find, cmd_ok := parse_warden_command(os.args[2:])
		if !cmd_ok {
			print_usage()
			os.exit(2)
		}
		os.exit(run_warden_verb(cmd, arg, find))
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

// Warden_Command is the closed `funpack warden` subcommand set (§29 §1) — one
// member per index query the sub-toolchain answers. The set is closed under
// the usual enum discipline: a new query is a new member plus its
// parse_warden_command name, never a stringly-dispatched extra.
Warden_Command :: enum {
	Find,
	Holes,
	Debt,
	Graph,
	Tags,
	Pipeline,
}

// parse_warden_command maps the warden verb's arguments to its Warden_Command
// plus the command's positional argument, mirroring parse_build_mode —
// argument text in, enum out, no host state. The subcommand name must be a
// recognized member; a missing name or an unknown name is a usage error
// (ok = false → usage + exit 2), so a typo never silently runs a different
// query. Arity is per-command: find owns the seam's flag extension — its
// tail tokens parse into the Warden_Find_Query through
// parse_warden_find_args (warden_find.odin), where the filterless bare
// `find` and an unknown --kind name are the same ok = false usage tier,
// adjudicated here at parse before any index read; graph admits one OPTIONAL
// positional (the incident-edge filter, `funpack warden graph
// [<qualified_name>]`); every other command stays strict zero-positional — a
// trailing argument there is the same usage error. Per-command flags extend
// this seam, not bypass it; arg is "" and find is the zero query whenever a
// command does not carry them.
parse_warden_command :: proc(args: []string) -> (cmd: Warden_Command, arg: string, find: Warden_Find_Query, ok: bool) {
	if len(args) == 0 {
		return .Find, "", {}, false
	}
	switch args[0] {
	case "find":
		cmd = .Find
	case "holes":
		cmd = .Holes
	case "debt":
		cmd = .Debt
	case "graph":
		cmd = .Graph
	case "tags":
		cmd = .Tags
	case "pipeline":
		cmd = .Pipeline
	case:
		return .Find, "", {}, false
	}
	if cmd == .Find {
		find, ok = parse_warden_find_args(args[1:])
		if !ok {
			return .Find, "", {}, false
		}
		return cmd, "", find, true
	}
	switch len(args) {
	case 1:
		return cmd, "", {}, true
	case 2:
		if cmd == .Graph {
			return cmd, args[1], {}, true
		}
	}
	return .Find, "", {}, false
}

// run_warden_verb drives a recognized warden subcommand at the working
// directory. The body lives in the root-parameterized warden_verb_exit (the
// project_test_exit_code precedent) so the exit contract is unit-tested
// against temp roots without the process exit; main always queries ".".
// arg is the command's parsed positional ("" when absent); find is find's
// parsed filter set (the zero query on every other command).
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
	// The per-command projection seam: each arm prints its pure NDJSON
	// projection of the decoded `index` and exits 0 — an empty projection
	// prints zero lines and is still success. Find, holes, and debt ride the
	// shared decl-filter core (warden_project.odin — find AND-composes its
	// parsed filters, warden_find.odin); graph emits its own edge-line shape
	// (warden_graph.odin); tags and pipeline re-project the project record's
	// registry join and recorded flat steps (warden_tags_pipeline.odin). The
	// projected bytes are temp-allocated and printed before this frame
	// returns, so the temp arena that owns the decoded index owns the whole
	// projection. arg is the command's parsed positional ("" when absent) —
	// today only graph admits one (its incident-edge filter); find carries
	// its parsed filter set instead (the zero query on every other command).
	switch cmd {
	case .Find:
		return warden_find_exit(index, find)
	case .Holes:
		fmt.print(warden_project_decls(index.decls, warden_holes_predicate, "", context.temp_allocator))
		return 0
	case .Debt:
		fmt.print(warden_project_decls(index.decls, warden_debt_predicate, "", context.temp_allocator))
		return 0
	case .Graph:
		return warden_graph_exit(index, arg)
	case .Tags:
		fmt.print(warden_tags_ndjson(index, context.temp_allocator))
		return 0
	case .Pipeline:
		fmt.print(warden_pipeline_ndjson(index, context.temp_allocator))
		return 0
	}
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
	fmt.eprintln("usage: funpack <test|build [--release]|check [--release]|warden <find [<name-query>] [--kind <kind>] [--gtag <tag>]|holes|debt|graph [<qualified_name>]|tags|pipeline>>")
}
