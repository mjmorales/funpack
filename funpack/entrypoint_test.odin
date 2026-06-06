// Emit-facing entrypoint selection tests: the §14 entrypoints grammar itself
// is exercised in project_test (parse_entrypoints_fcfg / validate_entrypoints);
// these pin what entrypoint.odin and stage_emit add on top of it — the
// exactly-one selection, the integer-Hz conversion, and the emission-time
// reference validation against the checked source.
package funpack

import "core:testing"

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
