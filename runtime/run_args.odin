// The live/run argv grammar: the single place a forwarded `funpack live` /
// `funpack run` argv is parsed into the artifact path, the optional replay-out
// override, and the optional `--seed N` root-seed override (§25 §60). Both verbs
// marshal their resolved CLI invocation into one argv shape the runtime re-parses
// here (the cmd-layer cli_run_live / run_run_verb pattern), so the seed override is
// read in ONE production rather than duplicated per verb. Pure — a function of the
// argv alone — so the precedence and the fail-closed arms are unit-tested without a
// live SDL session, and it is always-compiled (not FUNPACK_LIVE-gated) so the test
// build sees it in both modes.
package funpack_runtime

import "core:strconv"

// Live_Args is the parsed live/run argv: the required artifact path, the optional
// replay-out path override (empty when absent), and the optional `--seed` root-seed
// override (the Maybe is unset when no `--seed` was passed, so resolve_root_seed
// falls through to the config seed / engine default).
Live_Args :: struct {
	artifact:     string,
	out_override: string,
	seed:         Maybe(i64),
}

// parse_live_argv extracts the positionals and the optional `--seed N` flag from a
// forwarded argv. args[0] is the program label (ignored); the remainder is the
// artifact path, an optional replay-out path, and an optional `--seed N` pair in any
// position. The first positional is the artifact (required — ok=false when absent),
// the second is the replay-out override. A `--seed` with no following token, or a
// non-integer value, fails closed (ok=false) so a typo'd seed is a usage error,
// never a silent fall-through to the default seed.
parse_live_argv :: proc(args: []string) -> (parsed: Live_Args, ok: bool) {
	positionals := make([dynamic]string, 0, 2, context.temp_allocator)
	i := 1
	for i < len(args) {
		arg := args[i]
		if arg == "--seed" {
			if i + 1 >= len(args) {
				return {}, false
			}
			value, parse_ok := strconv.parse_i64(args[i + 1])
			if !parse_ok {
				return {}, false
			}
			parsed.seed = value
			i += 2
			continue
		}
		append(&positionals, arg)
		i += 1
	}
	if len(positionals) < 1 {
		return {}, false
	}
	parsed.artifact = positionals[0]
	if len(positionals) >= 2 {
		parsed.out_override = positionals[1]
	}
	return parsed, true
}
