package index

import (
	"strings"
	"testing"
)

// projectLine is a well-formed `project` record NDJSON line in the shape
// funpack/index_contract.odin emits: schema_version leading, the seven
// project-only top-level keys, enum values as their identifier names
// (use_enum_names). It is a minimal-but-valid fixture — the spine classifies on
// the top-level key signature, not the nested field values, so the slices stay
// small. No `kind` tag is present, mirroring the producer's bare-struct marshal.
const projectLine = `{"schema_version":1,"entrypoints":[{"name":"main","pipeline":"Pong","tick_hz":60,"bindings":"bindings"}],"builds":[{"name":"native","platform":"desktop"}],"tag_registry":["game"],"capabilities":["Render","Input","State"],"pipeline_flattened":[{"ordinal":0,"stage":"startup","behavior":"setup"}],"gate_results":[{"gate":"Cyclomatic","passed":true}]}`

func TestSchemaVersionMismatchIsHardRefusalWithFixIt(t *testing.T) {
	// A line carrying a schema_version other than IndexSchemaVersion is refused
	// hard — the gate returns a typed *SchemaVersionError whose message is the
	// fix-it shape ("index schema vN, warden expects v1; rebuild with a matching
	// funpack"), never coerced/best-effort parsing.
	line := strings.Replace(projectLine, `"schema_version":1`, `"schema_version":2`, 1)
	_, err := DecodeLine([]byte(line))
	if err == nil {
		t.Fatal("expected a hard refusal on schema-version mismatch, got nil error")
	}
	sve, ok := err.(*SchemaVersionError)
	if !ok {
		t.Fatalf("expected *SchemaVersionError, got %T: %v", err, err)
	}
	if sve.Got != 2 || sve.Want != IndexSchemaVersion {
		t.Fatalf("expected Got=2 Want=%d, got Got=%d Want=%d", IndexSchemaVersion, sve.Got, sve.Want)
	}
	msg := err.Error()
	for _, want := range []string{"index schema v2", "warden expects v1", "rebuild with a matching funpack"} {
		if !strings.Contains(msg, want) {
			t.Fatalf("fix-it message missing %q; got %q", want, msg)
		}
	}
}

func TestSchemaVersionMatchPasses(t *testing.T) {
	// The exact-match gate accepts a line whose schema_version equals
	// IndexSchemaVersion — the positive case the hard-refusal test bounds.
	if err := checkSchemaVersion(IndexSchemaVersion); err != nil {
		t.Fatalf("expected the matching version to pass the gate, got %v", err)
	}
}

func TestSchemaVersionConstMatchesProducer(t *testing.T) {
	// The Go-side const must equal the producer's INDEX_SCHEMA_VERSION (1). This
	// is the anchored value, not a guessed number — the producer-side assertion
	// (grep 'INDEX_SCHEMA_VERSION :: 1' funpack/index_contract.odin) is the
	// other half of this gate, checked by the task's bash AC.
	if IndexSchemaVersion != 1 {
		t.Fatalf("IndexSchemaVersion must be 1 to match the producer, got %d", IndexSchemaVersion)
	}
}

func TestRecordKindDispatchesProject(t *testing.T) {
	// A well-formed project line dispatches to RecordKindProject — structural
	// detection on the project-only top-level key signature, since the producer
	// emits no kind tag.
	rec, err := DecodeLine([]byte(projectLine))
	if err != nil {
		t.Fatalf("expected a well-formed project line to decode, got %v", err)
	}
	if rec.Kind != RecordKindProject {
		t.Fatalf("expected RecordKindProject, got %v", rec.Kind)
	}
	if string(rec.Raw) != projectLine {
		t.Fatal("expected the dispatch result to carry the original line bytes")
	}
}

func TestRecordKindUnknownIsFailure(t *testing.T) {
	// A line at a valid schema_version but with a top-level key set matching no
	// known record kind is a FAILURE — the kind enum is closed, so an
	// unrecognized record shape is refused, never guessed.
	line := `{"schema_version":1,"mystery_field":true}`
	_, err := DecodeLine([]byte(line))
	if err == nil {
		t.Fatal("expected an unknown record kind to fail, got nil error")
	}
	if !strings.Contains(err.Error(), "unknown record kind") {
		t.Fatalf("expected an unknown-record-kind error, got %q", err.Error())
	}
}

func TestRecordKindUnknownErrorIsDeterministic(t *testing.T) {
	// The unknown-kind error lists the offending top-level keys in a stable
	// sorted order, so the diagnostic is byte-reproducible (warden's determinism
	// obligation — no map iteration order reaching output).
	line := `{"schema_version":1,"zeta":1,"alpha":2,"mu":3}`
	_, err := DecodeLine([]byte(line))
	if err == nil {
		t.Fatal("expected an unknown record kind to fail, got nil error")
	}
	msg := err.Error()
	if !strings.Contains(msg, "[alpha mu schema_version zeta]") {
		t.Fatalf("expected sorted key list in error, got %q", msg)
	}
}

func TestDispatchVersionGateRunsBeforeKind(t *testing.T) {
	// On a record from an incompatible producer (mismatched version AND an
	// unrecognized shape), the version gate wins: the operator sees the
	// actionable "rebuild" fix-it, not a confusing structural-mismatch error
	// from a reshaped wire.
	line := `{"schema_version":99,"some_future_field":true}`
	_, err := DecodeLine([]byte(line))
	if err == nil {
		t.Fatal("expected a hard refusal, got nil error")
	}
	if _, ok := err.(*SchemaVersionError); !ok {
		t.Fatalf("expected the version gate to win, got %T: %v", err, err)
	}
}
