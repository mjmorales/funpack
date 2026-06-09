// Index Contract CONSUMER tests (spec §29 §2): every record kind round-trips
// through the producer's own emitters (emit → decode → field equality →
// re-emit byte-identity, including the live drift-tree stream), and every
// exact-match refusal cause has a failing-path case — schema_version
// mismatch, under-shaped (missing key) and over-shaped (unknown key) records
// at the top level AND inside nested records, unknown enum names, a line
// carrying neither (or both) structural marker sets, wrong value types, and
// unparseable lines. The negative lines are built by surgery on emitted
// bytes wherever possible, with the surgery asserted to have hit — a
// formatter drift turns the test loud, never vacuous. The drift fixture
// SKIP-warns when the sibling checkout is absent, mirroring the golden skip
// semantics.
package funpack

import "core:log"
import "core:os"
import "core:slice"
import "core:strings"
import "core:testing"

// ── Round-trip fixtures and equality helpers ───────────────────────────

// decl_record_fixture builds a fully-populated decl record for a given kind:
// every list non-empty, a doc with an escaped quote, and a dup_class above
// max(i64) so the u64 decode path is pinned (a producer hash uses the full
// unsigned domain). Slices are temp-allocated so the record outlives the
// constructor's frame.
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
		emits          = emits,
		consumes       = consumes,
		calls          = calls,
		dup_class      = 0xfffe_cbf2_9ce4_8422, // above max(i64): pins the unsigned decode
		mut_data       = mut_data,
	}
}

// empty_lists_decl_record builds a decl record whose every list field is an
// empty-but-present [] — the §29 §2 absence-is-empty-list shape.
empty_lists_decl_record :: proc() -> Decl_Record {
	return Decl_Record {
		schema_version = INDEX_SCHEMA_VERSION,
		qualified_name = "Board",
		kind           = .Data,
		span           = 1,
	}
}

// expect_decl_fields_equal asserts field-by-field equality of a decoded decl
// record against the record the producer emitted.
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
	testing.expect(t, slice.equal(got.emits, want.emits))
	testing.expect(t, slice.equal(got.consumes, want.consumes))
	testing.expect(t, slice.equal(got.calls, want.calls))
	testing.expect_value(t, got.dup_class, want.dup_class)
	testing.expect(t, slice.equal(got.mut_data, want.mut_data))
}

// expect_project_fields_equal asserts field-by-field equality of a decoded
// project record, nested slices compared element-wise.
expect_project_fields_equal :: proc(t: ^testing.T, got: Project_Record, want: Project_Record) {
	testing.expect_value(t, got.schema_version, want.schema_version)
	testing.expect(t, slice.equal(got.entrypoints, want.entrypoints))
	testing.expect(t, slice.equal(got.builds, want.builds))
	testing.expect(t, slice.equal(got.tag_registry, want.tag_registry))
	testing.expect(t, slice.equal(got.capabilities, want.capabilities))
	testing.expect(t, slice.equal(got.pipeline_flattened, want.pipeline_flattened))
	testing.expect(t, slice.equal(got.gate_results, want.gate_results))
}

// reemit_index_record re-emits a decoded record through the producer's own
// emitter — the byte-identity half of every round-trip assertion.
reemit_index_record :: proc(record: Index_Record) -> string {
	switch decoded in record {
	case Decl_Record:
		return emit_decl_record(decoded, context.temp_allocator)
	case Project_Record:
		return emit_project_record(decoded, context.temp_allocator)
	}
	return ""
}

// mutate_line rewrites one emitted substring — the negative-case surgery. The
// surgery must hit: an anchor the emitter no longer produces would make the
// negative vacuous, so a miss fails the test instead of silently passing.
mutate_line :: proc(t: ^testing.T, line: string, anchor: string, replacement: string) -> string {
	mutated, _ := strings.replace(line, anchor, replacement, 1, context.temp_allocator)
	testing.expect(t, mutated != line)
	return mutated
}

// inject_top_level_key appends an extra key to an emitted line's top-level
// object — the over-shaped surgery (the line's last byte pair is always the
// top-level `}` + LF).
inject_top_level_key :: proc(t: ^testing.T, line: string) -> string {
	testing.expect(t, strings.has_suffix(line, "}\n"))
	body := strings.trim_suffix(line, "}\n")
	return strings.concatenate({body, ",\"extra\":1}\n"}, context.temp_allocator)
}

// expect_refusal asserts a line decodes to exactly the expected refusal arm
// and carries no record.
expect_refusal :: proc(t: ^testing.T, line: string, want: Index_Read_Error) {
	record, err := decode_index_line(line, context.temp_allocator)
	testing.expect_value(t, err, want)
	testing.expect(t, record == nil)
}

// ── Round-trips through the producer's own emitters ────────────────────

@(test)
test_index_read_decl_round_trip_every_kind :: proc(t: ^testing.T) {
	// emit → decode → field equality → re-emit byte-identity, once per
	// Index_Decl_Kind value — the closed kind set round-trips whole.
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
	// The populated project shape: nested Entrypoint_Record / Build_Record /
	// Flat_Step_Record / Gate_Result slices all survive the round-trip.
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
	// Empty-but-present lists (§29 §2: absence is an empty list, never an
	// omitted key) decode to zero-length fields and re-emit byte-identically.
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
	// The live drift tree's whole emitted stream, per line: line 0 decodes to
	// the project record, every following line to a decl record, and each
	// re-emits byte-identically — decoding the producer's real output is
	// lossless, not just the hand-built fixtures.
	dir := resolve_drift_dir()
	if !os.is_dir(dir) {
		log.warnf("SKIP index read drift: %s not found — set FUNPACK_DRIFT_DIR or check out funpack-spec as a sibling", dir)
		return
	}
	stream, err, compiled := read_index_project(dir, context.temp_allocator)
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

// ── Exact-match refusals (§29 §2) ──────────────────────────────────────

@(test)
test_index_read_schema_mismatch_refused :: proc(t: ^testing.T) {
	// A non-current schema_version is Schema_Mismatch on BOTH record kinds —
	// below and above the current stamp alike, never best-effort parsed.
	decl_line := emit_decl_record(decl_record_fixture(.Fn), context.temp_allocator)
	expect_refusal(t, mutate_line(t, decl_line, "\"schema_version\":2", "\"schema_version\":1"), .Schema_Mismatch)
	project_line := emit_project_record(minimal_project_record(), context.temp_allocator)
	expect_refusal(t, mutate_line(t, project_line, "\"schema_version\":2", "\"schema_version\":999"), .Schema_Mismatch)
	// A line with no stamp at all is under-shaped before it is mismatched.
	expect_refusal(t, mutate_line(t, decl_line, "\"schema_version\":2,", ""), .Missing_Field)
}

@(test)
test_index_read_missing_key_refused :: proc(t: ^testing.T) {
	// Under-shaped records: a dropped mandatory key is Missing_Field at the
	// top level of either kind AND inside a nested record — all fields are
	// mandatory at every level, there are no optional fields.
	decl_line := emit_decl_record(decl_record_fixture(.Fn), context.temp_allocator)
	expect_refusal(t, mutate_line(t, decl_line, "\"todo\":false,", ""), .Missing_Field)
	// A project record missing its capabilities field.
	expect_refusal(
		t,
		"{\"schema_version\":2,\"entrypoints\":[],\"builds\":[],\"tag_registry\":[],\"pipeline_flattened\":[],\"gate_results\":[]}\n",
		.Missing_Field,
	)
	// A nested gate result missing its passed field.
	expect_refusal(
		t,
		"{\"schema_version\":2,\"entrypoints\":[],\"builds\":[],\"tag_registry\":[],\"capabilities\":[],\"pipeline_flattened\":[],\"gate_results\":[{\"gate\":\"Cyclomatic\"}]}\n",
		.Missing_Field,
	)
}

@(test)
test_index_read_unknown_key_refused :: proc(t: ^testing.T) {
	// Over-shaped records: an injected extra key is Unknown_Field at the top
	// level of either kind AND inside a nested record — the field sets are
	// closed both ways.
	decl_line := emit_decl_record(decl_record_fixture(.Fn), context.temp_allocator)
	expect_refusal(t, inject_top_level_key(t, decl_line), .Unknown_Field)
	project_line := emit_project_record(minimal_project_record(), context.temp_allocator)
	expect_refusal(t, inject_top_level_key(t, project_line), .Unknown_Field)
	// A nested entrypoint carrying a key outside its closed shape.
	expect_refusal(
		t,
		mutate_line(t, project_line, "\"bindings\":\"binds\"", "\"bindings\":\"binds\",\"extra\":1"),
		.Unknown_Field,
	)
}

@(test)
test_index_read_unknown_record_shape_refused :: proc(t: ^testing.T) {
	// Structural discrimination (§29 §2): a line carrying NEITHER disjoint
	// marker set has no kind to decode as, and a chimera carrying BOTH is
	// ambiguous — each is Unknown_Record_Shape, never a guessed kind.
	expect_refusal(t, "{\"schema_version\":2}\n", .Unknown_Record_Shape)
	expect_refusal(t, "{\"schema_version\":2,\"name\":\"native\",\"platform\":\"desktop\"}\n", .Unknown_Record_Shape)
	expect_refusal(t, "{\"schema_version\":2,\"qualified_name\":\"Board\",\"gate_results\":[]}\n", .Unknown_Record_Shape)
}

@(test)
test_index_read_unknown_enum_value_refused :: proc(t: ^testing.T) {
	// A name outside a closed enum — the decl kind, a capability, a gate
	// family — is Unknown_Enum_Value, never a defaulted member.
	decl_line := emit_decl_record(decl_record_fixture(.Fn), context.temp_allocator)
	expect_refusal(t, mutate_line(t, decl_line, "\"kind\":\"Fn\"", "\"kind\":\"Wizard\""), .Unknown_Enum_Value)
	project_line := emit_project_record(minimal_project_record(), context.temp_allocator)
	expect_refusal(t, mutate_line(t, project_line, "\"Render\"", "\"Teleport\""), .Unknown_Enum_Value)
	expect_refusal(t, mutate_line(t, project_line, "\"Cyclomatic\"", "\"Vibes\""), .Unknown_Enum_Value)
}

@(test)
test_index_read_wrong_field_type_refused :: proc(t: ^testing.T) {
	// A mandatory key carrying the wrong JSON value type is Wrong_Field_Type:
	// a string where an integer belongs, a number where a boolean belongs, a
	// number where a string-list element belongs.
	decl_line := emit_decl_record(decl_record_fixture(.Fn), context.temp_allocator)
	expect_refusal(t, mutate_line(t, decl_line, "\"span\":7", "\"span\":\"seven\""), .Wrong_Field_Type)
	expect_refusal(t, mutate_line(t, decl_line, "\"stub\":true", "\"stub\":1"), .Wrong_Field_Type)
	expect_refusal(t, mutate_line(t, decl_line, "\"gtags\":[\"game\",\"render\"]", "\"gtags\":[1]"), .Wrong_Field_Type)
}

@(test)
test_index_read_malformed_line_refused :: proc(t: ^testing.T) {
	// Not one parseable JSON object: broken syntax, an empty line, a
	// non-object top level, and trailing bytes after the object (the NDJSON
	// transport is ONE object per line — a second object on the line is
	// malformed, not a second record).
	expect_refusal(t, "{not json}\n", .Malformed_Json)
	expect_refusal(t, "", .Malformed_Json)
	expect_refusal(t, "[1,2]\n", .Malformed_Json)
	expect_refusal(t, "42\n", .Malformed_Json)
	expect_refusal(t, "{\"schema_version\":2}{\"schema_version\":2}\n", .Malformed_Json)
}
