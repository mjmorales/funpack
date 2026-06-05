// Emit-facing entrypoint selection tests: read_entrypoint rides the one §14
// entrypoints production (parse_entrypoints_fcfg, exercised in project_test)
// and owns only the selection and tick-conversion semantics on top of it —
// exactly one block, integer Hz. These pin that adapter surface.
package funpack

import "core:testing"

@(test)
test_read_entrypoint_happy :: proc(t: ^testing.T) {
	// The golden shape selects to the [entrypoint] wiring with its tick token
	// converted to integer Hz.
	config, err := read_entrypoint(PONG_ENTRYPOINTS)
	testing.expect_value(t, err, Entrypoints_Error.None)
	testing.expect_value(t, config.name, "main")
	testing.expect_value(t, config.pipeline, "Pong")
	testing.expect_value(t, config.tick_hz, 60)
	testing.expect_value(t, config.bindings, "bindings")
}

@(test)
test_read_entrypoint_multiple_blocks_rejected :: proc(t: ^testing.T) {
	// The v1 artifact carries exactly one [entrypoint] record and there is no
	// selection mechanism — a second block rejects through the dedicated
	// Multiple_Entrypoints arm, never a silent first-block pick.
	content := "use pong.{Pong, bindings}\n\nentrypoint main {\n  pipeline = Pong\n  tick = 60hz\n  bindings = bindings\n}\nentrypoint replay {\n  pipeline = Pong\n  tick = 30hz\n  bindings = bindings\n}\n"
	_, err := read_entrypoint(content)
	testing.expect_value(t, err, Entrypoints_Error.Multiple_Entrypoints)
}

@(test)
test_read_entrypoint_unknown_key_rejected :: proc(t: ^testing.T) {
	// The §14 grammar's key set is closed — an unknown key inside the block is
	// a grammar violation, never silently dropped wiring.
	content := "use pong.{Pong, bindings}\n\nentrypoint main {\n  pipeline = Pong\n  tick = 60hz\n  bindings = bindings\n  warp = fast\n}\n"
	_, err := read_entrypoint(content)
	testing.expect_value(t, err, Entrypoints_Error.Malformed_Entrypoints_Fcfg)
}

@(test)
test_read_entrypoint_bad_rate_rejected :: proc(t: ^testing.T) {
	// `60khz` passes the grammar's `hz`-suffix check but is not an integer
	// rate — the conversion rejects it as malformed.
	content := "use pong.{Pong, bindings}\n\nentrypoint main {\n  pipeline = Pong\n  tick = 60khz\n  bindings = bindings\n}\n"
	_, err := read_entrypoint(content)
	testing.expect_value(t, err, Entrypoints_Error.Malformed_Entrypoints_Fcfg)
}

@(test)
test_read_entrypoint_missing_use_rejected :: proc(t: ^testing.T) {
	// The grammar mandates the leading `use` source reference — an
	// entrypoints.fcfg that names no source module is malformed.
	content := "entrypoint main {\n  pipeline = Pong\n  tick = 60hz\n  bindings = bindings\n}\n"
	_, err := read_entrypoint(content)
	testing.expect_value(t, err, Entrypoints_Error.Malformed_Entrypoints_Fcfg)
}
