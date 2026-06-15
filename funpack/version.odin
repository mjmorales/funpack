// funpack's version surface: the `funpack version` verb and the toolchain
// version it prints. The version is NOT a hand-edited constant — it is embedded
// from the repo-root VERSION file at compile time via #load (a pure
// compile-time read of the committed bytes: no runtime IO, no clock, the same
// determinism floor the rest of the CLI holds, §29). VERSION is the
// release-managed mirror of the git tag: it is written ONLY by the release
// workflow's `chore(release)` commit (cloud-infra
// github/files/funpack-release.yml), never by hand, so a build's embedded
// version always equals the tag it was cut at.
package funpack

import "core:fmt"
import "core:strings"

// FUNPACK_VERSION_FILE is the raw bytes of the repo-root VERSION file embedded
// at compile time. The file carries a trailing newline (POSIX text); callers
// trim it (funpack_version). A missing VERSION file is a hard compile error —
// the source-of-truth mirror must exist in the tree, by design.
FUNPACK_VERSION_FILE :: #load("../VERSION", string)

// INTROSPECT_SCHEMA_VERSION is funpack's compile-time MIRROR of the §28 §2
// introspect-protocol version. The funpack compiler package may NOT import
// `runtime` (runtime links SDL; importing it breaks the single-binary topology
// and the pure `odin check -no-entry-point` story), so it cannot read
// runtime.INTROSPECT_PROTOCOL_VERSION directly — each package owns its own
// compile-time copy, exactly as ARTIFACT_SCHEMA_VERSION is dual-declared in
// funpack/artifact_format.odin and runtime/artifact_lex.odin. This value MUST
// equal runtime.INTROSPECT_PROTOCOL_VERSION and contract/funpack-api.json's
// `introspect.protocol_version`; a read-only contract-pin test asserts the
// equality, so a silent drift fails CI rather than mis-reporting compatibility.
INTROSPECT_SCHEMA_VERSION :: 1

// funpack_version returns the trimmed toolchain version embedded from VERSION.
// Pure — a function of the compile-time embed alone (the trim is a substring
// view, no allocation).
funpack_version :: proc() -> string {
	return strings.trim_space(FUNPACK_VERSION_FILE)
}

// version_report renders the `funpack version` report: the toolchain version
// line plus the bundled format-compatibility surface (the artifact, Index
// Contract, and §28 introspect schema versions a build of this tree emits and
// reads, sourced from their own constants). A function of the embedded VERSION
// plus ARTIFACT_SCHEMA_VERSION, INDEX_SCHEMA_VERSION, and
// INTROSPECT_SCHEMA_VERSION — no host state — so it is byte-stable for a given
// source tree. The label columns are padded in the literal (the labels are
// compile-time constants) to align every `v` on the longest label
// (`introspect-schema`), so the schema versions align without a format-flag
// dependency. Allocated in `allocator`.
version_report :: proc(allocator := context.allocator) -> string {
	return fmt.aprintf(
		"funpack %s\n  artifact-schema    v%d\n  index-schema       v%d\n  introspect-schema  v%d\n",
		funpack_version(),
		ARTIFACT_SCHEMA_VERSION,
		INDEX_SCHEMA_VERSION,
		INTROSPECT_SCHEMA_VERSION,
		allocator = allocator,
	)
}

// version_report_json renders the machine-readable `funpack version --json`
// surface: the contract shape
// `{"version":"<funpack_version>","schemas":{"artifact":<v>,"index":<v>,"introspect":<v>}}`.
// The MCP resolver consumes this JSON instead of screen-scraping version_report's
// human text (ADR 2026-06-15-funpack-api-contract-dual-codegen). The JSON KEYS are
// the generated field-name constants from api_contract.gen.odin (VERSION_FIELD_*,
// SCHEMA_NAME_*) — never hand-hardcoded here — so the shape can never drift from
// contract/funpack-api.json. The VALUES stay the existing Odin constants
// (ARTIFACT_SCHEMA_VERSION, INDEX_SCHEMA_VERSION, INTROSPECT_SCHEMA_VERSION) and the
// embedded VERSION, so this re-uses one source of truth per concern. The version
// value is a release-managed semver ([0-9.]+ plus pre-release tags) — no characters
// that require JSON escaping — so a direct interpolation stays valid JSON. Pure (a
// function of compile-time constants alone) and byte-stable like version_report.
// No trailing newline: a machine surface emits exactly the JSON value. Allocated
// in `allocator`.
version_report_json :: proc(allocator := context.allocator) -> string {
	return fmt.aprintf(
		`{{"%s":"%s","%s":{{"%s":%d,"%s":%d,"%s":%d}}}}`,
		VERSION_FIELD_VERSION,
		funpack_version(),
		VERSION_FIELD_SCHEMAS,
		SCHEMA_NAME_ARTIFACT,
		ARTIFACT_SCHEMA_VERSION,
		SCHEMA_NAME_INDEX,
		INDEX_SCHEMA_VERSION,
		SCHEMA_NAME_INTROSPECT,
		INTROSPECT_SCHEMA_VERSION,
		allocator = allocator,
	)
}

// run_version_verb prints the version report to stdout and exits 0. An
// informational verb with a single success tier — no refusal, no counted
// failure — so its exit contract is exactly {0}, never the build verbs' 2 or
// the test verb's 1. The json face prints the machine-readable contract shape
// (no trailing newline); the human face keeps the padded multi-line report.
run_version_verb :: proc(json := false) -> int {
	if json {
		fmt.println(version_report_json(context.temp_allocator))
	} else {
		fmt.print(version_report(context.temp_allocator))
	}
	return 0
}
