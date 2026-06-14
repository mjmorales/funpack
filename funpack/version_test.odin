// The version-verb golden: `funpack version` (version.odin) renders the
// toolchain version embedded from the repo-root VERSION file plus the bundled
// schema-version compatibility surface. The exact version string is
// release-managed (it changes every tag), so these tests pin the FORMAT and the
// constant WIRING — never a frozen version literal — and assert the embedded
// value is trimmed and the render is deterministic.
package funpack

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
