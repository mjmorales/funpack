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
// This file is the `funpack warden` consumer (§29 §1): the pure bytes→record
// decode plus the acquisition seam read_warden_index, whose single read of the
// emitted `.funpack/index.ndjson` build product is the file's ONLY impure
// operation (mirroring read_project's read-then-pure shape) — no clock, no
// write, and NEVER a recompile. The warden surface is a pure projection of the
// already-emitted index, so a missing or version-mismatched index is a closed
// refusal naming `funpack build` as the fix-it; an implicit rebuild would make
// a read-only query a writer-by-side-effect and bypass that contract.
package funpack

import "core:encoding/json"
import "core:fmt"
import "core:os"
import "core:reflect"
import "core:strings"

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

// ── The warden acquisition seam (§29 §1) ───────────────────────────────

// Warden_Read_Error is the closed refusal surface of the warden's index
// acquisition — one arm per way the `.funpack/index.ndjson` build product can
// fail to yield a whole decoded index. Schema_Mismatch is deliberately its own
// arm (not folded into Record_Refused): its fix-it is distinct — rebuild with
// THIS funpack — while every other per-line refusal shares the generic rebuild
// fix-it. Record_Refused delegates the precise cause to the per-line decoder's
// own closed enum (carried in Warden_Refusal.decode), so no decoder arm is
// re-mirrored here. A new refusal cause is a new arm, never a reused catch-all.
Warden_Read_Error :: enum {
	None,
	Missing_Index,            // no .funpack/index.ndjson build product at the root
	Empty_Index,              // the index file holds no record line at all
	Missing_Project_Record,   // the leading record is a decl — the project record must lead
	Duplicate_Project_Record, // a second project record after the leading one
	Schema_Mismatch,          // a record's schema_version stamp differs from this funpack's
	Record_Refused,           // a line the exact-match decoder refused (decode names the cause)
}

// Warden_Refusal is the whole-stream refusal verdict (the stage_flatten
// verdict-struct shape): the closed arm, the 1-based offending stream line for
// line-scoped arms (0 for Missing_Index / Empty_Index, which have no line),
// and the per-line decoder's arm behind Schema_Mismatch / Record_Refused.
// Agents repair from the warden's messages, so the refusal keeps full line and
// cause fidelity instead of collapsing to the arm alone.
Warden_Refusal :: struct {
	err:    Warden_Read_Error,
	line:   int,
	decode: Index_Read_Error,
}

// Warden_Index is the whole decoded index: the stream's single leading
// `project` record plus every `decl` record in emission order (the fixed
// entrypoint-module-first, source-ordered-declaration order emit_index_stream
// pinned — the decode is positional, no re-sort).
Warden_Index :: struct {
	project: Project_Record,
	decls:   []Decl_Record,
}

// read_warden_index reads the `.funpack/index.ndjson` build product at
// build_product_path(root) and decodes the WHOLE stream onto a Warden_Index.
// The file read is this seam's only impure operation; everything downstream is
// decode_warden_index's pure projection of the index bytes. An absent product
// is the Missing_Index refusal — the warden NEVER recompiles in its place
// (§29 §1: the surface is a pure projection of the already-emitted index), so
// the fix-it names `funpack build` and the query stays a reader. Decoded
// records are allocated from `allocator` (the decode_index_line contract:
// free the allocation arena, not individual fields).
read_warden_index :: proc(root: string, allocator := context.allocator) -> (index: Warden_Index, refusal: Warden_Refusal) {
	path := build_product_path(root, INDEX_PRODUCT_NAME, context.temp_allocator)
	bytes, read_err := os.read_entire_file_from_path(path, context.temp_allocator)
	if read_err != nil {
		return Warden_Index{}, Warden_Refusal{err = .Missing_Index}
	}
	return decode_warden_index(string(bytes), allocator)
}

// decode_warden_index decodes a whole Index Contract NDJSON stream against the
// emit_index_stream shape: exactly one `project` record and it leads, every
// subsequent non-empty line a `decl` record. The decode is whole-stream
// first-error: the FIRST offending line refuses the entire stream — never
// line-skipping, so a partially-readable index is never presented as a
// smaller-but-valid one. An empty interior line is not a record and is
// tolerated without being skipped AS one (the emitter writes none; the
// trailing LF is the usual producer shape). The walk is a single forward pass
// — no map iteration, no clock — so the projection is deterministic (§29 §1).
decode_warden_index :: proc(stream: string, allocator := context.allocator) -> (index: Warden_Index, refusal: Warden_Refusal) {
	decls := make([dynamic]Decl_Record, allocator)
	seen_project := false
	line_no := 0
	remaining := stream
	for line in strings.split_lines_iterator(&remaining) {
		line_no += 1
		if line == "" {
			continue
		}
		// decode_index_line's contract is one LF-terminated NDJSON line; the
		// iterator stripped the LF, so restore it (temp — the record's own
		// strings are cloned into `allocator` by the parse).
		full := strings.concatenate({line, "\n"}, context.temp_allocator)
		record, decode_err := decode_index_line(full, allocator)
		if decode_err != .None {
			err := Warden_Read_Error.Record_Refused
			if decode_err == .Schema_Mismatch {
				err = .Schema_Mismatch
			}
			return Warden_Index{}, Warden_Refusal{err = err, line = line_no, decode = decode_err}
		}
		switch decoded in record {
		case Project_Record:
			if seen_project {
				return Warden_Index{}, Warden_Refusal{err = .Duplicate_Project_Record, line = line_no}
			}
			seen_project = true
			index.project = decoded
		case Decl_Record:
			if !seen_project {
				return Warden_Index{}, Warden_Refusal{err = .Missing_Project_Record, line = line_no}
			}
			append(&decls, decoded)
		}
	}
	if !seen_project {
		// No record line at all: an empty (or all-blank) file is Empty_Index —
		// a decl-first stream already refused above, so this arm is exact.
		return Warden_Index{}, Warden_Refusal{err = .Empty_Index}
	}
	index.decls = decls[:]
	return index, Warden_Refusal{}
}

// warden_refusal_message maps a refusal to its fix-it text — the §29 §1
// refusal surface agents repair from. Every arm's fix-it is `funpack build`
// (the warden never rebuilds implicitly); Schema_Mismatch carries its OWN
// phrasing — rebuild with THIS funpack — because the index is well-formed,
// just stamped by a different funpack, and Record_Refused names the per-line
// decoder's exact cause so the message says WHY the bytes are not the
// contract. Pure formatting: bytes in, message out.
warden_refusal_message :: proc(refusal: Warden_Refusal, allocator := context.allocator) -> string {
	switch refusal.err {
	case .None:
		return ""
	case .Missing_Index:
		return fmt.aprintf(
			"%s/%s is missing — the warden reads the emitted index and never recompiles; run `funpack build` to emit it",
			FUNPACK_BUILD_DIR,
			INDEX_PRODUCT_NAME,
			allocator = allocator,
		)
	case .Empty_Index:
		return fmt.aprintf(
			"%s/%s holds no record — line 1 must be the `project` record; rebuild the index with `funpack build`",
			FUNPACK_BUILD_DIR,
			INDEX_PRODUCT_NAME,
			allocator = allocator,
		)
	case .Missing_Project_Record:
		return fmt.aprintf(
			"line %d: the stream must lead with the `project` record but a `decl` record came first; rebuild the index with `funpack build`",
			refusal.line,
			allocator = allocator,
		)
	case .Duplicate_Project_Record:
		return fmt.aprintf(
			"line %d: a second `project` record — the stream carries exactly one, leading; rebuild the index with `funpack build`",
			refusal.line,
			allocator = allocator,
		)
	case .Schema_Mismatch:
		return fmt.aprintf(
			"line %d: the index's schema_version stamp does not match this funpack's v%d — rebuild the index with this funpack: `funpack build`",
			refusal.line,
			INDEX_SCHEMA_VERSION,
			allocator = allocator,
		)
	case .Record_Refused:
		return fmt.aprintf(
			"line %d: %v — the index is not a well-formed Index Contract stream; rebuild it with `funpack build`",
			refusal.line,
			refusal.decode,
			allocator = allocator,
		)
	}
	return ""
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
	record.exposed, err = index_bool_field(object, "exposed")
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
