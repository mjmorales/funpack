// The live/run launch contract (§25 §60): the seed-source precedence
// (resolve_root_seed) and the forwarded-argv parse (parse_live_argv) that turn a
// `funpack run`/`live` invocation into a resolved artifact + replay-out + root seed.
// These are the pure half of the run-launch seam — the live session itself is SDL-
// gated, but the seed precedence and the argv grammar fold here so they are pinned
// without a window.
package funpack_runtime

import "core:testing"

// resolve_root_seed honors the §25 §60 precedence top-down: an explicit `--seed`
// override wins over a baked entrypoint config seed, which wins over the fixed engine
// default. Each tier is asserted in isolation so a regression names the broken rung.
@(test)
test_resolve_root_seed_precedence :: proc(t: ^testing.T) {
	with_config := Entrypoint{has_seed = true, seed = 99}
	no_config := Entrypoint{has_seed = false}

	// Override beats everything — even a config seed.
	testing.expect_value(t, resolve_root_seed(i64(7), with_config), i64(7))
	testing.expect_value(t, resolve_root_seed(i64(7), no_config), i64(7))
	// An override of 0 is a REAL choice (Maybe is set), not a fall-through.
	testing.expect_value(t, resolve_root_seed(i64(0), with_config), i64(0))

	// No override → the config seed.
	testing.expect_value(t, resolve_root_seed(nil, with_config), i64(99))
	// A config seed of 0 is honored (has_seed distinguishes it from "no seed").
	testing.expect_value(t, resolve_root_seed(nil, Entrypoint{has_seed = true, seed = 0}), i64(0))

	// No override, no config → the fixed engine default (reproducible by default).
	testing.expect_value(t, resolve_root_seed(nil, no_config), RUNTIME_DEFAULT_SEED)
}

// parse_live_argv extracts the required artifact positional, the optional replay-out
// positional, and the optional `--seed N` pair from a forwarded argv (args[0] is the
// program label). The seed Maybe is unset when no flag was passed so the resolver
// falls through to the config seed / default.
@(test)
test_parse_live_argv_positionals_and_seed :: proc(t: ^testing.T) {
	// Bare artifact: no replay-out, no seed override.
	bare, ok1 := parse_live_argv({"funpack live", "art"})
	testing.expect(t, ok1)
	testing.expect_value(t, bare.artifact, "art")
	testing.expect_value(t, bare.out_override, "")
	_, has1 := bare.seed.?
	testing.expect(t, !has1)

	// Artifact + replay-out.
	two, ok2 := parse_live_argv({"funpack live", "art", "out.replay"})
	testing.expect(t, ok2)
	testing.expect_value(t, two.artifact, "art")
	testing.expect_value(t, two.out_override, "out.replay")

	// --seed before the positional: seed parsed, artifact still resolved.
	pre, ok3 := parse_live_argv({"funpack live", "--seed", "42", "art"})
	testing.expect(t, ok3)
	testing.expect_value(t, pre.artifact, "art")
	seed3, has3 := pre.seed.?
	testing.expect(t, has3)
	testing.expect_value(t, seed3, i64(42))

	// --seed after both positionals: both positionals + the seed resolve.
	post, ok4 := parse_live_argv({"funpack run", "art", "out.replay", "--seed", "-5"})
	testing.expect(t, ok4)
	testing.expect_value(t, post.artifact, "art")
	testing.expect_value(t, post.out_override, "out.replay")
	seed4, has4 := post.seed.?
	testing.expect(t, has4)
	testing.expect_value(t, seed4, i64(-5))
}

// parse_live_argv FAILS CLOSED on a malformed invocation rather than silently
// dropping to a default: no artifact positional, a dangling `--seed` with no value,
// and a non-integer seed value are all usage errors (ok=false), so a typo never runs
// the wrong seed or a no-artifact session.
@(test)
test_parse_live_argv_fails_closed :: proc(t: ^testing.T) {
	_, ok_empty := parse_live_argv({"funpack live"})
	testing.expect(t, !ok_empty)

	_, ok_seed_only := parse_live_argv({"funpack live", "--seed", "42"})
	// --seed 42 leaves NO positional, so the artifact is missing.
	testing.expect(t, !ok_seed_only)

	_, ok_dangling := parse_live_argv({"funpack live", "art", "--seed"})
	testing.expect(t, !ok_dangling)

	_, ok_nonint := parse_live_argv({"funpack live", "art", "--seed", "notanumber"})
	testing.expect(t, !ok_nonint)
}
