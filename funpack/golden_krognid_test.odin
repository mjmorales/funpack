// The byte-exact krognid rig-seam golden: a fresh bake of models/krognid.fpm —
// parsed (fpm_parser.odin), §16.7 rig-gated (fpm_rig_gates.odin), and projected to
// a Rig_Seam (fpm_emit.odin) — emitted through emit_rig_seam, must reproduce the
// committed exemplar funpack-spec/examples/krognid/gen/krognid.gen.fun
// byte-for-byte. A stale committed seam is a build error, never a counted test
// failure (the seam-compare harness contract, seam_compare.odin). Like the arena
// gen-emit golden (gen_emit_test.odin), it resolves the live exemplar through the
// capability reader (or FUNPACK_KROGNID_DIR) and SKIPs LOUDLY when the funpack-spec
// sibling is absent — a skipped golden is a warning, NEVER a pass.
//
// The "fresh bake" parses the live KROGNID_RIG source and projects it: the slot
// bindings, mesh handle names, and mirror are DERIVED from the parsed rig, so the
// proof pins the projection, not a hand-fed seam. The seam-header and digest @doc
// strings are bake metadata (the rest-pose digest's rest-bbox and post-mirror count
// are functions of the engine skeleton's rest geometry the frontend does not model)
// passed through from the committed exemplar's authored docs.
package funpack

import "core:log"
import "core:os"
import "core:path/filepath"
import "core:testing"

// KROGNID_DIR_DEFAULT_REL is the krognid exemplar tree's path relative to the main
// checkout root (one level up from this package), resolved through resolve_spec_dir
// so it survives an orchestrator task-worktree #directory infix.
KROGNID_DIR_DEFAULT_REL :: "../funpack-spec/examples/krognid"

// KROGNID_MODULE is the krognid rig's seam module/namespace: the rig's lowercase
// name, the prefix every bound mesh handle carries (`krognid_torso`) and the stem of
// the seam fn names (`krognid_skeleton` / `krognid_parts`).
KROGNID_MODULE :: "krognid"

// KROGNID_FILE_DOC / KROGNID_SKELETON_DOC / KROGNID_PARTS_DOC are the seam's
// authored @doc strings, carried verbatim from the committed exemplar. The digest
// in KROGNID_SKELETON_DOC is the §16.7 rest-pose fingerprint the engine bake
// computed over the humanoid skeleton's rest geometry (rest-bbox and the post-mirror
// part count are not frontend-derivable), so a faithful bake passes it through. The
// em-dash is the exemplar's literal UTF-8 em-dash, kept so the byte comparison
// exercises multibyte content.
KROGNID_FILE_DOC :: "Generated rig seam for Krognid, baked from models/krognid.fpm: the bone skeleton and the part-to-slot mesh bindings the gameplay imports as the krognid module. Edit the .fpm script and re-bake, not this file."
KROGNID_SKELETON_DOC :: "Bone topology for Krognid: a standard humanoid skeleton. Generated from krognid.fpm — edit the script, not this file. Digest: 16 bones, 6 parts (11 after mirror), pivots verified, rest-bbox 24x20x68."
KROGNID_PARTS_DOC :: "Part meshes bound to bone slots. Left limbs are mirrored to the right at attach time. Generated from krognid.fpm."

// krognid_fresh_bake parses the live krognid.fpm source, gates it, and projects the
// resulting rig unit onto the Rig_Seam the emitter renders — the deterministic
// "fresh bake" whose bytes the committed seam must equal. It asserts the source
// parses and passes the §16.7 rig gates (a malformed or rig-gate-failing source is
// not a bakeable seam), then projects with the exemplar's authored docs.
krognid_fresh_bake :: proc(t: ^testing.T, allocator := context.allocator) -> Rig_Seam {
	unit, parse_err := fpm_parse(fpm_lex(KROGNID_RIG))
	testing.expect_value(t, parse_err, Fpm_Parse_Error.None)
	verdict := fpm_rig_verdict(unit)
	testing.expect_value(t, verdict.err, Fpm_Rig_Error.None)
	return rig_seam_of_unit(unit, KROGNID_MODULE, KROGNID_FILE_DOC, KROGNID_SKELETON_DOC, KROGNID_PARTS_DOC, allocator)
}

// resolve_krognid_dir resolves the krognid exemplar tree: the FUNPACK_KROGNID_DIR
// env override when set, else the sibling-checkout default anchored at the main
// checkout root (resolve_spec_dir handles the worktree infix). The path points at
// the tree root, not the gen/ file — the committed seam is found through the
// capability reader.
resolve_krognid_dir :: proc() -> string {
	return resolve_spec_dir("FUNPACK_KROGNID_DIR", KROGNID_DIR_DEFAULT_REL)
}

// krognid_committed_seam_path resolves the krognid exemplar tree, reads its §14.4
// capabilities, and joins the single expected gen/ output against the tree root —
// the committed seam path the golden diffs against. ok = false (with a LOUD SKIP
// warning) when the sibling checkout is absent or the tree does not derive exactly
// the one models seam, so a missing checkout never silently passes. This drives the
// SAME capability reader the bake pipeline uses (models/krognid.fpm =>
// gen/krognid.gen.fun), not a hard-coded gen/ path.
krognid_committed_seam_path :: proc(t: ^testing.T) -> (path: string, ok: bool) {
	dir := resolve_krognid_dir()
	if !os.is_dir(dir) {
		log.warnf(
			"SKIP krognid golden: %s not found — set FUNPACK_KROGNID_DIR or check out funpack-spec as a sibling of the repo",
			dir,
		)
		return "", false
	}
	project, read_err := read_project(dir)
	if read_err != .None {
		log.warnf("SKIP krognid golden: krognid tree at %s did not read (%v)", dir, read_err)
		return "", false
	}
	// The krognid tree has exactly one ON subsystem (models) expecting one seam.
	if !project.capabilities.models || len(project.capabilities.expected_gen_out) != 1 {
		log.warnf(
			"SKIP krognid golden: krognid capabilities unexpected (models=%v, %d expected gen outputs)",
			project.capabilities.models,
			len(project.capabilities.expected_gen_out),
		)
		return "", false
	}
	committed, _ := filepath.join({dir, project.capabilities.expected_gen_out[0]}, context.temp_allocator)
	return committed, true
}

// test_krognid_golden_byte_exact is the load-bearing acceptance: a fresh bake of
// models/krognid.fpm, emitted through emit_rig_seam, reproduces the committed
// krognid.gen.fun exemplar byte-for-byte. A diff in any byte — a doc character (the
// multibyte em-dash), an import member, a slot-alignment space, a mesh name, the
// trailing newline — fails here. The committed path is found through the capability
// reader (models/krognid.fpm => gen/krognid.gen.fun). SKIPs loudly when the sibling
// is absent (a skipped golden is not a pass).
@(test)
test_krognid_golden_byte_exact :: proc(t: ^testing.T) {
	committed_path, ok := krognid_committed_seam_path(t)
	if !ok {
		return
	}
	golden_bytes, read_err := os.read_entire_file_from_path(committed_path, context.temp_allocator)
	if read_err != nil {
		log.warnf("SKIP krognid golden: committed seam %s unreadable", committed_path)
		return
	}
	golden := string(golden_bytes)

	emitted := emit_rig_seam(krognid_fresh_bake(t, context.temp_allocator), context.temp_allocator)

	testing.expect_value(t, len(emitted), len(golden))
	testing.expect(t, emitted == golden)
	if emitted != golden {
		report_first_byte_diff(emitted, golden)
		return
	}
	// odin test echoes a name only on failure; announce the match so a passing run
	// leaves a trace the acceptance gate can read.
	log.infof("krognid golden: krognid.gen.fun reproduces the exemplar byte-for-byte (%d bytes)", len(emitted))
}

// test_krognid_seam_compare_stale proves the stale arm through the shared
// seam-compare harness: a fresh bake with a single byte flipped no longer matches
// the committed seam, so compare_seam returns Stale_Seam — a build error, not a
// test failure. The mutation is to the EMITTED string (the committed exemplar on
// disk is never touched), modeling a source change the committed seam was not
// re-baked for. SKIPs loudly when the sibling is absent.
@(test)
test_krognid_seam_compare_stale :: proc(t: ^testing.T) {
	committed_path, ok := krognid_committed_seam_path(t)
	if !ok {
		return
	}
	emitted := emit_rig_seam(krognid_fresh_bake(t, context.temp_allocator), context.temp_allocator)
	mutated := mutate_first_byte(emitted, context.temp_allocator)
	testing.expect(t, mutated != emitted)

	result := compare_seam(mutated, committed_path)
	testing.expect_value(t, result, Seam_Compare_Error.Stale_Seam)

	committed_bytes, read_err := os.read_entire_file_from_path(committed_path, context.temp_allocator)
	testing.expect(t, read_err == nil)
	if read_err == nil {
		testing.expect_value(t, first_byte_diff_index(mutated, string(committed_bytes)), 0)
	}
	if result == .Stale_Seam {
		log.infof("krognid seam compare: byte-mutated bake diverges from committed krognid.gen.fun at byte 0 (Stale_Seam)")
	}
}

// test_krognid_seam_compare_none proves the matching arm through the shared
// harness: the fresh bake's bytes equal the committed seam, so compare_seam returns
// None (the committed seam is current). Pairs with the stale arm to pin both sides
// of the harness verdict over the krognid exemplar. SKIPs loudly when absent.
@(test)
test_krognid_seam_compare_none :: proc(t: ^testing.T) {
	committed_path, ok := krognid_committed_seam_path(t)
	if !ok {
		return
	}
	emitted := emit_rig_seam(krognid_fresh_bake(t, context.temp_allocator), context.temp_allocator)
	result := compare_seam(emitted, committed_path)
	testing.expect_value(t, result, Seam_Compare_Error.None)
	if result != .None {
		committed_bytes, cerr := os.read_entire_file_from_path(committed_path, context.temp_allocator)
		if cerr == nil {
			report_first_byte_diff(emitted, string(committed_bytes))
		}
	}
}

// test_krognid_double_emit_identical proves emission is deterministic (spec §09,
// §29): two bakes of the same source emit byte-identical bytes, so the seam carries
// no field whose value depends on when, where, or on which machine it was baked.
// Self-contained — no golden checkout needed (the source is the in-repo fixture).
@(test)
test_krognid_double_emit_identical :: proc(t: ^testing.T) {
	first := emit_rig_seam(krognid_fresh_bake(t, context.temp_allocator), context.temp_allocator)
	second := emit_rig_seam(krognid_fresh_bake(t, context.temp_allocator), context.temp_allocator)
	testing.expect(t, first == second)
	testing.expect_value(t, len(first), len(second))
	if first == second {
		log.infof("krognid double emit: two krognid bakes are byte-identical (deterministic emit, %d bytes)", len(first))
	}
}

// test_krognid_seam_projection_derives_slots pins the projection's derived shape
// independent of the golden checkout: the fresh bake binds exactly the six parts in
// declaration order, each to its bone's PascalCase Slot and module-namespaced mesh
// handle, and ends in the L->R mirror. Self-contained, so the projection's
// slot/mesh/mirror derivation is fixed even when the sibling is absent.
@(test)
test_krognid_seam_projection_derives_slots :: proc(t: ^testing.T) {
	seam := krognid_fresh_bake(t, context.temp_allocator)
	testing.expect_value(t, seam.skeleton.name, "krognid_skeleton")
	testing.expect_value(t, seam.skeleton.factory, "humanoid")
	testing.expect_value(t, seam.parts.name, "krognid_parts")
	testing.expect_value(t, len(seam.parts.binds), 6)
	expected := [6]Rig_Slot_Bind {
		{slot = "Torso", mesh = "krognid_torso"},
		{slot = "Head", mesh = "krognid_head"},
		{slot = "LUpperArm", mesh = "krognid_upper_arm"},
		{slot = "LLowerArm", mesh = "krognid_lower_arm"},
		{slot = "LUpperLeg", mesh = "krognid_upper_leg"},
		{slot = "LLowerLeg", mesh = "krognid_lower_leg"},
	}
	for want, i in expected {
		if i >= len(seam.parts.binds) {
			break
		}
		testing.expect_value(t, seam.parts.binds[i].slot, want.slot)
		testing.expect_value(t, seam.parts.binds[i].mesh, want.mesh)
	}
	testing.expect(t, seam.parts.has_mirror, "krognid binds end in a mirror")
	testing.expect_value(t, seam.parts.mirror.from, "L")
	testing.expect_value(t, seam.parts.mirror.to, "R")
}

// test_resolve_krognid_dir_is_absolute keeps the exemplar resolver honest: the
// resolved path is absolute, so a bare `odin test .` from any cwd and a worktree
// validation run resolve the same sibling tree.
@(test)
test_resolve_krognid_dir_is_absolute :: proc(t: ^testing.T) {
	testing.expect(t, filepath.is_abs(resolve_krognid_dir()))
}
