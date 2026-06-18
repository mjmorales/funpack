// The funpack COMPILER command subtree — the pure-compiler verbs (version, test,
// build, check, fmt, and the warden index-query group) the single binary's entry
// package (cmd/funpack) grafts onto the unified root alongside the runtime verbs
// (run, live, attach). Every front-door verb here is one cli.Cli_Command node,
// its handler a thin adapter that reads the resolved flags/positionals and calls
// the verb's run_X_verb / *_verb_exit core — so each verb keeps its documented
// {0, 1, 2} exit contract (§29 §3); the framework (the cli package) owns only the
// argument plumbing.
//
// Two domain seams keep the generic framework from needing to know funpack's
// types: cli_validate_index_decl_kind is the per-flag predicate that adjudicates
// `warden find --kind` against the closed Index_Decl_Kind member names at parse
// time, and cli_validate_warden_find is the command-level predicate for find's
// "at least one non-empty filter, never an empty name-query" gate (the one
// constraint that is neither a flag nor an arity rule).
//
// This file owns the COMPILER half only. The run verb (which builds then launches
// the runtime in-process) and the live/attach verbs live in cmd/funpack, because
// they call into funpack_runtime — a dependency the pure compiler package must not
// take (it would pull SDL into `odin test funpack/`). The compiler subtree is
// returned UNFINALIZED: the entry package appends the runtime nodes and finalizes
// the whole tree at once, so cross-verb uniqueness is checked over the real root.
package funpack

import "../cli"
import "core:reflect"
import "core:slice"

// build_funpack_compiler_subtree constructs the compiler verb nodes and returns
// them as a slice for the entry package to graft onto the unified root. The nodes
// are allocated in `allocator` (process-lifetime for main, a scratch arena in
// tests) so every node has a stable address for the parent pointers cli_finalize
// wires when the entry package finalizes the composed root.
build_funpack_compiler_subtree :: proc(allocator := context.allocator) -> []^cli.Cli_Command {
	find := cli.cli_new_command(
		cli.Cli_Command {
			use = "find",
			short = "Look up an existing declaration before writing one",
			long = "Query the project index for a declaration to reuse before implementing one. At least one filter is required — a name substring, a --kind, or a --gtag; an empty result means nothing to reuse.",
			flags = slice.clone(
				[]cli.Cli_Flag {
					{
						name = "kind",
						kind = .String,
						usage = "Restrict to an exact Index_Decl_Kind (e.g. Fn, Thing, Signal)",
						validate = cli_validate_index_decl_kind,
					},
					{
						name = "gtag",
						kind = .String,
						usage = "Restrict to declarations carrying a governance tag",
						validate = cli.cli_nonempty,
					},
				},
				allocator,
			),
			args = cli.cli_range_args(0, 1),
			validate = cli_validate_warden_find,
			run = cli_run_warden_find,
		},
		allocator,
	)
	holes := cli.cli_new_command(
		cli.Cli_Command {
			use = "holes",
			short = "List every typed hole in the index",
			args = cli.cli_no_args(),
			run = cli_run_warden_holes,
		},
		allocator,
	)
	probes := cli.cli_new_command(
		cli.Cli_Command {
			use = "probes",
			short = "List every debug probe in the index",
			args = cli.cli_no_args(),
			run = cli_run_warden_probes,
		},
		allocator,
	)
	debt := cli.cli_new_command(
		cli.Cli_Command {
			use = "debt",
			short = "List declarations tagged as debt",
			args = cli.cli_no_args(),
			run = cli_run_warden_debt,
		},
		allocator,
	)
	graph := cli.cli_new_command(
		cli.Cli_Command {
			use = "graph",
			short = "Print the dependency graph, optionally filtered to one node's edges",
			args = cli.cli_range_args(0, 1),
			run = cli_run_warden_graph,
		},
		allocator,
	)
	tags := cli.cli_new_command(
		cli.Cli_Command {
			use = "tags",
			short = "List the registered governance tags",
			args = cli.cli_no_args(),
			run = cli_run_warden_tags,
		},
		allocator,
	)
	pipeline := cli.cli_new_command(
		cli.Cli_Command {
			use = "pipeline",
			short = "Print the pipeline projection from the index",
			args = cli.cli_no_args(),
			run = cli_run_warden_pipeline,
		},
		allocator,
	)
	warden := cli.cli_new_command(
		cli.Cli_Command {
			use = "warden",
			short = "Query the committed project index (read-only)",
			long = "The warden sub-toolchain answers pure index queries over the emitted .funpack/index.ndjson. Every subcommand refuses with exit 2 when the index is missing, schema-mismatched, or malformed; none recompiles in its place.",
			subcommands = slice.clone(
				[]^cli.Cli_Command{find, holes, probes, debt, graph, tags, pipeline},
				allocator,
			),
		},
		allocator,
	)

	version := cli.cli_new_command(
		cli.Cli_Command {
			use = "version",
			short = "Print the toolchain version and schema surface",
			flags = slice.clone(
				[]cli.Cli_Flag {
					{
						name = "json",
						kind = .Bool,
						usage = "Emit the machine-readable JSON contract shape (for tooling)",
					},
				},
				allocator,
			),
			args = cli.cli_no_args(),
			run = cli_run_version,
		},
		allocator,
	)
	introspect := cli.cli_new_command(
		cli.Cli_Command {
			use = "introspect",
			short = "Dump the live stdlib surface as byte-stable JSON (read-only)",
			long = "Emit the compiler-authoritative stdlib surface — the modules and decls, the §26 §3 re-exports, the typed free-function signatures, the engine-enum variant sets, the struct-payload variants, and the receiver/static/associated method surfaces — as one deterministic JSON object generated FROM the live surface.odin tables `check` enforces against. Use it to regenerate the docs corpus mechanically, or as ground truth when the corpus and the compiler disagree.",
			args = cli.cli_no_args(),
			run = cli_run_introspect,
		},
		allocator,
	)
	test := cli.cli_new_command(
		cli.Cli_Command {
			use = "test",
			short = "Run every test block in the project tree",
			args = cli.cli_no_args(),
			run = cli_run_test,
		},
		allocator,
	)
	build := cli.cli_new_command(
		cli.Cli_Command {
			use = "build",
			short = "Compile the project tree and write its artifacts",
			flags = slice.clone(
				[]cli.Cli_Flag {
					{
						name = "release",
						kind = .Bool,
						usage = "Ban typed holes and debug directives (the shippable build)",
					},
				},
				allocator,
			),
			args = cli.cli_no_args(),
			run = cli_run_build,
		},
		allocator,
	)
	check := cli.cli_new_command(
		cli.Cli_Command {
			use = "check",
			short = "Adjudicate the project tree, writing no products",
			flags = slice.clone(
				[]cli.Cli_Flag {
					{
						name = "release",
						kind = .Bool,
						usage = "Ban typed holes and debug directives (shippability verdict)",
					},
				},
				allocator,
			),
			args = cli.cli_no_args(),
			run = cli_run_check,
		},
		allocator,
	)
	fmt_cmd := cli.cli_new_command(
		cli.Cli_Command {
			use = "fmt",
			short = "Rewrite authored sources to canonical form",
			flags = slice.clone(
				[]cli.Cli_Flag {
					{
						name = "check",
						kind = .Bool,
						usage = "Report drift and write nothing (verdict-only)",
					},
				},
				allocator,
			),
			args = cli.cli_no_args(),
			run = cli_run_fmt,
		},
		allocator,
	)

	return slice.clone(
		[]^cli.Cli_Command{version, introspect, test, build, check, fmt_cmd, warden},
		allocator,
	)
}

// ── verb handlers ────────────────────────────────────────────────────────────
// Each handler is the adapter from a resolved invocation to a run_X_verb core.
// Verbs that read no flags/positionals ignore the invocation (the `_` parameter
// makes that explicit); build/check/fmt/find/graph project the invocation onto
// the verb's existing mode/query type through the mappers below.

cli_run_version :: proc(inv: ^cli.Cli_Invocation) -> int {
	return run_version_verb(cli.cli_flag_bool(inv, "json"))
}

cli_run_introspect :: proc(_: ^cli.Cli_Invocation) -> int {
	return run_introspect_verb()
}

cli_run_test :: proc(_: ^cli.Cli_Invocation) -> int {
	return run_test_verb()
}

cli_run_build :: proc(inv: ^cli.Cli_Invocation) -> int {
	return run_build_verb(cli_build_mode(inv))
}

cli_run_check :: proc(inv: ^cli.Cli_Invocation) -> int {
	return run_check_verb(".", cli_build_mode(inv))
}

cli_run_fmt :: proc(inv: ^cli.Cli_Invocation) -> int {
	return run_fmt_verb(cli_fmt_mode(inv))
}

cli_run_warden_find :: proc(inv: ^cli.Cli_Invocation) -> int {
	return run_warden_verb(.Find, "", cli_warden_find_query(inv))
}

cli_run_warden_holes :: proc(_: ^cli.Cli_Invocation) -> int {
	return run_warden_verb(.Holes, "", {})
}

cli_run_warden_probes :: proc(_: ^cli.Cli_Invocation) -> int {
	return run_warden_verb(.Probes, "", {})
}

cli_run_warden_debt :: proc(_: ^cli.Cli_Invocation) -> int {
	return run_warden_verb(.Debt, "", {})
}

cli_run_warden_tags :: proc(_: ^cli.Cli_Invocation) -> int {
	return run_warden_verb(.Tags, "", {})
}

cli_run_warden_pipeline :: proc(_: ^cli.Cli_Invocation) -> int {
	return run_warden_verb(.Pipeline, "", {})
}

cli_run_warden_graph :: proc(inv: ^cli.Cli_Invocation) -> int {
	arg := ""
	if len(inv.args) == 1 {
		arg = inv.args[0]
	}
	return run_warden_verb(.Graph, arg, {})
}

// ── invocation → verb-type mappers ───────────────────────────────────────────

// cli_build_mode maps the build/check `--release` flag to its Build_Mode: the
// flag present is Release (the §29 §4 hole-ban mode), absent is Dev. Both build
// and check read `--release` through this mapper, and the entry package's run verb
// reuses it for `funpack run --release`.
cli_build_mode :: proc(inv: ^cli.Cli_Invocation) -> Build_Mode {
	return .Release if cli.cli_flag_bool(inv, "release") else .Dev
}

// cli_fmt_mode maps the fmt `--check` flag to its Fmt_Mode: present is the
// verdict-only Check face, absent is the in-place Write face.
cli_fmt_mode :: proc(inv: ^cli.Cli_Invocation) -> Fmt_Mode {
	return .Check if cli.cli_flag_bool(inv, "check") else .Write
}

// cli_warden_find_query projects the find invocation onto its Warden_Find_Query:
// the optional positional becomes the name substring, and the validated --kind /
// --gtag flags become the kind/gtag filters ("" when absent — the sentinel the
// query treats as "filter not provided").
cli_warden_find_query :: proc(inv: ^cli.Cli_Invocation) -> Warden_Find_Query {
	query: Warden_Find_Query
	if len(inv.args) == 1 {
		query.name = inv.args[0]
	}
	query.kind = cli.cli_flag_string(inv, "kind")
	query.gtag = cli.cli_flag_string(inv, "gtag")
	return query
}

// ── domain validators ────────────────────────────────────────────────────────

// cli_validate_index_decl_kind is the `warden find --kind` value predicate: the
// value must be an EXACT Index_Decl_Kind member name (reflect.enum_from_name —
// never case-folded, never fuzzy), so an unknown kind is a usage error at parse,
// before any index read.
cli_validate_index_decl_kind :: proc(value: string) -> bool {
	_, known := reflect.enum_from_name(Index_Decl_Kind, value)
	return known
}

// cli_validate_warden_find is find's command-level gate: find answers a lookup,
// not an index dump, so it requires at least one filter — a name, a --kind, or a
// --gtag — and rejects an explicitly-empty name-query (a disguised dump). Run
// over the fully bound invocation after arity, so an over-long positional list
// is already a Bad_Arg_Count by the time this sees it.
cli_validate_warden_find :: proc(inv: ^cli.Cli_Invocation) -> bool {
	if len(inv.args) == 1 && inv.args[0] == "" {
		return false
	}
	has_name := len(inv.args) == 1
	has_kind := cli.cli_flag_string(inv, "kind") != ""
	has_gtag := cli.cli_flag_string(inv, "gtag") != ""
	return has_name || has_kind || has_gtag
}
