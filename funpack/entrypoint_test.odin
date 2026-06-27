package funpack

import "core:strings"
import "core:testing"

@(test)
test_emit_entrypoint_seed_field :: proc(t: ^testing.T) {
	seeded := Entrypoint_Config {
		name = "main",
		pipeline = "Pong",
		tick_hz = 60,
		logical_w = 160,
		logical_h = 120,
		bindings = "bindings",
		has_seed = true,
		seed = 1234,
	}
	sb := strings.builder_make(context.temp_allocator)
	emit_entrypoint(&sb, seeded)
	testing.expect(t, strings.contains(strings.to_string(sb), " seed:1234\n"))

	seedless := seeded
	seedless.has_seed = false
	seedless.seed = 0
	sb2 := strings.builder_make(context.temp_allocator)
	emit_entrypoint(&sb2, seedless)
	testing.expect(t, !strings.contains(strings.to_string(sb2), "seed:"))
	testing.expect(t, strings.has_suffix(strings.to_string(sb2), " bindings:bindings\n"))
}

@(test)
test_select_entrypoint_happy :: proc(t: ^testing.T) {
	parsed, parse_err := parse_entrypoints_fcfg(PONG_ENTRYPOINTS)
	testing.expect_value(t, parse_err, Entrypoints_Error.None)
	config, err := select_entrypoint(parsed)
	testing.expect_value(t, err, Entrypoints_Error.None)
	testing.expect_value(t, config.name, "main")
	testing.expect_value(t, config.pipeline, "Pong")
	testing.expect_value(t, config.tick_hz, 60)
	testing.expect_value(t, config.logical_w, 160)
	testing.expect_value(t, config.logical_h, 120)
	testing.expect_value(t, config.bindings, "bindings")
	testing.expect(t, !config.has_seed)
}

@(test)
test_select_entrypoint_with_config_seed :: proc(t: ^testing.T) {
	content := "use pong.{Pong, bindings}\n\nentrypoint main {\n  pipeline = Pong\n  tick = 60hz\n  logical = 160x120\n  bindings = bindings\n  seed = 1234\n}\n"
	parsed, parse_err := parse_entrypoints_fcfg(content)
	testing.expect_value(t, parse_err, Entrypoints_Error.None)
	config, err := select_entrypoint(parsed)
	testing.expect_value(t, err, Entrypoints_Error.None)
	testing.expect(t, config.has_seed)
	testing.expect_value(t, config.seed, i64(1234))
}

@(test)
test_select_entrypoint_bad_seed_rejected :: proc(t: ^testing.T) {
	content := "use pong.{Pong, bindings}\n\nentrypoint main {\n  pipeline = Pong\n  tick = 60hz\n  logical = 160x120\n  bindings = bindings\n  seed = 12oops\n}\n"
	parsed, parse_err := parse_entrypoints_fcfg(content)
	testing.expect_value(t, parse_err, Entrypoints_Error.None)
	_, err := select_entrypoint(parsed)
	testing.expect_value(t, err, Entrypoints_Error.Malformed_Entrypoints_Fcfg)
}

@(test)
test_select_entrypoint_bad_logical_rejected :: proc(t: ^testing.T) {
	zero := "use pong.{Pong, bindings}\n\nentrypoint main {\n  pipeline = Pong\n  tick = 60hz\n  logical = 160x0\n  bindings = bindings\n}\n"
	parsed_zero, parse_zero_err := parse_entrypoints_fcfg(zero)
	testing.expect_value(t, parse_zero_err, Entrypoints_Error.None)
	_, zero_err := select_entrypoint(parsed_zero)
	testing.expect_value(t, zero_err, Entrypoints_Error.Malformed_Entrypoints_Fcfg)

	no_sep := "use pong.{Pong, bindings}\n\nentrypoint main {\n  pipeline = Pong\n  tick = 60hz\n  logical = 160\n  bindings = bindings\n}\n"
	parsed_no_sep, parse_no_sep_err := parse_entrypoints_fcfg(no_sep)
	testing.expect_value(t, parse_no_sep_err, Entrypoints_Error.None)
	_, no_sep_err := select_entrypoint(parsed_no_sep)
	testing.expect_value(t, no_sep_err, Entrypoints_Error.Malformed_Entrypoints_Fcfg)
}

@(test)
test_select_entrypoint_multiple_blocks_rejected :: proc(t: ^testing.T) {
	content := "use pong.{Pong, bindings}\n\nentrypoint main {\n  pipeline = Pong\n  tick = 60hz\n  logical = 160x120\n  bindings = bindings\n}\nentrypoint replay {\n  pipeline = Pong\n  tick = 30hz\n  logical = 160x120\n  bindings = bindings\n}\n"
	parsed, parse_err := parse_entrypoints_fcfg(content)
	testing.expect_value(t, parse_err, Entrypoints_Error.None)
	_, err := select_entrypoint(parsed)
	testing.expect_value(t, err, Entrypoints_Error.Multiple_Entrypoints)
}

@(test)
test_select_entrypoint_bad_rate_rejected :: proc(t: ^testing.T) {
	content := "use pong.{Pong, bindings}\n\nentrypoint main {\n  pipeline = Pong\n  tick = 60khz\n  logical = 160x120\n  bindings = bindings\n}\n"
	parsed, parse_err := parse_entrypoints_fcfg(content)
	testing.expect_value(t, parse_err, Entrypoints_Error.None)
	_, err := select_entrypoint(parsed)
	testing.expect_value(t, err, Entrypoints_Error.Malformed_Entrypoints_Fcfg)
}

@(test)
test_parse_entrypoints_fcfg_unknown_key_rejected :: proc(t: ^testing.T) {
	content := "use pong.{Pong, bindings}\n\nentrypoint main {\n  pipeline = Pong\n  tick = 60hz\n  bindings = bindings\n  warp = fast\n}\n"
	_, err := parse_entrypoints_fcfg(content)
	testing.expect_value(t, err, Entrypoints_Error.Malformed_Entrypoints_Fcfg)
}

@(test)
test_parse_entrypoints_fcfg_missing_use_rejected :: proc(t: ^testing.T) {
	content := "entrypoint main {\n  pipeline = Pong\n  tick = 60hz\n  bindings = bindings\n}\n"
	_, err := parse_entrypoints_fcfg(content)
	testing.expect_value(t, err, Entrypoints_Error.Malformed_Entrypoints_Fcfg)
}

@(test)
test_stage_emit_dangling_entrypoint_rejected :: proc(t: ^testing.T) {
	inputs, ok := pong_emit_inputs(t)
	if !ok {
		return
	}
	dangling := "use pong.{Missing, bindings}\nentrypoint main {\n  pipeline = Missing\n  tick = 60hz\n  logical = 160x120\n  bindings = bindings\n}\n"
	_, err := stage_emit(inputs.source, inputs.module, inputs.project, dangling, context.temp_allocator)
	testing.expect_value(t, err, Emit_Error.Entrypoint_Failed)
}
