package funpack

import "core:log"
import "core:os"
import "core:strings"
import "core:testing"

PROBED_GOVERNANCE_ADDITION ::
	"\n@doc(\"Debug fixture: a breakpoint probe pausing when the serve threshold is crossed.\")\n" +
	"@break(self.pos.x > 70.0)\n" +
	"behavior debug_break_ball on Ball {\n" +
	"  fn step(self: Ball) -> Ball {\n" +
	"    return self with { pos: self.vel }\n" +
	"  }\n" +
	"}\n" +
	"\n" +
	"@doc(\"Debug fixture: a ball observer logged each step.\")\n" +
	"@log(self.pos)\n" +
	"behavior debug_log_ball on Ball {\n" +
	"  fn step(self: Ball) -> Ball {\n" +
	"    return self with { vel: self.pos }\n" +
	"  }\n" +
	"}\n" +
	"\n" +
	"@doc(\"Debug fixture: a board whose drift bias data field is watched for changes.\")\n" +
	"data DebugBoard {\n" +
	"  @watch(self.bias)\n" +
	"  bias: Fixed\n" +
	"}\n" +
	"\n" +
	"@doc(\"Debug fixture: a traced ball observer, with the @todo that retires the whole fixture.\")\n" +
	"@trace\n" +
	"@todo(\"retire the debug governance fixture\", T-0042)\n" +
	"behavior debug_trace_ball on Ball {\n" +
	"  fn step(self: Ball) -> Ball {\n" +
	"    return self\n" +
	"  }\n" +
	"}\n"

PROBED_DECL_NAMES :: [4]string{"debug_break_ball", "debug_log_ball", "DebugBoard", "debug_trace_ball"}

amend_probed_pong_root :: proc(t: ^testing.T) -> (root: string, ok: bool) {
	copied: bool
	root, copied = copy_spec_tree_to_temp(resolve_pong_dir(), "pong-probes", "FUNPACK_PONG_DIR")
	if !copied {
		return "", false
	}
	if !append_scratch_tree_file(t, root, "src/pong.fun", PROBED_GOVERNANCE_ADDITION) {
		remove_scratch_tree(root)
		return "", false
	}
	return root, true
}

build_probed_pong_root :: proc(t: ^testing.T) -> (root: string, stream: string, ok: bool) {
	amended: bool
	root, amended = amend_probed_pong_root(t)
	if !amended {
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

@(test)
test_golden_probed_pong_dev_build_indexes_all_four_probes :: proc(t: ^testing.T) {
	root, stream, ok := build_probed_pong_root(t)
	if !ok {
		return
	}
	defer remove_scratch_tree(root)

	testing.expect(t, os.exists(build_product_path(root, ARTIFACT_PRODUCT_NAME, context.temp_allocator)))
	testing.expect(t, os.exists(build_product_path(root, INDEX_PRODUCT_NAME, context.temp_allocator)))

	break_line, break_found := index_decl_line(stream, "debug_break_ball")
	testing.expect(t, break_found)
	testing.expect(t, strings.contains(break_line, "\"kind\":\"Behavior\""))
	testing.expect(t, strings.contains(break_line, "\"debug\":[\"break\"]"))
	testing.expect(t, strings.contains(break_line, "\"todo\":false"))

	log_line, log_found := index_decl_line(stream, "debug_log_ball")
	testing.expect(t, log_found)
	testing.expect(t, strings.contains(log_line, "\"kind\":\"Behavior\""))
	testing.expect(t, strings.contains(log_line, "\"debug\":[\"log\"]"))

	watch_line, watch_found := index_decl_line(stream, "DebugBoard")
	testing.expect(t, watch_found)
	testing.expect(t, strings.contains(watch_line, "\"kind\":\"Data\""))
	testing.expect(t, strings.contains(watch_line, "\"debug\":[\"watch\"]"))

	trace_line, trace_found := index_decl_line(stream, "debug_trace_ball")
	testing.expect(t, trace_found)
	testing.expect(t, strings.contains(trace_line, "\"kind\":\"Behavior\""))
	testing.expect(t, strings.contains(trace_line, "\"debug\":[\"trace\"]"))
	testing.expect(t, strings.contains(trace_line, "\"todo\":true"))

	pristine_line, pristine_found := index_decl_line(stream, "advance")
	testing.expect(t, pristine_found)
	testing.expect(t, strings.contains(pristine_line, "\"debug\":[]"))
	testing.expect(t, strings.contains(pristine_line, "\"todo\":false"))
	log.infof("golden probes dev build: exit 0, both products, and the index pins break/log/watch/trace each on its own decl with the live todo flag")
}

@(test)
test_golden_probed_pong_release_build_and_check_refuse :: proc(t: ^testing.T) {
	root, ok := amend_probed_pong_root(t)
	if !ok {
		return
	}
	defer remove_scratch_tree(root)

	_, verdict := stage_build(root, .Release, context.temp_allocator)
	testing.expect_value(t, verdict.err, Build_Error.Debug_Directive)
	testing.expect_value(t, verdict.offender, "debug_break_ball")
	testing.expect_value(t, build_refusal_message(verdict, context.temp_allocator), "Debug_Directive: debug_break_ball")
	testing.expect(t, !os.exists(build_product_path(root, ARTIFACT_PRODUCT_NAME, context.temp_allocator)))
	testing.expect(t, !os.exists(build_product_path(root, INDEX_PRODUCT_NAME, context.temp_allocator)))

	testing.expect_value(t, run_check_verb(root, .Dev), 0)
	testing.expect_value(t, run_check_verb(root, .Release), 2)
	testing.expect(t, !os.exists(scratch_join({root, FUNPACK_BUILD_DIR})))
	log.infof("golden probes release: build refuses naming the offender (Debug_Directive: debug_break_ball) with no product and check adjudicates dev 0 / release 2 — debug residue cannot ship")
}

@(test)
test_golden_probed_pong_warden_projects_probes :: proc(t: ^testing.T) {
	root, stream, ok := build_probed_pong_root(t)
	if !ok {
		return
	}
	defer remove_scratch_tree(root)

	index, refusal := read_warden_index(root, context.temp_allocator)
	testing.expect_value(t, refusal.err, Warden_Read_Error.None)
	if refusal.err != .None {
		return
	}

	directives := [4]string{"break", "log", "watch", "trace"}
	names := PROBED_DECL_NAMES
	for name, i in names {
		decl, found := find_warden_decl(index, name)
		testing.expect(t, found)
		if !found {
			continue
		}
		testing.expect_value(t, len(decl.debug), 1)
		if len(decl.debug) == 1 {
			testing.expect_value(t, decl.debug[0], directives[i])
		}
		testing.expect_value(t, decl.todo, name == "debug_trace_ball")
	}

	lines := ndjson_lines(stream)
	testing.expect_value(t, len(lines), len(index.decls) + 1)
	if len(lines) != len(index.decls) + 1 {
		return
	}

	expected_probes := make([dynamic]string, 0, len(index.decls), context.temp_allocator)
	probe_names := make([dynamic]string, 0, len(index.decls), context.temp_allocator)
	for decl, i in index.decls {
		if warden_probes_predicate(decl, "") {
			append(&expected_probes, strings.concatenate({lines[i + 1], "\n"}, context.temp_allocator))
			append(&probe_names, decl.qualified_name)
		}
	}
	testing.expect_value(t, len(probe_names), 4)
	if len(probe_names) == 4 {
		testing.expect_value(t, probe_names[0], "debug_break_ball")
		testing.expect_value(t, probe_names[1], "debug_log_ball")
		testing.expect_value(t, probe_names[2], "DebugBoard")
		testing.expect_value(t, probe_names[3], "debug_trace_ball")
	}
	testing.expect_value(
		t,
		warden_command_output(index, .Probes, allocator = context.temp_allocator),
		strings.concatenate(expected_probes[:], context.temp_allocator),
	)
	testing.expect_value(t, warden_verb_exit(root, .Probes), 0)

	for name in names {
		expected, found := probed_producer_line(index, lines, name)
		testing.expect(t, found)
		if !found {
			continue
		}
		query := Warden_Find_Query{name = name}
		testing.expect_value(t, warden_command_output(index, .Find, find = query, allocator = context.temp_allocator), expected)
		testing.expect_value(t, warden_verb_exit(root, .Find, "", query), 0)
	}

	expected_debt, debt_found := probed_producer_line(index, lines, "debug_trace_ball")
	testing.expect(t, debt_found)
	if debt_found {
		testing.expect_value(t, warden_command_output(index, .Debt, allocator = context.temp_allocator), expected_debt)
	}
	testing.expect_value(t, warden_verb_exit(root, .Debt), 0)
	testing.expect_value(t, warden_command_output(index, .Holes, allocator = context.temp_allocator), "")
	testing.expect_value(t, warden_verb_exit(root, .Holes), 0)

	expect_every_command_byte_determinism(t, root, Warden_Find_Query{name = "debug_trace_ball"})
	log.infof("golden probes warden: probes enumerates the four probed decls byte-identical to their producer lines, find answers each on demand, debt projects the @todo behavior, holes stays empty")
}

probed_producer_line :: proc(index: Warden_Index, lines: []string, name: string) -> (line: string, found: bool) {
	for decl, i in index.decls {
		if decl.qualified_name == name {
			return strings.concatenate({lines[i + 1], "\n"}, context.temp_allocator), true
		}
	}
	return "", false
}
