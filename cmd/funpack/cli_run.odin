// The `funpack run` verb: build the §14 project tree, then play the freshly-built
// artifact IN-PROCESS — the one-command, discoverable "build it and play it" path
// (cargo/go-run semantics) the spec §14 §6 envisions.
//
// THE LAUNCH: the build half is the same pure funpack.stage_build the build verb
// compiles; the launch half is a direct in-process call into
// funpack_runtime.run_live_session — no child process, no binary resolution.
//
// THE PURITY BOUNDARY (spec §29 §1): the funpack package stays the PURE compiler
// (no SDL). SDL enters only because THIS entry package imports funpack_runtime, and
// the build is define-gated (-define:FUNPACK_LIVE=true).
package main

import "../../cli"
import "../../funpack"
import funpack_runtime "../../runtime"
import "core:fmt"
import "core:slice"

// build_run_command declares the `run` verb node. `--release` parity with build:
// the same hole-ban mode the build/check verbs honor. Positionals are arbitrary
// (the zero-value arity): the optional [name] entrypoint pick is the first, any
// further positionals are forwarded to the runtime (e.g. a replay-out path).
build_run_command :: proc(allocator := context.allocator) -> ^cli.Cli_Command {
	return cli.cli_new_command(
		cli.Cli_Command {
			use = "run",
			short = "Build the project and play it in one step",
			long = "Build the §14 project tree (like `funpack build`), then launch the built artifact in the live SDL runtime — the one-command build-and-play path. Entrypoint selection by [name] (§14 §6) is not yet implemented: this build runs its single declared entrypoint, so omit the name. Because the first positional is parsed as the (unsupported) [name], record a replay by path with `funpack live <artifact> <replay-out>` instead. To play an ALREADY-built artifact without rebuilding, use `funpack live`.",
			flags = slice.clone(
				[]cli.Cli_Flag {
					{
						name = "release",
						kind = .Bool,
						usage = "Build in release mode (ban typed holes and debug directives) before running",
					},
				},
				allocator,
			),
			run = cli_run_run,
		},
		allocator,
	)
}

// cli_run_run adapts the `funpack run` invocation onto run_run_verb: `--release`
// maps to the build mode (the same funpack.cli_build_mode build/check share), the
// first positional is the optional [name] entrypoint pick, and every later
// positional is forwarded verbatim to the runtime.
cli_run_run :: proc(inv: ^cli.Cli_Invocation) -> int {
	return run_run_verb(cli_run_name(inv), cli_run_extra_args(inv), funpack.cli_build_mode(inv))
}

// run_run_verb is the `funpack run [name]` core: BUILD the project tree (the same
// pure funpack.stage_build the build verb runs), then PLAY the built artifact via
// funpack_runtime.run_live_session in-process. It mirrors the build verb's
// structure — the build path is identical, so a build that refuses under `funpack
// build` refuses identically under `funpack run`.
//
// THE EXIT CONTRACT (spec §29 §3):
//   - A build/gate/tree refusal is exit 2 with the SAME eprint_build_refusal block
//     build prints (a compile error is never a counted failure).
//   - A host IO failure writing the products is exit 2.
//   - A PACKAGE (no entrypoint ⇒ artifact_path == "") has nothing to run: exit 2
//     with the no-entrypoint fix-it.
//   - Otherwise the verb RELAYS run_live_session's own exit code, so `funpack run`'s
//     exit status IS the game's. run_live_session returns its code directly (an
//     in-process call, not a child wait), so a signal that kills the process is not
//     translated into an exit number — the clean/usage/load contract still holds.
//
// extra_args are the trailing positionals after the optional [name] — forwarded
// verbatim to the runtime as run_live_session's argv[2:] (e.g. a replay-out path).
// mode is the Dev/Release flag; the build half threads it through stage_build
// exactly as build does. root is the project root, a parameter (defaulting to ".")
// so the build-refusal and no-entrypoint arms are unit-tested against temp trees —
// the run_check_verb testability precedent; main always builds the working dir.
run_run_verb :: proc(name: string, extra_args: []string, mode: funpack.Build_Mode, root := ".") -> int {
	// BUILD — the same pure seam the build verb compiles, identical refusal block.
	product, verdict := funpack.stage_build(root, mode, context.temp_allocator)
	if verdict.err != .None {
		funpack.eprint_build_refusal("funpack run", verdict)
		return 2
	}
	if write_err := funpack.write_build_products(product, root); write_err != .None {
		fmt.eprintfln("funpack run: %v", write_err)
		return 2
	}
	// NO ENTRYPOINT — a package (Index Contract only, §30 §7) has no runtime
	// artifact, so there is nothing to run. Refuse before launching the runtime.
	if product.artifact_path == "" {
		fmt.eprintln("funpack run: nothing to run — this project declares no entrypoint")
		return 2
	}
	// [name] — validate the optional entrypoint pick against what the single-
	// artifact build path can honor (the multi-entrypoint selection is deferred).
	if sel_err := run_select_entrypoint(name); sel_err != "" {
		fmt.eprintfln("funpack run: %s", sel_err)
		return 2
	}
	// PLAY — call run_live_session in-process over the built artifact, relaying its
	// exit code. run_live_session reads its argv as {prog, artifact, forwarded…};
	// argv[0] is ignored, argv[1] is the artifact path, argv[2:] are forwarded.
	live_args := make([dynamic]string, 0, 2 + len(extra_args), context.temp_allocator)
	append(&live_args, "funpack run")
	append(&live_args, product.artifact_path)
	append(&live_args, ..extra_args)
	return funpack_runtime.run_live_session(live_args[:])
}

// run_select_entrypoint adjudicates the optional `funpack run [name]` positional
// against what the build path can honor. The current build emits the single
// entrypoints.fcfg artifact (no multi-entrypoint selection wired), so:
//   - no name ("") is always honored — the implicit single-entrypoint default.
//   - a NAMED pick is refused with a clear "selection not yet supported" message
//     rather than silently ignored, so a user never thinks a name took effect when
//     it did not. (Wiring the named pick is the tracked follow-up.)
// Returns "" when the selection is honorable, else the refusal detail. Pure — a
// function of the name alone — so it is unit-tested without a build.
run_select_entrypoint :: proc(name: string) -> (refusal: string) {
	if name == "" {
		return ""
	}
	return fmt.aprintf(
		"entrypoint selection (run %s) is not yet supported — this build runs its single declared entrypoint; omit the name (to record a replay by path, use `funpack live <artifact> <replay-out>`)",
		name,
		allocator = context.temp_allocator,
	)
}

// cli_run_name reads `funpack run`'s optional [name] entrypoint pick — the FIRST
// positional, "" when none was given. The remaining positionals are the runtime's
// forwarded args (cli_run_extra_args), so the name and the forwarded args partition
// the positional list at index 0.
cli_run_name :: proc(inv: ^cli.Cli_Invocation) -> string {
	if len(inv.args) == 0 {
		return ""
	}
	return inv.args[0]
}

// cli_run_extra_args reads the positionals AFTER the optional [name] — the args
// forwarded verbatim to the runtime (e.g. a replay-out path). With no positionals
// the slice is empty; with one it is empty (that one is the name); with more it is
// the tail past the name.
cli_run_extra_args :: proc(inv: ^cli.Cli_Invocation) -> []string {
	if len(inv.args) <= 1 {
		return {}
	}
	return inv.args[1:]
}
