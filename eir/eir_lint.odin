package eir

import "../cli"
import vmem "core:mem/virtual"
import "core:fmt"
import "core:os"
import "core:strings"

Lint :: struct {
	name:  string,
	short: string,
	long:  string,
	flags: []cli.Cli_Flag,
	args:  cli.Cli_Args,
	run:   cli.Cli_Run,
}

lint_registry := []Lint {
	{
		name = "dup",
		short = "Report Type-1/Type-2 AST clones in the source tree (DRY checker)",
		long = "Walk the Odin/funpack source tree from the optional [root] (default cwd) and report duplicated AST subtrees — Type-1 exact and Type-2 renamed clones — following the dup_class doctrine. Prints a leverage-ranked GNU-style diagnostic stream (`file:line:col: warning: ... [dup]`, extra sites as note: lines) by default, or --json for a byte-stable diagnostic array an agent can rank to the highest-leverage dedup target.",
		flags = []cli.Cli_Flag {
			{
				name = "exclude",
				kind = .String,
				usage = "Comma-separated glob list of paths to skip (e.g. 'cmd/funpack/mcp/corpus/,*.gen.odin')",
			},
			{
				name = "min-nodes",
				kind = .Int,
				usage = "Subtree node-count floor below which a clone class is dropped as noise",
				default = DEFAULT_MIN_NODES,
			},
			{
				name = "fold-literals",
				kind = .Bool,
				usage = "Collapse every literal to one token so constant-only differences collide",
			},
			{
				name = "json",
				kind = .Bool,
				usage = "Emit the ranked clones as a byte-stable diagnostic JSON array instead of the human stream",
			},
			{
				name = "baseline",
				kind = .String,
				usage = "Path to the committed clone-debt baseline; with it set, dup runs as a ratchet gate (exit 1 on debt above baseline)",
			},
			{
				name = "update-baseline",
				kind = .Bool,
				usage = "With --baseline, re-snapshot the current clone debt to the baseline file and exit 0 (the monotone-tighten path)",
			},
		},
		args = cli.cli_range_args(0, 1),
		run = run_dup_lint,
	},
	{
		name = "near",
		short = "Report Type-3 near-miss (gapped/parameterized) clones as ranked declaration pairs",
		long = "Walk the Odin/funpack source tree from the optional [root] (default cwd) and report NEAR-MISS clones — top-level declarations whose canonical subtree sets overlap at or above --similarity (default 80%) — on a surface SEPARATE from the exact dup tier. A pair is two declarations sharing most of their structure but diverging in a few statements (the gapped/parameterized copy exact hashing cannot collapse); exact whole-declaration clones are excluded, since those belong to `eir dup`. Prints a similarity-ranked GNU-style diagnostic stream (`file:line:col: warning: ... [near]`, the counterpart as a note: line) by default, or --json for a byte-stable diagnostic array.",
		flags = []cli.Cli_Flag {
			{
				name = "exclude",
				kind = .String,
				usage = "Comma-separated glob list of paths to skip (e.g. 'cmd/funpack/mcp/corpus/,*.gen.odin')",
			},
			{
				name = "min-nodes",
				kind = .Int,
				usage = "Whole-declaration node-count floor below which a declaration is not a near-miss candidate",
				default = NEAR_DEFAULT_MIN_NODES,
			},
			{
				name = "similarity",
				kind = .Int,
				usage = "Similarity cutoff in percent [1,100]; a declaration pair at or above it is reported",
				default = NEAR_DEFAULT_SIMILARITY,
			},
			{
				name = "fold-literals",
				kind = .Bool,
				usage = "Collapse every literal to one token so constant-only differences collide",
			},
			{
				name = "json",
				kind = .Bool,
				usage = "Emit the ranked near-miss pairs as a byte-stable diagnostic JSON array instead of the human stream",
			},
		},
		args = cli.cli_range_args(0, 1),
		run = run_near_lint,
	},
	{
		name = "dead",
		short = "Report dead (unreferenced) file-private package-level declarations",
		long = "Walk the Odin/funpack source tree from the optional [root] (default cwd) and report every `@(private=\"file\")` package-level declaration that nothing in its file references — definitively dead code, since a file-private declaration is reachable only from its own file. Odin's -vet does not flag an unused file-private proc/type/const, so this closes that gap. Prints a GNU-style diagnostic stream (`file:line:col: warning: ... [dead]`) by default, or --json for a byte-stable diagnostic array. The analysis is conservative (any ambiguous reference counts as a use), so it under-reports rather than condemn live code.",
		flags = []cli.Cli_Flag {
			{
				name = "exclude",
				kind = .String,
				usage = "Comma-separated glob list of paths to skip (e.g. 'cmd/funpack/mcp/corpus/,*.gen.odin')",
			},
			{
				name = "json",
				kind = .Bool,
				usage = "Emit the dead declarations as a byte-stable diagnostic JSON array instead of the human stream",
			},
		},
		args = cli.cli_range_args(0, 1),
		run = run_dead_lint,
	},
	{
		name = "comments",
		short = "Gate per-file comment volume against a hard budget — comments are debt, encode intent in names/types/tests",
		long = "Walk the Odin/funpack source tree from the optional [root] (default cwd) and report every file whose comment-line count exceeds the per-file budget (--max-comments, default 5). Comments poison agents: they consume context, drift out of sync with the code, and seed hallucinations, so the standard is near-zero — intent belongs in hyperdescriptive names, types, and tests, not prose. Every comment line counts (doc/lead blocks included; only `//+`-prefixed build constraints are exempt). Exits 1 when any file is over budget, 0 when the tree is clean. Prints a GNU-style diagnostic stream (`file:line:col: error: ... [comments]`) heaviest-file-first, or --json for a byte-stable diagnostic array.",
		flags = []cli.Cli_Flag {
			{
				name = "exclude",
				kind = .String,
				usage = "Comma-separated glob list of paths to skip (e.g. 'cmd/funpack/mcp/corpus/,*.gen.odin')",
			},
			{
				name = "max-comments",
				kind = .Int,
				usage = "Per-file comment-line budget; a file above it is flagged (the dial toward zero)",
				default = DEFAULT_MAX_COMMENTS_PER_FILE,
			},
			{
				name = "json",
				kind = .Bool,
				usage = "Emit the over-budget files as a byte-stable diagnostic JSON array instead of the human stream",
			},
		},
		args = cli.cli_range_args(0, 1),
		run = run_comments_lint,
	},
}

build_lint_subtree :: proc(allocator := context.allocator) -> []^cli.Cli_Command {
	nodes := make([dynamic]^cli.Cli_Command, 0, len(lint_registry), allocator)
	for lint in lint_registry {
		append(
			&nodes,
			cli.cli_new_command(
				cli.Cli_Command {
					use = lint.name,
					short = lint.short,
					long = lint.long,
					flags = lint.flags,
					args = lint.args,
					run = lint.run,
				},
				allocator,
			),
		)
	}
	return nodes[:]
}

run_dup_lint :: proc(inv: ^cli.Cli_Invocation) -> int {
	arena: vmem.Arena
	if arena_err := vmem.arena_init_growing(&arena); arena_err != .None {
		fmt.eprintln("eir dup: cannot initialize the scan arena")
		return 2
	}
	defer vmem.arena_destroy(&arena)
	scan := vmem.arena_allocator(&arena)

	options := Dup_Options {
		min_nodes     = cli.cli_flag_int(inv, "min-nodes"),
		fold_literals = cli.cli_flag_bool(inv, "fold-literals"),
	}

	result, excludes, ok := load_lint_sources(
		"dup",
		lint_root(inv),
		cli.cli_flag_string(inv, "exclude"),
		scan,
	)
	if !ok {
		return 2
	}

	classes := find_clones(result, options, scan)

	if baseline_path := cli.cli_flag_string(inv, "baseline"); baseline_path != "" {
		return run_dup_gate(
			baseline_path,
			cli.cli_flag_bool(inv, "update-baseline"),
			classes,
			options,
			excludes,
			scan,
		)
	}

	diags := dup_diagnostics(classes, .Warning, scan)
	if cli.cli_flag_bool(inv, "json") {
		fmt.println(render_diagnostics_json(diags, scan))
	} else {
		fmt.print(render_diagnostics_human(diags, scan))
	}
	return 0
}

@(private = "file")
run_dup_gate :: proc(
	path: string,
	update: bool,
	classes: []Clone_Class,
	opts: Dup_Options,
	excludes: []string,
	allocator := context.allocator,
) -> int {
	if update {
		baseline := build_baseline(classes, opts, excludes, allocator)
		body := render_baseline_json(baseline, allocator)
		if write_err := os.write_entire_file(path, transmute([]byte)body); write_err != nil {
			fmt.eprintfln("eir dup: cannot write baseline %q", path)
			return 2
		}
		fmt.eprintfln(
			"eir dup: wrote baseline %q (%d clone classes, total dedup_value %d)",
			path,
			len(baseline.classes),
			baseline.total_dedup_value,
		)
		return 0
	}

	data, read_err := os.read_entire_file(path, allocator)
	if read_err != nil {
		fmt.eprintfln(
			"eir dup: cannot read baseline %q (run with --update-baseline to create it)",
			path,
		)
		return 2
	}
	baseline, parse_ok := parse_baseline(string(data), allocator)
	if !parse_ok {
		fmt.eprintfln(
			"eir dup: baseline %q is malformed or a newer schema; re-create it with --update-baseline",
			path,
		)
		return 2
	}
	if !baseline_scan_matches(baseline, opts, excludes) {
		fmt.eprintfln(
			"eir dup: scan options differ from baseline %q (min-nodes/fold-literals/exclude); re-create it with --update-baseline",
			path,
		)
		return 2
	}

	verdict := compare_baseline(baseline, classes, opts, excludes, allocator)
	if verdict.regressed {
		fmt.eprint(render_gate_failure(verdict, allocator))
		return 1
	}
	fmt.eprintfln(
		"eir dup: clone debt within baseline (total dedup_value %d <= %d)",
		verdict.current_total,
		baseline.total_dedup_value,
	)
	return 0
}

run_near_lint :: proc(inv: ^cli.Cli_Invocation) -> int {
	arena: vmem.Arena
	if arena_err := vmem.arena_init_growing(&arena); arena_err != .None {
		fmt.eprintln("eir near: cannot initialize the scan arena")
		return 2
	}
	defer vmem.arena_destroy(&arena)
	scan := vmem.arena_allocator(&arena)

	opts := Near_Options {
		min_nodes      = cli.cli_flag_int(inv, "min-nodes"),
		similarity_pct = cli.cli_flag_int(inv, "similarity"),
		fold_literals  = cli.cli_flag_bool(inv, "fold-literals"),
	}

	result, _, ok := load_lint_sources("near", lint_root(inv), cli.cli_flag_string(inv, "exclude"), scan)
	if !ok {
		return 2
	}

	pairs := find_near_clones(result, opts, scan)

	diags := near_diagnostics(pairs, scan)
	if cli.cli_flag_bool(inv, "json") {
		fmt.println(render_diagnostics_json(diags, scan))
	} else {
		fmt.print(render_diagnostics_human(diags, scan))
	}
	return 0
}

run_dead_lint :: proc(inv: ^cli.Cli_Invocation) -> int {
	arena: vmem.Arena
	if arena_err := vmem.arena_init_growing(&arena); arena_err != .None {
		fmt.eprintln("eir dead: cannot initialize the scan arena")
		return 2
	}
	defer vmem.arena_destroy(&arena)
	scan := vmem.arena_allocator(&arena)

	result, _, ok := load_lint_sources("dead", lint_root(inv), cli.cli_flag_string(inv, "exclude"), scan)
	if !ok {
		return 2
	}

	dead := find_dead_decls(result, scan)

	diags := dead_diagnostics(dead, scan)
	if cli.cli_flag_bool(inv, "json") {
		fmt.println(render_diagnostics_json(diags, scan))
	} else {
		fmt.print(render_diagnostics_human(diags, scan))
	}
	return 0
}

run_comments_lint :: proc(inv: ^cli.Cli_Invocation) -> int {
	exclude := cli.cli_flag_string(inv, "exclude")
	budget := cli.cli_flag_int(inv, "max-comments")
	want_json := cli.cli_flag_bool(inv, "json")

	arena: vmem.Arena
	if arena_err := vmem.arena_init_growing(&arena); arena_err != .None {
		fmt.eprintln("eir comments: cannot initialize the scan arena")
		return 2
	}
	defer vmem.arena_destroy(&arena)
	scan := vmem.arena_allocator(&arena)

	result, _, ok := load_lint_sources("comments", lint_root(inv), exclude, scan)
	if !ok {
		return 2
	}

	counts := count_comment_lines_per_file(result, scan)
	diags := over_budget_diagnostics(counts, budget, .Error, scan)

	if want_json {
		fmt.println(render_diagnostics_json(diags, scan))
	} else {
		fmt.print(render_diagnostics_human(diags, scan))
	}
	return 1 if len(diags) > 0 else 0
}

@(private = "file")
lint_root :: proc(inv: ^cli.Cli_Invocation) -> string {
	if len(inv.args) > 0 {
		return inv.args[0]
	}
	return "."
}

@(private = "file")
load_lint_sources :: proc(
	name, root, exclude_flag: string,
	allocator := context.allocator,
) -> (
	result: Load_Result,
	excludes: []string,
	ok: bool,
) {
	excludes = parse_exclude_flag(exclude_flag, allocator)

	l: Loader
	loader_init(&l, allocator)
	defer loader_destroy(&l)

	result, ok = load_dir(&l, root, excludes)
	if !ok {
		fmt.eprintfln("eir %s: cannot scan %q", name, root)
		return {}, nil, false
	}

	if result.parse_failures > 0 {
		fmt.eprintfln("eir %s: %d file(s) failed to parse and were skipped", name, result.parse_failures)
	}
	return result, excludes, true
}

@(private = "file")
parse_exclude_flag :: proc(raw: string, allocator := context.allocator) -> []string {
	if raw == "" {
		return nil
	}
	out := make([dynamic]string, 0, 4, allocator)
	rest := raw
	for segment in strings.split_iterator(&rest, ",") {
		trimmed := strings.trim_space(segment)
		if trimmed != "" {
			append(&out, trimmed)
		}
	}
	return out[:]
}
