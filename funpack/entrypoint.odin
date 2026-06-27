package funpack

import "core:strconv"
import "core:strings"

Entrypoint_Config :: struct {
	name:      string,
	pipeline:  string,
	tick_hz:   int,
	logical_w: int,
	logical_h: int,
	bindings:  string,
	has_seed:  bool,
	seed:      i64,
}

select_entrypoint :: proc(parsed: Entrypoints) -> (config: Entrypoint_Config, err: Entrypoints_Error) {
	if len(parsed.entrypoints) != 1 {
		return Entrypoint_Config{}, .Multiple_Entrypoints
	}
	block := parsed.entrypoints[0]
	hz, ok := parse_tick_hz(block.tick)
	if !ok {
		return Entrypoint_Config{}, .Malformed_Entrypoints_Fcfg
	}
	w, h, logical_ok := parse_logical_extent(block.logical)
	if !logical_ok {
		return Entrypoint_Config{}, .Malformed_Entrypoints_Fcfg
	}
	has_seed, seed, seed_ok := parse_seed_field(block.seed)
	if !seed_ok {
		return Entrypoint_Config{}, .Malformed_Entrypoints_Fcfg
	}
	return Entrypoint_Config{
			name = block.name,
			pipeline = block.pipeline,
			tick_hz = hz,
			logical_w = w,
			logical_h = h,
			bindings = block.bindings,
			has_seed = has_seed,
			seed = seed,
		},
		.None
}

parse_seed_field :: proc(text: string) -> (has_seed: bool, seed: i64, ok: bool) {
	if text == "" {
		return false, 0, true
	}
	value, parse_ok := strconv.parse_i64(text)
	if !parse_ok {
		return false, 0, false
	}
	return true, value, true
}

parse_tick_hz :: proc(text: string) -> (hz: int, ok: bool) {
	digits := strings.trim_suffix(text, "hz")
	if digits == text {
		return 0, false
	}
	return strconv.parse_int(digits)
}

parse_logical_extent :: proc(text: string) -> (w: int, h: int, ok: bool) {
	sep := strings.index_byte(text, 'x')
	if sep <= 0 || sep >= len(text) - 1 {
		return 0, 0, false
	}
	parsed_w, w_ok := strconv.parse_int(text[:sep])
	parsed_h, h_ok := strconv.parse_int(text[sep + 1:])
	if !w_ok || !h_ok || parsed_w <= 0 || parsed_h <= 0 {
		return 0, 0, false
	}
	return parsed_w, parsed_h, true
}
