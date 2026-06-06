package index

import (
	"encoding/json"
	"fmt"
)

// Capability is warden's closed mirror of funpack's Capability enum
// (funpack/index_contract.odin): the §14 §4 battery set the `project` record
// reports as active. The producer marshals it with use_enum_names, so the wire
// carries the identifier names — Render/Input/State/Ui/Modeling/Netcode/
// Modding/Audio — exactly. The set is closed under the same discipline as the
// producer: an unknown capability string is a FAILURE (UnmarshalJSON below),
// never a coerced default, so a producer/consumer enum skew is refused rather
// than silently mapped. warden stores the capability funpack emitted; it never
// re-derives the set from source.
type Capability string

const (
	CapabilityRender   Capability = "Render"
	CapabilityInput    Capability = "Input"
	CapabilityState    Capability = "State"
	CapabilityUi       Capability = "Ui"
	CapabilityModeling Capability = "Modeling"
	CapabilityNetcode  Capability = "Netcode"
	CapabilityModding  Capability = "Modding"
	CapabilityAudio    Capability = "Audio"
)

// validCapabilities is the closed set of capability strings the producer emits,
// in the producer's enum-declaration order (funpack/index_contract.odin
// Capability). The unmarshaler keys off membership: a string outside this set
// is a contract skew, refused. The slice (not a map) keeps the order anchored to
// the producer's enum for a reader cross-checking the two sides.
var validCapabilities = []Capability{
	CapabilityRender,
	CapabilityInput,
	CapabilityState,
	CapabilityUi,
	CapabilityModeling,
	CapabilityNetcode,
	CapabilityModding,
	CapabilityAudio,
}

// UnmarshalJSON decodes a capability string into the closed Capability set,
// failing on any string the producer's enum does not name. This is the
// closed-enum half of the exact-match contract at the field level: encoding/json
// would happily accept any string into a `type Capability string`, so the gate
// lives here — an unknown capability is refused with a diagnostic naming the
// offending value, mirroring the producer's compiler-fixed battery set.
func (c *Capability) UnmarshalJSON(data []byte) error {
	var s string
	if err := json.Unmarshal(data, &s); err != nil {
		return fmt.Errorf("index contract: capability is not a JSON string: %w", err)
	}
	for _, valid := range validCapabilities {
		if Capability(s) == valid {
			*c = valid
			return nil
		}
	}
	return fmt.Errorf("index contract: unknown capability %q — not in the closed producer set %v", s, validCapabilities)
}

// GateFamily is warden's closed mirror of funpack's Gate_Family enum
// (funpack/index_contract.odin): the structural quality gates whose verdicts the
// `project` record reports (spec §29 §1). The producer marshals the gate field
// with use_enum_names, so the wire carries Cyclomatic/Nesting/Fn_Size/Arity/
// Exhaustiveness/Duplication/Effect_Closure exactly. The set is closed: an
// unknown gate family is a FAILURE (UnmarshalJSON below), the same discipline as
// the producer's compiler-fixed gate set.
type GateFamily string

const (
	GateFamilyCyclomatic     GateFamily = "Cyclomatic"
	GateFamilyNesting        GateFamily = "Nesting"
	GateFamilyFnSize         GateFamily = "Fn_Size"
	GateFamilyArity          GateFamily = "Arity"
	GateFamilyExhaustiveness GateFamily = "Exhaustiveness"
	GateFamilyDuplication    GateFamily = "Duplication"
	GateFamilyEffectClosure  GateFamily = "Effect_Closure"
)

// validGateFamilies is the closed set of gate-family strings the producer emits,
// in the producer's enum-declaration order (funpack/index_contract.odin
// Gate_Family). A string outside this set is a contract skew, refused by the
// unmarshaler.
var validGateFamilies = []GateFamily{
	GateFamilyCyclomatic,
	GateFamilyNesting,
	GateFamilyFnSize,
	GateFamilyArity,
	GateFamilyExhaustiveness,
	GateFamilyDuplication,
	GateFamilyEffectClosure,
}

// UnmarshalJSON decodes a gate-family string into the closed GateFamily set,
// failing on any string the producer's enum does not name — the field-level
// closed-enum gate, the gate-family analogue of Capability.UnmarshalJSON.
func (g *GateFamily) UnmarshalJSON(data []byte) error {
	var s string
	if err := json.Unmarshal(data, &s); err != nil {
		return fmt.Errorf("index contract: gate family is not a JSON string: %w", err)
	}
	for _, valid := range validGateFamilies {
		if GateFamily(s) == valid {
			*g = valid
			return nil
		}
	}
	return fmt.Errorf("index contract: unknown gate family %q — not in the closed producer set %v", s, validGateFamilies)
}

// EntrypointRecord mirrors funpack's Entrypoint_Record: one authored
// entrypoint's lifted wiring (§14 §4) — the entrypoint name and the root
// pipeline ↔ tick ↔ bindings it binds. tick_hz is the integer hertz rate. All
// four keys are present in the producer's grammar; the json tags match the
// producer's field-declaration order (name, pipeline, tick_hz, bindings).
type EntrypointRecord struct {
	Name     string `json:"name"`
	Pipeline string `json:"pipeline"`
	TickHz   int    `json:"tick_hz"`
	Bindings string `json:"bindings"`
}

// BuildRecord mirrors funpack's Build_Record: one authored emit target (§14
// §4/§6) — the build name and its presentation platform. platform is a free
// string here (the producer emits whatever builds.fcfg authored — `desktop`,
// `wasm`, `native`); warden stores it verbatim, never validating it against a
// closed set, because the producer's Build_Record carries no platform enum.
type BuildRecord struct {
	Name     string `json:"name"`
	Platform string `json:"platform"`
}

// FlatStepRecord mirrors funpack's Flat_Step_Record: one step of the emitted
// depth-first flattened total order (spec §07 §3) — the 0-based ordinal, the
// owning stage name, and the behavior run at this step. The json tags match the
// producer's field order (ordinal, stage, behavior).
type FlatStepRecord struct {
	Ordinal  int    `json:"ordinal"`
	Stage    string `json:"stage"`
	Behavior string `json:"behavior"`
}

// GateResult mirrors funpack's Gate_Result: one structural gate's verdict line —
// the gate family (a closed GateFamily) and whether the source cleared it. The
// whole vector is emitted (every family), so a reader keys off the family, never
// a positional index. The json tags match the producer's field order (gate,
// passed).
type GateResult struct {
	Gate   GateFamily `json:"gate"`
	Passed bool       `json:"passed"`
}

// ProjectRecord is warden's exact-match decode of funpack's Project_Record: the
// closed, schema-versioned, all-fields-mandatory `project` record of the Index
// Contract (spec §29 §2). The field set and json-tag order mirror the producer
// byte-for-byte — schema_version leads, then the AUTHORED entrypoints / builds /
// tag_registry, then the DERIVED capabilities / pipeline_flattened /
// gate_results. This is parse-and-validate ONLY: warden stores exactly what
// funpack emitted, with no projection, no capability re-derivation, and no gate
// logic on the consumer side.
type ProjectRecord struct {
	SchemaVersion     int                `json:"schema_version"`
	Entrypoints       []EntrypointRecord `json:"entrypoints"`
	Builds            []BuildRecord      `json:"builds"`
	TagRegistry       []string           `json:"tag_registry"`
	Capabilities      []Capability       `json:"capabilities"`
	PipelineFlattened []FlatStepRecord   `json:"pipeline_flattened"`
	GateResults       []GateResult       `json:"gate_results"`
}

// projectRequiredKeys is the closed set of top-level keys a `project` record
// MUST carry (spec §29 §2: all fields mandatory). It mirrors ProjectRecord's
// json tags in the producer's field order. The presence check below keys off
// this set: encoding/json zero-fills an absent key silently (an absent
// tag_registry and an empty-but-present tag_registry both decode to a nil/empty
// slice), so the under-shape half of exact-match — a MISSING mandatory key is a
// failure — is enforced here, not by the decoder. The over-shape half (an
// UNKNOWN key) is enforced by the spine's decodeStrict (DisallowUnknownFields).
var projectRequiredKeys = []string{
	"schema_version",
	"entrypoints",
	"builds",
	"tag_registry",
	"capabilities",
	"pipeline_flattened",
	"gate_results",
}

// DecodeProjectRecord decodes a spine-classified `project` Record into the typed
// ProjectRecord, enforcing the full exact-match contract: the spine already ran
// the version gate and the kind dispatch, so this consumes Record.Raw and adds
// the field-level decode. It refuses a Record whose kind is not project (a
// caller routing error), then runs the under-shape presence check (every
// mandatory key present), then the strict decode (DisallowUnknownFields rejects
// an unknown key; the closed-enum unmarshalers reject an unknown capability or
// gate-family string). An empty-but-present list (no builds, no tags) decodes to
// a zero-length slice and is VALID — only an absent key fails. It performs no
// projection or derivation: the returned struct is exactly funpack's emitted
// shape.
func DecodeProjectRecord(rec Record) (ProjectRecord, error) {
	if rec.Kind != RecordKindProject {
		return ProjectRecord{}, fmt.Errorf("index contract: DecodeProjectRecord called on a %s record, not project", rec.Kind)
	}
	if err := requireProjectKeys(rec.Raw); err != nil {
		return ProjectRecord{}, err
	}
	var record ProjectRecord
	if err := decodeStrict(rec.Raw, &record); err != nil {
		return ProjectRecord{}, err
	}
	return record, nil
}

// requireProjectKeys enforces the under-shape half of exact-match: every
// mandatory `project` key must be PRESENT on the line. It reads the top-level
// key set with a shallow decode (the same shape topLevelKeys uses) and reports
// the first missing mandatory key. This is the distinction the contract demands
// — an empty-but-present list is valid, an absent key is a failure — which the
// strict struct decode alone cannot make, since encoding/json zero-fills an
// absent key without complaint.
func requireProjectKeys(line []byte) error {
	keys, err := topLevelKeys(line)
	if err != nil {
		return err
	}
	for _, want := range projectRequiredKeys {
		if _, ok := keys[want]; !ok {
			return fmt.Errorf("index contract: project record missing mandatory key %q", want)
		}
	}
	return nil
}
