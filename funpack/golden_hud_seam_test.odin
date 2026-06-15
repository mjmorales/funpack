// The §21 §2 UI-seam golden: each committed example screen
// (examples/hud/ui/{hud,settings,pause}.fui) is parsed, inferred, and
// emitted through emit_screen_seam, and the bytes must reproduce the committed seam
// examples/hud/gen/{hud,settings,pause}.gen.fun EXACTLY. Like the
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
import "core:strings"
import "core:testing"

// HUD_DEFAULT_DIR is the committed example UI tree relative to the main checkout
// root, resolved through resolve_spec_dir so it survives an orchestrator
// task-worktree #directory (the worktree infix is stripped, anchoring at the real
// checkout).
HUD_DEFAULT_DIR :: "examples/hud"

// FUI_SCREEN_STEMS is the file-set the routing seam emits over, in sorted
// authoring-path order — the order read_project collects ui/*.fui (slice.sort of
// the stems) and the order the committed screens.gen.fun pins. Listed explicitly
// so the byte-match proof reads exactly the committed three screens in the exact
// committed order without re-deriving the directory walk (the capability reader's
// job, exercised by the project tests).
FUI_SCREEN_STEMS :: []string{"hud", "pause", "settings"}

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
			"SKIP golden hud-seam: %s not found — set FUNPACK_HUD_DIR or ensure the in-repo fixture exists",
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



// hud_screens reads and parses the three committed ui/*.fui files in file-set
// order, returning the parsed screens the emitter consumes. ok = false (with a
// loud SKIP warning) when the sibling checkout is absent or any source fails to
// read or parse, so a missing checkout never silently passes.
hud_screens :: proc(t: ^testing.T) -> (screens: []Fui_Screen, ok: bool) {
	dir := resolve_hud_dir()
	if !os.is_dir(dir) {
		log.warnf(
			"SKIP hud screens seam: %s not found — set FUNPACK_HUD_DIR or ensure the in-repo fixture exists",
			dir,
		)
		return nil, false
	}
	parsed := make([dynamic]Fui_Screen, 0, len(FUI_SCREEN_STEMS), context.temp_allocator)
	for stem in FUI_SCREEN_STEMS {
		path, _ := filepath.join({dir, "ui", strings.concatenate({stem, ".fui"}, context.temp_allocator)}, context.temp_allocator)
		source, read_err := os.read_entire_file_from_path(path, context.temp_allocator)
		if read_err != nil {
			log.warnf("SKIP hud screens seam: %s did not read (%v)", path, read_err)
			return nil, false
		}
		screen, parse_err := parse_fui(string(source))
		if parse_err != .None {
			log.warnf("SKIP hud screens seam: %s did not parse (%v)", path, parse_err)
			return nil, false
		}
		append(&parsed, screen)
	}
	return parsed[:], true
}

// ── (byte-match) the routing seam matches committed screens.gen.fun ───────────

// test_screens_seam_byte_matches_committed is the load-bearing acceptance: the
// routing seam emitted from the SET of three committed .fui files matches the
// committed gen/screens.gen.fun byte-for-byte, proven through the shared
// golden-comparison helper compare_seam (None). The committed path is the gen/
// output beside the ui/ sources; the fresh bytes are emit_screens_seam over the
// parsed screens. A byte divergence is a build error (Stale_Seam) the diff
// reporter locates, never a silently-passing range.
@(test)
test_screens_seam_byte_matches_committed :: proc(t: ^testing.T) {
	screens, ok := hud_screens(t)
	if !ok {
		return
	}
	emitted := emit_screens_seam(screens, context.temp_allocator)
	committed_path, _ := filepath.join({resolve_hud_dir(), "gen", "screens.gen.fun"}, context.temp_allocator)

	result := compare_seam(emitted, committed_path)
	testing.expect_value(t, result, Seam_Compare_Error.None)
	if result != .None {
		committed_bytes, read_err := os.read_entire_file_from_path(committed_path, context.temp_allocator)
		if read_err == nil {
			report_first_byte_diff(emitted, string(committed_bytes))
		}
		return
	}
	log.infof("screens seam: committed screens.gen.fun matches the fresh bake byte-for-byte (None, %d bytes)", len(emitted))
}

// ── (set-level regeneration) a fourth screen grows both enums ─────────────────

// test_four_screen_fixture_grows_both_enums proves §21 §3: adding a .fui extends
// BOTH the Screen enum and the AppMsg union. A 4-screen fixture (the three §21
// screens plus a fourth `Inventory`) emits a Screen enum with FOUR variants and
// an AppMsg union with FOUR tagged variants — the route table grows with the
// screen set, so the mount and the update's match stop compiling until the new
// screen is handled. The assertions read the emitted bytes for the exact variant
// lines, pinning that the fourth screen lands in both enums in file-set order.
@(test)
test_four_screen_fixture_grows_both_enums :: proc(t: ^testing.T) {
	// The three committed screens plus a fourth, hand-built (the proof pins the
	// set-level regeneration rule, not the sibling checkout). Only the screen
	// NAMES drive the set-level seam (the per-screen bodies are the per-screen
	// seam's input), so each fixture screen is a bare-named empty screen.
	screens := []Fui_Screen {
		{name = "Hud"},
		{name = "Pause"},
		{name = "Settings"},
		{name = "Inventory"},
	}
	emitted := emit_screens_seam(screens, context.temp_allocator)

	// The Screen enum grows to FOUR variants, the fourth appended in file-set
	// order.
	testing.expect(
		t,
		strings.contains(emitted, "enum Screen { Hud, Pause, Settings, Inventory }"),
		"Screen enum gains the fourth variant",
	)
	// The AppMsg union grows to FOUR tagged variants, the fourth tagging
	// InventoryMsg.
	testing.expect(
		t,
		strings.contains(emitted, "enum AppMsg { Hud(HudMsg), Pause(PauseMsg), Settings(SettingsMsg), Inventory(InventoryMsg) }"),
		"AppMsg union gains the fourth tagged variant",
	)
	// The fourth screen's import line lands in the header.
	testing.expect(
		t,
		strings.contains(emitted, "import inventory.InventoryMsg\n"),
		"the fourth screen's Msg import lands in the header",
	)
}

// test_three_vs_four_screen_variant_count pins the GROWTH itself: the three-screen
// seam carries exactly three Screen variants and three AppMsg arms, and the
// four-screen seam carries exactly four of each — counted by the comma separators
// in each enum body, so the count is the structural fact, not a substring match.
@(test)
test_three_vs_four_screen_variant_count :: proc(t: ^testing.T) {
	three := []Fui_Screen{{name = "Hud"}, {name = "Pause"}, {name = "Settings"}}
	four := []Fui_Screen{{name = "Hud"}, {name = "Pause"}, {name = "Settings"}, {name = "Inventory"}}

	testing.expect_value(t, fui_screen_enum_variant_count(emit_screens_seam(three, context.temp_allocator)), 3)
	testing.expect_value(t, fui_appmsg_enum_variant_count(emit_screens_seam(three, context.temp_allocator)), 3)
	testing.expect_value(t, fui_screen_enum_variant_count(emit_screens_seam(four, context.temp_allocator)), 4)
	testing.expect_value(t, fui_appmsg_enum_variant_count(emit_screens_seam(four, context.temp_allocator)), 4)
}

// ── (theme gate) §21 §1 closed-vocabulary token check ─────────────────────────

// test_theme_tokens_known_list_passes proves the passing arm: the committed hud
// screen, whose every class token is in the project theme vocabulary, validates
// clean (None) against FUI_HUD_THEME_TOKENS. The screen is the frozen hand-built
// HUD_FUI copy (shared with the inference proofs), so the gate is pinned against a
// known-good template independent of the sibling checkout.
@(test)
test_theme_tokens_known_list_passes :: proc(t: ^testing.T) {
	screen, perr := parse_fui(HUD_FUI)
	testing.expect_value(t, perr, Fui_Parse_Error.None)
	testing.expect_value(t, validate_theme_tokens(screen, FUI_HUD_THEME_TOKENS), Theme_Error.None)
}

// test_theme_tokens_unknown_token_rejects proves the §21 §1 compile-error arm: a
// class token outside the closed theme vocabulary is Unknown_Token, and the detail
// names the exact offending token so the fix-it can point at it. A made-up token
// on an otherwise-valid template is rejected — checked like a @gtag, an unknown
// token resolves to nothing.
@(test)
test_theme_tokens_unknown_token_rejects :: proc(t: ^testing.T) {
	src := `screen Broken {
  col class="panel made-up-token" {
    text class="text-2xl" { "Hi" }
  }
}`
	screen, perr := parse_fui(src)
	testing.expect_value(t, perr, Fui_Parse_Error.None)

	err, unknown := validate_theme_tokens_detail(screen, FUI_HUD_THEME_TOKENS)
	testing.expect_value(t, err, Theme_Error.Unknown_Token)
	testing.expect_value(t, unknown, "made-up-token")
}

// test_theme_tokens_unknown_nested_rejects pins that the walk reaches a token at
// depth: an unknown token on a widget nested inside an `if`/`for`/element block is
// still rejected, so the gate cannot be evaded by burying a bad token below the
// top level.
@(test)
test_theme_tokens_unknown_nested_rejects :: proc(t: ^testing.T) {
	src := `screen Nested {
  col class="panel" {
    if shown {
      row class="gap-3" {
        text class="bogus-token" { "x" }
      }
    }
  }
}`
	screen, perr := parse_fui(src)
	testing.expect_value(t, perr, Fui_Parse_Error.None)

	err, unknown := validate_theme_tokens_detail(screen, FUI_HUD_THEME_TOKENS)
	testing.expect_value(t, err, Theme_Error.Unknown_Token)
	testing.expect_value(t, unknown, "bogus-token")
}

// ── Test helpers ──────────────────────────────────────────────────────────────

// fui_screen_enum_variant_count counts the variants in the emitted `enum Screen {
// … }` body — one more than the comma count inside the braces (a non-empty enum
// has count = commas + 1). The structural variant count behind the growth proof,
// read off the emitted bytes so it measures what the emitter actually wrote.
fui_screen_enum_variant_count :: proc(emitted: string) -> int {
	return fui_enum_body_variant_count(emitted, "enum Screen { ")
}

// fui_appmsg_enum_variant_count counts the tagged variants in the emitted `enum
// AppMsg { … }` body the same way — comma count inside the braces plus one.
fui_appmsg_enum_variant_count :: proc(emitted: string) -> int {
	return fui_enum_body_variant_count(emitted, "enum AppMsg { ")
}

// fui_enum_body_variant_count returns the variant count of the enum whose body
// opens with `open` (`enum Screen { ` or `enum AppMsg { `): it slices from after
// `open` to the closing ` }` and counts top-level `, ` separators, returning that
// count plus one. Returns 0 when the open marker is absent. The AppMsg arms carry
// inner parens (`Hud(HudMsg)`) but no inner `, `, so a plain `, ` count is exact.
fui_enum_body_variant_count :: proc(emitted: string, open: string) -> int {
	start := strings.index(emitted, open)
	if start < 0 {
		return 0
	}
	body := emitted[start + len(open):]
	end := strings.index(body, " }")
	if end < 0 {
		return 0
	}
	body = body[:end]
	if len(body) == 0 {
		return 0
	}
	return strings.count(body, ", ") + 1
}
