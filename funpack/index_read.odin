// The Index Contract CONSUMER: decodes one NDJSON line back onto the SAME
// Decl_Record / Project_Record structs index_contract.odin emits (spec §29
// §2) — one schema definition shared by producer and consumer, so a field
// drift is a type error here, never a silent mismatch (the exact failure the
// retired Go mirror had; ADR 2026-06-08-warden-sub-toolchain-ethos).
//
// Decode is EXACT-MATCH per §29 §2: the schema_version stamp must equal
// INDEX_SCHEMA_VERSION (a mismatch is a refusal, never best-effort parsing);
// ALL fields are mandatory, so an under-shaped record (missing key) and an
// over-shaped record (unknown key) are both errors; and the two record kinds
// are discriminated STRUCTURALLY by their disjoint mandatory marker fields —
// the contract carries no fabricated tag field. core:encoding/json's
// unmarshal is lenient on missing/unknown keys, so it cannot enforce this:
// the decoder parses to a json.Value tree and projects manually, checking
// each record's key set both ways (every mandatory key present + the object's
// key count equals the struct's field count — no map iteration, so the check
// is deterministic per §29 §1).
//
// This file is the pure bytes→record half of the `funpack warden` consumer
// (§29 §1): no core:os import, no clock, no write. File acquisition and the
// whole-stream shape live with the warden verb seam, not here.
package funpack

import "core:encoding/json"
import "core:reflect"

// Index_Read_Error is closed with one arm per §29 §2 refusal cause — the
// consumer never best-effort-parses past any of these, and the warden
// refusal surface maps each arm to its fix-it. A new refusal cause is a new
// arm under closed-enum discipline, never a reused catch-all.
Index_Read_Error :: enum {
	None,
	Malformed_Json,       // the line is not exactly one parseable JSON object
	Schema_Mismatch,      // schema_version differs from INDEX_SCHEMA_VERSION
	Missing_Field,        // a mandatory key is absent (under-shaped record)
	Unknown_Field,        // a key outside the closed field set (over-shaped record)
	Wrong_Field_Type,     // a mandatory key carries the wrong JSON value type
	Unknown_Enum_Value,   // a kind/capability/gate name outside its closed enum
	Unknown_Record_Shape, // neither (or both) §29 §2 marker sets present
}

// Index_Record is the decoded line: exactly one of the two §29 §2 record
// kinds, carried as the producer's own struct (index_contract.odin defines
// both — this union declares no mirrored shape). nil only rides an error.
Index_Record :: union {
	Decl_Record,
	Project_Record,
}

// decode_index_line decodes ONE NDJSON line of the Index Contract stream onto
// the producer's record structs (spec §29 §2). The refusal order is fixed:
// the line must parse as exactly one JSON object (Malformed_Json), its
// schema_version stamp must be present and exact-match INDEX_SCHEMA_VERSION
// (Missing_Field / Schema_Mismatch — the version gate fires before any shape
// reading, so a reshaped stream refuses on the version, never on a confusing
// field error), and the record kind must discriminate structurally from the
// disjoint marker fields. Decoded strings and slices are allocated from (or
// alias the parse tree allocated from) `allocator` — free the allocation
// arena, not individual fields.
decode_index_line :: proc(line: string, allocator := context.allocator) -> (record: Index_Record, err: Index_Read_Error) {
	object, object_err := parse_index_object(line, allocator)
	if object_err != .None {
		return nil, object_err
	}
	version, version_err := index_int_field(object, "schema_version")
	if version_err != .None {
		return nil, version_err
	}
	if version != INDEX_SCHEMA_VERSION {
		return nil, .Schema_Mismatch
	}
	// Structural kind discrimination (§29 §2): the `decl` markers
	// (qualified_name/dup_class/mut_data) and the `project` markers
	// (pipeline_flattened/gate_results) are disjoint mandatory field sets, so a
	// well-shaped record carries exactly one set. Equality covers both refusal
	// shapes: neither set present (nothing to discriminate) and both present
	// (an ambiguous chimera) are each Unknown_Record_Shape.
	decl_marked := ("qualified_name" in object) || ("dup_class" in object) || ("mut_data" in object)
	project_marked := ("pipeline_flattened" in object) || ("gate_results" in object)
	if decl_marked == project_marked {
		return nil, .Unknown_Record_Shape
	}
	if decl_marked {
		decl, decl_err := decode_decl_record(object, allocator)
		if decl_err != .None {
			return nil, decl_err
		}
		return decl, .None
	}
	project, project_err := decode_project_record(object, allocator)
	if project_err != .None {
		return nil, project_err
	}
	return project, .None
}

// parse_index_object parses one NDJSON line into its top-level JSON object.
// json.parse stops at the first complete value and ignores trailing bytes,
// which would let `{…}{…}` pass as one line — so this drives the parser
// directly and requires EOF after the object (a trailing LF tokenizes to EOF;
// trailing content is Malformed_Json). A non-object top-level value and a
// duplicated key (a parser error) are likewise Malformed_Json: the transport
// is one JSON object per line, anything else is not a record.
parse_index_object :: proc(line: string, allocator := context.allocator) -> (object: json.Object, err: Index_Read_Error) {
	context.allocator = allocator
	// parse_integers keeps whole numbers as json.Integer — the contract has no
	// float (§29 §1), and the default float path would round dup_class.
	parser := json.make_parser_from_string(line, json.DEFAULT_SPECIFICATION, true, allocator)
	value, parse_err := json.parse_value(&parser)
	if parse_err != .None {
		return nil, .Malformed_Json
	}
	if parser.curr_token.kind != .EOF {
		return nil, .Malformed_Json
	}
	parsed, is_object := value.(json.Object)
	if !is_object {
		return nil, .Malformed_Json
	}
	return parsed, .None
}

// decode_decl_record projects a discriminated `decl` object onto the
// producer's Decl_Record, field by mandatory field. The trailing key-count
// check closes the key set the other way: with every struct field's key
// proven present, a count above the struct's field count means an unknown key
// rode along (reflect.struct_field_count reads the count off the ONE shared
// struct, so the check reshapes in lockstep with the contract). A duplicate
// key cannot defeat the count — the parser refused it upstream.
decode_decl_record :: proc(object: json.Object, allocator := context.allocator) -> (record: Decl_Record, err: Index_Read_Error) {
	record.schema_version, err = index_int_field(object, "schema_version")
	if err != .None {
		return
	}
	record.qualified_name, err = index_string_field(object, "qualified_name")
	if err != .None {
		return
	}
	record.kind, err = index_enum_field(Index_Decl_Kind, object, "kind")
	if err != .None {
		return
	}
	record.file, err = index_string_field(object, "file")
	if err != .None {
		return
	}
	record.span, err = index_int_field(object, "span")
	if err != .None {
		return
	}
	record.doc, err = index_string_field(object, "doc")
	if err != .None {
		return
	}
	record.gtags, err = index_string_list_field(object, "gtags", allocator)
	if err != .None {
		return
	}
	record.stub, err = index_bool_field(object, "stub")
	if err != .None {
		return
	}
	record.todo, err = index_bool_field(object, "todo")
	if err != .None {
		return
	}
	record.debug, err = index_string_list_field(object, "debug", allocator)
	if err != .None {
		return
	}
	record.emits, err = index_string_list_field(object, "emits", allocator)
	if err != .None {
		return
	}
	record.consumes, err = index_string_list_field(object, "consumes", allocator)
	if err != .None {
		return
	}
	record.calls, err = index_string_list_field(object, "calls", allocator)
	if err != .None {
		return
	}
	record.dup_class, err = index_u64_field(object, "dup_class")
	if err != .None {
		return
	}
	record.mut_data, err = index_string_list_field(object, "mut_data", allocator)
	if err != .None {
		return
	}
	if len(object) != reflect.struct_field_count(Decl_Record) {
		return Decl_Record{}, .Unknown_Field
	}
	return record, .None
}

// decode_project_record projects a discriminated `project` object onto the
// producer's Project_Record. Every field is mandatory — an empty-but-present
// list decodes to a zero-length slice, never to an omitted field — and each
// nested record (entrypoint, build, flat step, gate result) is exact-matched
// recursively: the §29 §2 closed-shape rule applies at every level, not just
// the top. The trailing key-count check mirrors decode_decl_record's.
decode_project_record :: proc(object: json.Object, allocator := context.allocator) -> (record: Project_Record, err: Index_Read_Error) {
	record.schema_version, err = index_int_field(object, "schema_version")
	if err != .None {
		return
	}
	record.entrypoints, err = decode_entrypoint_list(object, "entrypoints", allocator)
	if err != .None {
		return
	}
	record.builds, err = decode_build_list(object, "builds", allocator)
	if err != .None {
		return
	}
	record.tag_registry, err = index_string_list_field(object, "tag_registry", allocator)
	if err != .None {
		return
	}
	record.capabilities, err = decode_capability_list(object, "capabilities", allocator)
	if err != .None {
		return
	}
	record.pipeline_flattened, err = decode_flat_step_list(object, "pipeline_flattened", allocator)
	if err != .None {
		return
	}
	record.gate_results, err = decode_gate_result_list(object, "gate_results", allocator)
	if err != .None {
		return
	}
	if len(object) != reflect.struct_field_count(Project_Record) {
		return Project_Record{}, .Unknown_Field
	}
	return record, .None
}

// decode_entrypoint_list decodes the mandatory `entrypoints` array: each
// element is an exact-match Entrypoint_Record object (all four keys present,
// no extras — the nested count check closes the nested shape).
decode_entrypoint_list :: proc(object: json.Object, key: string, allocator := context.allocator) -> (records: []Entrypoint_Record, err: Index_Read_Error) {
	elements, array_err := index_array_field(object, key)
	if array_err != .None {
		return nil, array_err
	}
	decoded := make([]Entrypoint_Record, len(elements), allocator)
	for element, i in elements {
		nested, is_object := element.(json.Object)
		if !is_object {
			return nil, .Wrong_Field_Type
		}
		decoded[i].name, err = index_string_field(nested, "name")
		if err != .None {
			return nil, err
		}
		decoded[i].pipeline, err = index_string_field(nested, "pipeline")
		if err != .None {
			return nil, err
		}
		decoded[i].tick_hz, err = index_int_field(nested, "tick_hz")
		if err != .None {
			return nil, err
		}
		decoded[i].bindings, err = index_string_field(nested, "bindings")
		if err != .None {
			return nil, err
		}
		if len(nested) != reflect.struct_field_count(Entrypoint_Record) {
			return nil, .Unknown_Field
		}
	}
	return decoded, .None
}

// decode_build_list decodes the mandatory `builds` array: each element is an
// exact-match Build_Record object (name + platform, nothing else).
decode_build_list :: proc(object: json.Object, key: string, allocator := context.allocator) -> (records: []Build_Record, err: Index_Read_Error) {
	elements, array_err := index_array_field(object, key)
	if array_err != .None {
		return nil, array_err
	}
	decoded := make([]Build_Record, len(elements), allocator)
	for element, i in elements {
		nested, is_object := element.(json.Object)
		if !is_object {
			return nil, .Wrong_Field_Type
		}
		decoded[i].name, err = index_string_field(nested, "name")
		if err != .None {
			return nil, err
		}
		decoded[i].platform, err = index_string_field(nested, "platform")
		if err != .None {
			return nil, err
		}
		if len(nested) != reflect.struct_field_count(Build_Record) {
			return nil, .Unknown_Field
		}
	}
	return decoded, .None
}

// decode_capability_list decodes the mandatory `capabilities` array: each
// element is a Capability name emitted via use_enum_names, exact-matched
// against the closed enum — an unrecognized battery name is a refusal, never
// a skipped element.
decode_capability_list :: proc(object: json.Object, key: string, allocator := context.allocator) -> (capabilities: []Capability, err: Index_Read_Error) {
	elements, array_err := index_array_field(object, key)
	if array_err != .None {
		return nil, array_err
	}
	decoded := make([]Capability, len(elements), allocator)
	for element, i in elements {
		decoded[i], err = decode_enum_name(Capability, element)
		if err != .None {
			return nil, err
		}
	}
	return decoded, .None
}

// decode_flat_step_list decodes the mandatory `pipeline_flattened` array:
// each element is an exact-match Flat_Step_Record object in emitted order —
// the depth-first total order is positional, so no re-sort happens here.
decode_flat_step_list :: proc(object: json.Object, key: string, allocator := context.allocator) -> (steps: []Flat_Step_Record, err: Index_Read_Error) {
	elements, array_err := index_array_field(object, key)
	if array_err != .None {
		return nil, array_err
	}
	decoded := make([]Flat_Step_Record, len(elements), allocator)
	for element, i in elements {
		nested, is_object := element.(json.Object)
		if !is_object {
			return nil, .Wrong_Field_Type
		}
		decoded[i].ordinal, err = index_int_field(nested, "ordinal")
		if err != .None {
			return nil, err
		}
		decoded[i].stage, err = index_string_field(nested, "stage")
		if err != .None {
			return nil, err
		}
		decoded[i].behavior, err = index_string_field(nested, "behavior")
		if err != .None {
			return nil, err
		}
		if len(nested) != reflect.struct_field_count(Flat_Step_Record) {
			return nil, .Unknown_Field
		}
	}
	return decoded, .None
}

// decode_gate_result_list decodes the mandatory `gate_results` array: each
// element is an exact-match Gate_Result object whose gate name exact-matches
// the closed Gate_Family enum.
decode_gate_result_list :: proc(object: json.Object, key: string, allocator := context.allocator) -> (results: []Gate_Result, err: Index_Read_Error) {
	elements, array_err := index_array_field(object, key)
	if array_err != .None {
		return nil, array_err
	}
	decoded := make([]Gate_Result, len(elements), allocator)
	for element, i in elements {
		nested, is_object := element.(json.Object)
		if !is_object {
			return nil, .Wrong_Field_Type
		}
		decoded[i].gate, err = index_enum_field(Gate_Family, nested, "gate")
		if err != .None {
			return nil, err
		}
		decoded[i].passed, err = index_bool_field(nested, "passed")
		if err != .None {
			return nil, err
		}
		if len(nested) != reflect.struct_field_count(Gate_Result) {
			return nil, .Unknown_Field
		}
	}
	return decoded, .None
}

// ── Mandatory-field accessors ──────────────────────────────────────────
// Each accessor is one half of the both-ways key-set check: it proves a
// mandatory key present (Missing_Field) and correctly typed
// (Wrong_Field_Type); the record decoders' key-count comparison closes the
// set against extras. Lookups are point reads — no map iteration — so the
// projection is deterministic (§29 §1).

// index_string_field reads a mandatory string-typed key.
index_string_field :: proc(object: json.Object, key: string) -> (value: string, err: Index_Read_Error) {
	raw, present := object[key]
	if !present {
		return "", .Missing_Field
	}
	str, is_string := raw.(json.String)
	if !is_string {
		return "", .Wrong_Field_Type
	}
	return string(str), .None
}

// index_int_field reads a mandatory integer-typed key (span, tick_hz,
// ordinal, schema_version — all comfortably inside i64).
index_int_field :: proc(object: json.Object, key: string) -> (value: int, err: Index_Read_Error) {
	raw, present := object[key]
	if !present {
		return 0, .Missing_Field
	}
	integer, is_integer := raw.(json.Integer)
	if !is_integer {
		return 0, .Wrong_Field_Type
	}
	return int(integer), .None
}

// index_u64_field reads the mandatory dup_class key, whose u64 hash domain
// exceeds json.Integer's i64. The producer emits the full unsigned decimal;
// strconv's digit loop wraps modulo 2^64 (Odin integer arithmetic is defined
// two's-complement), so the parsed i64 carries the exact bit pattern and the
// unsigned cast recovers the exact u64 — round-tripping any producer-emitted
// hash byte-identically. A non-canonical numeral (a negative, an over-2^64
// literal) is outside the contract and decodes to its wrapped value.
index_u64_field :: proc(object: json.Object, key: string) -> (value: u64, err: Index_Read_Error) {
	raw, present := object[key]
	if !present {
		return 0, .Missing_Field
	}
	integer, is_integer := raw.(json.Integer)
	if !is_integer {
		return 0, .Wrong_Field_Type
	}
	return u64(i64(integer)), .None
}

// index_bool_field reads a mandatory boolean-typed key.
index_bool_field :: proc(object: json.Object, key: string) -> (value: bool, err: Index_Read_Error) {
	raw, present := object[key]
	if !present {
		return false, .Missing_Field
	}
	boolean, is_boolean := raw.(json.Boolean)
	if !is_boolean {
		return false, .Wrong_Field_Type
	}
	return bool(boolean), .None
}

// index_array_field reads a mandatory array-typed key, returning the raw
// elements for the caller's per-element projection. An empty-but-present
// list is a zero-length array — present, never an error (§29 §2).
index_array_field :: proc(object: json.Object, key: string) -> (elements: json.Array, err: Index_Read_Error) {
	raw, present := object[key]
	if !present {
		return nil, .Missing_Field
	}
	array, is_array := raw.(json.Array)
	if !is_array {
		return nil, .Wrong_Field_Type
	}
	return array, .None
}

// index_string_list_field reads a mandatory array-of-strings key into a
// []string allocated from `allocator`.
index_string_list_field :: proc(object: json.Object, key: string, allocator := context.allocator) -> (list: []string, err: Index_Read_Error) {
	elements, array_err := index_array_field(object, key)
	if array_err != .None {
		return nil, array_err
	}
	decoded := make([]string, len(elements), allocator)
	for element, i in elements {
		str, is_string := element.(json.String)
		if !is_string {
			return nil, .Wrong_Field_Type
		}
		decoded[i] = string(str)
	}
	return decoded, .None
}

// index_enum_field reads a mandatory enum-named key (kind, gate), decoding
// the use_enum_names string by exact name against the closed enum E.
index_enum_field :: proc($E: typeid, object: json.Object, key: string) -> (value: E, err: Index_Read_Error) {
	raw, present := object[key]
	if !present {
		err = .Missing_Field
		return
	}
	return decode_enum_name(E, raw)
}

// decode_enum_name exact-matches an emitted enum-name string against the
// closed enum E (the inverse of use_enum_names). A name outside the enum is
// Unknown_Enum_Value — the §29 §2 closed-set refusal, never a default value.
decode_enum_name :: proc($E: typeid, raw: json.Value) -> (value: E, err: Index_Read_Error) {
	name, is_string := raw.(json.String)
	if !is_string {
		err = .Wrong_Field_Type
		return
	}
	decoded, known := reflect.enum_from_name(E, string(name))
	if !known {
		err = .Unknown_Enum_Value
		return
	}
	return decoded, .None
}
