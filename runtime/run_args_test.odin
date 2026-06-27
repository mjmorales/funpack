package funpack_runtime

import "core:testing"

@(test)
test_resolve_root_seed_precedence :: proc(t: ^testing.T) {
	with_config := Entrypoint{has_seed = true, seed = 99}
	no_config := Entrypoint{has_seed = false}

	testing.expect_value(t, resolve_root_seed(i64(7), with_config), i64(7))
	testing.expect_value(t, resolve_root_seed(i64(7), no_config), i64(7))
	testing.expect_value(t, resolve_root_seed(i64(0), with_config), i64(0))

	testing.expect_value(t, resolve_root_seed(nil, with_config), i64(99))
	testing.expect_value(t, resolve_root_seed(nil, Entrypoint{has_seed = true, seed = 0}), i64(0))

	testing.expect_value(t, resolve_root_seed(nil, no_config), RUNTIME_DEFAULT_SEED)
}

@(test)
test_parse_live_argv_positionals_and_seed :: proc(t: ^testing.T) {
	bare, ok1 := parse_live_argv({"funpack live", "art"})
	testing.expect(t, ok1)
	testing.expect_value(t, bare.artifact, "art")
	testing.expect_value(t, bare.out_override, "")
	_, has1 := bare.seed.?
	testing.expect(t, !has1)

	two, ok2 := parse_live_argv({"funpack live", "art", "out.replay"})
	testing.expect(t, ok2)
	testing.expect_value(t, two.artifact, "art")
	testing.expect_value(t, two.out_override, "out.replay")

	pre, ok3 := parse_live_argv({"funpack live", "--seed", "42", "art"})
	testing.expect(t, ok3)
	testing.expect_value(t, pre.artifact, "art")
	seed3, has3 := pre.seed.?
	testing.expect(t, has3)
	testing.expect_value(t, seed3, i64(42))

	post, ok4 := parse_live_argv({"funpack run", "art", "out.replay", "--seed", "-5"})
	testing.expect(t, ok4)
	testing.expect_value(t, post.artifact, "art")
	testing.expect_value(t, post.out_override, "out.replay")
	seed4, has4 := post.seed.?
	testing.expect(t, has4)
	testing.expect_value(t, seed4, i64(-5))
}

@(test)
test_parse_live_argv_fails_closed :: proc(t: ^testing.T) {
	_, ok_empty := parse_live_argv({"funpack live"})
	testing.expect(t, !ok_empty)

	_, ok_seed_only := parse_live_argv({"funpack live", "--seed", "42"})
	testing.expect(t, !ok_seed_only)

	_, ok_dangling := parse_live_argv({"funpack live", "art", "--seed"})
	testing.expect(t, !ok_dangling)

	_, ok_nonint := parse_live_argv({"funpack live", "art", "--seed", "notanumber"})
	testing.expect(t, !ok_nonint)
}
