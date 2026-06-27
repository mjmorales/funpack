package funpack

import "core:log"
import "core:os"
import "core:strings"
import "core:testing"

warden_match_all :: proc(decl: Decl_Record, needle: string) -> bool {
	_ = decl
	_ = needle
	return true
}

warden_match_none :: proc(decl: Decl_Record, needle: string) -> bool {
	_ = decl
	_ = needle
	return false
}

warden_project_fixture :: proc() -> []Decl_Record {
	stubbed := decl_record_fixture(.Fn)
	stubbed.qualified_name = "drift.launch_speed"

	indebted := decl_record_fixture(.Data)
	indebted.qualified_name = "drift.board"
	indebted.stub = false
	debt_tags := make([]string, 2, context.temp_allocator)
	debt_tags[0], debt_tags[1] = "game", WARDEN_DEBT_GTAG
	indebted.gtags = debt_tags

	clean := decl_record_fixture(.Behavior)
	clean.qualified_name = "drift.steer"
	clean.stub = false

	decls := make([]Decl_Record, 3, context.temp_allocator)
	decls[0], decls[1], decls[2] = stubbed, indebted, clean
	return decls
}

@(test)
test_warden_project_decls_byte_identity_and_order :: proc(t: ^testing.T) {
	decls := warden_project_fixture()
	want := strings.concatenate(
		{
			emit_decl_record(decls[0], context.temp_allocator),
			emit_decl_record(decls[1], context.temp_allocator),
			emit_decl_record(decls[2], context.temp_allocator),
		},
		context.temp_allocator,
	)
	got := warden_project_decls(decls, warden_match_all, "", context.temp_allocator)
	testing.expect_value(t, got, want)

	again := warden_project_decls(decls, warden_match_all, "", context.temp_allocator)
	testing.expect_value(t, again, got)
}

@(test)
test_warden_project_decls_filter_preserves_stream_order :: proc(t: ^testing.T) {
	decls := warden_project_fixture()
	either := proc(decl: Decl_Record, needle: string) -> bool {
		return warden_holes_predicate(decl, needle) || warden_debt_predicate(decl, needle)
	}
	want := strings.concatenate(
		{
			emit_decl_record(decls[0], context.temp_allocator),
			emit_decl_record(decls[1], context.temp_allocator),
		},
		context.temp_allocator,
	)
	got := warden_project_decls(decls, either, "", context.temp_allocator)
	testing.expect_value(t, got, want)
}

@(test)
test_warden_project_decls_empty_result_is_empty_output :: proc(t: ^testing.T) {
	decls := warden_project_fixture()
	testing.expect_value(t, warden_project_decls(decls, warden_match_none, "", context.temp_allocator), "")
	testing.expect_value(t, warden_project_decls(nil, warden_match_all, "", context.temp_allocator), "")
}

@(test)
test_warden_holes_predicate_is_stub :: proc(t: ^testing.T) {
	decls := warden_project_fixture()
	testing.expect(t, warden_holes_predicate(decls[0], ""))
	testing.expect(t, !warden_holes_predicate(decls[1], ""))
	testing.expect(t, !warden_holes_predicate(decls[2], ""))
}

@(test)
test_warden_probes_predicate_is_debug_presence :: proc(t: ^testing.T) {
	probed := decl_record_fixture(.Fn)
	probed.stub = false
	testing.expect(t, warden_probes_predicate(probed, ""))

	multi := decl_record_fixture(.Behavior)
	multi.stub = false
	two := make([]string, 2, context.temp_allocator)
	two[0], two[1] = "break", "log"
	multi.debug = two
	testing.expect(t, warden_probes_predicate(multi, ""))

	unprobed := decl_record_fixture(.Data)
	unprobed.stub = true
	unprobed.todo = true
	unprobed.debug = nil
	testing.expect(t, !warden_probes_predicate(unprobed, ""))

	empty_present := decl_record_fixture(.Fn)
	empty_present.debug = make([]string, 0, context.temp_allocator)
	testing.expect(t, !warden_probes_predicate(empty_present, ""))
}

@(test)
test_warden_debt_predicate_todo_or_debt_gtag :: proc(t: ^testing.T) {
	decls := warden_project_fixture()
	testing.expect(t, warden_debt_predicate(decls[1], ""))
	testing.expect(t, !warden_debt_predicate(decls[0], ""))
	testing.expect(t, !warden_debt_predicate(decls[2], ""))

	todo_only := decl_record_fixture(.Fn)
	todo_only.stub = false
	todo_only.todo = true
	testing.expect(t, warden_debt_predicate(todo_only, ""))

	both := decl_record_fixture(.Fn)
	both.todo = true
	both.gtags = decls[1].gtags
	testing.expect(t, warden_debt_predicate(both, ""))
}

@(test)
test_warden_verb_exit_empty_projection_zero :: proc(t: ^testing.T) {
	root, stream, _, _, ok := warden_stream_fixture(t)
	if !ok {
		return
	}
	defer remove_scratch_tree(root)
	if !write_warden_index_product(t, root, stream) {
		return
	}
	testing.expect_value(t, warden_verb_exit(root, .Holes), 0)
	testing.expect_value(t, warden_verb_exit(root, .Probes), 0)
	testing.expect_value(t, warden_verb_exit(root, .Debt), 0)
	log.infof("warden projection: an empty holes/probes/debt result exits 0 — empty output is success")
}

@(test)
test_warden_holes_drift_live :: proc(t: ^testing.T) {
	dir := resolve_drift_dir()
	if !os.is_dir(dir) {
		log.warnf("SKIP warden holes drift: %s not found — set FUNPACK_DRIFT_DIR or ensure the in-repo fixture exists", dir)
		return
	}
	stream, err, _, compiled := read_index_project(dir, context.temp_allocator)
	testing.expect_value(t, err, Index_Contract_Error.None)
	testing.expect(t, compiled)
	if !compiled {
		return
	}
	index, refusal := decode_warden_index(stream, context.temp_allocator)
	testing.expect_value(t, refusal.err, Warden_Read_Error.None)
	if refusal.err != .None {
		return
	}

	holes := warden_project_decls(index.decls, warden_holes_predicate, "", context.temp_allocator)
	hole_lines := ndjson_lines(holes)
	testing.expect_value(t, len(hole_lines), 2)
	testing.expect(t, strings.contains(holes, "drag"))
	testing.expect(t, strings.contains(holes, "launch_speed"))
	for line in hole_lines {
		full := strings.concatenate({line, "\n"}, context.temp_allocator)
		testing.expect(t, strings.contains(stream, full))
	}

	testing.expect_value(t, warden_project_decls(index.decls, warden_debt_predicate, "", context.temp_allocator), "")
	log.infof("warden projection: drift's two typed holes project byte-identically from the live stream")
}
