package funpack

import "core:fmt"
import "core:log"
import "core:os"
import "core:strings"
import "core:testing"

build_warden_index_root :: proc(t: ^testing.T, src: string, label: string, env_name: string) -> (root: string, stream: string, ok: bool) {
	copied: bool
	root, copied = copy_spec_tree_to_temp(src, label, env_name)
	if !copied {
		return "", "", false
	}
	product, verdict := stage_build(root, .Dev, context.temp_allocator)
	testing.expect_value(t, verdict.err, Build_Error.None)
	if verdict.err != .None {
		remove_scratch_tree(root)
		return "", "", false
	}
	write_err := write_build_products(product, root)
	testing.expect_value(t, write_err, Build_Write_Error.None)
	if write_err != .None {
		remove_scratch_tree(root)
		return "", "", false
	}
	index_bytes, read_err := os.read_entire_file_from_path(product.index_path, context.temp_allocator)
	testing.expect(t, read_err == nil)
	if read_err != nil {
		remove_scratch_tree(root)
		return "", "", false
	}
	return root, string(index_bytes), true
}

build_drift_index_root :: proc(t: ^testing.T) -> (root: string, stream: string, ok: bool) {
	return build_warden_index_root(t, resolve_drift_dir(), "drift-warden", "FUNPACK_DRIFT_DIR")
}

build_pong_index_root :: proc(t: ^testing.T) -> (root: string, stream: string, ok: bool) {
	return build_warden_index_root(t, resolve_pong_dir(), "pong-warden", "FUNPACK_PONG_DIR")
}

expect_every_command_byte_determinism :: proc(t: ^testing.T, root: string, find_query: Warden_Find_Query) {
	index_a, refusal_a := read_warden_index(root, context.temp_allocator)
	testing.expect_value(t, refusal_a.err, Warden_Read_Error.None)
	index_b, refusal_b := read_warden_index(root, context.temp_allocator)
	testing.expect_value(t, refusal_b.err, Warden_Read_Error.None)
	if refusal_a.err != .None || refusal_b.err != .None {
		return
	}
	for cmd in Warden_Command {
		first := warden_command_output(index_a, cmd, "", find_query, context.temp_allocator)
		second := warden_command_output(index_b, cmd, "", find_query, context.temp_allocator)
		testing.expect_value(t, second, first)
		testing.expect_value(t, warden_verb_exit(root, cmd, "", find_query), 0)
	}
}

find_warden_decl :: proc(index: Warden_Index, qualified_name: string) -> (decl: Decl_Record, found: bool) {
	for candidate in index.decls {
		if candidate.qualified_name == qualified_name {
			return candidate, true
		}
	}
	return Decl_Record{}, false
}

@(test)
test_golden_warden_round_trip_typed_decode :: proc(t: ^testing.T) {
	root, stream, ok := build_drift_index_root(t)
	if !ok {
		return
	}
	defer remove_scratch_tree(root)

	index, refusal := read_warden_index(root, context.temp_allocator)
	testing.expect_value(t, refusal.err, Warden_Read_Error.None)
	if refusal.err != .None {
		return
	}
	testing.expect_value(t, index.project.schema_version, INDEX_SCHEMA_VERSION)
	testing.expect_value(t, len(index.decls), len(ndjson_lines(stream)) - 1)

	drag, drag_found := find_warden_decl(index, "drag")
	testing.expect(t, drag_found)
	if drag_found {
		testing.expect(t, drag.stub)
	}
	damped, damped_found := find_warden_decl(index, "damped")
	testing.expect(t, damped_found)
	if damped_found {
		testing.expect(t, !damped.stub)
	}

	for cmd in Warden_Command {
		testing.expect_value(t, warden_verb_exit(root, cmd), 0)
	}
	log.infof("golden warden round-trip: the written drift index decodes whole through the consumer and every command exits 0")
}

@(test)
test_golden_warden_drift_every_command_byte_determinism :: proc(t: ^testing.T) {
	root, _, ok := build_drift_index_root(t)
	if !ok {
		return
	}
	defer remove_scratch_tree(root)

	expect_every_command_byte_determinism(t, root, Warden_Find_Query{name = "damped"})

	index, refusal := read_warden_index(root, context.temp_allocator)
	testing.expect_value(t, refusal.err, Warden_Read_Error.None)
	if refusal.err != .None {
		return
	}
	testing.expect_value(t, len(ndjson_lines(warden_command_output(index, .Holes, allocator = context.temp_allocator))), 2)
	testing.expect_value(t, warden_command_output(index, .Probes, allocator = context.temp_allocator), "")
	testing.expect_value(t, len(ndjson_lines(warden_command_output(index, .Find, find = Warden_Find_Query{name = "damped"}, allocator = context.temp_allocator))), 1)
	testing.expect(t, warden_command_output(index, .Graph, allocator = context.temp_allocator) != "")
	testing.expect_value(t, len(ndjson_lines(warden_command_output(index, .Tags, allocator = context.temp_allocator))), 1)
	testing.expect_value(t, warden_command_output(index, .Pipeline, allocator = context.temp_allocator), "")
	log.infof("golden warden drift determinism: every projection is byte-identical across two acquisitions of the written index (holes=2, probes empty, pipeline empty)")
}

@(test)
test_golden_warden_pong_every_command_byte_determinism :: proc(t: ^testing.T) {
	root, _, ok := build_pong_index_root(t)
	if !ok {
		return
	}
	defer remove_scratch_tree(root)

	expect_every_command_byte_determinism(t, root, Warden_Find_Query{name = "paddle"})

	index, refusal := read_warden_index(root, context.temp_allocator)
	testing.expect_value(t, refusal.err, Warden_Read_Error.None)
	if refusal.err != .None {
		return
	}
	testing.expect_value(t, len(index.project.pipeline_flattened), 11)
	testing.expect_value(t, len(index.project.tag_registry), 10)
	testing.expect_value(t, len(ndjson_lines(warden_command_output(index, .Pipeline, allocator = context.temp_allocator))), 11)
	testing.expect_value(t, len(ndjson_lines(warden_command_output(index, .Tags, allocator = context.temp_allocator))), 10)
	testing.expect(t, warden_command_output(index, .Graph, allocator = context.temp_allocator) != "")
	log.infof("golden warden pong determinism: pipeline (11 steps) and tags (10 tags) project real bytes identically across two acquisitions")
}

@(test)
test_golden_warden_holes_projects_producer_lines_byte_identical :: proc(t: ^testing.T) {
	root, stream, ok := build_drift_index_root(t)
	if !ok {
		return
	}
	defer remove_scratch_tree(root)

	index, refusal := read_warden_index(root, context.temp_allocator)
	testing.expect_value(t, refusal.err, Warden_Read_Error.None)
	if refusal.err != .None {
		return
	}
	lines := ndjson_lines(stream)
	testing.expect_value(t, len(lines), len(index.decls) + 1)
	if len(lines) != len(index.decls) + 1 {
		return
	}
	expected := make([dynamic]string, 0, len(index.decls), context.temp_allocator)
	stub_names := make([dynamic]string, 0, len(index.decls), context.temp_allocator)
	for decl, i in index.decls {
		if decl.stub {
			append(&expected, strings.concatenate({lines[i + 1], "\n"}, context.temp_allocator))
			append(&stub_names, decl.qualified_name)
		}
	}
	testing.expect_value(t, len(stub_names), 2)
	if len(stub_names) == 2 {
		testing.expect_value(t, stub_names[0], "drag")
		testing.expect_value(t, stub_names[1], "launch_speed")
	}
	holes := warden_command_output(index, .Holes, allocator = context.temp_allocator)
	testing.expect_value(t, holes, strings.concatenate(expected[:], context.temp_allocator))
	log.infof("golden warden holes: the projection is byte-identical to the stream's two stub=true producer lines (drag, launch_speed)")
}

@(test)
test_golden_warden_debt_empty_projection_is_success :: proc(t: ^testing.T) {
	root, _, ok := build_drift_index_root(t)
	if !ok {
		return
	}
	defer remove_scratch_tree(root)

	index, refusal := read_warden_index(root, context.temp_allocator)
	testing.expect_value(t, refusal.err, Warden_Read_Error.None)
	if refusal.err != .None {
		return
	}
	testing.expect_value(t, warden_command_output(index, .Debt, allocator = context.temp_allocator), "")
	testing.expect_value(t, warden_verb_exit(root, .Debt), 0)
	log.infof("golden warden debt: the empty drift projection exits 0 — emptiness is success, never a failure tier")
}

@(test)
test_golden_warden_probes_empty_projection_is_success :: proc(t: ^testing.T) {
	root, _, ok := build_drift_index_root(t)
	if !ok {
		return
	}
	defer remove_scratch_tree(root)

	index, refusal := read_warden_index(root, context.temp_allocator)
	testing.expect_value(t, refusal.err, Warden_Read_Error.None)
	if refusal.err != .None {
		return
	}
	testing.expect_value(t, warden_command_output(index, .Probes, allocator = context.temp_allocator), "")
	testing.expect_value(t, warden_verb_exit(root, .Probes), 0)
	log.infof("golden warden probes: the empty drift projection exits 0 — a probe-free tree enumerates zero probes, success not failure")
}

overwrite_scratch_tree_file :: proc(t: ^testing.T, root: string, rel: string, content: string) -> bool {
	path := scratch_join({root, rel})
	err := os.write_entire_file(path, transmute([]byte)content)
	testing.expect(t, err == nil)
	return err == nil
}

append_scratch_tree_file :: proc(t: ^testing.T, root: string, rel: string, addition: string) -> bool {
	path := scratch_join({root, rel})
	bytes, read_err := os.read_entire_file_from_path(path, context.temp_allocator)
	testing.expect(t, read_err == nil)
	if read_err != nil {
		return false
	}
	joined := strings.concatenate({string(bytes), addition}, context.temp_allocator)
	return overwrite_scratch_tree_file(t, root, rel, joined)
}

@(test)
test_golden_warden_debt_projects_live_todo_alongside_gtag :: proc(t: ^testing.T) {
	root, copied := copy_spec_tree_to_temp(resolve_drift_dir(), "drift-warden-todo", "FUNPACK_DRIFT_DIR")
	if !copied {
		return
	}
	defer remove_scratch_tree(root)
	if !overwrite_scratch_tree_file(t, root, "funpack_configs/tags.fcfg", "tags {\n  game\n  debt\n}\n") {
		return
	}
	addition := "\n@todo(\"retire the placeholder drag target\", T-0042)\nfn drag_target() -> Fixed {\n  return 0.5\n}\n\n@gtag(\"debt\")\nfn coast_speed(base: Fixed) -> Fixed {\n  return base * 2.0\n}\n"
	if !append_scratch_tree_file(t, root, "src/drift.fun", addition) {
		return
	}
	product, verdict := stage_build(root, .Dev, context.temp_allocator)
	testing.expect_value(t, verdict.err, Build_Error.None)
	if verdict.err != .None {
		return
	}
	write_err := write_build_products(product, root)
	testing.expect_value(t, write_err, Build_Write_Error.None)
	if write_err != .None {
		return
	}
	index_bytes, read_err := os.read_entire_file_from_path(product.index_path, context.temp_allocator)
	testing.expect(t, read_err == nil)
	if read_err != nil {
		return
	}
	stream := string(index_bytes)

	index, refusal := read_warden_index(root, context.temp_allocator)
	testing.expect_value(t, refusal.err, Warden_Read_Error.None)
	if refusal.err != .None {
		return
	}
	target, target_found := find_warden_decl(index, "drag_target")
	testing.expect(t, target_found)
	if target_found {
		testing.expect(t, target.todo)
		testing.expect_value(t, len(target.gtags), 0)
	}
	coast, coast_found := find_warden_decl(index, "coast_speed")
	testing.expect(t, coast_found)
	if coast_found {
		testing.expect(t, !coast.todo)
		testing.expect(t, contains_str(coast.gtags, WARDEN_DEBT_GTAG))
	}
	lines := ndjson_lines(stream)
	testing.expect_value(t, len(lines), len(index.decls) + 1)
	if len(lines) != len(index.decls) + 1 {
		return
	}
	expected := make([dynamic]string, 0, len(index.decls), context.temp_allocator)
	debt_names := make([dynamic]string, 0, len(index.decls), context.temp_allocator)
	for decl, i in index.decls {
		if warden_debt_predicate(decl, "") {
			append(&expected, strings.concatenate({lines[i + 1], "\n"}, context.temp_allocator))
			append(&debt_names, decl.qualified_name)
		}
	}
	testing.expect_value(t, len(debt_names), 2)
	if len(debt_names) == 2 {
		testing.expect_value(t, debt_names[0], "drag_target")
		testing.expect_value(t, debt_names[1], "coast_speed")
	}
	debt := warden_command_output(index, .Debt, allocator = context.temp_allocator)
	testing.expect_value(t, debt, strings.concatenate(expected[:], context.temp_allocator))
	testing.expect_value(t, warden_verb_exit(root, .Debt), 0)
	log.infof("golden warden debt: the live @todo and @gtag(debt) decls project byte-identical producer lines (drag_target, coast_speed)")
}

@(test)
test_golden_warden_missing_index_refuses_naming_build :: proc(t: ^testing.T) {
	root, ok := copy_spec_tree_to_temp(resolve_drift_dir(), "drift-warden", "FUNPACK_DRIFT_DIR")
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
	for cmd in Warden_Command {
		testing.expect_value(t, warden_verb_exit(root, cmd), 2)
	}
	log.infof("golden warden missing index: an unbuilt drift tree refuses exit 2 on every command with the `funpack build` fix-it")
}

@(test)
test_golden_warden_doctored_schema_version_refused :: proc(t: ^testing.T) {
	root, stream, ok := build_drift_index_root(t)
	if !ok {
		return
	}
	defer remove_scratch_tree(root)

	anchor := fmt.tprintf("\"schema_version\":%d", INDEX_SCHEMA_VERSION)
	doctored, _ := strings.replace_all(stream, anchor, "\"schema_version\":999", context.temp_allocator)
	testing.expect(t, doctored != stream)
	if !write_warden_index_product(t, root, doctored) {
		return
	}

	_, refusal := read_warden_index(root, context.temp_allocator)
	testing.expect_value(t, refusal.err, Warden_Read_Error.Schema_Mismatch)
	testing.expect_value(t, refusal.line, 1)
	testing.expect_value(t, refusal.decode, Index_Read_Error.Schema_Mismatch)
	testing.expect(t, strings.contains(warden_refusal_message(refusal, context.temp_allocator), "rebuild the index with this funpack"))
	for cmd in Warden_Command {
		testing.expect_value(t, warden_verb_exit(root, cmd), 2)
	}
	log.infof("golden warden doctored schema: a bumped schema_version refuses the written index exit 2 on every command")
}

@(test)
test_golden_warden_injected_extra_key_refused :: proc(t: ^testing.T) {
	root, stream, ok := build_drift_index_root(t)
	if !ok {
		return
	}
	defer remove_scratch_tree(root)

	lines := ndjson_lines(stream)
	testing.expect(t, len(lines) >= 2)
	if len(lines) < 2 {
		return
	}
	doctored := make([dynamic]string, 0, len(lines), context.temp_allocator)
	for line, i in lines {
		full := strings.concatenate({line, "\n"}, context.temp_allocator)
		if i == 1 {
			full = inject_top_level_key(t, full)
		}
		append(&doctored, full)
	}
	joined := strings.concatenate(doctored[:], context.temp_allocator)
	if !write_warden_index_product(t, root, joined) {
		return
	}

	_, refusal := read_warden_index(root, context.temp_allocator)
	testing.expect_value(t, refusal.err, Warden_Read_Error.Record_Refused)
	testing.expect_value(t, refusal.line, 2)
	testing.expect_value(t, refusal.decode, Index_Read_Error.Unknown_Field)
	testing.expect(t, strings.contains(warden_refusal_message(refusal, context.temp_allocator), "`funpack build`"))
	testing.expect_value(t, warden_verb_exit(root, .Graph), 2)
	log.infof("golden warden injected key: an over-shaped decl line refuses the written index exit 2")
}
