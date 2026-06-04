package funpack

import "core:testing"

@(test)
test_parse_project_identity_happy :: proc(t: ^testing.T) {
	content := "project numerics {\n  version = \"0.1.0\"\n}\n"
	name, version, ok := parse_project_identity(content)
	testing.expect(t, ok)
	testing.expect_value(t, name, "numerics")
	testing.expect_value(t, version, "0.1.0")
}

@(test)
test_parse_project_identity_missing_version :: proc(t: ^testing.T) {
	_, _, ok := parse_project_identity("project numerics {\n}\n")
	testing.expect(t, !ok)
}

@(test)
test_parse_project_identity_empty :: proc(t: ^testing.T) {
	_, _, ok := parse_project_identity("")
	testing.expect(t, !ok)
}

@(test)
test_read_project_missing_tree :: proc(t: ^testing.T) {
	_, err := read_project("/nonexistent-funpack-project-root")
	testing.expect_value(t, err, Project_Error.Missing_Configs_Dir)
}
