// The funpack command-tree contract tests: the argument grammar of the real tree
// from build_funpack_cli, exercised through the pure cli_parse. Every accept maps
// to the verb mode / query the handler reads; every reject is the usage tier
// (exit 2). The verb EXIT contracts ({0, 1, 2}) stay pinned by build_test /
// check_test / fmt_test / warden_test against the run_X_verb cores — this file
// proves only the argument plumbing.
package funpack

import "core:testing"

// expect_funpack_ok parses argv against the funpack tree and asserts success.
expect_funpack_ok :: proc(
	t: ^testing.T,
	root: ^Cli_Command,
	argv: []string,
	loc := #caller_location,
) -> Cli_Invocation {
	inv, err := cli_parse(root, argv, context.temp_allocator)
	testing.expect_value(t, err.kind, Cli_Parse_Error_Kind.None, loc = loc)
	return inv
}

// expect_funpack_reject parses argv and asserts a usage error of SOME closed kind
// — the rejection battery cares that the shape is refused (the path main maps to
// exit 2), not which specific kind, matching the old `ok = false` contract.
expect_funpack_reject :: proc(
	t: ^testing.T,
	root: ^Cli_Command,
	argv: []string,
	loc := #caller_location,
) {
	_, err := cli_parse(root, argv, context.temp_allocator)
	testing.expect(t, err.kind != .None, "expected a usage rejection", loc = loc)
}

// test_funpack_tree_finalizes pins that the authored tree is well-formed —
// unique subcommand names, unique flag names/shorthands, every node runnable or a
// parent — so build_funpack_cli's startup assert can never fire in a shipped
// binary. A malformed tree is caught here, at test time.
@(test)
test_funpack_tree_finalizes :: proc(t: ^testing.T) {
	root := build_funpack_cli(context.temp_allocator)
	ok, message := cli_finalize(root)
	testing.expect(t, ok, message)
}

// test_funpack_top_level_verbs pins the root's verb set: version and test take no
// arguments (a trailing token is the usage tier), and the bare program and an
// unknown verb are usage errors.
@(test)
test_funpack_top_level_verbs :: proc(t: ^testing.T) {
	root := build_funpack_cli(context.temp_allocator)

	testing.expect_value(t, expect_funpack_ok(t, root, {"version"}).command.use, "version")
	testing.expect_value(t, expect_funpack_ok(t, root, {"test"}).command.use, "test")

	expect_funpack_reject(t, root, {})
	expect_funpack_reject(t, root, {"bogus"})
	expect_funpack_reject(t, root, {"version", "extra"})
	expect_funpack_reject(t, root, {"test", "--flag"})
}

// test_funpack_build_release_flag pins the `--release` seam build and check
// share: no flag is Dev, `--release` is Release, and a typo'd or trailing
// argument is the usage tier — so a misspelled flag never silently adjudicates in
// the wrong mode.
@(test)
test_funpack_build_release_flag :: proc(t: ^testing.T) {
	root := build_funpack_cli(context.temp_allocator)

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

// test_funpack_fmt_check_flag pins the fmt `--check` seam: no flag is Write,
// `--check` is Check, and a typo or trailing argument is the usage tier.
@(test)
test_funpack_fmt_check_flag :: proc(t: ^testing.T) {
	root := build_funpack_cli(context.temp_allocator)

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
	root := build_funpack_cli(context.temp_allocator)

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
	root := build_funpack_cli(context.temp_allocator)

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
	root := build_funpack_cli(context.temp_allocator)

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
	root := build_funpack_cli(context.temp_allocator)

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
	root := build_funpack_cli(context.temp_allocator)

	inv, err := cli_parse(root, {"--help"}, context.temp_allocator)
	testing.expect_value(t, err.kind, Cli_Parse_Error_Kind.None)
	testing.expect(t, inv.help)
	testing.expect_value(t, inv.command.use, "funpack")

	inv, err = cli_parse(root, {"build", "-h"}, context.temp_allocator)
	testing.expect_value(t, err.kind, Cli_Parse_Error_Kind.None)
	testing.expect(t, inv.help)
	testing.expect_value(t, inv.command.use, "build")

	inv, err = cli_parse(root, {"warden", "--help"}, context.temp_allocator)
	testing.expect_value(t, err.kind, Cli_Parse_Error_Kind.None)
	testing.expect(t, inv.help)
	testing.expect_value(t, inv.command.use, "warden")
}
