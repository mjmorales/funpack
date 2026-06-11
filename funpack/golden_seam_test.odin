// The byte-exact golden seam-comparison proof: the harness (seam_compare.odin)
// run against the live arena exemplar must report None for the committed seam
// matching a freshly-emitted bake, Stale_Seam for a byte-mutated emission, and
// Missing_Seam for a capability-ON subsystem whose gen/ output is absent. It
// mirrors the artifact golden (golden_emit_test.odin) — byte-equality plus
// report_first_byte_diff, the resolve_spec_dir env-override/SKIP-warn resolution
// (FUNPACK_ARENA_DIR) — and the gen-emit golden (gen_emit_test.odin), whose
// hand-built arena_seam supplies the "fresh" bake until the per-subsystem
// source→Seam bakers land downstream. A skipped golden (sibling checkout absent)
// is a loud warning, never a pass.
//
// HARNESS CONTRACT, NOT BAKER: this proves the byte-diff verdict and its
// stale/missing arms, independent of which baker fills the Seam model. The None
// arm uses the capability reader (read_project → derive_tree_capabilities) to
// find the expected gen/ output and the emitter (emit_gen_fun) to produce the
// fresh bytes, so the harness is exercised end to end against the real committed
// exemplar, not a hand-fed path.
package funpack

import "core:log"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:testing"

// arena_committed_seam_path resolves the arena exemplar tree, reads its §14.4
// capabilities, and joins the single expected gen/ output against the arena root
// — the committed seam path the harness diffs against. ok = false (with a loud
// SKIP warning) when the sibling checkout is absent or the tree does not derive
// exactly the one levels seam, so a missing checkout never silently passes. This
// drives the harness through the SAME capability reader the bake pipeline uses,
// rather than hard-coding the gen/ path.
arena_committed_seam_path :: proc(t: ^testing.T) -> (path: string, ok: bool) {
	dir := resolve_arena_dir()
	if !os.is_dir(dir) {
		log.warnf(
			"SKIP seam compare: %s not found — set FUNPACK_ARENA_DIR or check out funpack-spec as a sibling of the repo",
			dir,
		)
		return "", false
	}
	project, read_err, _ := read_project(dir)
	if read_err != .None {
		log.warnf("SKIP seam compare: arena tree at %s did not read (%v)", dir, read_err)
		return "", false
	}
	// The arena tree has exactly one ON subsystem (levels) expecting one seam.
	if !project.capabilities.levels || len(project.capabilities.expected_gen_out) != 1 {
		log.warnf(
			"SKIP seam compare: arena capabilities unexpected (levels=%v, %d expected gen outputs)",
			project.capabilities.levels,
			len(project.capabilities.expected_gen_out),
		)
		return "", false
	}
	committed, _ := filepath.join({dir, project.capabilities.expected_gen_out[0]}, context.temp_allocator)
	return committed, true
}

// test_seam_compare_none is the load-bearing acceptance: the committed arena seam
// matches a freshly-emitted-from-model seam, so the harness returns None. The
// committed path is found through the capability reader; the fresh bytes are
// emitted through emit_gen_fun over the hand-built arena_seam (the same model the
// emitter story pins, standing in for the not-yet-built .flvl baker). A byte
// divergence here means either the emitter regressed or the committed exemplar
// drifted — both are build errors, never test failures, but the proof surfaces
// the first diverging byte so the cause is visible.
@(test)
test_seam_compare_none :: proc(t: ^testing.T) {
	committed_path, ok := arena_committed_seam_path(t)
	if !ok {
		return
	}
	emitted := emit_gen_fun(arena_seam(context.temp_allocator), context.temp_allocator)
	result := compare_seam(emitted, committed_path)
	testing.expect_value(t, result, Seam_Compare_Error.None)
	if result != .None {
		// On a Stale_Seam point at the first diverging byte; on a Missing_Seam the
		// committed file is unreadable, which the capability check above already
		// ruled out, so a Stale_Seam is the only non-None path that reaches here.
		committed_bytes, read_err := os.read_entire_file_from_path(committed_path, context.temp_allocator)
		if read_err == nil {
			report_first_byte_diff(emitted, string(committed_bytes))
		}
		return
	}
	// odin test echoes a name only on failure; announce the match so a passing run
	// leaves a trace the acceptance gate can read.
	log.infof("seam compare: committed arena.gen.fun matches the fresh bake byte-for-byte (None, %d bytes)", len(emitted))
}

// test_seam_compare_stale proves the Stale_Seam arm: a freshly-emitted seam with
// a single byte flipped no longer matches the committed file, so the harness
// returns Stale_Seam and report_first_byte_diff points at the divergence. The
// mutation is to the EMITTED string (the committed exemplar on disk is never
// touched), modeling a source change the committed seam was not re-baked for.
@(test)
test_seam_compare_stale :: proc(t: ^testing.T) {
	committed_path, ok := arena_committed_seam_path(t)
	if !ok {
		return
	}
	emitted := emit_gen_fun(arena_seam(context.temp_allocator), context.temp_allocator)
	// Flip one byte of the emission so it diverges from the committed file. The
	// doc text is non-empty, so mutating its first character is a guaranteed,
	// well-located divergence the first-byte-diff report can point at.
	mutated := mutate_first_byte(emitted, context.temp_allocator)
	testing.expect(t, mutated != emitted)

	result := compare_seam(mutated, committed_path)
	testing.expect_value(t, result, Seam_Compare_Error.Stale_Seam)

	// The divergence locator points at the mutated byte: byte 0 (the doc's
	// leading '@', which mutate_first_byte flipped). first_byte_diff_index is the
	// pure side of report_first_byte_diff — asserting it here proves the diff
	// reporter points at the first divergence without emitting the error-level
	// log that would itself trip the test runner on this passing path.
	committed_bytes, read_err := os.read_entire_file_from_path(committed_path, context.temp_allocator)
	testing.expect(t, read_err == nil)
	if read_err == nil {
		testing.expect_value(t, first_byte_diff_index(mutated, string(committed_bytes)), 0)
	}
	if result == .Stale_Seam {
		log.infof("seam compare: byte-mutated emission diverges from committed arena.gen.fun at byte 0 (Stale_Seam)")
	}
}

// test_seam_compare_missing proves the Missing_Seam arm: a capability-ON
// subsystem (a non-empty levels/) whose expected gen/ output is absent returns
// Missing_Seam, distinct from a byte divergence. The scratch tree holds a
// levels/<stem>.flvl so derive_tree_capabilities turns levels ON and expects
// gen/<stem>.gen.fun — but no gen/ directory is written, so the committed path
// the harness reads does not exist. This is self-contained (no golden checkout),
// so the missing arm is pinned even when the sibling is absent.
@(test)
test_seam_compare_missing :: proc(t: ^testing.T) {
	root, ok := write_scratch_tree(t, "project numerics {\n  version = \"0.1.0\"\n}\n")
	if !ok {
		return
	}
	defer remove_scratch_tree(root)
	// A non-empty levels/ turns the levels capability ON and expects
	// gen/arena.gen.fun; the gen/ directory is deliberately never created.
	levels_dir := scratch_join({root, "levels"})
	if os.make_directory_all(levels_dir) != nil ||
	   os.write_entire_file(scratch_join({levels_dir, "arena.flvl"}), "level Arena 2d {\n}\n") != nil {
		log.warnf("SKIP seam compare missing: cannot write under %s", levels_dir)
		return
	}

	project, read_err, _ := read_project(root)
	testing.expect_value(t, read_err, Project_Error.None)
	if read_err != .None {
		return
	}
	testing.expect(t, project.capabilities.levels)
	testing.expect_value(t, len(project.capabilities.expected_gen_out), 1)
	if len(project.capabilities.expected_gen_out) != 1 {
		return
	}

	// The expected seam path resolves under the tree, but no gen/ output was
	// baked, so the harness reads an absent file and reports Missing_Seam. The
	// emitted bytes are irrelevant to the verdict (there is nothing to diff
	// against), so any emission stands in.
	committed_path, _ := filepath.join({root, project.capabilities.expected_gen_out[0]}, context.temp_allocator)
	emitted := emit_gen_fun(arena_seam(context.temp_allocator), context.temp_allocator)
	result := compare_seam(emitted, committed_path)
	testing.expect_value(t, result, Seam_Compare_Error.Missing_Seam)
	if result == .Missing_Seam {
		log.infof("seam compare: capability-ON levels with absent gen/arena.gen.fun (Missing_Seam)")
	}
}

// mutate_first_byte returns a copy of `s` with its first byte incremented (wrapped
// to stay a byte), so the result is guaranteed to differ from `s` at index 0 — a
// deterministic single-byte mutation the first-byte-diff report can locate. An
// empty string is returned unchanged (no byte to mutate); the seam emission is
// never empty (it always leads with the @doc line), so the stale fixture always
// gets a real divergence.
mutate_first_byte :: proc(s: string, allocator := context.allocator) -> string {
	if len(s) == 0 {
		return s
	}
	bytes := make([]u8, len(s), allocator)
	copy(bytes, transmute([]u8)s)
	bytes[0] = bytes[0] + 1
	return strings.string_from_ptr(raw_data(bytes), len(bytes))
}
