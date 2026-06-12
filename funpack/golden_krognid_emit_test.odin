// The krognid MULTI-MODULE emission golden: the production emitter, driven over
// the LIVE 2-module krognid tree (stroll entrypoint + the baked krognid rig seam)
// through emit_tree_artifact / stage_emit_indexed — NOT yard's single-source
// stage_emit — emits a well-formed v6 artifact. krognid is the first multi-module
// artifact the runtime executes, and the load-bearing new behavior is the §17
// cross-module SEAM-FN CARRY: stroll's `draw_krognid` calls krognid_skeleton() /
// krognid_parts() living in the SEAM module, so the emitter must carry those
// imported fns' bodies into [functions] or the runtime's program_function would
// return nil and the Rigged draw body would be dead.
//
// SCOPE (the documented arena/yard split, mirrored from golden_krognid_test.odin
// and golden_yard_test.odin): this golden pins parse + the full checked pipeline
// THROUGH flatten + EMISSION — the artifact carries ARTIFACT_SCHEMA_VERSION, parses
// well-formed through the funpack reader, double-emits byte-identical, and pins the
// load-bearing emitted tokens (the seam fns in [functions], the Krognid thing/
// fields, the setup spawn batch, the entrypoint logical:160x120). It does NOT
// execute the artifact (the runtime owns execution). The fixture resolves the
// sibling checkout (or FUNPACK_KROGNID_DIR, through resolve_krognid_dir) and SKIPs
// LOUDLY when it is absent — a skipped golden is a warning, NEVER a pass.
package funpack

import "core:log"
import "core:os"
import "core:path/filepath"
import "core:testing"

// krognid_emit reads the live krognid tree and drives the production multi-module
// emitter (emit_tree_artifact, the same seam the `build` verb uses) over it,
// returning the v6 artifact bytes. ok = false (with a LOUD SKIP warning) when the
// sibling checkout is absent or the tree does not read — never a silent pass. It is
// the multi-module analogue of yard_emit_inputs + stage_emit, collapsed because the
// tree path is the emitter's input (it resolves the entrypoint module and the
// sibling seam ASTs itself).
krognid_emit :: proc(t: ^testing.T) -> (artifact: string, ok: bool) {
	dir := resolve_krognid_dir()
	if !os.is_dir(dir) {
		log.warnf(
			"SKIP krognid emit golden: %s not found — set FUNPACK_KROGNID_DIR or check out funpack-spec as a sibling of the repo",
			dir,
		)
		return "", false
	}
	project, read_err, _ := read_project(dir)
	if read_err != .None {
		log.warnf("SKIP krognid emit golden: krognid tree at %s did not read (%v)", dir, read_err)
		return "", false
	}
	emitted, emit_err := emit_tree_artifact(dir, project, project_pipeline_sources(project), context.temp_allocator)
	testing.expect_value(t, emit_err, Emit_Error.None)
	if emit_err != .None {
		return "", false
	}
	return emitted, true
}

// test_emit_krognid_artifact_round_trips is the load-bearing krognid emission
// acceptance: the production multi-module emitter, run over the live krognid tree,
// emits a well-formed v6 artifact (Emit_Error.None), parses well-formed through the
// funpack reader (every section count reconciles), carries the current
// ARTIFACT_SCHEMA_VERSION (6), and is deterministic (double-emit byte-identical).
// The per-construct token pins below pin the exact emitted tokens; this is the
// end-to-end round-trip proof. SKIPs loudly when the sibling is absent.
@(test)
test_emit_krognid_artifact_round_trips :: proc(t: ^testing.T) {
	artifact, ok := krognid_emit(t)
	if !ok {
		return
	}
	doc, parse_err := parse_artifact(artifact)
	testing.expect_value(t, parse_err, Artifact_Parse_Error.None)
	testing.expect_value(t, doc.schema_version, ARTIFACT_SCHEMA_VERSION)

	// Deterministic emission (spec §09, §29): two emissions are byte-identical, so
	// the multi-module artifact carries no field whose value depends on when, where,
	// or on which machine it was emitted (the seam-fn carry is order-stable).
	second, second_ok := krognid_emit(t)
	testing.expect(t, second_ok)
	testing.expect(t, artifact == second)
	if artifact == second {
		log.infof(
			"emit krognid: multi-module v6 artifact emits well-formed and byte-identical twice (%d bytes)",
			len(artifact),
		)
	}
}

// test_emit_krognid_seam_fn_carry is the §17 cross-module CARRY proof — the central
// new behavior. The entrypoint module (stroll) imports krognid_skeleton /
// krognid_parts from the SEAM module, and the Rigged draw body calls them; the
// emitter must carry those imported fns' FULL records — the lead line with the SEAM
// module's span AND the body node run — into [functions], so the runtime resolves
// the calls to a self-contained record by bare name (program_function looks fns up
// by bare name, never a §15 qualifier). The pins are at exact-token granularity
// (never ranges, the hunt golden's discipline): the two seam lead lines with their
// `span:krognid:N` spans, and a body node line from each carried body proving the
// body — not just the signature — is present. SKIPs loudly when absent.
@(test)
test_emit_krognid_seam_fn_carry :: proc(t: ^testing.T) {
	artifact, ok := krognid_emit(t)
	if !ok {
		return
	}

	// The two seam fn lead lines: bare names, the seam module's span (krognid:8 /
	// krognid:14, the .gen.fun decl lines), and the body_count 1 (each is a single
	// `return`). The span keying to `krognid` (not `stroll`) is the load-bearing
	// proof the carry kept the originating module, not the entrypoint's.
	testing.expect(t, artifact_has_line(artifact, "function krognid_skeleton fn 0 return:Skeleton 1 span:krognid:8"))
	testing.expect(t, artifact_has_line(artifact, "function krognid_parts fn 0 return:PartSet 1 span:krognid:14"))

	// krognid_skeleton's body is `return Skeleton.humanoid()` — a return over a call
	// of the `.humanoid` field of the Skeleton name. The `node field humanoid 1` line
	// proves the BODY rode the carry, not just the signature.
	testing.expect(t, artifact_has_line(artifact, "node field humanoid 1"))

	// krognid_parts' body is a `.bind(Slot::…, mesh("…")).mirror(Side::L, Side::R)`
	// builder chain over PartSet.empty(). The mesh-handle string token and the mirror
	// variants prove the full chain body carried, not a stub.
	testing.expect(t, artifact_has_line(artifact, "node string L13:krognid_torso 0"))
	testing.expect(t, artifact_has_line(artifact, "node variant Side L false 0"))
	testing.expect(t, artifact_has_line(artifact, "node variant Side R false 0"))

	// The Rigged draw body (in stroll's draw_krognid behavior) calls the seam fns by
	// bare name — the call sites the carried records satisfy. `node name krognid_skeleton`
	// is the call the runtime's program_function resolves to the carried record.
	testing.expect(t, artifact_contains(artifact, "node name krognid_skeleton"))
	testing.expect(t, artifact_contains(artifact, "node name krognid_parts"))

	log.infof("emit krognid: the krognid seam fns krognid_skeleton/krognid_parts carried into [functions] with seam spans and full bodies")
}

// test_emit_krognid_thing_and_setup pins the entrypoint-module constructs the
// multi-module artifact must carry for the runtime to spawn and wire the world: the
// Krognid thing's blackboard schema (bare name + the §6 composite/scalar defaults),
// the §13 setup spawn batch (Krognid at board center + the Field scene singleton-
// holder), and the §15 entrypoint logical:160x120 draw space. The decl name is BARE
// (`thing Krognid`, `spawn Krognid`) even in this multi-module project: the runtime
// resolves things by bare name, and the §15-qualification ADR governs the SEPARATE
// Index Contract decl surface, not the artifact's name tokens. Exact tokens, never
// ranges. SKIPs loudly when absent.
@(test)
test_emit_krognid_thing_and_setup :: proc(t: ^testing.T) {
	artifact, ok := krognid_emit(t)
	if !ok {
		return
	}

	// The Krognid thing: a plain (non-singleton) thing with one gtag and five fields,
	// bare-named. The two required fields (player, pos) and the three §6-defaulted
	// fields (intent Vec2 composite default, phase/speed scalar 0).
	testing.expect(t, artifact_has_line(artifact, "thing Krognid false 1 5"))
	testing.expect(t, artifact_has_line(artifact, "field player PlayerId -"))
	testing.expect(t, artifact_has_line(artifact, "field pos Vec3 -"))
	testing.expect(t, artifact_has_line(artifact, "field intent Vec2 =Vec2(x=0,y=0)"))
	testing.expect(t, artifact_has_line(artifact, "field phase Fixed =0"))

	// The Field scene-holder thing: bare-named, no fields.
	testing.expect(t, artifact_has_line(artifact, "thing Field false 1 0"))

	// The §13 setup batch: two spawns in source-list order — one Krognid at the board
	// center (25.0 in raw Q32.32 is 107374182400) and the Field scene holder. The
	// Krognid carries the two source-supplied fields; the §6 field defaults fill the
	// rest at runtime spawn.
	testing.expect(t, artifact_has_line(artifact, "[setup 2]"))
	testing.expect(t, artifact_has_line(artifact, "spawn Krognid 2"))
	testing.expect(t, artifact_has_line(artifact, "set player =PlayerId::P1"))
	testing.expect(t, artifact_has_line(artifact, "set pos =Vec3(x=107374182400,y=0,z=107374182400)"))
	testing.expect(t, artifact_has_line(artifact, "spawn Field 0"))

	// The §15 entrypoint logical:160x120 draw space, lifted from the entrypoints.fcfg
	// `logical = 160x120` — the integer world-unit extent the present pass letterboxes.
	testing.expect(t, artifact_has_line(artifact, "entrypoint main pipeline:Stroll tick_hz:60 logical:160x120 bindings:bindings"))
}

// test_emit_krognid_matches_runtime_testdata is the cross-package byte seam: the
// freshly-emitted krognid artifact equals the committed runtime/testdata/krognid.
// artifact the runtime story #loads byte-for-byte. The committed copy is an emitter
// PRODUCT, so it must track the live emitter exactly — a divergence means the
// committed copy is stale and the runtime would #load bytes this emitter no longer
// produces. Mirrors the pong emit golden's committed-byte contract
// (golden_emit_test.odin), extended to the runtime-side copy. SKIPs loudly when the
// sibling source is absent (no emit to compare) but FAILS on a stale committed copy
// when both are present. FUNPACK_REGEN_GOLDEN=1 REWRITES the committed copy from the
// live emit — checked BEFORE the staged-bump skip, so a regen run can bootstrap the
// copy across a schema bump (the warren/dungeon regen-first mold). The ONE sanctioned
// divergence is a STAGED SCHEMA
// BUMP: when the committed copy's version stamp trails the emitter's
// ARTIFACT_SCHEMA_VERSION, the producer side has bumped first and the runtime-side
// reconcile (its own constant, restamps, and replay-hash regeneration — the v7
// precedent's runtime half) has not landed yet; the test then SKIPs loudly instead
// of failing, and the runtime-side bump restores full byte equality. A SAME-version
// divergence stays a hard failure — the staleness this seam exists to catch.
@(test)
test_emit_krognid_matches_runtime_testdata :: proc(t: ^testing.T) {
	emitted, ok := krognid_emit(t)
	if !ok {
		return
	}
	// The committed copy lives in the sibling runtime package's testdata; #directory
	// is funpack/, so runtime/testdata is ../runtime/testdata — resolved relative to
	// THIS package (the worktree copy), never the main checkout, so a worktree
	// validation run compares against the worktree's committed bytes.
	committed_path, _ := filepath.join({#directory, "..", "runtime", "testdata", "krognid.artifact"}, context.temp_allocator)
	if os.get_env("FUNPACK_REGEN_GOLDEN", context.temp_allocator) != "" {
		testing.expect(t, os.write_entire_file(committed_path, transmute([]u8)emitted) == nil)
		log.infof("REGEN krognid: wrote %s (%d bytes)", committed_path, len(emitted))
		return
	}
	committed_bytes, read_err := os.read_entire_file_from_path(committed_path, context.temp_allocator)
	if read_err != nil {
		log.warnf("SKIP krognid testdata match: committed %s unreadable", committed_path)
		return
	}
	committed := string(committed_bytes)
	if _, committed_version, stamp_ok := parse_version_stamp(line_around(committed, 0)); stamp_ok && committed_version < ARTIFACT_SCHEMA_VERSION {
		log.warnf(
			"SKIP krognid testdata match: committed runtime copy is stamped v%d while the emitter is at v%d — a staged schema bump; the runtime-side reconcile restamps its copy and restores this byte seam",
			committed_version,
			ARTIFACT_SCHEMA_VERSION,
		)
		return
	}
	testing.expect_value(t, len(emitted), len(committed))
	testing.expect(t, emitted == committed)
	if emitted != committed {
		report_first_byte_diff(emitted, committed)
		return
	}
	log.infof(
		"emit krognid: the live emitter reproduces the committed runtime/testdata/krognid.artifact byte-for-byte (%d bytes)",
		len(emitted),
	)
}
