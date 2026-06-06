package index

import (
	"encoding/json"
	"fmt"
)

// schemaEnvelope reads ONLY the leading schema_version stamp from a line — the
// version-gate decode that runs before kind classification and the full
// per-record decode. It is deliberately permissive on the rest of the object
// (no DisallowUnknownFields): the gate must read the version of an
// otherwise-unknown-shaped record so a version skew is refused with the fix-it
// rather than a confusing strict-decode error. The strict over-shape check runs
// later, in the per-record decode.
type schemaEnvelope struct {
	SchemaVersion int `json:"schema_version"`
}

// Record is the spine's typed dispatch result for one Index Contract line: the
// classified record kind and the raw line bytes the selected per-record decoder
// consumes. The spine's job ends at classification — it produces a Record naming
// WHICH kind a line is and hands the bytes on; the field-level decode into the
// project / decl struct is the per-record story's job. Holding the raw bytes
// (not a decoded struct) keeps the spine free of any per-record schema, so a new
// record decoder needs no spine change.
type Record struct {
	// Kind is the classified record kind (closed enum).
	Kind RecordKind
	// Raw is the line's bytes (the single JSON object, no trailing LF), the
	// input to the per-kind decoder Kind selects.
	Raw []byte
}

// DecodeLine is the spine for one NDJSON line: it runs the schema-version gate
// first (a mismatch is a hard refusal with a fix-it, NEVER best-effort
// parsing), then classifies the record kind structurally (an unknown kind is a
// failure — the enum is closed). It returns a Record naming the kind and
// carrying the raw bytes; it does NOT run the strict per-record decode, which is
// the per-record decoder's job. Order matters: the version gate runs before
// classification so a record from an incompatible producer is refused with the
// actionable "rebuild with a matching funpack" message, not a structural
// mismatch error from a reshaped wire.
func DecodeLine(line []byte) (Record, error) {
	var env schemaEnvelope
	if err := json.Unmarshal(line, &env); err != nil {
		return Record{}, fmt.Errorf("index contract: cannot read schema_version: %w", err)
	}
	if err := checkSchemaVersion(env.SchemaVersion); err != nil {
		return Record{}, err
	}
	kind, err := classifyRecordKind(line)
	if err != nil {
		return Record{}, err
	}
	return Record{Kind: kind, Raw: line}, nil
}
