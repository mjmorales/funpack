package index

import (
	"strings"
	"testing"
)

// pongProjectLine is a byte-faithful golden `project` record for the pong shape
// funpack/index_contract.odin emits (anchored against funpack-spec's pong
// example: entrypoints.fcfg, builds.fcfg, tags.fcfg, and the Pong pipeline's
// depth-first flatten). schema_version leads (2); the keys appear in the
// producer's struct-declaration order; enum values are the use_enum_names
// identifier strings. The eleven flattened steps are the pong pipeline's
// depth-first total order (startup → control → collision → scoring → render),
// the ten tags are the authored tags.fcfg registry in order, the three
// capabilities are pong's core-only battery set, and the seven gate results are
// the full all-passing gate vector. This is hand-authored, NOT machine-emitted
// (the task never builds funpack).
const pongProjectLine = `{"schema_version":2,` +
	`"entrypoints":[{"name":"main","pipeline":"Pong","tick_hz":60,"bindings":"bindings"}],` +
	`"builds":[{"name":"native","platform":"desktop"}],` +
	`"tag_registry":["game","startup","render","spatial","paddle","ball","input","score","board","event"],` +
	`"capabilities":["Render","Input","State"],` +
	`"pipeline_flattened":[` +
	`{"ordinal":0,"stage":"startup","behavior":"setup"},` +
	`{"ordinal":1,"stage":"control","behavior":"paddle_move"},` +
	`{"ordinal":2,"stage":"control","behavior":"ball_move"},` +
	`{"ordinal":3,"stage":"collision","behavior":"wall_bounce"},` +
	`{"ordinal":4,"stage":"collision","behavior":"paddle_bounce"},` +
	`{"ordinal":5,"stage":"scoring","behavior":"score"},` +
	`{"ordinal":6,"stage":"scoring","behavior":"tally"},` +
	`{"ordinal":7,"stage":"scoring","behavior":"serve"},` +
	`{"ordinal":8,"stage":"render","behavior":"draw_paddle"},` +
	`{"ordinal":9,"stage":"render","behavior":"draw_ball"},` +
	`{"ordinal":10,"stage":"render","behavior":"draw_score"}],` +
	`"gate_results":[` +
	`{"gate":"Cyclomatic","passed":true},` +
	`{"gate":"Nesting","passed":true},` +
	`{"gate":"Fn_Size","passed":true},` +
	`{"gate":"Arity","passed":true},` +
	`{"gate":"Exhaustiveness","passed":true},` +
	`{"gate":"Duplication","passed":true},` +
	`{"gate":"Effect_Closure","passed":true}]}`

// decodeProjectLine runs a line through the full spine + project-decode path the
// way warden consumes a real stream: DecodeLine (version gate + kind dispatch),
// then DecodeProjectRecord (presence + strict + closed-enum decode). It is the
// single seam the project tests assert through, so each test exercises the
// integrated contract, not a bypass of the spine.
func decodeProjectLine(t *testing.T, line string) (ProjectRecord, error) {
	t.Helper()
	rec, err := DecodeLine([]byte(line))
	if err != nil {
		return ProjectRecord{}, err
	}
	return DecodeProjectRecord(rec)
}

func TestProjectGoldenRoundTrips(t *testing.T) {
	// The golden pong line decodes into a fully-populated ProjectRecord — every
	// authored and derived field carries its pong value, proving the json tags
	// match the producer's emitted keys exactly (a renamed or drifted key would
	// leave a field zero-valued or trip DisallowUnknownFields).
	record, err := decodeProjectLine(t, pongProjectLine)
	if err != nil {
		t.Fatalf("expected the golden pong line to decode, got %v", err)
	}
	if record.SchemaVersion != 2 {
		t.Fatalf("expected schema_version 2, got %d", record.SchemaVersion)
	}
	if len(record.Entrypoints) != 1 {
		t.Fatalf("expected 1 entrypoint, got %d", len(record.Entrypoints))
	}
	ep := record.Entrypoints[0]
	if ep.Name != "main" || ep.Pipeline != "Pong" || ep.TickHz != 60 || ep.Bindings != "bindings" {
		t.Fatalf("entrypoint mismatch: %+v", ep)
	}
	if len(record.Builds) != 1 || record.Builds[0].Name != "native" || record.Builds[0].Platform != "desktop" {
		t.Fatalf("build mismatch: %+v", record.Builds)
	}
	if len(record.TagRegistry) != 10 || record.TagRegistry[0] != "game" || record.TagRegistry[9] != "event" {
		t.Fatalf("tag_registry mismatch: %v", record.TagRegistry)
	}
	if len(record.PipelineFlattened) != 11 {
		t.Fatalf("expected 11 flattened steps, got %d", len(record.PipelineFlattened))
	}
	first := record.PipelineFlattened[0]
	if first.Ordinal != 0 || first.Stage != "startup" || first.Behavior != "setup" {
		t.Fatalf("first flattened step mismatch: %+v", first)
	}
	if last := record.PipelineFlattened[10]; last.Behavior != "draw_score" {
		t.Fatalf("expected last step behavior draw_score, got %q", last.Behavior)
	}
}

func TestProjectRecordEnumStringsMapToClosedSet(t *testing.T) {
	// Every capability and gate-family string in the golden line maps to its
	// closed Go enum constant — the use_enum_names spellings the producer emits
	// decode 1:1, with no coercion. This is the field-level closed-enum contract.
	record, err := decodeProjectLine(t, pongProjectLine)
	if err != nil {
		t.Fatalf("expected the golden line to decode, got %v", err)
	}
	wantCaps := []Capability{CapabilityRender, CapabilityInput, CapabilityState}
	if len(record.Capabilities) != len(wantCaps) {
		t.Fatalf("expected %d capabilities, got %d", len(wantCaps), len(record.Capabilities))
	}
	for i, want := range wantCaps {
		if record.Capabilities[i] != want {
			t.Fatalf("capability[%d] = %q, want %q", i, record.Capabilities[i], want)
		}
	}
	wantGates := []GateFamily{
		GateFamilyCyclomatic, GateFamilyNesting, GateFamilyFnSize, GateFamilyArity,
		GateFamilyExhaustiveness, GateFamilyDuplication, GateFamilyEffectClosure,
	}
	if len(record.GateResults) != len(wantGates) {
		t.Fatalf("expected %d gate results, got %d", len(wantGates), len(record.GateResults))
	}
	for i, want := range wantGates {
		if record.GateResults[i].Gate != want {
			t.Fatalf("gate[%d] = %q, want %q", i, record.GateResults[i].Gate, want)
		}
		if !record.GateResults[i].Passed {
			t.Fatalf("gate[%d] (%q) expected passed=true on the golden", i, want)
		}
	}
}

func TestProjectRecordEnumStringSetCoversProducer(t *testing.T) {
	// The closed Go enum sets must have exactly the producer's cardinality — eight
	// capabilities, seven gate families (funpack/index_contract.odin). A drift on
	// either side (a battery or gate added to one but not the other) is caught
	// here before it reaches a live stream.
	if len(validCapabilities) != 8 {
		t.Fatalf("expected 8 capabilities to mirror the producer, got %d", len(validCapabilities))
	}
	if len(validGateFamilies) != 7 {
		t.Fatalf("expected 7 gate families to mirror the producer, got %d", len(validGateFamilies))
	}
}

func TestProjectEmptyListsDecodeAsZeroLength(t *testing.T) {
	// An empty-but-present builds and tag_registry decode to zero-length slices,
	// NEVER an error — the contract distinguishes an empty list (valid) from an
	// absent key (a failure, covered by the missing-field test). Both keys are
	// present, just `[]`, so the record is well-shaped.
	line := `{"schema_version":2,` +
		`"entrypoints":[{"name":"main","pipeline":"Pong","tick_hz":60,"bindings":"bindings"}],` +
		`"builds":[],"tag_registry":[],` +
		`"capabilities":["Render","Input","State"],` +
		`"pipeline_flattened":[{"ordinal":0,"stage":"startup","behavior":"setup"}],` +
		`"gate_results":[{"gate":"Cyclomatic","passed":true}]}`
	record, err := decodeProjectLine(t, line)
	if err != nil {
		t.Fatalf("expected empty-but-present lists to decode, got %v", err)
	}
	if record.Builds == nil || len(record.Builds) != 0 {
		t.Fatalf("expected an empty (non-nil) builds slice, got %#v", record.Builds)
	}
	if record.TagRegistry == nil || len(record.TagRegistry) != 0 {
		t.Fatalf("expected an empty (non-nil) tag_registry slice, got %#v", record.TagRegistry)
	}
}

func TestProjectMissingMandatoryFieldFails(t *testing.T) {
	// A project line with a missing mandatory key (tag_registry dropped) fails —
	// encoding/json would zero-fill it silently, so the presence check refuses it,
	// distinguishing absence (failure) from an empty list (valid).
	line := `{"schema_version":2,` +
		`"entrypoints":[{"name":"main","pipeline":"Pong","tick_hz":60,"bindings":"bindings"}],` +
		`"builds":[{"name":"native","platform":"desktop"}],` +
		`"capabilities":["Render","Input","State"],` +
		`"pipeline_flattened":[{"ordinal":0,"stage":"startup","behavior":"setup"}],` +
		`"gate_results":[{"gate":"Cyclomatic","passed":true}]}`
	_, err := decodeProjectLine(t, line)
	if err == nil {
		t.Fatal("expected a missing mandatory key to fail, got nil error")
	}
	if !strings.Contains(err.Error(), "missing mandatory key") || !strings.Contains(err.Error(), "tag_registry") {
		t.Fatalf("expected a missing-tag_registry error, got %q", err.Error())
	}
}

func TestProjectUnknownFieldFails(t *testing.T) {
	// A project line carrying an unknown top-level key fails — the over-shape half
	// of exact-match, enforced by the spine's decodeStrict
	// (DisallowUnknownFields). The line is otherwise the well-formed golden, so
	// only the extra key trips it.
	line := strings.Replace(
		pongProjectLine,
		`"schema_version":2,`,
		`"schema_version":2,"surprise_field":true,`,
		1,
	)
	_, err := decodeProjectLine(t, line)
	if err == nil {
		t.Fatal("expected an unknown field to fail, got nil error")
	}
	// classifyRecordKind still matches on the project marker keys (which are
	// present), so the failure surfaces at the strict decode, not the spine kind
	// dispatch.
	if !strings.Contains(err.Error(), "strict decode failed") {
		t.Fatalf("expected a strict-decode failure on the unknown field, got %q", err.Error())
	}
}

func TestProjectUnknownCapabilityStringFails(t *testing.T) {
	// A capability string outside the closed producer set fails — the field-level
	// closed-enum gate (Capability.UnmarshalJSON). "Physics" is not a battery
	// funpack emits, so the decode is refused, never coerced.
	line := strings.Replace(
		pongProjectLine,
		`"capabilities":["Render","Input","State"]`,
		`"capabilities":["Render","Physics","State"]`,
		1,
	)
	_, err := decodeProjectLine(t, line)
	if err == nil {
		t.Fatal("expected an unknown capability to fail, got nil error")
	}
	if !strings.Contains(err.Error(), "unknown capability") || !strings.Contains(err.Error(), "Physics") {
		t.Fatalf("expected an unknown-capability error naming Physics, got %q", err.Error())
	}
}

func TestProjectRejectUnknownGateFamilyString(t *testing.T) {
	// A gate-family string outside the closed producer set fails — the gate-family
	// closed-enum gate (GateFamily.UnmarshalJSON). "Halting" is not a gate funpack
	// emits, so the decode is refused.
	line := strings.Replace(
		pongProjectLine,
		`{"gate":"Cyclomatic","passed":true}`,
		`{"gate":"Halting","passed":true}`,
		1,
	)
	_, err := decodeProjectLine(t, line)
	if err == nil {
		t.Fatal("expected an unknown gate family to fail, got nil error")
	}
	if !strings.Contains(err.Error(), "unknown gate family") || !strings.Contains(err.Error(), "Halting") {
		t.Fatalf("expected an unknown-gate-family error naming Halting, got %q", err.Error())
	}
}

func TestProjectRejectVersionMismatch(t *testing.T) {
	// A version-mismatch line is refused by the spine gate BEFORE the project
	// decode runs — the per-record decoder never sees a record from an
	// incompatible producer. The fix-it *SchemaVersionError surfaces, not a
	// field-level decode error.
	line := strings.Replace(pongProjectLine, `"schema_version":2`, `"schema_version":1`, 1)
	_, err := decodeProjectLine(t, line)
	if err == nil {
		t.Fatal("expected a version mismatch to fail, got nil error")
	}
	if _, ok := err.(*SchemaVersionError); !ok {
		t.Fatalf("expected the spine version gate to refuse it, got %T: %v", err, err)
	}
}

func TestProjectNegativeWrongKindRejected(t *testing.T) {
	// DecodeProjectRecord refuses a Record the spine did not classify as project —
	// a caller routing error. Constructing a non-project Record directly (the
	// spine never produces RecordKindUnknown on success) proves the kind guard,
	// independent of the spine's structural detection.
	_, err := DecodeProjectRecord(Record{Kind: RecordKindDecl, Raw: []byte(pongProjectLine)})
	if err == nil {
		t.Fatal("expected a non-project Record to be refused, got nil error")
	}
	if !strings.Contains(err.Error(), "not project") {
		t.Fatalf("expected a wrong-kind error, got %q", err.Error())
	}
}
