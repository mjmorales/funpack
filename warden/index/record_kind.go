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
	// producer does not emit decl records yet (see the discriminator note
	// below); the kind exists so the dispatch enum mirrors the spec's closed
	// pair and the decl story has a target to decode into.
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
// funpack/index_contract.odin marshals Project_Record as a BARE struct
// (`json.marshal(record, …)`) with schema_version leading and NO `kind` /
// `record` discriminator field. So the wire carries no kind tag for warden to
// read. Per spec §29 §2 there are two record kinds — `project` and `decl` — but
// only `project` has a producer today; no decl emitter exists in funpack.
//
// The spine therefore detects kind STRUCTURALLY: a record's top-level key set is
// its own discriminator. The `project` record is uniquely identified by its
// project-only keys (entrypoints / pipeline_flattened / gate_results), which a
// per-declaration `decl` record cannot carry. The consumer NEVER fabricates a
// `kind` field the producer does not emit.
//
// This is a recorded PRODUCER GAP, not a settled design: a per-record `kind` tag
// on each Index Contract record would make dispatch a tag read instead of a
// structural inference, and is the cleaner contract. Closing it is the funpack
// team's call (it reshapes the wire and bumps INDEX_SCHEMA_VERSION). The
// decl-record story will also force the question: a decl record's structural
// signature must be distinguishable from project's, or the gap must be closed
// first. Surfaced as a discovery, not papered over.

// projectMarkerKeys are top-level keys the `project` record carries that no
// other record kind does. Their presence is the structural signature warden
// keys on while the producer emits no `kind` tag. They mirror the project-only
// fields of Project_Record (funpack/index_contract.odin): the flattened
// pipeline and the structural gate verdicts are derived fields unique to the
// whole-project summary.
var projectMarkerKeys = []string{"pipeline_flattened", "gate_results"}

// classifyRecordKind derives a line's record kind from its top-level key set —
// structural detection, since the producer emits no kind tag (see the
// discriminator note). It first reads the top-level keys (a shallow decode into
// a key map, NOT the strict per-record decode), then matches the project
// signature. A line whose key set matches no known kind is a FAILURE: the enum
// is closed, so an unrecognized record shape is refused rather than guessed.
func classifyRecordKind(line []byte) (RecordKind, error) {
	keys, err := topLevelKeys(line)
	if err != nil {
		return RecordKindUnknown, err
	}
	if hasAllKeys(keys, projectMarkerKeys) {
		return RecordKindProject, nil
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
