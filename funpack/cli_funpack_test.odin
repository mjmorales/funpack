// The funpack COMPILER command-tree contract tests: the argument grammar of the
// compiler subtree (build_funpack_compiler_subtree), exercised through the pure
// cli.cli_parse. Every accept maps to the verb mode / query the handler reads;
// every reject is the usage tier (exit 2). The verb EXIT contracts ({0, 1, 2})
// stay pinned by build_test / check_test / fmt_test / warden_test against the
// run_X_verb cores — this file proves only the argument plumbing.
//
// The run/live/attach verbs live in the entry package (cmd/funpack) and are
// tested there (cli_root_test.odin, cli_run_test.odin), because they depend on
// funpack_runtime. Here the subtree is wrapped under a local test root so the
// grammar parses against the same shape main composes, minus those runtime verbs.
package funpack

import "../cli"
import "core:testing"

// build_compiler_test_root wraps the compiler subtree under a finalized root so
// the grammar tests parse against the same shape the entry package composes
// (minus the runtime verbs). It mirrors the entry package's build_root_cli: a
// root node owning the compiler subtree, finalized to wire parent pointers.
build_compiler_test_root :: proc(allocator := context.temp_allocator) -> ^cli.Cli_Command {
	root := cli.cli_new_command(
		cli.Cli_Command {
			use = "funpack",
			short = "The funpack source → artifact compiler",
			subcommands = build_funpack_compiler_subtree(allocator),
		},
		allocator,
	)
	cli.cli_finalize(root)
	return root
}

// expect_funpack_ok parses argv against the compiler tree and asserts success.
expect_funpack_ok :: proc(
	t: ^testing.T,
	root: ^cli.Cli_Command,
	argv: []string,
	loc := #caller_location,
) -> cli.Cli_Invocation {
	inv, err := cli.cli_parse(root, argv, context.temp_allocator)
	testing.expect_value(t, err.kind, cli.Cli_Parse_Error_Kind.None, loc = loc)
	return inv
}

// expect_funpack_reject parses argv and asserts a usage error of SOME closed kind
// — the rejection battery cares that the shape is refused (the path the entry
// package maps to exit 2), not which specific kind, matching the old `ok = false`
// contract.
expect_funpack_reject :: proc(
	t: ^testing.T,
	root: ^cli.Cli_Command,
	argv: []string,
	loc := #caller_location,
) {
	_, err := cli.cli_parse(root, argv, context.temp_allocator)
	testing.expect(t, err.kind != .None, "expected a usage rejection", loc = loc)
}

// test_funpack_tree_finalizes pins that the authored compiler subtree is
// well-formed — unique subcommand names, unique flag names/shorthands, every node
// runnable or a parent — so the entry package's startup assert can never fire on
// the compiler half. A malformed subtree is caught here, at test time.
@(test)
test_funpack_tree_finalizes :: proc(t: ^testing.T) {
	root := build_compiler_test_root()
	ok, message := cli.cli_finalize(root)
	testing.expect(t, ok, message)
}

// test_funpack_top_level_verbs pins the compiler verb set: version and test take
// no positional arguments (a trailing token is the usage tier), and the bare
// program and an unknown verb are usage errors.
@(test)
test_funpack_top_level_verbs :: proc(t: ^testing.T) {
	root := build_compiler_test_root()

	testing.expect_value(t, expect_funpack_ok(t, root, {"version"}).command.use, "version")
	testing.expect_value(t, expect_funpack_ok(t, root, {"test"}).command.use, "test")
	testing.expect_value(t, expect_funpack_ok(t, root, {"introspect"}).command.use, "introspect")

	expect_funpack_reject(t, root, {})
	expect_funpack_reject(t, root, {"bogus"})
	expect_funpack_reject(t, root, {"version", "extra"})
	expect_funpack_reject(t, root, {"test", "--flag"})
}

// test_funpack_introspect_verb pins the introspect verb wiring: it resolves to its
// leaf with no positional, takes NO flags or arguments (a trailing token or any
// flag is the usage tier), and its handler is the read-only dump core — so the
// surface-dump fallback the §26 parity check relies on is reachable through the
// tree exactly like version/test, never silently dropped or shadowed.
@(test)
test_funpack_introspect_verb :: proc(t: ^testing.T) {
	root := build_compiler_test_root()

	inv := expect_funpack_ok(t, root, {"introspect"})
	testing.expect_value(t, inv.command.use, "introspect")
	testing.expect_value(t, len(inv.args), 0)
	testing.expect(t, inv.command.run == cli_run_introspect, "introspect routes to its dump core")

	expect_funpack_reject(t, root, {"introspect", "extra"})
	expect_funpack_reject(t, root, {"introspect", "--json"})
}

// test_funpack_version_json_flag pins the version `--json` seam: no flag is the
// human face (cli_flag_bool false), `--json` selects the machine face (true), and
// a typo'd or trailing positional is the usage tier — so a misspelled flag never
// silently falls back to the wrong face, and `funpack version --json` keeps its
// {0} exit contract through cli_run_version.
@(test)
test_funpack_version_json_flag :: proc(t: ^testing.T) {
	root := build_compiler_test_root()

	inv := expect_funpack_ok(t, root, {"version"})
	testing.expect(t, !cli.cli_flag_bool(&inv, "json"), "bare version is the human face")

	inv = expect_funpack_ok(t, root, {"version", "--json"})
	testing.expect(t, cli.cli_flag_bool(&inv, "json"), "--json selects the machine face")

	expect_funpack_reject(t, root, {"version", "--jsn"})
	expect_funpack_reject(t, root, {"version", "--json", "extra"})
}

// test_funpack_build_release_flag pins the `--release` seam build and check
// share: no flag is Dev, `--release` is Release, and a typo'd or trailing
// argument is the usage tier — so a misspelled flag never silently adjudicates in
// the wrong mode.
@(test)
test_funpack_build_release_flag :: proc(t: ^testing.T) {
	root := build_compiler_test_root()

	inv := expect_funpack_ok(t, root, {"build"})
	testing.expect_value(t, cli_build_mode(&inv), Build_Mode.Dev)

	inv = expect_funpack_ok(t, root, {"build", "--release"})
	testing.expect_value(t, cli_build_mode(&inv), Build_Mode.Release)

	inv = expect_funpack_ok(t, root, {"check", "--release"})
	testing.expect_value(t, cli_build_mode(&inv), Build_Mode.Release)

	expect_funpack_reject(t, root, {"build", "--relase"})
	expect_funpack_reject(t, root, {"build", "--release", "extra"})
	expect_funpack_reject(t, root, {"check", "--relase"})
}

// test_funpack_check_recursive_flag pins the recursive-check seam: check accepts
// the optional `[root]` positional and the `--recursive`/`-r` bool flag (the
// multi-project sweep), the long and short spellings parse
// identically, and `--release`/`--recursive` compose. A typo'd flag or a SECOND
// positional is the usage tier — check takes at most one root, so a stray argument
// never silently becomes a misread root.
@(test)
test_funpack_check_recursive_flag :: proc(t: ^testing.T) {
	root := build_compiler_test_root()

	// No flag: not recursive, root is cwd (no positional).
	inv := expect_funpack_ok(t, root, {"check"})
	testing.expect_value(t, cli.cli_flag_bool(&inv, "recursive"), false)
	testing.expect_value(t, len(inv.args), 0)

	// Long flag with an explicit root positional.
	inv = expect_funpack_ok(t, root, {"check", "--recursive", "games"})
	testing.expect_value(t, cli.cli_flag_bool(&inv, "recursive"), true)
	testing.expect_value(t, len(inv.args), 1)
	testing.expect_value(t, inv.args[0], "games")

	// Short flag parses identically to the long spelling.
	inv = expect_funpack_ok(t, root, {"check", "-r", "games"})
	testing.expect_value(t, cli.cli_flag_bool(&inv, "recursive"), true)
	testing.expect_value(t, inv.args[0], "games")

	// --release and --recursive compose (a recursive shippability sweep).
	inv = expect_funpack_ok(t, root, {"check", "--recursive", "--release", "games"})
	testing.expect_value(t, cli.cli_flag_bool(&inv, "recursive"), true)
	testing.expect_value(t, cli_build_mode(&inv), Build_Mode.Release)

	// A bare root positional (no flag) is the single-project check at that root.
	inv = expect_funpack_ok(t, root, {"check", "games"})
	testing.expect_value(t, cli.cli_flag_bool(&inv, "recursive"), false)
	testing.expect_value(t, inv.args[0], "games")

	expect_funpack_reject(t, root, {"check", "--recursiv"})
	expect_funpack_reject(t, root, {"check", "--recursive", "a", "b"})
}

// test_funpack_fmt_check_flag pins the fmt `--check` seam: no flag is Write,
// `--check` is Check, and a typo or trailing argument is the usage tier.
@(test)
test_funpack_fmt_check_flag :: proc(t: ^testing.T) {
	root := build_compiler_test_root()

	inv := expect_funpack_ok(t, root, {"fmt"})
	testing.expect_value(t, cli_fmt_mode(&inv), Fmt_Mode.Write)

	inv = expect_funpack_ok(t, root, {"fmt", "--check"})
	testing.expect_value(t, cli_fmt_mode(&inv), Fmt_Mode.Check)

	expect_funpack_reject(t, root, {"fmt", "--chek"})
	expect_funpack_reject(t, root, {"fmt", "--check", "extra"})
}

// test_funpack_warden_subcommand_totality pins the closed warden set: each
// argumentless subcommand resolves to its leaf with no positional, the bare
// `warden` and an unknown subcommand are usage errors, and a trailing token on a
// strict zero-positional command is rejected — the closed warden subcommand set,
// adjudicated by the tree.
@(test)
test_funpack_warden_subcommand_totality :: proc(t: ^testing.T) {
	root := build_compiler_test_root()

	argless := []string{"holes", "probes", "debt", "tags", "pipeline"}
	for name in argless {
		inv := expect_funpack_ok(t, root, {"warden", name})
		testing.expect_value(t, inv.command.use, name)
		testing.expect_value(t, len(inv.args), 0)
	}

	expect_funpack_reject(t, root, {"warden"})
	expect_funpack_reject(t, root, {"warden", "fnid"})
	expect_funpack_reject(t, root, {"warden", "tags", "extra"})
}

// test_funpack_warden_graph_positional pins graph's optional single positional:
// the incident-edge filter is carried verbatim into the handler's arg, a second
// positional is the usage tier, and the optional arity is graph's alone — a
// positional on a strict command (holes, pipeline) stays a usage error.
@(test)
test_funpack_warden_graph_positional :: proc(t: ^testing.T) {
	root := build_compiler_test_root()

	inv := expect_funpack_ok(t, root, {"warden", "graph", "drift.damped"})
	testing.expect_value(t, inv.command.use, "graph")
	testing.expect_value(t, len(inv.args), 1)
	testing.expect_value(t, inv.args[0], "drift.damped")

	expect_funpack_reject(t, root, {"warden", "graph", "drift.damped", "extra"})
	expect_funpack_reject(t, root, {"warden", "holes", "drift.damped"})
	expect_funpack_reject(t, root, {"warden", "pipeline", "drift.damped"})
}

// test_funpack_warden_find_query pins find's filter grammar and its projection
// onto Warden_Find_Query: a positional name, --kind, and --gtag each bind alone
// and together, and the mapper produces the expected query.
@(test)
test_funpack_warden_find_query :: proc(t: ^testing.T) {
	root := build_compiler_test_root()

	inv := expect_funpack_ok(t, root, {"warden", "find", "damped"})
	testing.expect_value(t, cli_warden_find_query(&inv), Warden_Find_Query{name = "damped"})

	inv = expect_funpack_ok(t, root, {"warden", "find", "--kind", "Extern_Fn"})
	testing.expect_value(t, cli_warden_find_query(&inv), Warden_Find_Query{kind = "Extern_Fn"})

	inv = expect_funpack_ok(t, root, {"warden", "find", "--gtag", "debt"})
	testing.expect_value(t, cli_warden_find_query(&inv), Warden_Find_Query{gtag = "debt"})

	inv = expect_funpack_ok(t, root, {"warden", "find", "damped", "--kind", "Fn", "--gtag", "physics"})
	testing.expect_value(
		t,
		cli_warden_find_query(&inv),
		Warden_Find_Query{name = "damped", kind = "Fn", gtag = "physics"},
	)
}

// test_funpack_warden_find_rejections pins find's usage tier — every malformed
// find shape: the filterless bare command, an unknown or case-folded kind name, a
// missing or empty flag value, an empty name-query, a second positional, a
// duplicate flag, and an unknown flag. Each is adjudicated at parse, before any
// index read, so the rejection holds in any directory.
@(test)
test_funpack_warden_find_rejections :: proc(t: ^testing.T) {
	root := build_compiler_test_root()

	rejected := [][]string {
		{"warden", "find"}, // filterless — find is not the index dump
		{"warden", "find", "--kind", "fn"}, // kind names are exact, never case-folded
		{"warden", "find", "--kind", "Widget"}, // unknown kind name, never fuzzy
		{"warden", "find", "--kind"}, // missing flag value
		{"warden", "find", "--gtag"}, // missing flag value
		{"warden", "find", "--gtag", ""}, // empty flag value
		{"warden", "find", ""}, // empty name-query (a disguised dump)
		{"warden", "find", "a", "b"}, // second positional
		{"warden", "find", "--kind", "Fn", "--kind", "Fn"}, // duplicate flag
		{"warden", "find", "--glob", "x"}, // unknown flag
	}
	for shape in rejected {
		expect_funpack_reject(t, root, shape)
	}
}

// test_funpack_help_requested pins `--help`/`-h` at each level: the root, a leaf,
// and the warden parent each return a successful help invocation against
// themselves, so dispatch renders that command's usage and exits 0.
@(test)
test_funpack_help_requested :: proc(t: ^testing.T) {
	root := build_compiler_test_root()

	inv, err := cli.cli_parse(root, {"--help"}, context.temp_allocator)
	testing.expect_value(t, err.kind, cli.Cli_Parse_Error_Kind.None)
	testing.expect(t, inv.help)
	testing.expect_value(t, inv.command.use, "funpack")

	inv, err = cli.cli_parse(root, {"build", "-h"}, context.temp_allocator)
	testing.expect_value(t, err.kind, cli.Cli_Parse_Error_Kind.None)
	testing.expect(t, inv.help)
	testing.expect_value(t, inv.command.use, "build")

	inv, err = cli.cli_parse(root, {"warden", "--help"}, context.temp_allocator)
	testing.expect_value(t, err.kind, cli.Cli_Parse_Error_Kind.None)
	testing.expect(t, inv.help)
	testing.expect_value(t, inv.command.use, "warden")
}
