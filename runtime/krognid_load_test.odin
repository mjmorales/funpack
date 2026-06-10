// The krognid multi-module loader smoke test: the committed
// runtime/testdata/krognid.artifact — the funpack emitter's product over the live
// 2-module krognid tree (stroll entrypoint + the baked rig seam) — #loads into a
// Program with NO refusal at the current v6 stamp. This is the runtime side of the
// coupled v5→v6 version bump: the artifact is the cross-team byte seam (spec §29),
// so this proves the runtime parses the multi-module shape the emitter now writes.
//
// SCOPE: this is the MINIMAL parse acceptance — load succeeds, the v6 stamp gates,
// and the §17 cross-module seam-fn carry landed (both seam fns are in [functions]
// alongside the entrypoint module's). The DEEP consumption of the krognid program
// (executing the Rigged draw, the rig pose blend) belongs to later runtime stories;
// this test only pins that the bytes load.
package funpack_runtime

import "core:testing"

// KROGNID_ARTIFACT is the committed multi-module krognid artifact, embedded at
// compile time. `#load` keeps the test hermetic — no filesystem, no cwd, no funpack
// source on the path, exactly as the pong golden does (artifact_load_test.odin).
KROGNID_ARTIFACT := #load("testdata/krognid.artifact", string)

// test_load_krognid_artifact_parses is the coupled multi-module loader
// acceptance (the v6 carry): the committed krognid artifact loads with no
// error, carries the current ARTIFACT_SCHEMA_VERSION (the exact-match version
// gate, so the committed copy restamps with every bump), and the §17 seam-fn
// carry is present — krognid_skeleton and krognid_parts (imported from the seam
// module) sit in [functions] alongside the entrypoint module's own fns, so the
// Rigged draw body's calls resolve to a self-contained record by bare name.
@(test)
test_load_krognid_artifact_parses :: proc(t: ^testing.T) {
	program, err := load_program(KROGNID_ARTIFACT, context.temp_allocator)
	if !testing.expectf(t, err == .None, "krognid artifact must load, got %v", err) {
		return
	}

	// The exact-match version gate admitted it at v6 — the multi-module schema.
	testing.expect_value(t, program.schema_version, ARTIFACT_SCHEMA_VERSION)

	// The §17 cross-module seam-fn carry: both seam fns are in [functions], so a
	// bare-name program_function lookup of the Rigged draw's calls finds a body.
	testing.expect(t, program_function(&program, "krognid_skeleton") != nil)
	testing.expect(t, program_function(&program, "krognid_parts") != nil)

	// The entrypoint module's own fns also loaded (the carry APPENDS, never
	// replaces) — pose_walk is one of stroll's helpers.
	testing.expect(t, program_function(&program, "pose_walk") != nil)

	// The Krognid thing schema loaded under its bare name (the runtime resolves
	// things by bare name; the §15-qualification ADR governs the Index Contract
	// surface, not the artifact name token).
	found_krognid := false
	for thing in program.things {
		if thing.name == "Krognid" {
			found_krognid = true
		}
	}
	testing.expect(t, found_krognid)
}
