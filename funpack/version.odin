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

// funpack_version returns the trimmed toolchain version embedded from VERSION.
// Pure — a function of the compile-time embed alone (the trim is a substring
// view, no allocation).
funpack_version :: proc() -> string {
	return strings.trim_space(FUNPACK_VERSION_FILE)
}

// version_report renders the `funpack version` report: the toolchain version
// line plus the bundled format-compatibility surface (the artifact and Index
// Contract schema versions a build of this tree emits and reads, sourced from
// their own constants). A function of the embedded VERSION plus
// ARTIFACT_SCHEMA_VERSION and INDEX_SCHEMA_VERSION — no host state — so it is
// byte-stable for a given source tree. The label columns are padded in the
// literal (the labels are compile-time constants), so the schema versions align
// without a format-flag dependency. Allocated in `allocator`.
version_report :: proc(allocator := context.allocator) -> string {
	return fmt.aprintf(
		"funpack %s\n  artifact-schema  v%d\n  index-schema     v%d\n",
		funpack_version(),
		ARTIFACT_SCHEMA_VERSION,
		INDEX_SCHEMA_VERSION,
		allocator = allocator,
	)
}

// run_version_verb prints the version report to stdout and exits 0. An
// informational verb with a single success tier — no refusal, no counted
// failure — so its exit contract is exactly {0}, never the build verbs' 2 or
// the test verb's 1.
run_version_verb :: proc() -> int {
	fmt.print(version_report(context.temp_allocator))
	return 0
}
