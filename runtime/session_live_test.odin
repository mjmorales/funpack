package funpack_runtime

import "core:testing"

@(private = "file")
PONG_BOARD :: Vec2{Fixed(687194767360), Fixed(515396075520)}

@(private = "file")
PONG_WINDOW :: Window_Px{640, 480}

@(test)
test_live_window_for_integer_scale :: proc(t: ^testing.T) {
	testing.expect_value(t, live_window_for(160, 120), Window_Px{640, 480})
	testing.expect_value(t, live_window_for(160, 160), Window_Px{640, 640})
	testing.expect_value(t, live_window_for(200, 100), Window_Px{600, 300})
}

@(test)
test_live_window_for_oversized_logical_is_1x :: proc(t: ^testing.T) {
	testing.expect_value(t, live_window_for(1000, 800), Window_Px{1000, 800})
}

@(test)
test_board_extent_matches_artifact_geometry :: proc(t: ^testing.T) {
	testing.expect_value(t, board_extent(160, 120), PONG_BOARD)
}

@(test)
test_world_to_pixel_origin_rail :: proc(t: ^testing.T) {
	px := world_to_pixel(VEC2_ZERO, PONG_BOARD, PONG_WINDOW)
	testing.expect_value(t, px, Pixel{0, 0})
}

@(test)
test_world_to_pixel_board_extent_rail :: proc(t: ^testing.T) {
	extent := Vec2{PONG_BOARD.x, PONG_BOARD.y}
	px := world_to_pixel(extent, PONG_BOARD, PONG_WINDOW)
	testing.expect_value(t, px, Pixel{640, 480})
}

@(test)
test_world_to_pixel_ball_start_rail :: proc(t: ^testing.T) {
	ball := Vec2{to_fixed(80), to_fixed(60)}
	px := world_to_pixel(ball, PONG_BOARD, PONG_WINDOW)
	testing.expect_value(t, px, Pixel{320, 240})
}

@(test)
test_world_axis_to_pixel_zero_board_is_total :: proc(t: ^testing.T) {
	testing.expect_value(t, world_axis_to_pixel(to_fixed(80), 640, Fixed(0)), i32(0))
}

@(test)
test_camera_identity_is_world_to_pixel :: proc(t: ^testing.T) {
	camera := identity_camera(PONG_BOARD)
	ball := Vec2{to_fixed(80), to_fixed(60)}
	px := camera_world_to_pixel(ball, camera, PONG_BOARD, PONG_WINDOW)
	testing.expect_value(t, px, Pixel{320, 240})
}

@(test)
test_camera_recenter_maps_camera_at_to_screen_center :: proc(t: ^testing.T) {
	camera := Camera_View{at = Vec2{to_fixed(40), to_fixed(30)}, zoom = to_fixed(1)}

	center := camera_world_to_pixel(Vec2{to_fixed(40), to_fixed(30)}, camera, PONG_BOARD, PONG_WINDOW)
	testing.expect_value(t, center, Pixel{320, 240})

	offset := camera_world_to_pixel(Vec2{to_fixed(80), to_fixed(60)}, camera, PONG_BOARD, PONG_WINDOW)
	testing.expect_value(t, offset, Pixel{480, 360})
}

@(test)
test_camera_zoom_scales_offset_from_center :: proc(t: ^testing.T) {
	camera := Camera_View{at = Vec2{to_fixed(80), to_fixed(60)}, zoom = to_fixed(2)}

	zoomed := camera_world_to_pixel(Vec2{to_fixed(100), to_fixed(60)}, camera, PONG_BOARD, PONG_WINDOW)
	testing.expect_value(t, zoomed, Pixel{480, 240})

	center := camera_world_to_pixel(Vec2{to_fixed(80), to_fixed(60)}, camera, PONG_BOARD, PONG_WINDOW)
	testing.expect_value(t, center, Pixel{320, 240})
}

@(test)
test_camera_pre_transform_is_exact_fixed_point :: proc(t: ^testing.T) {
	camera := Camera_View{at = Vec2{to_fixed(40), to_fixed(30)}, zoom = to_fixed(2)}
	world := Vec2{to_fixed(50), to_fixed(40)}
	got := camera_pre_transform(world, camera, PONG_BOARD)
	testing.expect_value(t, got, Vec2{to_fixed(100), to_fixed(80)})
}

@(test)
test_camera_from_command_zero_zoom_is_unity :: proc(t: ^testing.T) {
	camera := camera_from_command(Draw_Camera{at = Vec2{to_fixed(80), to_fixed(60)}, zoom = Fixed(0), rotation = Fixed(0)})
	testing.expect_value(t, camera.zoom, to_fixed(1))
}

@(test)
test_draw_color_to_rgba_totality :: proc(t: ^testing.T) {
	testing.expect_value(t, draw_color_to_rgba(named_color(.White)), Rgba8{255, 255, 255, 255})
	testing.expect_value(t, draw_color_to_rgba(named_color(.Black)), Rgba8{0, 0, 0, 255})
	testing.expect_value(t, draw_color_to_rgba(named_color(.Red)), Rgba8{255, 0, 0, 255})
	testing.expect_value(t, draw_color_to_rgba(named_color(.Green)), Rgba8{0, 255, 0, 255})
	testing.expect_value(t, draw_color_to_rgba(named_color(.Blue)), Rgba8{0, 0, 255, 255})
	testing.expect_value(t, draw_color_to_rgba(named_color(.Yellow)), Rgba8{255, 255, 0, 255})
	testing.expect_value(t, draw_color_to_rgba(named_color(.Cyan)), Rgba8{0, 255, 255, 255})
	testing.expect_value(t, draw_color_to_rgba(named_color(.Magenta)), Rgba8{255, 0, 255, 255})
	testing.expect_value(t, draw_color_to_rgba(named_color(.Gray)), Rgba8{128, 128, 128, 255})
}

@(test)
test_draw_color_to_rgba_maps_rgb_channels_deterministically :: proc(t: ^testing.T) {
	testing.expect_value(t, draw_color_to_rgba(rgb_color(Fixed(0), Fixed(0), Fixed(0))), Rgba8{0, 0, 0, 255})
	testing.expect_value(t, draw_color_to_rgba(rgb_color(FIXED_ONE, FIXED_ONE, FIXED_ONE)), Rgba8{255, 255, 255, 255})
	half := fixed_div(FIXED_ONE, to_fixed(2))
	testing.expect_value(t, draw_color_to_rgba(rgb_color(half, half, half)), Rgba8{128, 128, 128, 255})
	testing.expect_value(t, draw_color_to_rgba(rgb_color(FIXED_ONE, half, Fixed(0))), Rgba8{255, 128, 0, 255})
	testing.expect_value(t, draw_color_to_rgba(rgb_color(to_fixed(2), fixed_neg(FIXED_ONE), Fixed(0))), Rgba8{255, 0, 0, 255})
}

@(test)
test_glyph_rects_space_is_empty :: proc(t: ^testing.T) {
	rects := glyph_rects(' ', VEC2_ZERO, Vec2{to_fixed(1), to_fixed(1)}, named_color(.White), context.temp_allocator)
	testing.expect_value(t, len(rects), 0)
}

@(test)
test_glyph_rects_unmapped_is_loud_tofu :: proc(t: ^testing.T) {
	rects := glyph_rects('?', VEC2_ZERO, Vec2{to_fixed(1), to_fixed(1)}, named_color(.White), context.temp_allocator)
	testing.expect_value(t, len(rects), 15)
}

@(test)
test_glyph_rects_one_glyph :: proc(t: ^testing.T) {
	cell := Vec2{to_fixed(2), to_fixed(3)}
	origin := Vec2{to_fixed(10), to_fixed(20)}
	rects := glyph_rects('1', origin, cell, named_color(.White), context.temp_allocator)
	testing.expect_value(t, len(rects), 8)
	first := rects[0]
	testing.expect_value(t, first.color, named_color(.White))
	testing.expect_value(t, first.size, cell)
	testing.expect_value(t, first.at.x, fixed_add(fixed_add(origin.x, cell.x), fixed_div(cell.x, to_fixed(2))))
	testing.expect_value(t, first.at.y, fixed_add(origin.y, fixed_div(cell.y, to_fixed(2))))
}

@(test)
test_glyph_rects_eight_is_full_block :: proc(t: ^testing.T) {
	cell := Vec2{to_fixed(4), to_fixed(4)}
	rects := glyph_rects('8', VEC2_ZERO, cell, named_color(.White), context.temp_allocator)
	testing.expect_value(t, len(rects), 13)
}

@(test)
test_glyph_rects_zero_corner_placement :: proc(t: ^testing.T) {
	cell := Vec2{to_fixed(5), to_fixed(7)}
	origin := Vec2{to_fixed(100), to_fixed(200)}
	rects := glyph_rects('0', origin, cell, named_color(.White), context.temp_allocator)
	testing.expect_value(t, len(rects), 12)
	last := rects[len(rects) - 1]
	last_corner_x := fixed_add(origin.x, fixed_mul(cell.x, to_fixed(2)))
	last_corner_y := fixed_add(origin.y, fixed_mul(cell.y, to_fixed(4)))
	testing.expect_value(t, last.at.x, fixed_add(last_corner_x, fixed_div(cell.x, to_fixed(2))))
	testing.expect_value(t, last.at.y, fixed_add(last_corner_y, fixed_div(cell.y, to_fixed(2))))
}

@(test)
test_glyph_rects_letters_distinct :: proc(t: ^testing.T) {
	cell := Vec2{to_fixed(1), to_fixed(1)}
	letter_o := glyph_rects('O', VEC2_ZERO, cell, named_color(.Green), context.temp_allocator)
	digit_0 := glyph_rects('0', VEC2_ZERO, cell, named_color(.Green), context.temp_allocator)
	testing.expect_value(t, len(letter_o), 8)
	testing.expect_value(t, len(digit_0), 12)

	upper_g := glyph_rects('G', VEC2_ZERO, cell, named_color(.Green), context.temp_allocator)
	lower_g := glyph_rects('g', VEC2_ZERO, cell, named_color(.Green), context.temp_allocator)
	testing.expect_value(t, len(upper_g), 9)
	testing.expect_value(t, len(lower_g), 9)
	testing.expect_value(t, upper_g[0].color, named_color(.Green))
	testing.expect_value(t, upper_g[0].at, lower_g[0].at)
}
