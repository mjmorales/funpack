// Package index is warden's consumer of the funpack Index Contract (spec §29):
// the NDJSON, schema-versioned, exact-match record stream funpack emits
// whole-stream per build. This package owns the DECODE SPINE only — line
// framing, the schema-version compatibility gate, record-kind dispatch, and the
// strict-JSON foundation every record decoder rides. It is parse-and-validate
// only: no projection, no governance, no clock. The contract crosses a PROCESS
// boundary — warden reads the NDJSON funpack produced; it never links the
// compiler or the grammar (spec §29).
//
// The per-record struct decoders (the project record's fields, the decl
// record's fields) land in their own files; this spine produces a typed
// dispatch result naming which record kind a line is, leaving the field-level
// decode to the per-kind decoder the dispatcher selects.
package index

import "fmt"

// IndexSchemaVersion is warden's pinned copy of the producer's
// INDEX_SCHEMA_VERSION (funpack/index_contract.odin) — the leading
// schema_version stamp every Index Contract record carries (spec §29 §2). The
// gate exact-matches a line's schema_version against this const: a mismatch is a
// HARD REFUSAL with a fix-it, never best-effort parsing. Bumping the producer's
// INDEX_SCHEMA_VERSION (a contract reshape) requires bumping this in lockstep —
// the two values are one compatibility gate split across the process boundary.
const IndexSchemaVersion = 1

// SchemaVersionError is the typed hard-refusal returned when a record's
// schema_version does not exact-match IndexSchemaVersion. It carries the fix-it
// in its message — the producer-version vs warden-version mismatch and the
// remedy (rebuild with a matching funpack) — so the operator gets the actionable
// shape, not a generic parse failure. A version mismatch never falls through to
// coerced parsing: the whole stream is refused.
type SchemaVersionError struct {
	// Got is the schema_version the line actually carried.
	Got int
	// Want is the version warden was built against (IndexSchemaVersion).
	Want int
}

// Error renders the fix-it message: which schema the index carries, which
// warden expects, and the remedy. The wording is asserted on by the spine
// tests, so it is the stable contract surface — a producer/consumer skew reads
// as "rebuild with a matching funpack", not "unexpected field".
func (e *SchemaVersionError) Error() string {
	return fmt.Sprintf(
		"index schema v%d, warden expects v%d; rebuild with a matching funpack",
		e.Got, e.Want,
	)
}

// checkSchemaVersion is the exact-match compatibility gate. It returns a
// *SchemaVersionError when the line's version differs from IndexSchemaVersion,
// and nil on a match — the single point where a version skew is refused before
// any field-level decode runs.
func checkSchemaVersion(got int) error {
	if got != IndexSchemaVersion {
		return &SchemaVersionError{Got: got, Want: IndexSchemaVersion}
	}
	return nil
}
