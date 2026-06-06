// The §21 §2 UI-seam golden: each committed example screen
// (funpack-spec/examples/hud/ui/{hud,settings,pause}.fui) is parsed, inferred, and
// emitted through emit_screen_seam, and the bytes must reproduce the committed seam
// funpack-spec/examples/hud/gen/{hud,settings,pause}.gen.fun EXACTLY. Like the
// arena seam golden (gen_emit_test.odin), the fixture resolves the sibling checkout
// (or FUNPACK_HUD_DIR) and SKIPs loudly when it is absent — a skipped golden is a
// warning, never a pass — and report_first_byte_diff locates any divergence.
//
// The @doc prose each screen carries is bake metadata the template does not encode
// (the flvl/fpm seams carry their docs the same way), so the committed doc strings
// are pinned here per screen as the Screen_Seam_Docs the emitter stamps. The em-dash
// in the hud/settings/pause file docs is the exemplars' literal UTF-8 em-dash, kept
// verbatim so the byte comparison exercises multibyte content. The empty PauseView
// {} no-reads seam is the load-bearing edge: its read contract is empty, it carries
// no engine.prelude import, and the seam must still byte-match.
package funpack

import "core:log"
import "core:os"
import "core:path/filepath"
import "core:testing"

// HUD_DEFAULT_DIR is the committed example UI tree relative to the main checkout
// root, resolved through resolve_spec_dir so it survives an orchestrator
// task-worktree #directory (the worktree infix is stripped, anchoring at the real
// checkout).
HUD_DEFAULT_DIR :: "../funpack-spec/examples/hud"

// resolve_hud_dir resolves the committed hud example tree: the FUNPACK_HUD_DIR env
// override when set, else the sibling-checkout default anchored at the main checkout
// root. The path points at the example directory holding ui/ and gen/.
resolve_hud_dir :: proc() -> string {
	return resolve_spec_dir("FUNPACK_HUD_DIR", HUD_DEFAULT_DIR)
}

// hud_screen_docs returns the committed Screen_Seam_Docs for a screen by name — the
// authored @doc prose pinned from the committed gen/<screen>.gen.fun exemplar. The
// docs are bake metadata the template does not encode, so a faithful bake passes
// them through; an unknown screen returns the zero docs (and the byte match would
// fail, surfacing the gap).
hud_screen_docs :: proc(screen: string) -> Screen_Seam_Docs {
	switch screen {
	case "hud":
		return Screen_Seam_Docs {
			file    = "Generated UI seam for the Hud screen: its read contract, write contract, and view builder. Generated from ui/hud.fui — edit the template, not this file.",
			view    = "The read contract for the Hud screen: every value its template binds. Generated from hud.fui — edit the template, not this file.",
			msg     = "The write contract for the Hud screen: every message its template can emit.",
			builder = "Builds the Hud view tree from its view-model. Backed by hud.fui.",
		}
	case "settings":
		return Screen_Seam_Docs {
			file    = "Generated UI seam for the Settings screen: its preset row, read contract, write contract, and view builder. Generated from ui/settings.fui — edit the template, not this file.",
			row     = "A row of the volume_presets list. Its shape is inferred from the bindings the for-block uses (only p.value, an Int). Generated from settings.fui.",
			view    = "The read contract for the Settings screen. player_name and volume come from the bind: targets; volume_presets from the for-list.",
			msg     = "The write contract for the Settings screen. SetPlayerName/SetVolume are the two-way bind: lowerings; SetVolume is reused by the preset buttons.",
			builder = "Builds the Settings view tree from its view-model. Backed by settings.fui.",
		}
	case "pause":
		return Screen_Seam_Docs {
			file    = "Generated UI seam for the Pause screen: its read contract, write contract, and view builder. Generated from ui/pause.fui — edit the template, not this file.",
			view    = "The read contract for the Pause screen: it binds nothing, so the view-model is empty. Generated from pause.fui.",
			msg     = "The write contract for the Pause screen.",
			builder = "Builds the Pause view tree. Backed by pause.fui.",
		}
	}
	return Screen_Seam_Docs{}
}

// emit_committed_screen_seam reads, parses, infers, and emits one committed screen's
// seam: it reads ui/<screen>.fui from the resolved hud tree, parses+infers it, and
// emits through emit_screen_seam with the screen's pinned docs. ok = false (with a
// SKIP warning) when the sibling checkout is absent, matching the pong golden's skip
// semantics. The emitted bytes back into context.temp_allocator.
emit_committed_screen_seam :: proc(screen: string) -> (emitted: string, golden: string, ok: bool) {
	dir := resolve_hud_dir()
	if !os.is_dir(dir) {
		log.warnf(
			"SKIP golden hud-seam: %s not found — set FUNPACK_HUD_DIR or check out funpack-spec as a sibling of the repo",
			dir,
		)
		return "", "", false
	}
	fui_path, _ := filepath.join({dir, "ui", strings_concat3(screen, ".fui")}, context.temp_allocator)
	gen_path, _ := filepath.join({dir, "gen", strings_concat3(screen, ".gen.fun")}, context.temp_allocator)

	fui_bytes, fui_err := os.read_entire_file_from_path(fui_path, context.temp_allocator)
	if fui_err != nil {
		log.warnf("SKIP golden hud-seam: %s not readable", fui_path)
		return "", "", false
	}
	golden_bytes, gen_err := os.read_entire_file_from_path(gen_path, context.temp_allocator)
	if gen_err != nil {
		log.warnf("SKIP golden hud-seam: %s not readable", gen_path)
		return "", "", false
	}

	parsed, parse_err := parse_fui(string(fui_bytes))
	if parse_err != .None {
		// A parse failure on a committed example is a real defect, not a skip — let
		// the byte comparison surface it as an empty-vs-golden mismatch.
		return "", string(golden_bytes), true
	}
	seam := infer_seam(parsed)
	emitted = emit_screen_seam(seam, hud_screen_docs(screen), context.temp_allocator)
	return emitted, string(golden_bytes), true
}

// strings_concat3 joins two parts into a temp-allocated string — the small two-part
// concat the path joins use to form `<screen>.fui` / `<screen>.gen.fun` without a
// strings.Builder.
strings_concat3 :: proc(a, b: string) -> string {
	out := make([]u8, len(a) + len(b), context.temp_allocator)
	copy(out[:], a)
	copy(out[len(a):], b)
	return string(out)
}

// expect_screen_seam_byte_exact is the shared per-screen acceptance: the committed
// screen's emitted seam reproduces its committed gen/<screen>.gen.fun exemplar
// byte-for-byte. A diff in any byte — a doc character, an import member, a field
// type, the empty-view braces, the trailing newline — fails here, with
// report_first_byte_diff locating it. SKIPs loudly when the sibling is absent.
expect_screen_seam_byte_exact :: proc(t: ^testing.T, screen: string) {
	emitted, golden, ok := emit_committed_screen_seam(screen)
	if !ok {
		return
	}
	testing.expect_value(t, len(emitted), len(golden))
	testing.expect(t, emitted == golden)
	if emitted != golden {
		report_first_byte_diff(emitted, golden)
		return
	}
	// odin test echoes a name only on failure, so announce the byte match so a
	// passing run leaves a trace the acceptance gate can read.
	log.infof("hud-seam golden: %s.gen.fun reproduces the exemplar byte-for-byte (%d bytes)", screen, len(emitted))
}

@(test)
test_hud_seam_byte_exact :: proc(t: ^testing.T) {
	expect_screen_seam_byte_exact(t, "hud")
}

@(test)
test_settings_seam_byte_exact :: proc(t: ^testing.T) {
	expect_screen_seam_byte_exact(t, "settings")
}

// test_pause_seam_byte_exact pins the empty-view edge: Pause binds nothing, so its
// seam carries an empty `data PauseView {}`, no engine.prelude import, and still
// byte-matches the committed pause.gen.fun. A spurious field, a dangling prelude
// import, or `data PauseView { }` (inner spaces) would all fail the byte match.
@(test)
test_pause_seam_byte_exact :: proc(t: ^testing.T) {
	expect_screen_seam_byte_exact(t, "pause")
}

// test_screen_seam_double_emit_identical proves emission is deterministic (spec §09,
// §29): two emissions of the same Inferred_Seam are byte-identical, so the seam
// bytes carry no field whose value depends on when, where, or on which machine they
// were emitted — the §29 determinism tripwire is that field/variant/import ordering
// is template order, never map order. Settings exercises every form (a row record,
// a list field, a payload enum variant, a brace-list import). SKIPs loudly when the
// sibling is absent.
@(test)
test_screen_seam_double_emit_identical :: proc(t: ^testing.T) {
	dir := resolve_hud_dir()
	if !os.is_dir(dir) {
		log.warnf("SKIP golden hud-seam double-emit: %s not found", dir)
		return
	}
	fui_path, _ := filepath.join({dir, "ui", "settings.fui"}, context.temp_allocator)
	fui_bytes, fui_err := os.read_entire_file_from_path(fui_path, context.temp_allocator)
	if fui_err != nil {
		log.warnf("SKIP golden hud-seam double-emit: %s not readable", fui_path)
		return
	}
	parsed, parse_err := parse_fui(string(fui_bytes))
	testing.expect_value(t, parse_err, Fui_Parse_Error.None)
	seam := infer_seam(parsed)
	docs := hud_screen_docs("settings")
	first := emit_screen_seam(seam, docs, context.temp_allocator)
	second := emit_screen_seam(seam, docs, context.temp_allocator)
	testing.expect(t, first == second)
	testing.expect_value(t, len(first), len(second))
	if first == second {
		log.infof("hud-seam double emit: two settings seam emissions are byte-identical (deterministic emit, %d bytes)", len(first))
	}
}

// test_resolve_hud_dir_is_absolute keeps the exemplar resolver honest: the resolved
// path is absolute (so a bare `odin test .` from any cwd, and a worktree validation
// run, resolve the same sibling tree).
@(test)
test_resolve_hud_dir_is_absolute :: proc(t: ^testing.T) {
	testing.expect(t, filepath.is_abs(resolve_hud_dir()))
}
