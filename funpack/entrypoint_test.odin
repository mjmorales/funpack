// Emit-facing entrypoint selection tests: the §14 entrypoints grammar itself
// is exercised in project_test (parse_entrypoints_fcfg / validate_entrypoints);
// these pin what entrypoint.odin and stage_emit add on top of it — the
// exactly-one selection, the integer-Hz conversion, and the emission-time
// reference validation against the checked source.
package funpack

import "core:strings"
import "core:testing"

@(test)
test_emit_entrypoint_seed_field :: proc(t: ^testing.T) {
	// A baked config seed emits the trailing ` seed:N` field; a seedless config omits
	// it entirely, so a no-config-seed [entrypoint] record is the bare 6-field form.
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
	// The seedless record ends `bindings:bindings\n` with no trailing seed field.
	testing.expect(t, strings.has_suffix(strings.to_string(sb2), " bindings:bindings\n"))
}

@(test)
test_select_entrypoint_happy :: proc(t: ^testing.T) {
	// The golden shape selects to the [entrypoint] wiring with its tick token
	// converted to integer Hz and its logical token split into integer world
	// units.
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
	// The golden block bakes no `seed`, so the config is seedless — the runtime
	// resolves the engine default at launch, and the artifact omits the seed field.
	testing.expect(t, !config.has_seed)
}

@(test)
test_select_entrypoint_with_config_seed :: proc(t: ^testing.T) {
	// An OPTIONAL `seed = N` block key bakes the §25 §60 root seed: the resolved
	// config carries has_seed=true and the parsed integer, which the runtime later
	// uses as the precedence tier below an explicit `--seed`.
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
	// A `seed` value that is not an integer passes the block grammar (a bare
	// digit-led/ident token) but rejects at the conversion — never a silent default.
	content := "use pong.{Pong, bindings}\n\nentrypoint main {\n  pipeline = Pong\n  tick = 60hz\n  logical = 160x120\n  bindings = bindings\n  seed = 12oops\n}\n"
	parsed, parse_err := parse_entrypoints_fcfg(content)
	testing.expect_value(t, parse_err, Entrypoints_Error.None)
	_, err := select_entrypoint(parsed)
	testing.expect_value(t, err, Entrypoints_Error.Malformed_Entrypoints_Fcfg)
}

@(test)
test_select_entrypoint_bad_logical_rejected :: proc(t: ^testing.T) {
	// A logical extent must be `WxH` with both sides positive integers: a
	// zero dimension and a separator-less token both pass the block grammar
	// (digit-led tokens) but reject at the conversion — a degenerate letterbox
	// space never reaches the artifact.
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
	// The v1 artifact carries exactly one [entrypoint] record and there is no
	// selection mechanism — a second block rejects through the dedicated
	// Multiple_Entrypoints arm, never a silent first-block pick.
	content := "use pong.{Pong, bindings}\n\nentrypoint main {\n  pipeline = Pong\n  tick = 60hz\n  logical = 160x120\n  bindings = bindings\n}\nentrypoint replay {\n  pipeline = Pong\n  tick = 30hz\n  logical = 160x120\n  bindings = bindings\n}\n"
	parsed, parse_err := parse_entrypoints_fcfg(content)
	testing.expect_value(t, parse_err, Entrypoints_Error.None)
	_, err := select_entrypoint(parsed)
	testing.expect_value(t, err, Entrypoints_Error.Multiple_Entrypoints)
}

@(test)
test_select_entrypoint_bad_rate_rejected :: proc(t: ^testing.T) {
	// `60khz` passes the grammar's `hz`-suffix check but is not an integer
	// rate — the conversion rejects it as malformed.
	content := "use pong.{Pong, bindings}\n\nentrypoint main {\n  pipeline = Pong\n  tick = 60khz\n  logical = 160x120\n  bindings = bindings\n}\n"
	parsed, parse_err := parse_entrypoints_fcfg(content)
	testing.expect_value(t, parse_err, Entrypoints_Error.None)
	_, err := select_entrypoint(parsed)
	testing.expect_value(t, err, Entrypoints_Error.Malformed_Entrypoints_Fcfg)
}

@(test)
test_parse_entrypoints_fcfg_unknown_key_rejected :: proc(t: ^testing.T) {
	// The §14 grammar's key set is closed — an unknown key inside the block is
	// a grammar violation, never silently dropped wiring.
	content := "use pong.{Pong, bindings}\n\nentrypoint main {\n  pipeline = Pong\n  tick = 60hz\n  bindings = bindings\n  warp = fast\n}\n"
	_, err := parse_entrypoints_fcfg(content)
	testing.expect_value(t, err, Entrypoints_Error.Malformed_Entrypoints_Fcfg)
}

@(test)
test_parse_entrypoints_fcfg_missing_use_rejected :: proc(t: ^testing.T) {
	// The grammar mandates the leading `use` source reference — an
	// entrypoints.fcfg that names no source module is malformed.
	content := "entrypoint main {\n  pipeline = Pong\n  tick = 60hz\n  bindings = bindings\n}\n"
	_, err := parse_entrypoints_fcfg(content)
	testing.expect_value(t, err, Entrypoints_Error.Malformed_Entrypoints_Fcfg)
}

@(test)
test_stage_emit_dangling_entrypoint_rejected :: proc(t: ^testing.T) {
	// Emission validates the entrypoint references against the checked source
	// (§07's dangling-reference obligation): an entrypoints.fcfg naming a
	// pipeline the module does not declare yields no artifact, so a
	// [entrypoint] section can never name wiring the runtime cannot resolve.
	// Rides the pong golden inputs and SKIPs with them when absent.
	inputs, ok := pong_emit_inputs(t)
	if !ok {
		return
	}
	dangling := "use pong.{Missing, bindings}\nentrypoint main {\n  pipeline = Missing\n  tick = 60hz\n  logical = 160x120\n  bindings = bindings\n}\n"
	_, err := stage_emit(inputs.source, inputs.module, inputs.project, dangling, context.temp_allocator)
	testing.expect_value(t, err, Emit_Error.Entrypoint_Failed)
}
