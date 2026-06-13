// The §28 §4 EMIT-half acceptance: a dev-build artifact carries the [probes]
// section (schema v18) — one `probe KIND TARGET body_count` record per in-code
// @break/@watch/@log/@trace, each predicate/expression body a §2.7 NODE FOREST
// (never funpack source) — while a --release build carries NONE. These are the
// funpack-side emission pins; the runtime LOAD+HONOR half is a separate downstream
// task (the runtime stays at v17 here and refuses a v18 artifact by design).
//
// FIXTURE TECHNIQUE: self-contained scratch trees (the write_minimal_valid_tree /
// write_holed_tree mold), never the sibling-checkout goldens — so the section is
// pinned without a pong/snake checkout. The probed tree adds the four directives
// onto a minimal compileable module; the probe-free tree is the bare minimal
// module, so its release artifact proves the constant `[probes 0]` tail. The
// release-vs-dev verdict is isolated to the debug-directive ban: the tree is
// otherwise valid and hole-free, exactly as write_holed_tree isolates the
// hole-ban.
package funpack

import "core:log"
import "core:os"
import "core:strconv"
import "core:strings"
import "core:testing"

// FOUR_PROBE_SOURCE is the minimal compileable module (MINI_SOURCE's empty
// pipeline + deviceless bindings) plus all four §05 §5 / §28 §4 debug directives,
// each on a different declaration kind so the [probes] walk crosses the AST's
// declaration sequence: @break(pred) on a fn, @log(expr) on a let, @watch(expr)
// on a thing, @trace on a behavior. Each carries a distinct node-forest body shape
// — @break a `binary gt` predicate, @log a field access, @watch a field access,
// @trace none — so the emitted bodies exercise the emit_expr forest end to end. The
// behavior steps on the watched thing and is wired into the pipeline through an
// explicit `mark:` stage so the schedule references it. Distinct from build_test's
// single-@log PROBED_SOURCE: this fixture spreads all four KINDs to pin each token
// and body shape in the [probes] section.
FOUR_PROBE_SOURCE ::
	"@doc(\"Minimal probed module: an empty pipeline, a deviceless bindings fn, and the four debug directives.\")\n" +
	"\n" +
	"import engine.input.{Bindings}\n" +
	"import engine.math.{Fixed, Vec2}\n" +
	"\n" +
	"@doc(\"A breakpoint probe pausing when the serve threshold is crossed.\")\n" +
	"@break(base > 70.0)\n" +
	"fn debug_serve_threshold(base: Fixed) -> Fixed {\n" +
	"  return base + 1.0\n" +
	"}\n" +
	"\n" +
	"@doc(\"The drift bias under live observation, logged each step.\")\n" +
	"@log(DRIFT.x)\n" +
	"let DEBUG_DRIFT_BIAS: Fixed = 0.25\n" +
	"\n" +
	"@doc(\"The level origin a log probe reads a field off.\")\n" +
	"let DRIFT: Vec2 = Vec2{x: 0.0, y: 0.0}\n" +
	"\n" +
	"@doc(\"A marker thing whose position is watched for changes.\")\n" +
	"@watch(self.pos)\n" +
	"thing DebugMarker {\n" +
	"  pos: Vec2 = Vec2{x: 0.0, y: 0.0}\n" +
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
	"@doc(\"The schedule that runs the traced marker behavior.\")\n" +
	"pipeline Loop {\n" +
	"  mark: [debug_trace_marker]\n" +
	"}\n"

// FOUR_PROBE_ENTRYPOINT wires the probed module's pipeline + bindings (the
// write_minimal_valid_tree entrypoint shape).
FOUR_PROBE_ENTRYPOINT :: "use mini.{Loop, bindings}\n\nentrypoint main {\n  pipeline = Loop\n  tick = 60hz\n  logical = 160x120\n  bindings = bindings\n}\n"

// write_four_probe_tree materializes the write_minimal_valid_tree fixture with the
// four debug directives added to its source (FOUR_PROBE_SOURCE) — a valid §14
// tree whose only dev/release-distinguishing trait is the probes, isolating the
// release verdict to the §29 §3 debug-directive ban (the write_holed_tree mold for
// the hole-ban). ok = false owns the cleanup of a partial tree.
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
	// AC (dev build, the EMIT half): the probed tree built in Dev mode (the no-flag
	// default) is exit 0 and writes the artifact, whose [probes] section carries one
	// `probe KIND TARGET body_count` record per in-code directive in source-
	// declaration order — break on the fn, log on the let, watch on the thing, trace
	// on the behavior — each non-@trace body a §2.7 node forest (NEVER funpack
	// source) and @trace body-less. The section count reconciles under the funpack
	// reader (probe is a top-level keyword; the `node` body lines are sub-records),
	// proving the lead-line discipline shapes the variable-length records.
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

	// The new v18 stamp and the [probes] section with all four records.
	testing.expect(t, strings.contains(artifact, "funpack-artifact 18\n"))
	testing.expect(t, strings.contains(artifact, "[probes 4]\n"))

	// @break: the predicate `base > 70.0` rides as a node forest (binary gt over a
	// name and a fixed literal) under `probe break debug_serve_threshold 1`.
	testing.expect(t, strings.contains(artifact, "probe break debug_serve_threshold 1\nnode binary gt 2\nnode name base 0\nnode fixed 300647710720 0\n"))
	// @log: `DRIFT.x` is a field access node forest under `probe log DEBUG_DRIFT_BIAS 1`.
	testing.expect(t, strings.contains(artifact, "probe log DEBUG_DRIFT_BIAS 1\nnode field x 1\nnode name DRIFT 0\n"))
	// @watch: `self.pos` is a field access under `probe watch DebugMarker 1`.
	testing.expect(t, strings.contains(artifact, "probe watch DebugMarker 1\nnode field pos 1\nnode name self 0\n"))
	// @trace: no argument — body_count 0, no body lines follow.
	testing.expect(t, strings.contains(artifact, "probe trace debug_trace_marker 0\n"))

	// The bodies are node forests, never funpack source: no raw predicate text leaks.
	testing.expect(t, !strings.contains(artifact, "base > 70.0"))

	// The section reconciles under the funpack reader — every section's lead-line
	// count equals its declared N, including [probes] with its mixed probe/node run.
	doc, parse_err := parse_artifact(artifact)
	testing.expect_value(t, parse_err, Artifact_Parse_Error.None)
	testing.expect_value(t, doc.schema_version, ARTIFACT_SCHEMA_VERSION)
	section, found := artifact_find_section(doc, "probes")
	testing.expect(t, found)
	testing.expect_value(t, section.count, 4)
	log.infof("dev build probes: artifact [probes 4] carries break/log/watch/trace with node-forest bodies, section reconciles under the reader")
}

@(test)
test_release_build_refuses_probed_tree_emitting_no_artifact :: proc(t: ^testing.T) {
	// AC (release ban): the SAME probed tree under --release is the exit-2 compile
	// error — stage_build refuses with Debug_Directive naming the first probed
	// declaration (debug_serve_threshold, the addendum's first decl in source order)
	// and writes NO artifact, so a release artifact can never carry a [probes]
	// section. The ban fires before emission, exactly the hole-ban's sibling tier
	// (§28 §4: a @break in a --release build is a compile error). Never a counted
	// failure: there is no exit-1 tier.
	root, ok := write_four_probe_tree(t)
	if !ok {
		return
	}
	defer remove_scratch_tree(root)

	_, verdict := stage_build(root, .Release, context.temp_allocator)
	testing.expect_value(t, verdict.err, Build_Error.Debug_Directive)
	testing.expect_value(t, verdict.offender, "debug_serve_threshold")
	testing.expect(t, !os.exists(build_product_path(root, ARTIFACT_PRODUCT_NAME, context.temp_allocator)))
	testing.expect_value(t, run_check_verb(root, .Dev), 0)
	testing.expect_value(t, run_check_verb(root, .Release), 2)
	log.infof("release build probes: the probed tree refuses (Debug_Directive: debug_serve_threshold) with no artifact — a release artifact holds no probe section")
}

@(test)
test_release_build_probe_free_tree_emits_empty_probes_tail :: proc(t: ^testing.T) {
	// AC (the constant `[probes 0]` tail): a PROBE-FREE minimal tree under --release
	// emits an artifact (release admits a probe-free tree) whose [probes] section is
	// the constant empty tail — the emitter stays mode-blind and writes `[probes 0]`
	// because the AST carries no probes. This proves "release artifacts hold no
	// introspection machinery" (§28) is realized as an always-present, always-empty
	// section, never a mode-gated header the runtime would need the build mode to
	// parse around (§3 fixed header sequence; the [nav 0]/[assets 0] tail precedent).
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

	// The empty tail reconciles under the funpack reader (count 0, no body lines).
	doc, parse_err := parse_artifact(product.artifact)
	testing.expect_value(t, parse_err, Artifact_Parse_Error.None)
	section, found := artifact_find_section(doc, "probes")
	testing.expect(t, found)
	testing.expect_value(t, section.count, 0)
	log.infof("release build probe-free: the artifact carries the constant [probes 0] tail — section always present, always empty in release")
}

@(test)
test_emit_probe_bodies_round_trip_well_formed :: proc(t: ^testing.T) {
	// AC (round-trip + determinism, the §2.7 forest end to end on the funpack side):
	// the probed module emitted directly through stage_emit (mode-blind, the dev
	// path) carries the [probes] section, every probe body is a well-formed §2.7
	// node forest (the body_count-1 records have exactly one statement subtree, the
	// @trace record none), and two emissions are byte-identical (§29). This is the
	// disk-independent twin of the dev-build test — it pins the encoder, not the
	// build verb.
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
	testing.expect_value(t, section.count, 4)
	// Every probe's body run is a well-formed pre-order forest: a non-@trace record
	// declares body_count 1 (one statement subtree), a @trace record body_count 0,
	// and the `node` lines after each `probe` line are exactly that subtree with no
	// leftover — read through the same body-forest reader the §2.7 bodies use.
	expect_probe_bodies_well_formed(t, section)

	// Emission is a pure function of its inputs — two calls, identical bytes (§29).
	second, second_err := stage_emit(FOUR_PROBE_SOURCE, "mini", identity, FOUR_PROBE_ENTRYPOINT, context.temp_allocator)
	testing.expect_value(t, second_err, Emit_Error.None)
	testing.expect(t, artifact == second)
	log.infof("emit probes round-trip: [probes 4] body forests are well-formed and emission is byte-identical twice")
}

// expect_probe_bodies_well_formed walks a [probes] section's body lines and asserts
// each `probe KIND TARGET body_count` lead line is followed by exactly body_count
// well-formed §2.7 node subtrees with no leftover before the next `probe` line —
// the same count-driven body discipline body_forest_is_well_formed enforces for a
// [functions] body, applied to the probe records. It splits the section body on
// `probe ` lead lines and reads each record's trailing `node` run.
expect_probe_bodies_well_formed :: proc(t: ^testing.T, section: Artifact_Section) {
	i := 0
	probe_records := 0
	for i < len(section.body) {
		line := section.body[i]
		// Each record opens with a `probe ` lead line; everything up to the next
		// `probe ` lead line (or the section end) is its `node` body run.
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
		// The trailing `node` run is exactly `declared` pre-order subtrees, no leftover.
		testing.expect(t, body_forest_is_well_formed(section.body[body_start:j], declared))
		i = j
	}
	testing.expect_value(t, probe_records, section.count)
}

// probe_record_body_count reads a `probe KIND TARGET body_count` lead line's
// trailing decimal body_count token. ok is false on a malformed line — the same
// trailing-token discipline node_child_count reads a node line's child count with.
probe_record_body_count :: proc(line: string) -> (count: int, ok: bool) {
	space := strings.last_index_byte(line, ' ')
	if space < 0 {
		return 0, false
	}
	return strconv.parse_int(line[space + 1:])
}
