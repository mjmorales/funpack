package funpack

import "core:log"
import "core:os"
import "core:slice"
import "core:strings"
import "core:testing"

decl_record_fixture :: proc(kind: Index_Decl_Kind) -> Decl_Record {
	gtags := make([]string, 2, context.temp_allocator)
	gtags[0], gtags[1] = "game", "render"
	debug := make([]string, 1, context.temp_allocator)
	debug[0] = "probe"
	emits := make([]string, 1, context.temp_allocator)
	emits[0] = "Goal"
	consumes := make([]string, 1, context.temp_allocator)
	consumes[0] = "Tick"
	calls := make([]string, 2, context.temp_allocator)
	calls[0], calls[1] = "add", "clamp"
	mut_data := make([]string, 1, context.temp_allocator)
	mut_data[0] = "Board"
	return Decl_Record {
		schema_version = INDEX_SCHEMA_VERSION,
		qualified_name = "drift.launch_speed",
		kind           = kind,
		file           = "",
		span           = 7,
		doc            = "Speeds the \"launch\" up.",
		gtags          = gtags,
		stub           = true,
		todo           = false,
		debug          = debug,
		exposed        = true,
		emits          = emits,
		consumes       = consumes,
		calls          = calls,
		dup_class      = 0xfffe_cbf2_9ce4_8422,
		mut_data       = mut_data,
	}
}

empty_lists_decl_record :: proc() -> Decl_Record {
	return Decl_Record {
		schema_version = INDEX_SCHEMA_VERSION,
		qualified_name = "Board",
		kind           = .Data,
		span           = 1,
	}
}

expect_decl_fields_equal :: proc(t: ^testing.T, got: Decl_Record, want: Decl_Record) {
	testing.expect_value(t, got.schema_version, want.schema_version)
	testing.expect_value(t, got.qualified_name, want.qualified_name)
	testing.expect_value(t, got.kind, want.kind)
	testing.expect_value(t, got.file, want.file)
	testing.expect_value(t, got.span, want.span)
	testing.expect_value(t, got.doc, want.doc)
	testing.expect(t, slice.equal(got.gtags, want.gtags))
	testing.expect_value(t, got.stub, want.stub)
	testing.expect_value(t, got.todo, want.todo)
	testing.expect(t, slice.equal(got.debug, want.debug))
	testing.expect_value(t, got.exposed, want.exposed)
	testing.expect(t, slice.equal(got.emits, want.emits))
	testing.expect(t, slice.equal(got.consumes, want.consumes))
	testing.expect(t, slice.equal(got.calls, want.calls))
	testing.expect_value(t, got.dup_class, want.dup_class)
	testing.expect(t, slice.equal(got.mut_data, want.mut_data))
}

expect_project_fields_equal :: proc(t: ^testing.T, got: Project_Record, want: Project_Record) {
	testing.expect_value(t, got.schema_version, want.schema_version)
	testing.expect(t, slice.equal(got.entrypoints, want.entrypoints))
	testing.expect(t, slice.equal(got.builds, want.builds))
	testing.expect(t, slice.equal(got.tag_registry, want.tag_registry))
	testing.expect(t, slice.equal(got.capabilities, want.capabilities))
	testing.expect(t, slice.equal(got.pipeline_flattened, want.pipeline_flattened))
	testing.expect(t, slice.equal(got.gate_results, want.gate_results))
}

reemit_index_record :: proc(record: Index_Record) -> string {
	switch decoded in record {
	case Decl_Record:
		return emit_decl_record(decoded, context.temp_allocator)
	case Project_Record:
		return emit_project_record(decoded, context.temp_allocator)
	}
	return ""
}

mutate_line :: proc(t: ^testing.T, line: string, anchor: string, replacement: string) -> string {
	mutated, _ := strings.replace(line, anchor, replacement, 1, context.temp_allocator)
	testing.expect(t, mutated != line)
	return mutated
}

inject_top_level_key :: proc(t: ^testing.T, line: string) -> string {
	testing.expect(t, strings.has_suffix(line, "}\n"))
	body := strings.trim_suffix(line, "}\n")
	return strings.concatenate({body, ",\"extra\":1}\n"}, context.temp_allocator)
}

expect_refusal :: proc(t: ^testing.T, line: string, want: Index_Read_Error) {
	record, err := decode_index_line(line, context.temp_allocator)
	testing.expect_value(t, err, want)
	testing.expect(t, record == nil)
}

@(test)
test_index_read_decl_round_trip_every_kind :: proc(t: ^testing.T) {
	for kind in Index_Decl_Kind {
		record := decl_record_fixture(kind)
		line := emit_decl_record(record, context.temp_allocator)
		decoded, err := decode_index_line(line, context.temp_allocator)
		testing.expect_value(t, err, Index_Read_Error.None)
		decl, is_decl := decoded.(Decl_Record)
		testing.expect(t, is_decl)
		if !is_decl {
			return
		}
		expect_decl_fields_equal(t, decl, record)
		testing.expect_value(t, reemit_index_record(decoded), line)
	}
}

@(test)
test_index_read_project_round_trip :: proc(t: ^testing.T) {
	record := minimal_project_record()
	line := emit_project_record(record, context.temp_allocator)
	decoded, err := decode_index_line(line, context.temp_allocator)
	testing.expect_value(t, err, Index_Read_Error.None)
	project, is_project := decoded.(Project_Record)
	testing.expect(t, is_project)
	if !is_project {
		return
	}
	expect_project_fields_equal(t, project, record)
	testing.expect_value(t, reemit_index_record(decoded), line)
}

@(test)
test_index_read_empty_lists_round_trip :: proc(t: ^testing.T) {
	decl := empty_lists_decl_record()
	decl_line := emit_decl_record(decl, context.temp_allocator)
	decoded_decl, decl_err := decode_index_line(decl_line, context.temp_allocator)
	testing.expect_value(t, decl_err, Index_Read_Error.None)
	if got, is_decl := decoded_decl.(Decl_Record); is_decl {
		testing.expect_value(t, len(got.gtags), 0)
		testing.expect_value(t, len(got.mut_data), 0)
	} else {
		testing.expect(t, is_decl)
	}
	testing.expect_value(t, reemit_index_record(decoded_decl), decl_line)

	project := Project_Record {
		schema_version = INDEX_SCHEMA_VERSION,
	}
	project_line := emit_project_record(project, context.temp_allocator)
	decoded_project, project_err := decode_index_line(project_line, context.temp_allocator)
	testing.expect_value(t, project_err, Index_Read_Error.None)
	if got, is_project := decoded_project.(Project_Record); is_project {
		testing.expect_value(t, len(got.entrypoints), 0)
		testing.expect_value(t, len(got.gate_results), 0)
	} else {
		testing.expect(t, is_project)
	}
	testing.expect_value(t, reemit_index_record(decoded_project), project_line)
}

@(test)
test_index_read_drift_stream_round_trip :: proc(t: ^testing.T) {
	dir := resolve_drift_dir()
	if !os.is_dir(dir) {
		log.warnf("SKIP index read drift: %s not found — set FUNPACK_DRIFT_DIR or ensure the in-repo fixture exists", dir)
		return
	}
	stream, err, _, compiled := read_index_project(dir, context.temp_allocator)
	testing.expect_value(t, err, Index_Contract_Error.None)
	testing.expect(t, compiled)
	if !compiled {
		return
	}
	lines := ndjson_lines(stream)
	testing.expect(t, len(lines) > 1)
	for line, i in lines {
		full := strings.concatenate({line, "\n"}, context.temp_allocator)
		record, decode_err := decode_index_line(full, context.temp_allocator)
		testing.expect_value(t, decode_err, Index_Read_Error.None)
		if decode_err != .None {
			return
		}
		if i == 0 {
			_, is_project := record.(Project_Record)
			testing.expect(t, is_project)
		} else {
			_, is_decl := record.(Decl_Record)
			testing.expect(t, is_decl)
		}
		testing.expect_value(t, reemit_index_record(record), full)
	}
}

@(test)
test_index_read_schema_mismatch_refused :: proc(t: ^testing.T) {
	decl_line := emit_decl_record(decl_record_fixture(.Fn), context.temp_allocator)
	expect_refusal(t, mutate_line(t, decl_line, "\"schema_version\":6", "\"schema_version\":1"), .Schema_Mismatch)
	project_line := emit_project_record(minimal_project_record(), context.temp_allocator)
	expect_refusal(t, mutate_line(t, project_line, "\"schema_version\":6", "\"schema_version\":999"), .Schema_Mismatch)
	expect_refusal(t, mutate_line(t, decl_line, "\"schema_version\":6,", ""), .Missing_Field)
}

@(test)
test_index_read_missing_key_refused :: proc(t: ^testing.T) {
	decl_line := emit_decl_record(decl_record_fixture(.Fn), context.temp_allocator)
	expect_refusal(t, mutate_line(t, decl_line, "\"todo\":false,", ""), .Missing_Field)
	expect_refusal(
		t,
		"{\"schema_version\":6,\"entrypoints\":[],\"builds\":[],\"tag_registry\":[],\"pipeline_flattened\":[],\"gate_results\":[]}\n",
		.Missing_Field,
	)
	expect_refusal(
		t,
		"{\"schema_version\":6,\"entrypoints\":[],\"builds\":[],\"tag_registry\":[],\"capabilities\":[],\"pipeline_flattened\":[],\"gate_results\":[{\"gate\":\"Cyclomatic\"}]}\n",
		.Missing_Field,
	)
}

@(test)
test_index_read_unknown_key_refused :: proc(t: ^testing.T) {
	decl_line := emit_decl_record(decl_record_fixture(.Fn), context.temp_allocator)
	expect_refusal(t, inject_top_level_key(t, decl_line), .Unknown_Field)
	project_line := emit_project_record(minimal_project_record(), context.temp_allocator)
	expect_refusal(t, inject_top_level_key(t, project_line), .Unknown_Field)
	expect_refusal(
		t,
		mutate_line(t, project_line, "\"bindings\":\"binds\"", "\"bindings\":\"binds\",\"extra\":1"),
		.Unknown_Field,
	)
}

@(test)
test_index_read_unknown_record_shape_refused :: proc(t: ^testing.T) {
	expect_refusal(t, "{\"schema_version\":6}\n", .Unknown_Record_Shape)
	expect_refusal(t, "{\"schema_version\":6,\"name\":\"native\",\"platform\":\"desktop\"}\n", .Unknown_Record_Shape)
	expect_refusal(t, "{\"schema_version\":6,\"qualified_name\":\"Board\",\"gate_results\":[]}\n", .Unknown_Record_Shape)
}

@(test)
test_index_read_unknown_enum_value_refused :: proc(t: ^testing.T) {
	decl_line := emit_decl_record(decl_record_fixture(.Fn), context.temp_allocator)
	expect_refusal(t, mutate_line(t, decl_line, "\"kind\":\"Fn\"", "\"kind\":\"Wizard\""), .Unknown_Enum_Value)
	project_line := emit_project_record(minimal_project_record(), context.temp_allocator)
	expect_refusal(t, mutate_line(t, project_line, "\"Render\"", "\"Teleport\""), .Unknown_Enum_Value)
	expect_refusal(t, mutate_line(t, project_line, "\"Cyclomatic\"", "\"Vibes\""), .Unknown_Enum_Value)
}

@(test)
test_index_read_wrong_field_type_refused :: proc(t: ^testing.T) {
	decl_line := emit_decl_record(decl_record_fixture(.Fn), context.temp_allocator)
	expect_refusal(t, mutate_line(t, decl_line, "\"span\":7", "\"span\":\"seven\""), .Wrong_Field_Type)
	expect_refusal(t, mutate_line(t, decl_line, "\"stub\":true", "\"stub\":1"), .Wrong_Field_Type)
	expect_refusal(t, mutate_line(t, decl_line, "\"gtags\":[\"game\",\"render\"]", "\"gtags\":[1]"), .Wrong_Field_Type)
}

warden_stream_fixture :: proc(t: ^testing.T) -> (root: string, stream: string, record: Project_Record, decls: []Decl_Record, ok: bool) {
	source := `data Board { w: Int, h: Int }
signal Goal { side: Int }
fn add(a: Int, b: Int) -> Int {
  return a + b
}
`
	typed, flat, compiled := compile_for_index(source)
	testing.expect(t, compiled)
	if !compiled {
		return "", "", Project_Record{}, nil, false
	}
	root = scratch_join({scratch_base(), tprintf_seq("funpack-warden")})
	remove_scratch_tree(root)
	if !ensure_dir(scratch_join({root, "funpack_configs"})) {
		testing.expect(t, false)
		return "", "", Project_Record{}, nil, false
	}
	built, record_err := build_project_record(root, typed, flat)
	testing.expect_value(t, record_err, Index_Contract_Error.None)
	if record_err != .None {
		remove_scratch_tree(root)
		return "", "", Project_Record{}, nil, false
	}
	modules := make([]Index_Module, 1, context.temp_allocator)
	modules[0] = Index_Module {
		module = "",
		typed  = typed,
		flat   = flat,
	}
	return root, emit_index_stream(built, modules, context.temp_allocator), built, derive_decl_records("", typed, flat), true
}

write_warden_index_product :: proc(t: ^testing.T, root: string, stream: string) -> bool {
	dir := scratch_join({root, FUNPACK_BUILD_DIR})
	ok := ensure_dir(dir) && os.write_entire_file(scratch_join({dir, INDEX_PRODUCT_NAME}), transmute([]u8)stream) == nil
	testing.expect(t, ok)
	return ok
}

expect_warden_refusal :: proc(t: ^testing.T, root: string, stream: string, want: Warden_Refusal) {
	if !write_warden_index_product(t, root, stream) {
		return
	}
	_, refusal := read_warden_index(root, context.temp_allocator)
	testing.expect_value(t, refusal.err, want.err)
	testing.expect_value(t, refusal.line, want.line)
	testing.expect_value(t, refusal.decode, want.decode)
	testing.expect(t, strings.contains(warden_refusal_message(refusal, context.temp_allocator), "`funpack build`"))
}

@(test)
test_warden_index_round_trip :: proc(t: ^testing.T) {
	root, stream, record, decls, ok := warden_stream_fixture(t)
	if !ok {
		return
	}
	defer remove_scratch_tree(root)
	if !write_warden_index_product(t, root, stream) {
		return
	}
	index, refusal := read_warden_index(root, context.temp_allocator)
	testing.expect_value(t, refusal.err, Warden_Read_Error.None)
	if refusal.err != .None {
		return
	}
	testing.expect_value(t, warden_refusal_message(refusal, context.temp_allocator), "")
	expect_project_fields_equal(t, index.project, record)
	testing.expect_value(t, len(index.decls), len(decls))
	if len(index.decls) != len(decls) {
		return
	}
	for decl, i in index.decls {
		expect_decl_fields_equal(t, decl, decls[i])
	}
}

@(test)
test_warden_index_missing_index_refused :: proc(t: ^testing.T) {
	root, _, _, _, ok := warden_stream_fixture(t)
	if !ok {
		return
	}
	defer remove_scratch_tree(root)
	index, refusal := read_warden_index(root, context.temp_allocator)
	testing.expect_value(t, refusal.err, Warden_Read_Error.Missing_Index)
	testing.expect_value(t, refusal.line, 0)
	testing.expect_value(t, len(index.decls), 0)
	message := warden_refusal_message(refusal, context.temp_allocator)
	testing.expect(t, strings.contains(message, "`funpack build`"))
	testing.expect(t, strings.contains(message, INDEX_PRODUCT_NAME))
}

@(test)
test_warden_index_schema_mismatch_refused :: proc(t: ^testing.T) {
	root, stream, _, _, ok := warden_stream_fixture(t)
	if !ok {
		return
	}
	defer remove_scratch_tree(root)
	doctored := mutate_line(t, stream, "\"schema_version\":6", "\"schema_version\":1")
	expect_warden_refusal(t, root, doctored, Warden_Refusal{err = .Schema_Mismatch, line = 1, decode = .Schema_Mismatch})
	if !write_warden_index_product(t, root, doctored) {
		return
	}
	_, refusal := read_warden_index(root, context.temp_allocator)
	testing.expect(t, strings.contains(warden_refusal_message(refusal, context.temp_allocator), "rebuild the index with this funpack"))
}

@(test)
test_warden_index_missing_project_record_refused :: proc(t: ^testing.T) {
	root, stream, _, _, ok := warden_stream_fixture(t)
	if !ok {
		return
	}
	defer remove_scratch_tree(root)
	first_lf := strings.index_byte(stream, '\n')
	testing.expect(t, first_lf >= 0)
	expect_warden_refusal(t, root, stream[first_lf + 1:], Warden_Refusal{err = .Missing_Project_Record, line = 1})
}

@(test)
test_warden_index_duplicate_project_record_refused :: proc(t: ^testing.T) {
	root, stream, _, _, ok := warden_stream_fixture(t)
	if !ok {
		return
	}
	defer remove_scratch_tree(root)
	first_lf := strings.index_byte(stream, '\n')
	testing.expect(t, first_lf >= 0)
	doctored := strings.concatenate({stream, stream[:first_lf + 1]}, context.temp_allocator)
	dup_line := len(ndjson_lines(stream)) + 1
	expect_warden_refusal(t, root, doctored, Warden_Refusal{err = .Duplicate_Project_Record, line = dup_line})
}

@(test)
test_warden_index_first_error_refusal_never_skips :: proc(t: ^testing.T) {
	root, stream, _, _, ok := warden_stream_fixture(t)
	if !ok {
		return
	}
	defer remove_scratch_tree(root)
	lines := ndjson_lines(stream)
	testing.expect(t, len(lines) >= 3)
	if len(lines) < 3 {
		return
	}
	doctored := make([dynamic]string, 0, len(lines), context.temp_allocator)
	for line, i in lines {
		full := strings.concatenate({line, "\n"}, context.temp_allocator)
		switch i {
		case 1:
			full = inject_top_level_key(t, full)
		case 2:
			full = mutate_line(t, full, "\"todo\":false,", "")
		}
		append(&doctored, full)
	}
	joined := strings.concatenate(doctored[:], context.temp_allocator)
	expect_warden_refusal(t, root, joined, Warden_Refusal{err = .Record_Refused, line = 2, decode = .Unknown_Field})
}

@(test)
test_warden_index_empty_index_refused :: proc(t: ^testing.T) {
	root, _, _, _, ok := warden_stream_fixture(t)
	if !ok {
		return
	}
	defer remove_scratch_tree(root)
	expect_warden_refusal(t, root, "", Warden_Refusal{err = .Empty_Index})
	expect_warden_refusal(t, root, "\n\n", Warden_Refusal{err = .Empty_Index})
}

@(test)
test_index_read_malformed_line_refused :: proc(t: ^testing.T) {
	expect_refusal(t, "{not json}\n", .Malformed_Json)
	expect_refusal(t, "", .Malformed_Json)
	expect_refusal(t, "[1,2]\n", .Malformed_Json)
	expect_refusal(t, "42\n", .Malformed_Json)
	expect_refusal(t, "{\"schema_version\":6}{\"schema_version\":6}\n", .Malformed_Json)
}
