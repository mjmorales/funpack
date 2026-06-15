// The run/live/attach verb-wiring tests: the argument plumbing of the runtime
// verbs through the pure cli.cli_parse, the pure entrypoint-name guard, and the
// build-half refusal arm of run_run_verb against a temp tree. The live SDL launch
// itself (run_live_session on a real artifact) stays manually verified — these
// tests cover the COMPOSITION and MARSHALLING this entry package owns, not the
// runtime session (spec'd in the runtime package) nor the compile path (spec'd in
// funpack/build_test.odin).
package main

import "../../cli"
import "../../funpack"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:testing"

// test_run_dispatch pins the `funpack run` verb-dispatch junction: the verb
// resolves to its leaf, `--release` maps to the build mode (funpack.cli_build_mode,
// the seam build and run share), and the positional list partitions into the
// optional [name] (first positional) and the runtime-forwarded tail (cli_run_name /
// cli_run_extra_args). A misspelled flag is the usage tier — never a silent
// wrong-mode build.
@(test)
test_run_dispatch :: proc(t: ^testing.T) {
	root := build_root_cli(context.temp_allocator)
	cli.cli_finalize(root)

	// Bare `run`: default Dev mode, no name, no forwarded args.
	inv := expect_root_ok(t, root, {"run"})
	testing.expect_value(t, inv.command.use, "run")
	testing.expect_value(t, funpack.cli_build_mode(&inv), funpack.Build_Mode.Dev)
	testing.expect_value(t, cli_run_name(&inv), "")
	testing.expect_value(t, len(cli_run_extra_args(&inv)), 0)

	// `run --release`: Release mode, still no positionals.
	inv = expect_root_ok(t, root, {"run", "--release"})
	testing.expect_value(t, funpack.cli_build_mode(&inv), funpack.Build_Mode.Release)
	testing.expect_value(t, cli_run_name(&inv), "")

	// `run main out.replay extra`: [name] = main, the tail is forwarded verbatim.
	inv = expect_root_ok(t, root, {"run", "main", "out.replay", "extra"})
	testing.expect_value(t, cli_run_name(&inv), "main")
	extra := cli_run_extra_args(&inv)
	testing.expect_value(t, len(extra), 2)
	testing.expect_value(t, extra[0], "out.replay")
	testing.expect_value(t, extra[1], "extra")

	// A misspelled flag is the usage tier, never a silent Dev build.
	expect_root_reject(t, root, {"run", "--relase"})
}

// test_live_attach_dispatch pins the live/attach arity and flags: live requires an
// artifact (1) and accepts an optional replay-out (2); attach mirrors that and
// adds --port. A missing artifact and an over-long positional list are the usage
// tier; a non-int --port is rejected at parse.
@(test)
test_live_attach_dispatch :: proc(t: ^testing.T) {
	root := build_root_cli(context.temp_allocator)
	cli.cli_finalize(root)

	testing.expect_value(t, len(expect_root_ok(t, root, {"live", "art"}).args), 1)
	testing.expect_value(t, len(expect_root_ok(t, root, {"live", "art", "out.replay"}).args), 2)
	expect_root_reject(t, root, {"live"}) // artifact required
	expect_root_reject(t, root, {"live", "a", "b", "c"}) // too many

	inv := expect_root_ok(t, root, {"attach", "art", "--port", "9000"})
	testing.expect_value(t, cli.cli_flag_int(&inv, "port"), 9000)
	expect_root_reject(t, root, {"attach"}) // artifact required
	expect_root_reject(t, root, {"attach", "art", "--port", "notint"}) // bad int
}

// test_run_select_entrypoint pins the entrypoint-name guard: no name is honored
// (the implicit single-entrypoint default), a named pick is refused with a clear
// "not yet supported" detail (never silently ignored). Pure — a function of the
// name alone.
@(test)
test_run_select_entrypoint :: proc(t: ^testing.T) {
	testing.expect_value(t, run_select_entrypoint(""), "")
	refusal := run_select_entrypoint("boss-rush")
	testing.expect(t, strings.contains(refusal, "not yet supported"))
	testing.expect(t, strings.contains(refusal, "boss-rush"))
}

// test_run_build_refusal pins the build-half refusal arm: run_run_verb over a root
// with no buildable project tree refuses with exit 2 (the build-refusal tier),
// before any runtime launch — so a `funpack run` in a non-project directory fails
// the same way `funpack build` would, never crossing into the SDL session. The
// compile-path detail itself is spec'd in funpack/build_test.odin; here we prove
// only that run_run_verb relays a refusal as exit 2.
@(test)
test_run_build_refusal :: proc(t: ^testing.T) {
	base := os.get_env("TMPDIR", context.temp_allocator)
	if base == "" {
		base = "/tmp"
	}
	dir, _ := filepath.join({base, "funpack-cmd-run-refusal"}, context.temp_allocator)
	if os.make_directory(dir) != nil && !os.exists(dir) {
		return // cannot stage the scratch root — skip rather than false-fail
	}
	defer os.remove_all(dir)

	testing.expect_value(t, run_run_verb("", {}, funpack.Build_Mode.Dev, dir), 2)
}
