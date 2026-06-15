// The version-verb golden: `funpack version` (version.odin) renders the
// toolchain version embedded from the repo-root VERSION file plus the bundled
// schema-version compatibility surface. The exact version string is
// release-managed (it changes every tag), so these tests pin the FORMAT and the
// constant WIRING — never a frozen version literal — and assert the embedded
// value is trimmed and the render is deterministic.
package funpack

import "core:encoding/json"
import "core:fmt"
import "core:strings"
import "core:testing"

// test_funpack_version_is_trimmed_nonempty: the embedded VERSION value has its
// POSIX trailing newline stripped and is non-empty — the #load mirror must
// always carry a usable version (a missing file is already a compile error).
@(test)
test_funpack_version_is_trimmed_nonempty :: proc(t: ^testing.T) {
	v := funpack_version()
	testing.expect(t, len(v) > 0, "embedded VERSION must be non-empty")
	testing.expect(t, v == strings.trim_space(v), "embedded VERSION must be whitespace-trimmed")
}

// test_version_report_format: the report leads with the `funpack <version>`
// identity line and carries both schema-version lines sourced from their own
// constants — so the verb cannot drift from the formats a build actually emits.
@(test)
test_version_report_format :: proc(t: ^testing.T) {
	report := version_report(context.temp_allocator)

	want_head := fmt.tprintf("funpack %s\n", funpack_version())
	testing.expect(t, strings.has_prefix(report, want_head), "report must lead with the funpack version line")

	want_artifact := fmt.tprintf("  artifact-schema  v%d\n", ARTIFACT_SCHEMA_VERSION)
	testing.expect(t, strings.contains(report, want_artifact), "report must carry the artifact schema version")

	want_index := fmt.tprintf("  index-schema     v%d\n", INDEX_SCHEMA_VERSION)
	testing.expect(t, strings.contains(report, want_index), "report must carry the index schema version")
}

// test_version_report_is_deterministic: a pure function of compile-time
// constants — two renders are byte-identical (§29 determinism floor).
@(test)
test_version_report_is_deterministic :: proc(t: ^testing.T) {
	a := version_report(context.temp_allocator)
	b := version_report(context.temp_allocator)
	testing.expect_value(t, a, b)
}

// test_version_report_json_is_valid_contract_shape: `funpack version --json`
// emits well-formed JSON whose KEYS are the generated contract field-name
// constants (api_contract.gen.odin) and whose VALUES are the embedded version and
// the two schema constants — so the machine surface the MCP resolver consumes can
// never drift from contract/funpack-api.json on either side. Parsed through
// core:encoding/json (a real parse, not a substring sniff), then each field is
// read by its generated key and asserted against its source-of-truth constant.
@(test)
test_version_report_json_is_valid_contract_shape :: proc(t: ^testing.T) {
	report := version_report_json(context.temp_allocator)

	// parse_integers = true keeps the schema versions as json.Integer (the §29 §1
	// no-float discipline the Index Contract reader uses); the default float path
	// would type them as json.Float.
	value, err := json.parse_string(report, parse_integers = true, allocator = context.temp_allocator)
	testing.expect(t, err == .None, "version --json must emit valid JSON")

	root, is_object := value.(json.Object)
	testing.expect(t, is_object, "the JSON root must be an object")

	// version: the embedded toolchain semver, keyed by the generated field-name
	// constant — never a hardcoded "version" literal.
	version_field, has_version := root[VERSION_FIELD_VERSION]
	testing.expect(t, has_version, "JSON must carry the version field")
	version_string, version_is_string := version_field.(json.String)
	testing.expect(t, version_is_string, "version must be a JSON string")
	testing.expect_value(t, string(version_string), funpack_version())

	// schemas: a nested object of schema-name -> emitted version, keyed by the
	// generated constants — the values equal the Odin schema constants exactly.
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

	// introspect is intentionally NOT emitted yet (the contract's "absent schema"
	// case) — the held t-version-line story adds it.
	_, has_introspect := schemas[SCHEMA_NAME_INTROSPECT]
	testing.expect(t, !has_introspect, "introspect schema must be absent until t-version-line lands")
}

// test_version_report_json_is_deterministic: the machine surface is a pure
// function of compile-time constants — two renders are byte-identical, and the
// value carries no trailing newline (a machine surface emits exactly the JSON).
@(test)
test_version_report_json_is_deterministic :: proc(t: ^testing.T) {
	a := version_report_json(context.temp_allocator)
	b := version_report_json(context.temp_allocator)
	testing.expect_value(t, a, b)
	testing.expect(t, !strings.has_suffix(a, "\n"), "the JSON value carries no trailing newline")
}
