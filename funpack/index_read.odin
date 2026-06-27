package funpack

import "core:encoding/json"
import "core:fmt"
import "core:os"
import "core:reflect"
import "core:strings"

Index_Read_Error :: enum {
	None,
	Malformed_Json,
	Schema_Mismatch,
	Missing_Field,
	Unknown_Field,
	Wrong_Field_Type,
	Unknown_Enum_Value,
	Unknown_Record_Shape,
}

Index_Record :: union {
	Decl_Record,
	Project_Record,
}

Warden_Read_Error :: enum {
	None,
	Missing_Index,
	Empty_Index,
	Missing_Project_Record,
	Duplicate_Project_Record,
	Schema_Mismatch,
	Record_Refused,
}

Warden_Refusal :: struct {
	err:    Warden_Read_Error,
	line:   int,
	decode: Index_Read_Error,
}

Warden_Index :: struct {
	project: Project_Record,
	decls:   []Decl_Record,
}

read_warden_index :: proc(root: string, allocator := context.allocator) -> (index: Warden_Index, refusal: Warden_Refusal) {
	path := build_product_path(root, INDEX_PRODUCT_NAME, context.temp_allocator)
	bytes, read_err := os.read_entire_file_from_path(path, context.temp_allocator)
	if read_err != nil {
		return Warden_Index{}, Warden_Refusal{err = .Missing_Index}
	}
	return decode_warden_index(string(bytes), allocator)
}

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
		return Warden_Index{}, Warden_Refusal{err = .Empty_Index}
	}
	index.decls = decls[:]
	return index, Warden_Refusal{}
}

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

parse_index_object :: proc(line: string, allocator := context.allocator) -> (object: json.Object, err: Index_Read_Error) {
	context.allocator = allocator
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

index_enum_field :: proc($E: typeid, object: json.Object, key: string) -> (value: E, err: Index_Read_Error) {
	raw, present := object[key]
	if !present {
		err = .Missing_Field
		return
	}
	return decode_enum_name(E, raw)
}

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
