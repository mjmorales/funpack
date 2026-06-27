package funpack

import "core:encoding/json"
import "core:fmt"
import "core:strings"
import "core:testing"

@(test)
test_funpack_version_is_trimmed_nonempty :: proc(t: ^testing.T) {
	v := funpack_version()
	testing.expect(t, len(v) > 0, "embedded VERSION must be non-empty")
	testing.expect(t, v == strings.trim_space(v), "embedded VERSION must be whitespace-trimmed")
}

@(test)
test_version_report_format :: proc(t: ^testing.T) {
	report := version_report(context.temp_allocator)

	want_head := fmt.tprintf("funpack %s\n", funpack_version())
	testing.expect(t, strings.has_prefix(report, want_head), "report must lead with the funpack version line")

	want_artifact := fmt.tprintf("  artifact-schema    v%d\n", ARTIFACT_SCHEMA_VERSION)
	testing.expect(t, strings.contains(report, want_artifact), "report must carry the artifact schema version")

	want_index := fmt.tprintf("  index-schema       v%d\n", INDEX_SCHEMA_VERSION)
	testing.expect(t, strings.contains(report, want_index), "report must carry the index schema version")

	want_introspect := fmt.tprintf("  introspect-schema  v%d\n", INTROSPECT_SCHEMA_VERSION)
	testing.expect(t, strings.contains(report, want_introspect), "report must carry the introspect schema version")
}

@(test)
test_version_report_is_deterministic :: proc(t: ^testing.T) {
	a := version_report(context.temp_allocator)
	b := version_report(context.temp_allocator)
	testing.expect_value(t, a, b)
}

@(test)
test_version_report_json_is_valid_contract_shape :: proc(t: ^testing.T) {
	report := version_report_json(context.temp_allocator)

	value, err := json.parse_string(report, parse_integers = true, allocator = context.temp_allocator)
	testing.expect(t, err == .None, "version --json must emit valid JSON")

	root, is_object := value.(json.Object)
	testing.expect(t, is_object, "the JSON root must be an object")

	version_field, has_version := root[VERSION_FIELD_VERSION]
	testing.expect(t, has_version, "JSON must carry the version field")
	version_string, version_is_string := version_field.(json.String)
	testing.expect(t, version_is_string, "version must be a JSON string")
	testing.expect_value(t, string(version_string), funpack_version())

	schemas_field, has_schemas := root[VERSION_FIELD_SCHEMAS]
	testing.expect(t, has_schemas, "JSON must carry the schemas object")
	schemas, schemas_is_object := schemas_field.(json.Object)
	testing.expect(t, schemas_is_object, "schemas must be a JSON object")

	artifact_field, has_artifact := schemas[SCHEMA_NAME_ARTIFACT]
	testing.expect(t, has_artifact, "schemas must carry the artifact version")
	artifact_value, artifact_is_int := artifact_field.(json.Integer)
	testing.expect(t, artifact_is_int, "artifact schema version must be a JSON integer")
	testing.expect_value(t, int(artifact_value), int(ARTIFACT_SCHEMA_VERSION))

	index_field, has_index := schemas[SCHEMA_NAME_INDEX]
	testing.expect(t, has_index, "schemas must carry the index version")
	index_value, index_is_int := index_field.(json.Integer)
	testing.expect(t, index_is_int, "index schema version must be a JSON integer")
	testing.expect_value(t, int(index_value), int(INDEX_SCHEMA_VERSION))

	introspect_field, has_introspect := schemas[SCHEMA_NAME_INTROSPECT]
	testing.expect(t, has_introspect, "schemas must carry the introspect version")
	introspect_value, introspect_is_int := introspect_field.(json.Integer)
	testing.expect(t, introspect_is_int, "introspect schema version must be a JSON integer")
	testing.expect_value(t, int(introspect_value), int(INTROSPECT_SCHEMA_VERSION))
}

@(test)
test_version_report_json_is_deterministic :: proc(t: ^testing.T) {
	a := version_report_json(context.temp_allocator)
	b := version_report_json(context.temp_allocator)
	testing.expect_value(t, a, b)
	testing.expect(t, !strings.has_suffix(a, "\n"), "the JSON value carries no trailing newline")
}
