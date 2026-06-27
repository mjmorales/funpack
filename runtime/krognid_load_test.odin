package funpack_runtime

import "core:testing"

KROGNID_ARTIFACT := #load("testdata/krognid.artifact", string)

@(test)
test_load_krognid_artifact_parses :: proc(t: ^testing.T) {
	program, err := load_program(KROGNID_ARTIFACT, context.temp_allocator)
	if !testing.expectf(t, err == .None, "krognid artifact must load, got %v", err) {
		return
	}

	testing.expect_value(t, program.schema_version, ARTIFACT_SCHEMA_VERSION)

	testing.expect(t, program_function(&program, "krognid_skeleton") != nil)
	testing.expect(t, program_function(&program, "krognid_parts") != nil)

	testing.expect(t, program_function(&program, "pose_walk") != nil)

	found_krognid := false
	for thing in program.things {
		if thing.name == "Krognid" {
			found_krognid = true
		}
	}
	testing.expect(t, found_krognid)
}
