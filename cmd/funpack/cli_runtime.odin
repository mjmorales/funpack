// The runtime verbs `live` and `attach` — the two front doors into
// funpack_runtime that DON'T rebuild. `live` plays a prebuilt artifact in the SDL
// session; `attach` opens a §28 introspection session over one. They are
// first-class verbs in the unified tree (the build-and-play path is `run`).
//
// Each handler marshals the resolved cli invocation into the argv shape the
// runtime entry proc already parses (run_live_session / run_attach_session own
// their positional+flag grammar), then relays the proc's exit code. The framework
// owns the unified `--help` and arity; the runtime proc owns artifact load and
// session lifecycle.
package main

import "../../cli"
import funpack_runtime "../../runtime"
import "core:fmt"
import "core:slice"

// build_live_command declares `funpack live <artifact> [replay-out]` — play a
// prebuilt artifact without rebuilding. The artifact is required (1 positional);
// an optional replay-out path is the second. Use `funpack run` to build-and-play.
build_live_command :: proc(allocator := context.allocator) -> ^cli.Cli_Command {
	return cli.cli_new_command(
		cli.Cli_Command {
			use = "live",
			short = "Play a prebuilt game artifact (no rebuild)",
			long = "Launch an ALREADY-built artifact (from `funpack build`, default .funpack/artifact) in the live SDL session, without rebuilding. The artifact path is required; an optional second positional is the replay-out path. Use `funpack run` to build and play in one step.",
			args = cli.cli_range_args(1, 2),
			run = cli_run_live,
		},
		allocator,
	)
}

// cli_run_live marshals {artifact, [replay-out]} into run_live_session's argv:
// argv[0] is ignored, argv[1] is the artifact, argv[2] the optional replay-out.
cli_run_live :: proc(inv: ^cli.Cli_Invocation) -> int {
	live_args := make([dynamic]string, 0, 1 + len(inv.args), context.temp_allocator)
	append(&live_args, "funpack live")
	append(&live_args, ..inv.args)
	return funpack_runtime.run_live_session(live_args[:])
}

// build_attach_command declares `funpack attach <artifact> [recorded.replay]
// [--port N]` — open a §28 introspection session on the auth-gated loopback port.
// The artifact is required; an optional replay log pre-folds recorded inputs;
// --port overrides the default loopback port.
build_attach_command :: proc(allocator := context.allocator) -> ^cli.Cli_Command {
	return cli.cli_new_command(
		cli.Cli_Command {
			use = "attach",
			short = "Open a §28 introspection session over a built artifact",
			long = "Load a built artifact and serve an introspection session on the auth-gated loopback port (§28.2 remote-attach). The artifact path is required; an optional second positional is a recorded replay log to pre-fold; --port overrides the default loopback port.",
			flags = slice.clone(
				[]cli.Cli_Flag {
					{
						name = "port",
						kind = .Int,
						usage = "Override the loopback port the introspection session serves on",
					},
				},
				allocator,
			),
			args = cli.cli_range_args(1, 2),
			run = cli_run_attach,
		},
		allocator,
	)
}

// cli_run_attach marshals {artifact, [replay]} + --port into run_attach_session's
// argv: parse_attach_args expects argv[1]=="attach", then the positionals and the
// --port flag from argv[2:]. A --port the operator did not pass is left off, so the
// runtime applies its own default; a passed --port is forwarded for the runtime's
// own range validation.
cli_run_attach :: proc(inv: ^cli.Cli_Invocation) -> int {
	attach_args := make([dynamic]string, 0, 4 + len(inv.args), context.temp_allocator)
	append(&attach_args, "funpack")
	append(&attach_args, "attach")
	append(&attach_args, ..inv.args)
	if _, passed := inv.flags["port"]; passed {
		append(&attach_args, "--port")
		append(&attach_args, fmt.tprintf("%d", cli.cli_flag_int(inv, "port")))
	}
	return funpack_runtime.run_attach_session(attach_args[:])
}
