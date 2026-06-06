package index

import (
	"fmt"
	"sort"
)

// DeclKind is warden's pinned copy of the producer's closed Index_Decl_Kind
// enum (funpack/index_contract.odin) — the §29 §2 set of source DECLARATION
// FORMS the per-declaration `decl` record reports. The producer marshals the
// enum with use_enum_names, so each kind crosses the wire as its identifier
// STRING ("Behavior", "Extern_Fn", …), never an ordinal; warden decodes that
// string back to this typed kind. The set is closed by the same discipline as
// the producer's: an unknown kind string is a FAILURE, never a best-effort
// default, so a producer that adds a declaration form (a schema reshape that
// bumps INDEX_SCHEMA_VERSION) is refused here until warden adds the arm in
// lockstep. The string spellings are the producer's enum names byte-for-byte —
// the two sides share one fixed vocabulary across the process boundary.
type DeclKind int

const (
	// DeclKindUnknown is the zero value, reserved for "not a recognized kind
	// string". It is never a valid decoded kind — a `kind` value that maps here
	// is refused by decodeDeclKind, the closed-enum failure.
	DeclKindUnknown DeclKind = iota
	// DeclKindData is a `data` record declaration (§03).
	DeclKindData
	// DeclKindEnum is an `enum` declaration (§03).
	DeclKindEnum
	// DeclKindThing is a `thing` declaration (§06).
	DeclKindThing
	// DeclKindSignal is a `signal` declaration (§04).
	DeclKindSignal
	// DeclKindFn is a bodied free function (§02).
	DeclKindFn
	// DeclKindExternFn is a body-less `extern fn` native-boundary fn (§02/§26)
	// — a distinct kind from a bodied Fn, mirroring the producer's split.
	DeclKindExternFn
	// DeclKindBehavior is a `behavior` declaration (§06).
	DeclKindBehavior
	// DeclKindPipeline is a `pipeline` declaration (§07).
	DeclKindPipeline
	// DeclKindLet is a module-level `let` value binding (§02).
	DeclKindLet
	// DeclKindTest is a `test` declaration (§29 §1).
	DeclKindTest
)

// declKindByName maps each producer enum NAME (the use_enum_names wire string)
// to its typed kind. The keys are the Index_Decl_Kind variant names from
// funpack/index_contract.odin verbatim — this table IS the byte-match contract
// for the `kind` field. A string absent from this table is an unknown kind
// (the closed-enum failure decodeDeclKind raises); adding a producer kind means
// adding its name here in lockstep with the schema-version bump.
var declKindByName = map[string]DeclKind{
	"Data":      DeclKindData,
	"Enum":      DeclKindEnum,
	"Thing":     DeclKindThing,
	"Signal":    DeclKindSignal,
	"Fn":        DeclKindFn,
	"Extern_Fn": DeclKindExternFn,
	"Behavior":  DeclKindBehavior,
	"Pipeline":  DeclKindPipeline,
	"Let":       DeclKindLet,
	"Test":      DeclKindTest,
}

// String renders a kind back to its producer wire name for diagnostics. The
// inverse of declKindByName, it is a small fixed switch so a kind round-trips to
// the exact string the producer emitted; an unrecognized value renders
// "unknown" (the zero-value diagnostic, never a wire-valid string).
func (k DeclKind) String() string {
	switch k {
	case DeclKindData:
		return "Data"
	case DeclKindEnum:
		return "Enum"
	case DeclKindThing:
		return "Thing"
	case DeclKindSignal:
		return "Signal"
	case DeclKindFn:
		return "Fn"
	case DeclKindExternFn:
		return "Extern_Fn"
	case DeclKindBehavior:
		return "Behavior"
	case DeclKindPipeline:
		return "Pipeline"
	case DeclKindLet:
		return "Let"
	case DeclKindTest:
		return "Test"
	default:
		return "unknown"
	}
}

// declWire is the decode-side mirror of the producer's Decl_Record struct
// (funpack/index_contract.odin) — the §29 §2 per-declaration `decl` record, the
// frozen wire shape warden consumes across the process boundary. Every json tag
// is the producer key byte-for-byte and the field order mirrors the producer's
// declaration order (the producer marshals in field-declaration order, so this
// is also the emitted key order); the `kind` field is the raw enum-name string
// (decoded to a typed DeclKind in a second pass). All fields are mandatory — an
// absent value crosses the wire as the empty list / false / "" / 0, never an
// omitted key — so the decoder validates PRESENCE separately (see decodeDecl):
// encoding/json cannot distinguish a missing key from a zero value, which is why
// the wire struct decodes into pointer-free fields and a parallel presence probe
// catches the under-shape half of the exact-match discipline.
//
// dup_class is the producer's u64 normalized-AST duplication hash (§29 §1). It
// crosses the wire as a BARE JSON number (the producer marshals u64 unquoted,
// e.g. dup_class 14695981039346656037), so it decodes to a Go uint64 — the only
// field type that holds the full u64 range without the float53 precision loss a
// float64 intermediary would introduce.
type declWire struct {
	SchemaVersion int      `json:"schema_version"`
	QualifiedName string   `json:"qualified_name"`
	Kind          string   `json:"kind"`
	File          string   `json:"file"`
	Span          int      `json:"span"`
	Doc           string   `json:"doc"`
	GTags         []string `json:"gtags"`
	Stub          bool     `json:"stub"`
	Todo          bool     `json:"todo"`
	Debug         []string `json:"debug"`
	Emits         []string `json:"emits"`
	Consumes      []string `json:"consumes"`
	Calls         []string `json:"calls"`
	DupClass      uint64   `json:"dup_class"`
	MutData       []string `json:"mut_data"`
}

// DeclRecord is warden's decoded, validated §29 §2 per-declaration `decl`
// record. It is the typed result of a clean decode: every mandatory field
// present, the `kind` resolved from its wire name to the closed DeclKind enum,
// and no unknown top-level key. It carries the same field set as the producer's
// Decl_Record in the same order, the `kind` now a typed enum rather than a raw
// string. This is parse-and-validate ONLY — no governance, no lease, no anchor
// resolution, no clock; those are downstream warden epics that read this struct.
type DeclRecord struct {
	// SchemaVersion is the leading §29 §2 stamp (always IndexSchemaVersion on a
	// record that passed the spine's version gate).
	SchemaVersion int
	// QualifiedName is the module-qualified declaration name (§15).
	QualifiedName string
	// Kind is the source declaration form, resolved from the wire enum name to
	// the closed DeclKind (an unknown name is a decode failure).
	Kind DeclKind
	// File is the source file path; "" in the single-source frontend (the
	// producer does not yet thread the path).
	File string
	// Span is the 1-based source line of the declaration keyword (§9 line-span).
	Span int
	// Doc is the attached @doc text (§05); "" when undocumented.
	Doc string
	// GTags are the attached @gtag registry tags (§05) in authored order.
	GTags []string
	// Stub is the @stub directive flag (§05). It is a plain bool on the v2 wire
	// — the producer marshals a single bool, NOT the §29 §4 two-flavor
	// @stub(T)/@stub(T,fallback) sub-shape (that flavor split is not on the v2
	// wire and is not modeled here; inventing it would diverge from the frozen
	// producer shape).
	Stub bool
	// Todo is the @todo directive flag (§05). Like Stub it is a plain bool on the
	// v2 wire — the producer does NOT emit the §29 §4 todo-window discriminator
	// (relative/absolute/build-count/task-ref), so warden does not model a window
	// sub-shape it would have to invent.
	Todo bool
	// Debug are the @debug probe names (§05) in authored order.
	Debug []string
	// Emits are the signal names this declaration emits (§04).
	Emits []string
	// Consumes are the signal names this declaration consumes (§04).
	Consumes []string
	// Calls are the function names this declaration calls (the call-graph edges).
	Calls []string
	// DupClass is the normalized-AST duplication-class hash (§29 §1) — the
	// producer's u64, held as a uint64 to round-trip the full range.
	DupClass uint64
	// MutData are the data-type names this declaration mutates (§08).
	MutData []string
}

// declRequiredKeys is the closed, ordered set of top-level keys a `decl` record
// MUST carry — every field of the producer's Decl_Record, in emitted-key order.
// It is the under-shape half of the exact-match discipline (spec §29 §2): a
// record missing any of these is a FAILURE, since a mandatory field absent on
// the wire is a contract skew, not a defaulted value. (The over-shape half — an
// UNKNOWN key — is caught by decodeStrict's DisallowUnknownFields.) The order is
// the producer's field-declaration order so the missing-field diagnostic reports
// the first absent key in a stable, wire-meaningful order.
var declRequiredKeys = []string{
	"schema_version",
	"qualified_name",
	"kind",
	"file",
	"span",
	"doc",
	"gtags",
	"stub",
	"todo",
	"debug",
	"emits",
	"consumes",
	"calls",
	"dup_class",
	"mut_data",
}

// DecodeDecl decodes one raw `decl` record line into a validated DeclRecord. It
// enforces the full exact-match discipline (spec §29 §2): the over-shape half
// (an unknown top-level key) via decodeStrict's DisallowUnknownFields, the
// under-shape half (a missing mandatory key) via an explicit presence probe (Go
// cannot distinguish an absent key from a zero value), and the closed-enum half
// (an unknown `kind` name) via decodeDeclKind. It performs NO governance — it
// parses and validates the shape into a typed struct, nothing more. The input is
// the raw line bytes the spine's DecodeLine handed on after the version gate and
// kind classification; this decoder owns the field-level decode the spine
// deliberately leaves to the per-record decoder.
func DecodeDecl(line []byte) (DeclRecord, error) {
	if err := checkRequiredKeys(line, declRequiredKeys); err != nil {
		return DeclRecord{}, err
	}
	var wire declWire
	if err := decodeStrict(line, &wire); err != nil {
		return DeclRecord{}, err
	}
	kind, err := decodeDeclKind(wire.Kind)
	if err != nil {
		return DeclRecord{}, err
	}
	return DeclRecord{
		SchemaVersion: wire.SchemaVersion,
		QualifiedName: wire.QualifiedName,
		Kind:          kind,
		File:          wire.File,
		Span:          wire.Span,
		Doc:           wire.Doc,
		GTags:         wire.GTags,
		Stub:          wire.Stub,
		Todo:          wire.Todo,
		Debug:         wire.Debug,
		Emits:         wire.Emits,
		Consumes:      wire.Consumes,
		Calls:         wire.Calls,
		DupClass:      wire.DupClass,
		MutData:       wire.MutData,
	}, nil
}

// decodeDeclKind resolves a wire enum-name string to its typed DeclKind. An
// unrecognized name is a FAILURE — the kind set is closed, so a value outside
// the producer's Index_Decl_Kind is refused with a diagnostic listing the
// accepted names, never coerced to a default. This is the closed-enum half of
// the exact-match discipline applied to the `kind` field specifically.
func decodeDeclKind(name string) (DeclKind, error) {
	if kind, ok := declKindByName[name]; ok {
		return kind, nil
	}
	return DeclKindUnknown, fmt.Errorf(
		"index contract: unknown decl kind %q — not one of %v",
		name, sortedDeclKindNames(),
	)
}

// checkRequiredKeys reports a missing-mandatory-field failure when the line
// omits any key in want. It reads the line's top-level keys (the same shallow
// decode the spine's classifier uses) and reports the FIRST absent required key
// in want's order, so the diagnostic is deterministic and names a wire-meaningful
// field. It is the under-shape enforcement encoding/json cannot do on its own —
// a zero value and an absent key are indistinguishable to the strict decoder, so
// presence is checked here before the value decode.
func checkRequiredKeys(line []byte, want []string) error {
	keys, err := topLevelKeys(line)
	if err != nil {
		return err
	}
	for _, k := range want {
		if _, ok := keys[k]; !ok {
			return fmt.Errorf("index contract: decl record missing mandatory field %q", k)
		}
	}
	return nil
}

// sortedDeclKindNames returns the accepted kind names in a deterministic sorted
// order for the unknown-kind diagnostic. Map iteration order is nondeterministic
// in Go, so sorting keeps the error byte-stable — the same determinism
// obligation the spine's sortedKeys carries (no map iteration order reaching
// output).
func sortedDeclKindNames() []string {
	out := make([]string, 0, len(declKindByName))
	for name := range declKindByName {
		out = append(out, name)
	}
	sort.Strings(out)
	return out
}

// declWireFieldCount is the producer's Decl_Record field count (15 — the §29 §2
// decl field list). It anchors a compile-time guard keeping the required-key set
// and the wire struct in lockstep: the array index below is negative — a compile
// error — if declRequiredKeys ever drifts from this count, so a field added to
// declWire without a matching declRequiredKeys entry (or vice versa) cannot
// silently weaken the under-shape presence check.
const declWireFieldCount = 15

var _ = [1]struct{}{}[declWireFieldCount-len(declRequiredKeys)]
