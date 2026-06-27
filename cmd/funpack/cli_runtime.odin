package main

import "../../cli"
import funpack_runtime "../../runtime"
import "core:slice"

build_live_command :: proc(allocator := context.allocator) -> ^cli.Cli_Command {
	return cli.cli_new_command(
		cli.Cli_Command {
			use = "live",
			short = "Play a prebuilt game artifact (no rebuild)",
			long = "Launch an ALREADY-built artifact (from `funpack build`, default .funpack/artifact) in the live SDL session, without rebuilding. The artifact path is required; an optional second positional is the replay-out path. --seed overrides the root RNG seed (§25 §60) for this run. Use `funpack run` to build and play in one step.",
			args = cli.cli_range_args(1, 2),
			flags = slice.clone(
				[]cli.Cli_Flag {
					{
						name = "seed",
						kind = .Int,
						usage = "Root RNG seed for this run (§25 §60); overrides the entrypoints.fcfg config seed and the fixed engine default. Recorded in the replay header so the run re-folds",
					},
				},
				allocator,
			),
			run = cli_run_live,
		},
		allocator,
	)
}

cli_run_live :: proc(inv: ^cli.Cli_Invocation) -> int {
	live_args := make([dynamic]string, 0, 3 + len(inv.args), context.temp_allocator)
	append(&live_args, "funpack live")
	append(&live_args, ..inv.args)
	cli.cli_marshal_int_flag(&live_args, inv, "seed")
	return funpack_runtime.run_live_session(live_args[:])
}

build_attach_command :: proc(allocator := context.allocator) -> ^cli.Cli_Command {
	return cli.cli_new_command(
		cli.Cli_Command {
			use = "attach",
			short = "Open a §28 introspection session over a built artifact",
			long = "Load a built artifact and serve an introspection session on the auth-gated loopback port (§28.2 remote-attach). The artifact path is required; an optional second positional is a recorded replay log to pre-fold. --port overrides the loopback port (pass 0 for a kernel-assigned ephemeral port). --port-file writes the actual bound port (bare decimal) so a supervisor can dial it without racing the bind. --token-file reads the per-session auth token from a file, taking precedence over FUNPACK_ATTACH_TOKEN so the secret stays off the inherited environment. --seed overrides the root RNG seed (§25 §60) for a BARE open of a uses_rng game so the session reproduces the seeded run; it is ignored over a replay log (the log pins its own seed).",
			flags = slice.clone(
				[]cli.Cli_Flag {
					{
						name = "port",
						kind = .Int,
						usage = "Override the loopback port the introspection session serves on (0 = ephemeral kernel-assigned)",
					},
					{
						name = "port-file",
						kind = .String,
						usage = "Write the actual bound port (bare decimal) to this path before accepting, for the supervisor to read",
					},
					{
						name = "token-file",
						kind = .String,
						usage = "Read the auth token from this file (precedence over FUNPACK_ATTACH_TOKEN)",
					},
					{
						name = "seed",
						kind = .Int,
						usage = "Root RNG seed for a BARE open of a uses_rng game (§25 §60); overrides the entrypoints.fcfg config seed and the fixed engine default so the bare session reproduces the seeded run. Ignored over a replay log",
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

cli_run_attach :: proc(inv: ^cli.Cli_Invocation) -> int {
	attach_args := make([dynamic]string, 0, 8 + len(inv.args), context.temp_allocator)
	append(&attach_args, "funpack")
	append(&attach_args, "attach")
	append(&attach_args, ..inv.args)
	cli.cli_marshal_int_flag(&attach_args, inv, "port")
	cli.cli_marshal_string_flag(&attach_args, inv, "port-file")
	cli.cli_marshal_string_flag(&attach_args, inv, "token-file")
	cli.cli_marshal_int_flag(&attach_args, inv, "seed")
	return funpack_runtime.run_attach_session(attach_args[:])
}
