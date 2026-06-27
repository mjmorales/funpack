package funpack

import "core:log"
import "core:os"
import "core:strconv"
import "core:strings"
import "core:testing"

FOUR_PROBE_SOURCE ::
	"@doc(\"Minimal probed module: a watched thing, a watched data field, four probed behaviors, a deviceless bindings fn, and a traced schedule.\")\n" +
	"\n" +
	"import engine.input.{Bindings}\n" +
	"import engine.math.{Fixed, Vec2}\n" +
	"\n" +
	"@doc(\"The marker thing the probed behaviors step on.\")\n" +
	"thing DebugMarker {\n" +
	"  pos: Vec2 = Vec2{x: 0.0, y: 0.0}\n" +
	"  vel: Vec2 = Vec2{x: 0.0, y: 0.0}\n" +
	"}\n" +
	"\n" +
	"@doc(\"A drift-log data record whose bias field is watched (the §28 §4 field-probe position).\")\n" +
	"data DriftLog {\n" +
	"  @watch(self.bias)\n" +
	"  bias: Fixed\n" +
	"}\n" +
	"\n" +
	"@doc(\"The level origin a log probe reads a field off.\")\n" +
	"let DRIFT: Vec2 = Vec2{x: 0.0, y: 0.0}\n" +
	"\n" +
	"@doc(\"A breakpoint probe pausing when the serve threshold is crossed.\")\n" +
	"@break(self.pos.x > 70.0)\n" +
	"behavior debug_serve_threshold on DebugMarker {\n" +
	"  fn step(self: DebugMarker) -> DebugMarker {\n" +
	"    return self with { pos: self.vel }\n" +
	"  }\n" +
	"}\n" +
	"\n" +
	"@doc(\"The drift bias under live observation, logged each step.\")\n" +
	"@log(DRIFT.x)\n" +
	"behavior debug_drift_bias on DebugMarker {\n" +
	"  fn step(self: DebugMarker) -> DebugMarker {\n" +
	"    return self with { vel: self.pos }\n" +
	"  }\n" +
	"}\n" +
	"\n" +
	"@doc(\"A marker observer whose position is watched for changes.\")\n" +
	"@watch(self.pos)\n" +
	"behavior debug_marker_watch on DebugMarker {\n" +
	"  fn step(self: DebugMarker) -> DebugMarker {\n" +
	"    return self with { pos: self.pos }\n" +
	"  }\n" +
	"}\n" +
	"\n" +
	"@doc(\"A traced marker observer.\")\n" +
	"@trace\n" +
	"behavior debug_trace_marker on DebugMarker {\n" +
	"  fn step(self: DebugMarker) -> DebugMarker {\n" +
	"    return self\n" +
	"  }\n" +
	"}\n" +
	"\n" +
	"@doc(\"No bindings — the minimal deviceless map.\")\n" +
	"fn bindings() -> Bindings {\n" +
	"  return Bindings.empty()\n" +
	"}\n" +
	"\n" +
	"@doc(\"The schedule that runs the four probed behaviors, with a traced stage (the §28 §4 stage-probe position).\")\n" +
	"pipeline Loop {\n" +
	"  @trace\n" +
	"  mark: [debug_serve_threshold, debug_drift_bias, debug_marker_watch, debug_trace_marker]\n" +
	"}\n"

FOUR_PROBE_ENTRYPOINT :: "use mini.{Loop, bindings}\n\nentrypoint main {\n  pipeline = Loop\n  tick = 60hz\n  logical = 160x120\n  bindings = bindings\n}\n"

write_four_probe_tree :: proc(t: ^testing.T) -> (root: string, ok: bool) {
	root = scratch_join({scratch_base(), tprintf_seq("funpack-build-probed")})
	remove_scratch_tree(root)
	configs := scratch_join({root, "funpack_configs"})
	src_path := scratch_join({root, "src", "mini.fun"})
	if !ensure_dir(configs) || !ensure_dir(scratch_join({root, "src"})) {
		log.warnf("SKIP build probed tree: cannot create dirs under %s", root)
		return "", false
	}
	ok_writes :=
		os.write_entire_file(scratch_join({configs, "project.fcfg"}), "project mini {\n  version = \"0.1.0\"\n}\n") == nil &&
		os.write_entire_file(scratch_join({configs, "entrypoints.fcfg"}), FOUR_PROBE_ENTRYPOINT) == nil &&
		os.write_entire_file(scratch_join({configs, "builds.fcfg"}), "build native {\n  platform = desktop\n}\n") == nil &&
		os.write_entire_file(scratch_join({configs, "tags.fcfg"}), "tags {\n  game\n}\n") == nil &&
		os.write_entire_file(src_path, FOUR_PROBE_SOURCE) == nil
	if !ok_writes {
		remove_scratch_tree(root)
		log.warnf("SKIP build probed tree: cannot write files under %s", root)
		return "", false
	}
	return root, true
}

@(test)
test_dev_build_emits_probe_section_with_node_forest_bodies :: proc(t: ^testing.T) {
	root, ok := write_four_probe_tree(t)
	if !ok {
		return
	}
	defer remove_scratch_tree(root)

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
	artifact_bytes, read_err := os.read_entire_file_from_path(build_product_path(root, ARTIFACT_PRODUCT_NAME, context.temp_allocator), context.temp_allocator)
	testing.expect(t, read_err == nil)
	if read_err != nil {
		return
	}
	artifact := string(artifact_bytes)

	testing.expect(t, strings.contains(artifact, "funpack-artifact 19\n"))
	testing.expect(t, strings.contains(artifact, "[probes 6]\n"))

	testing.expect(t, strings.contains(artifact, "probe watch DriftLog.bias 1\nnode field bias 1\nnode name self 0\n"))

	testing.expect(t, strings.contains(artifact, "probe break debug_serve_threshold 1\nnode binary gt 2\nnode field x 1\nnode field pos 1\nnode name self 0\nnode fixed 300647710720 0\n"))
	testing.expect(t, strings.contains(artifact, "probe log debug_drift_bias 1\nnode field x 1\nnode name DRIFT 0\n"))
	testing.expect(t, strings.contains(artifact, "probe watch debug_marker_watch 1\nnode field pos 1\nnode name self 0\n"))
	testing.expect(t, strings.contains(artifact, "probe trace debug_trace_marker 0\n"))

	testing.expect(t, strings.contains(artifact, "probe trace Loop.mark 0\n"))

	testing.expect(t, !strings.contains(artifact, "self.pos.x > 70.0"))

	doc, parse_err := parse_artifact(artifact)
	testing.expect_value(t, parse_err, Artifact_Parse_Error.None)
	testing.expect_value(t, doc.schema_version, ARTIFACT_SCHEMA_VERSION)
	section, found := artifact_find_section(doc, "probes")
	testing.expect(t, found)
	testing.expect_value(t, section.count, 6)
	log.infof("dev build probes: artifact [probes 6] carries four behavior probes + the DriftLog.bias field @watch + the Loop.mark stage @trace with node-forest bodies, section reconciles under the reader")
}

@(test)
test_release_build_refuses_probed_tree_emitting_no_artifact :: proc(t: ^testing.T) {
	root, ok := write_four_probe_tree(t)
	if !ok {
		return
	}
	defer remove_scratch_tree(root)

	_, verdict := stage_build(root, .Release, context.temp_allocator)
	testing.expect_value(t, verdict.err, Build_Error.Debug_Directive)
	testing.expect_value(t, verdict.offender, "DriftLog")
	testing.expect(t, !os.exists(build_product_path(root, ARTIFACT_PRODUCT_NAME, context.temp_allocator)))
	testing.expect_value(t, run_check_verb(root, .Dev), 0)
	testing.expect_value(t, run_check_verb(root, .Release), 2)
	log.infof("release build probes: the probed tree refuses (Debug_Directive: DriftLog, the field-probe carrier) with no artifact — a release artifact holds no probe section")
}

@(test)
test_release_build_probe_free_tree_emits_empty_probes_tail :: proc(t: ^testing.T) {
	root, ok := write_minimal_valid_tree(t)
	if !ok {
		return
	}
	defer remove_scratch_tree(root)

	product, verdict := stage_build(root, .Release, context.temp_allocator)
	testing.expect_value(t, verdict.err, Build_Error.None)
	if verdict.err != .None {
		return
	}
	testing.expect(t, strings.contains(product.artifact, "[probes 0]\n"))
	testing.expect(t, !strings.contains(product.artifact, "probe "))

	doc, parse_err := parse_artifact(product.artifact)
	testing.expect_value(t, parse_err, Artifact_Parse_Error.None)
	section, found := artifact_find_section(doc, "probes")
	testing.expect(t, found)
	testing.expect_value(t, section.count, 0)
	log.infof("release build probe-free: the artifact carries the constant [probes 0] tail — section always present, always empty in release")
}

@(test)
test_emit_probe_bodies_round_trip_well_formed :: proc(t: ^testing.T) {
	identity := Project_Identity{name = "mini", version = "0.1.0"}
	artifact, err := stage_emit(FOUR_PROBE_SOURCE, "mini", identity, FOUR_PROBE_ENTRYPOINT, context.temp_allocator)
	testing.expect_value(t, err, Emit_Error.None)
	if err != .None {
		return
	}

	doc, parse_err := parse_artifact(artifact)
	testing.expect_value(t, parse_err, Artifact_Parse_Error.None)
	testing.expect_value(t, doc.schema_version, ARTIFACT_SCHEMA_VERSION)
	section, found := artifact_find_section(doc, "probes")
	testing.expect(t, found)
	if !found {
		return
	}
	testing.expect_value(t, section.count, 6)
	expect_probe_bodies_well_formed(t, section)

	second, second_err := stage_emit(FOUR_PROBE_SOURCE, "mini", identity, FOUR_PROBE_ENTRYPOINT, context.temp_allocator)
	testing.expect_value(t, second_err, Emit_Error.None)
	testing.expect(t, artifact == second)
	log.infof("emit probes round-trip: [probes 6] body forests (incl. the DriftLog.bias field @watch + Loop.mark stage @trace) are well-formed and emission is byte-identical twice")
}

expect_probe_bodies_well_formed :: proc(t: ^testing.T, section: Artifact_Section) {
	i := 0
	probe_records := 0
	for i < len(section.body) {
		line := section.body[i]
		testing.expect(t, strings.has_prefix(line, "probe "))
		if !strings.has_prefix(line, "probe ") {
			return
		}
		declared, count_ok := probe_record_body_count(line)
		testing.expect(t, count_ok)
		probe_records += 1
		body_start := i + 1
		j := body_start
		for j < len(section.body) && !strings.has_prefix(section.body[j], "probe ") {
			j += 1
		}
		testing.expect(t, body_forest_is_well_formed(section.body[body_start:j], declared))
		i = j
	}
	testing.expect_value(t, probe_records, section.count)
}

probe_record_body_count :: proc(line: string) -> (count: int, ok: bool) {
	space := strings.last_index_byte(line, ' ')
	if space < 0 {
		return 0, false
	}
	return strconv.parse_int(line[space + 1:])
}
