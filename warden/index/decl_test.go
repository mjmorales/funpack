package index

import (
	"strings"
	"testing"
)

// declGoldenLine is the canonical `decl` record line in the exact wire shape
// funpack/index_contract.odin's emit_decl_record produces. It mirrors the
// producer's minimal_decl_record fixture byte-for-byte: schema_version leading,
// the 15 §29 §2 keys in producer field-declaration order, kind as its
// use_enum_names identifier string ("Behavior"), dup_class as a BARE u64 number
// (0xcbf29ce484222325 = 14695981039346656037), and the always-present-but-empty
// directive fields stub:false / todo:false / debug:[]. This line IS the contract
// — it is what the live producer emits — so the decode test pins to it, not to a
// best-reading of the spec.
const declGoldenLine = `{"schema_version":2,"qualified_name":"pong.update_ball","kind":"Behavior","file":"","span":42,"doc":"advances the ball","gtags":["game"],"stub":false,"todo":false,"debug":[],"emits":["Hit"],"consumes":["Tick"],"calls":["advance"],"dup_class":14695981039346656037,"mut_data":["Ball"]}`

func TestDeclRecordDecodesGolden(t *testing.T) {
	// The golden decl line — the exact shape the live producer emits — decodes
	// into a fully-populated DeclRecord with every §29 §2 field carrying its wire
	// value. This is the byte-match contract against funpack/index_contract.odin's
	// emit_decl_record output.
	rec, err := DecodeDecl([]byte(declGoldenLine))
	if err != nil {
		t.Fatalf("expected the golden decl line to decode, got %v", err)
	}
	if rec.SchemaVersion != 2 {
		t.Fatalf("schema_version: want 2, got %d", rec.SchemaVersion)
	}
	if rec.QualifiedName != "pong.update_ball" {
		t.Fatalf("qualified_name: want pong.update_ball, got %q", rec.QualifiedName)
	}
	if rec.Kind != DeclKindBehavior {
		t.Fatalf("kind: want DeclKindBehavior, got %v", rec.Kind)
	}
	if rec.File != "" {
		t.Fatalf("file: want empty, got %q", rec.File)
	}
	if rec.Span != 42 {
		t.Fatalf("span: want 42, got %d", rec.Span)
	}
	if rec.Doc != "advances the ball" {
		t.Fatalf("doc: want 'advances the ball', got %q", rec.Doc)
	}
	if len(rec.GTags) != 1 || rec.GTags[0] != "game" {
		t.Fatalf("gtags: want [game], got %v", rec.GTags)
	}
	if rec.Stub || rec.Todo {
		t.Fatalf("stub/todo: want false/false, got %v/%v", rec.Stub, rec.Todo)
	}
	if len(rec.Debug) != 0 {
		t.Fatalf("debug: want empty, got %v", rec.Debug)
	}
	if len(rec.Emits) != 1 || rec.Emits[0] != "Hit" {
		t.Fatalf("emits: want [Hit], got %v", rec.Emits)
	}
	if len(rec.Consumes) != 1 || rec.Consumes[0] != "Tick" {
		t.Fatalf("consumes: want [Tick], got %v", rec.Consumes)
	}
	if len(rec.Calls) != 1 || rec.Calls[0] != "advance" {
		t.Fatalf("calls: want [advance], got %v", rec.Calls)
	}
	// dup_class is the producer's u64 FNV-offset-basis hash, the full-range value
	// that would lose precision through a float64 — it must round-trip exactly.
	if rec.DupClass != 0xcbf29ce484222325 {
		t.Fatalf("dup_class: want 0xcbf29ce484222325, got %#x", rec.DupClass)
	}
	if len(rec.MutData) != 1 || rec.MutData[0] != "Ball" {
		t.Fatalf("mut_data: want [Ball], got %v", rec.MutData)
	}
}

func TestDeclGoldenRidesTheSpine(t *testing.T) {
	// The golden decl line dispatches through the spine to RecordKindDecl on its
	// decl-only structural signature, then decodes via DecodeDecl on the bytes the
	// spine carried — the end-to-end consumer path (version gate → structural kind
	// classification → per-record decode), no kind tag on the wire.
	rec, err := DecodeLine([]byte(declGoldenLine))
	if err != nil {
		t.Fatalf("expected the golden decl line to ride the spine, got %v", err)
	}
	if rec.Kind != RecordKindDecl {
		t.Fatalf("expected RecordKindDecl, got %v", rec.Kind)
	}
	decoded, err := DecodeDecl(rec.Raw)
	if err != nil {
		t.Fatalf("expected the spine-carried bytes to decode, got %v", err)
	}
	if decoded.QualifiedName != "pong.update_ball" {
		t.Fatalf("spine-decoded qualified_name wrong: %q", decoded.QualifiedName)
	}
}

func TestDeclFullCoversEveryKind(t *testing.T) {
	// Every closed Index_Decl_Kind wire name decodes to its typed DeclKind — the
	// full kind taxonomy byte-matched against the producer's enum names
	// (use_enum_names). A name absent from the producer's set would be an unknown
	// kind; this asserts the table covers the whole closed enum.
	cases := map[string]DeclKind{
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
	for name, want := range cases {
		line := strings.Replace(declGoldenLine, `"kind":"Behavior"`, `"kind":"`+name+`"`, 1)
		rec, err := DecodeDecl([]byte(line))
		if err != nil {
			t.Fatalf("kind %q: expected a clean decode, got %v", name, err)
		}
		if rec.Kind != want {
			t.Fatalf("kind %q: want %v, got %v", name, want, rec.Kind)
		}
		// The kind round-trips back to its exact producer wire name.
		if rec.Kind.String() != name {
			t.Fatalf("kind %q: String() round-trip got %q", name, rec.Kind.String())
		}
	}
}

func TestDeclRejectUnknownField(t *testing.T) {
	// An over-shaped decl record (a top-level key the wire struct does not name)
	// is a FAILURE under DisallowUnknownFields — the over-shape half of the
	// exact-match discipline (spec §29 §2).
	line := strings.Replace(declGoldenLine, `"mut_data":["Ball"]`, `"mut_data":["Ball"],"extra":true`, 1)
	_, err := DecodeDecl([]byte(line))
	if err == nil {
		t.Fatal("expected an unknown field to be rejected, got nil")
	}
	if !strings.Contains(err.Error(), "strict decode failed") {
		t.Fatalf("expected a strict-decode error, got %q", err.Error())
	}
}

func TestDeclMissingMandatoryField(t *testing.T) {
	// A decl record omitting any mandatory field is a FAILURE — the under-shape
	// half of the exact-match discipline (spec §29 §2). encoding/json cannot
	// distinguish an absent key from a zero value, so presence is checked
	// explicitly; the diagnostic names the first missing field. Every mandatory
	// key is exercised by dropping it from the golden line.
	for _, key := range declRequiredKeys {
		t.Run(key, func(t *testing.T) {
			line := dropKey(t, declGoldenLine, key)
			_, err := DecodeDecl([]byte(line))
			if err == nil {
				t.Fatalf("expected dropping %q to fail, got nil", key)
			}
			if !strings.Contains(err.Error(), "missing mandatory field") {
				t.Fatalf("expected a missing-mandatory-field error for %q, got %q", key, err.Error())
			}
			if !strings.Contains(err.Error(), key) {
				t.Fatalf("expected the error to name the missing field %q, got %q", key, err.Error())
			}
		})
	}
}

func TestDeclUnknownKindEnum(t *testing.T) {
	// An unknown `kind` value is a FAILURE — the kind set is closed (the
	// producer's Index_Decl_Kind), so a name outside it is refused, never coerced
	// to a default. The diagnostic lists the accepted names.
	line := strings.Replace(declGoldenLine, `"kind":"Behavior"`, `"kind":"Widget"`, 1)
	_, err := DecodeDecl([]byte(line))
	if err == nil {
		t.Fatal("expected an unknown decl kind to fail, got nil")
	}
	if !strings.Contains(err.Error(), "unknown decl kind") {
		t.Fatalf("expected an unknown-decl-kind error, got %q", err.Error())
	}
	if !strings.Contains(err.Error(), `"Widget"`) {
		t.Fatalf("expected the offending kind named in the error, got %q", err.Error())
	}
}

func TestDeclNegativeKindOrdinalRejected(t *testing.T) {
	// The producer emits the kind as its enum NAME string (use_enum_names), never
	// an ordinal. A numeric kind is therefore not the wire shape and is refused —
	// the wire struct's kind field is a string, so a number is a strict-decode
	// type error, not a silently-coerced ordinal.
	line := strings.Replace(declGoldenLine, `"kind":"Behavior"`, `"kind":6`, 1)
	_, err := DecodeDecl([]byte(line))
	if err == nil {
		t.Fatal("expected a numeric kind to be rejected, got nil")
	}
}

func TestDeclRejectDupClassPrecisionLoss(t *testing.T) {
	// The maximum u64 dup_class (the producer's hash domain ceiling) decodes
	// without precision loss — proving the uint64 field, not a float64
	// intermediary, holds the full range. A float64 would round 2^64-1 to a
	// different value; uint64 round-trips it exactly.
	const maxU64 = `18446744073709551615`
	line := strings.Replace(declGoldenLine, `"dup_class":14695981039346656037`, `"dup_class":`+maxU64, 1)
	rec, err := DecodeDecl([]byte(line))
	if err != nil {
		t.Fatalf("expected the max-u64 dup_class to decode, got %v", err)
	}
	if rec.DupClass != 18446744073709551615 {
		t.Fatalf("dup_class precision loss: want 18446744073709551615, got %d", rec.DupClass)
	}
}

func TestDeclEmptyListsAndStringsDecode(t *testing.T) {
	// A decl record whose mandatory list/string fields are all empty (the
	// always-empty current-tree directive fields, plus an undocumented
	// declaration with no routes/calls) decodes cleanly with present-but-empty
	// values — absence is the empty list / "" / false, never an omitted key, so
	// the presence check passes and the fields decode to their zero values.
	line := `{"schema_version":2,"qualified_name":"pong.tiny","kind":"Data","file":"","span":1,"doc":"","gtags":[],"stub":false,"todo":false,"debug":[],"emits":[],"consumes":[],"calls":[],"dup_class":0,"mut_data":[]}`
	rec, err := DecodeDecl([]byte(line))
	if err != nil {
		t.Fatalf("expected an all-empty-but-present decl record to decode, got %v", err)
	}
	if rec.Kind != DeclKindData {
		t.Fatalf("kind: want DeclKindData, got %v", rec.Kind)
	}
	if len(rec.GTags) != 0 || len(rec.Emits) != 0 || len(rec.MutData) != 0 {
		t.Fatalf("expected empty lists to decode empty, got gtags=%v emits=%v mut_data=%v", rec.GTags, rec.Emits, rec.MutData)
	}
}

func TestDeclAndProjectSignaturesDisjoint(t *testing.T) {
	// The structural marker sets the spine classifies on must stay disjoint — no
	// key appears in both, so no line can satisfy both signatures and the kind
	// dispatch is unambiguous. This guards the no-aliasing invariant the
	// classifier's both-match failure arm assumes.
	for _, pk := range projectMarkerKeys {
		for _, dk := range declMarkerKeys {
			if pk == dk {
				t.Fatalf("marker-set aliasing: %q is in both project and decl signatures", pk)
			}
		}
	}
	// A project line must NOT classify as decl, and the golden decl line must NOT
	// classify as project — the disjoint signatures route each kind to itself.
	pRec, err := DecodeLine([]byte(projectLine))
	if err != nil {
		t.Fatalf("project line failed to decode: %v", err)
	}
	if pRec.Kind != RecordKindProject {
		t.Fatalf("project line misclassified as %v", pRec.Kind)
	}
	dRec, err := DecodeLine([]byte(declGoldenLine))
	if err != nil {
		t.Fatalf("decl line failed to decode: %v", err)
	}
	if dRec.Kind != RecordKindDecl {
		t.Fatalf("decl line misclassified as %v", dRec.Kind)
	}
}

// dropKey returns the golden line with one top-level key removed, for the
// missing-mandatory-field cases. It rebuilds the object from a shallow key map
// so the result is a valid JSON object minus exactly one key — a textual splice
// would risk leaving a dangling comma. The helper is test-local; production
// never removes a key, it only refuses a record missing one.
func dropKey(t *testing.T, line, key string) string {
	t.Helper()
	keys, err := topLevelKeys([]byte(line))
	if err != nil {
		t.Fatalf("dropKey: golden line is not an object: %v", err)
	}
	if _, ok := keys[key]; !ok {
		t.Fatalf("dropKey: key %q not present in golden line", key)
	}
	// Locate the key's "key":value segment and excise it plus its delimiter. The
	// golden line is a flat object with no nested objects sharing these top-level
	// key names, so a first-match splice on the quoted key is unambiguous here.
	return spliceOutKey(t, line, key)
}

// spliceOutKey removes a single `"key":value` member (and its adjacent comma)
// from a flat JSON object string. It handles both the leading member (comma
// after) and any interior/trailing member (comma before), so the result stays a
// valid object. Scoped to the flat golden decl line — it does not recurse into
// nested objects, which the golden line does not contain at a colliding key.
func spliceOutKey(t *testing.T, line, key string) string {
	t.Helper()
	marker := `"` + key + `":`
	start := strings.Index(line, marker)
	if start < 0 {
		t.Fatalf("spliceOutKey: marker %q not found", marker)
	}
	// Find the end of this member's value: the next top-level comma or the
	// closing brace. The values in the golden line are scalars, strings, or flat
	// arrays of strings/numbers — none contains a top-level comma outside its own
	// brackets — so a bracket-depth scan finds the member boundary.
	end := memberEnd(line, start+len(marker))
	// Excise the member plus exactly one adjacent comma so no dangling comma
	// remains: prefer the trailing comma; if absent (the member is last), take the
	// preceding comma instead.
	if end < len(line) && line[end] == ',' {
		end++ // consume the trailing comma
		return line[:start] + line[end:]
	}
	// Last member: walk back over the preceding comma.
	prev := start
	for prev > 0 && line[prev-1] != ',' {
		prev--
	}
	if prev > 0 {
		prev-- // consume the preceding comma
	}
	return line[:prev] + line[end:]
}

// memberEnd returns the index one past a member's value, starting at the value's
// first byte. It scans to the next comma at bracket-depth zero or the closing
// `}` of the object, tracking string literals so a comma or brace inside a
// string is not mistaken for a boundary. It serves spliceOutKey over the flat
// golden line; it is not a general JSON parser.
func memberEnd(line string, i int) int {
	depth := 0
	inStr := false
	for ; i < len(line); i++ {
		c := line[i]
		if inStr {
			if c == '\\' {
				i++ // skip the escaped byte
				continue
			}
			if c == '"' {
				inStr = false
			}
			continue
		}
		switch c {
		case '"':
			inStr = true
		case '[', '{':
			depth++
		case ']', '}':
			if depth == 0 {
				return i // the object's closing brace ends the last member
			}
			depth--
		case ',':
			if depth == 0 {
				return i
			}
		}
	}
	return i
}
