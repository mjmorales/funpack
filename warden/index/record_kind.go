package index

import (
	"encoding/json"
	"fmt"
	"sort"
)

// RecordKind is the closed enum of Index Contract record kinds (spec §29 §2:
// `project` and per-declaration `decl`). It is closed by the same discipline as
// funpack's closed enums — an unknown kind is a FAILURE, never a best-effort
// default — so the consumer and producer share one fixed vocabulary. A new
// record kind is a schema-version bump on both sides, never a silently-added
// arm.
type RecordKind int

const (
	// RecordKindUnknown is the zero value, reserved for "not yet classified".
	// It is never a valid dispatch target — a line that lands here is a
	// failure, surfaced by classifyRecordKind.
	RecordKindUnknown RecordKind = iota
	// RecordKindProject is the whole-project `project` record (spec §29 §2):
	// the one-per-stream summary of entrypoints, builds, capabilities, the
	// flattened pipeline, and the structural gate verdicts.
	RecordKindProject
	// RecordKindDecl is a per-declaration `decl` record (spec §29 §2). The
	// producer emits it (funpack/index_contract.odin: Decl_Record /
	// emit_decl_record) as a bare struct with no kind tag, so the spine
	// classifies it STRUCTURALLY on its decl-only key signature (see the
	// discriminator note below), the same key-set inference it uses for project.
	RecordKindDecl
)

// String renders a kind for diagnostics and error messages.
func (k RecordKind) String() string {
	switch k {
	case RecordKindProject:
		return "project"
	case RecordKindDecl:
		return "decl"
	default:
		return "unknown"
	}
}

// Discriminator note — STRUCTURAL detection, not a producer kind tag.
//
// funpack/index_contract.odin marshals BOTH record kinds as BARE structs
// (`json.marshal(record, …)`) with schema_version leading and NO `kind` /
// `record` discriminator field — Project_Record via emit_project_record and
// Decl_Record via emit_decl_record. So the wire carries no kind tag for warden
// to read on either kind. Per spec §29 §2 there are two record kinds — `project`
// and `decl` — and BOTH now have a producer.
//
// The spine therefore detects kind STRUCTURALLY: a record's top-level key set is
// its own discriminator. Each kind is identified by keys unique to it — keys the
// OTHER kind's struct cannot carry — so the two signatures never alias:
//   - `project` carries pipeline_flattened / gate_results (its derived
//     whole-project fields), absent from a decl record.
//   - `decl` carries qualified_name / dup_class / mut_data (its
//     per-declaration fields), absent from a project record.
// The two marker sets are disjoint by construction, so no line can satisfy both;
// classifyRecordKind asserts that disjointness rather than trust it. The
// consumer NEVER fabricates a `kind` field the producer does not emit.
//
// This is a recorded PRODUCER GAP still under adjudication, not a settled
// design: a per-record `kind` tag on each Index Contract record would make
// dispatch a tag read instead of a structural inference, and is the cleaner
// contract. Closing it is the funpack team's call (it reshapes the wire and
// bumps INDEX_SCHEMA_VERSION). Until then, structural inference on disjoint
// marker sets is the consumer's contract. Surfaced as a discovery, not papered
// over.

// projectMarkerKeys are top-level keys the `project` record carries that the
// `decl` record cannot. Their presence is the structural signature warden keys
// on while the producer emits no `kind` tag. They mirror the project-only
// derived fields of Project_Record (funpack/index_contract.odin): the flattened
// pipeline and the structural gate verdicts are unique to the whole-project
// summary.
var projectMarkerKeys = []string{"pipeline_flattened", "gate_results"}

// declMarkerKeys are top-level keys the `decl` record carries that the `project`
// record cannot. They mirror per-declaration fields of Decl_Record
// (funpack/index_contract.odin): qualified_name (the declaration name),
// dup_class (the per-declaration duplication hash), and mut_data (the
// per-declaration mutated-data set). Disjoint from projectMarkerKeys by
// construction — no project record carries any of them — so the two structural
// signatures never alias.
var declMarkerKeys = []string{"qualified_name", "dup_class", "mut_data"}

// classifyRecordKind derives a line's record kind from its top-level key set —
// structural detection, since the producer emits no kind tag on either kind (see
// the discriminator note). It first reads the top-level keys (a shallow decode
// into a key map, NOT the strict per-record decode), then matches each kind's
// disjoint marker signature. A line satisfying BOTH signatures is an aliasing
// failure (the marker sets are disjoint by construction, so this can only mean a
// reshaped wire) and is refused rather than guessed; a line matching NEITHER is
// the closed-enum failure — an unrecognized record shape, refused not defaulted.
func classifyRecordKind(line []byte) (RecordKind, error) {
	keys, err := topLevelKeys(line)
	if err != nil {
		return RecordKindUnknown, err
	}
	isProject := hasAllKeys(keys, projectMarkerKeys)
	isDecl := hasAllKeys(keys, declMarkerKeys)
	if isProject && isDecl {
		return RecordKindUnknown, fmt.Errorf(
			"index contract: ambiguous record kind — top-level keys %v match both project and decl signatures (the marker sets must stay disjoint; the wire was reshaped)",
			sortedKeys(keys),
		)
	}
	if isProject {
		return RecordKindProject, nil
	}
	if isDecl {
		return RecordKindDecl, nil
	}
	return RecordKindUnknown, fmt.Errorf(
		"index contract: unknown record kind — top-level keys %v match no known kind (project/decl)",
		sortedKeys(keys),
	)
}

// topLevelKeys decodes a line into its top-level key set only — a shallow decode
// that ignores nested structure and value shapes, used purely to classify the
// record kind before the strict per-record decode runs. A line that is not a
// single JSON object is a failure here.
func topLevelKeys(line []byte) (map[string]struct{}, error) {
	var raw map[string]json.RawMessage
	if err := json.Unmarshal(line, &raw); err != nil {
		return nil, fmt.Errorf("index contract: line is not a JSON object: %w", err)
	}
	keys := make(map[string]struct{}, len(raw))
	for k := range raw {
		keys[k] = struct{}{}
	}
	return keys, nil
}

// hasAllKeys reports whether keys contains every name in want — the marker-set
// match a structural classification keys on.
func hasAllKeys(keys map[string]struct{}, want []string) bool {
	for _, k := range want {
		if _, ok := keys[k]; !ok {
			return false
		}
	}
	return true
}

// sortedKeys returns the key set in a deterministic sorted order. Map iteration
// order is nondeterministic in Go, which would make the unknown-kind error
// message non-reproducible; sorting keeps warden's diagnostics byte-stable, the
// same determinism obligation the whole governance fold carries (no map
// iteration order reaching output).
func sortedKeys(keys map[string]struct{}) []string {
	out := make([]string, 0, len(keys))
	for k := range keys {
		out = append(out, k)
	}
	sort.Strings(out)
	return out
}
