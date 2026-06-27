package funpack

import "core:log"
import "core:os"
import "core:strings"
import "core:testing"

@(test)
test_warden_find_name_predicate_substring_case_sensitive :: proc(t: ^testing.T) {
	decl := decl_record_fixture(.Fn)
	testing.expect(t, warden_find_name_predicate(decl, "launch"))
	testing.expect(t, warden_find_name_predicate(decl, "drift.launch_speed"))
	testing.expect(t, warden_find_name_predicate(decl, "t.l"))
	testing.expect(t, !warden_find_name_predicate(decl, "Launch"))
	testing.expect(t, !warden_find_name_predicate(decl, "steer"))
}

@(test)
test_warden_find_kind_predicate_exact_member_name :: proc(t: ^testing.T) {
	fn := decl_record_fixture(.Fn)
	extern := decl_record_fixture(.Extern_Fn)
	testing.expect(t, warden_find_kind_predicate(fn, "Fn"))
	testing.expect(t, warden_find_kind_predicate(extern, "Extern_Fn"))
	testing.expect(t, !warden_find_kind_predicate(extern, "Fn"))
	testing.expect(t, !warden_find_kind_predicate(fn, "fn"))
	testing.expect(t, !warden_find_kind_predicate(fn, "Widget"))
}

@(test)
test_warden_find_gtag_predicate_exact_membership :: proc(t: ^testing.T) {
	decl := decl_record_fixture(.Fn)
	testing.expect(t, warden_find_gtag_predicate(decl, "game"))
	testing.expect(t, warden_find_gtag_predicate(decl, "render"))
	testing.expect(t, !warden_find_gtag_predicate(decl, "rend"))
	testing.expect(t, !warden_find_gtag_predicate(decl, "debt"))
	testing.expect(t, !warden_find_gtag_predicate(empty_lists_decl_record(), "game"))
}

@(test)
test_warden_find_filters_one_per_provided_argument :: proc(t: ^testing.T) {
	testing.expect_value(t, len(warden_find_filters({name = "damped"}, context.temp_allocator)), 1)
	testing.expect_value(t, len(warden_find_filters({kind = "Fn", gtag = "debt"}, context.temp_allocator)), 2)
	full := warden_find_filters({name = "damped", kind = "Fn", gtag = "debt"}, context.temp_allocator)
	testing.expect_value(t, len(full), 3)
	testing.expect_value(t, full[0].needle, "damped")
	testing.expect_value(t, full[1].needle, "Fn")
	testing.expect_value(t, full[2].needle, "debt")
}

@(test)
test_warden_find_filters_and_compose_in_stream_order :: proc(t: ^testing.T) {
	decls := warden_project_fixture()
	index := Warden_Index {
		decls = decls,
	}

	all := warden_find_output(index, {name = "drift."}, context.temp_allocator)
	want_all := strings.concatenate(
		{
			emit_decl_record(decls[0], context.temp_allocator),
			emit_decl_record(decls[1], context.temp_allocator),
			emit_decl_record(decls[2], context.temp_allocator),
		},
		context.temp_allocator,
	)
	testing.expect_value(t, all, want_all)

	narrowed := warden_find_output(index, {name = "drift.", kind = "Fn"}, context.temp_allocator)
	testing.expect_value(t, narrowed, emit_decl_record(decls[0], context.temp_allocator))

	tagged := warden_find_output(index, {name = "drift.", gtag = WARDEN_DEBT_GTAG}, context.temp_allocator)
	testing.expect_value(t, tagged, emit_decl_record(decls[1], context.temp_allocator))

	testing.expect_value(t, warden_find_output(index, {name = "drift.", kind = "Fn", gtag = WARDEN_DEBT_GTAG}, context.temp_allocator), "")

	testing.expect_value(t, warden_find_output(index, {name = "drift.", kind = "Fn"}, context.temp_allocator), narrowed)
}

@(test)
test_warden_verb_exit_find_zero_matches_zero :: proc(t: ^testing.T) {
	root, stream, _, _, ok := warden_stream_fixture(t)
	if !ok {
		return
	}
	defer remove_scratch_tree(root)
	if !write_warden_index_product(t, root, stream) {
		return
	}
	testing.expect_value(t, warden_verb_exit(root, .Find, "", {name = "add"}), 0)
	testing.expect_value(t, warden_verb_exit(root, .Find, "", {name = "no_such_decl"}), 0)
	testing.expect_value(t, warden_verb_exit(root, .Find, "", {kind = "Signal", gtag = "debt"}), 0)
	log.infof("warden find: a zero-match lookup exits 0 — nothing to reuse is a clean answer")
}

@(test)
test_warden_find_drift_live :: proc(t: ^testing.T) {
	dir := resolve_drift_dir()
	if !os.is_dir(dir) {
		log.warnf("SKIP warden find drift: %s not found — set FUNPACK_DRIFT_DIR or ensure the in-repo fixture exists", dir)
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

	found := warden_find_output(index, {name = "damped"}, context.temp_allocator)
	lines := ndjson_lines(found)
	testing.expect_value(t, len(lines), 1)
	testing.expect(t, strings.contains(found, "damped"))
	testing.expect(t, strings.contains(stream, found))

	testing.expect_value(t, warden_find_output(index, {name = "damped", kind = "Fn"}, context.temp_allocator), found)
	testing.expect_value(t, warden_find_output(index, {name = "damped", kind = "Data"}, context.temp_allocator), "")
	log.infof("warden find: drift's damped decl projects byte-identically from the live stream")
}
