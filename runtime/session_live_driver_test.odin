package funpack_runtime

import "core:testing"

@(test)
test_replay_out_path_swaps_extension :: proc(t: ^testing.T) {
	out := replay_out_path("testdata/pong.artifact", "", context.temp_allocator)
	testing.expect_value(t, out, "testdata/pong.replay")
}

@(test)
test_replay_out_path_no_extension_appends :: proc(t: ^testing.T) {
	out := replay_out_path("build/pong", "", context.temp_allocator)
	testing.expect_value(t, out, "build/pong.replay")
}

@(test)
test_replay_out_path_override_wins :: proc(t: ^testing.T) {
	out := replay_out_path("testdata/pong.artifact", "/tmp/custom.replay", context.temp_allocator)
	testing.expect_value(t, out, "/tmp/custom.replay")
}

@(test)
test_replay_out_path_preserves_nested_dir :: proc(t: ^testing.T) {
	out := replay_out_path("a/b/c/game.fpk", "", context.temp_allocator)
	testing.expect_value(t, out, "a/b/c/game.replay")
}

@(test)
test_save_root_path_swaps_extension :: proc(t: ^testing.T) {
	root := save_root_path("testdata/yard.artifact", context.temp_allocator)
	testing.expect_value(t, root, "testdata/yard.saves")
}

@(test)
test_save_root_path_no_extension_appends :: proc(t: ^testing.T) {
	root := save_root_path("build/yard", context.temp_allocator)
	testing.expect_value(t, root, "build/yard.saves")
}

@(test)
test_save_root_path_preserves_nested_dir :: proc(t: ^testing.T) {
	root := save_root_path("a/b/c/game.fpk", context.temp_allocator)
	testing.expect_value(t, root, "a/b/c/game.saves")
}

@(test)
test_text_rects_empty_is_no_rects :: proc(t: ^testing.T) {
	rects := text_rects("", Vec2{to_fixed(80), to_fixed(8)}, TEXT_CELL, named_color(.White), context.temp_allocator)
	testing.expect_value(t, len(rects), 0)
}

@(test)
test_text_rects_centers_the_run :: proc(t: ^testing.T) {
	at := Vec2{to_fixed(80), to_fixed(8)}
	rects := text_rects("1", at, TEXT_CELL, named_color(.Green), context.temp_allocator)
	testing.expect_value(t, len(rects), 8)
	first := rects[0]
	testing.expect_value(t, first.color, named_color(.Green))
	testing.expect_value(t, first.size, TEXT_CELL)
	testing.expect_value(t, first.at.x, to_fixed(80))
	testing.expect_value(t, first.at.y, to_fixed(4))
}

@(test)
test_text_rects_advances_per_character :: proc(t: ^testing.T) {
	at := Vec2{to_fixed(80), to_fixed(8)}
	rects := text_rects("0 0", at, TEXT_CELL, named_color(.White), context.temp_allocator)
	testing.expect_value(t, len(rects), 24)
	half_y := fixed_div(TEXT_CELL.y, to_fixed(2))
	testing.expect_value(t, rects[12].at.x, to_fixed(86))
	testing.expect_value(t, rects[12].at.y, fixed_add(fixed_sub(at.y, to_fixed(5)), half_y))
}
