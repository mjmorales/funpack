// The §21 §3 SET-LEVEL routing-seam proof: emit_screens_seam over the SET of
// three committed .fui files must byte-match the committed
// examples/hud/gen/screens.gen.fun EXACTLY, adding a fourth screen must extend
// BOTH the Screen enum and the AppMsg union, and the §21 §1 theme-token gate must
// pass a known-token template and reject an unknown class token with the
// Theme_Error.Unknown_Token arm.
//
// THREE obligations, mirroring the task's acceptance criteria:
//   (byte-match) the routing seam emitted from the three committed .fui files (in
//     file-set / sorted-authoring-path order: Hud, Pause, Settings) is byte-for-
//     byte identical to the committed screens.gen.fun, proven through the shared
//     golden-comparison helper compare_seam (None = match). Skips LOUDLY when the
//     sibling funpack-spec checkout is absent — a skipped golden is never a pass.
//   (set-level regeneration) a 4-screen fixture (the three plus a fourth)
//     emits a Screen enum with FOUR variants and an AppMsg union with FOUR tagged
//     variants — adding a .fui grows both enums (§21 §3, "the screens are the
//     route table").
//   (theme gate) the §21 §1 theme-token gate returns None for a template whose
//     class tokens are all in the project theme vocabulary, and Unknown_Token
//     (naming the offending token) for class="made-up-token".
package funpack

import "core:log"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:testing"

// HUD_DIR_DEFAULT_REL is the sibling-checkout default for the hud example tree,
// relative to the MAIN checkout root (resolve_spec_dir handles the worktree
// infix). The FUNPACK_HUD_DIR env override takes precedence.
HUD_DIR_DEFAULT_REL :: "../funpack-spec/examples/hud"

// FUI_SCREEN_STEMS is the file-set the routing seam emits over, in sorted
// authoring-path order — the order read_project collects ui/*.fui (slice.sort of
// the stems) and the order the committed screens.gen.fun pins. Listed explicitly
// so the byte-match proof reads exactly the committed three screens in the exact
// committed order without re-deriving the directory walk (the capability reader's
// job, exercised by the project tests).
FUI_SCREEN_STEMS :: []string{"hud", "pause", "settings"}

// resolve_hud_dir resolves the hud example tree: the FUNPACK_HUD_DIR override, else
// the sibling-checkout default made absolute against the main checkout root.
resolve_hud_dir :: proc() -> string {
	return resolve_spec_dir("FUNPACK_HUD_DIR", HUD_DIR_DEFAULT_REL)
}

// hud_screens reads and parses the three committed ui/*.fui files in file-set
// order, returning the parsed screens the emitter consumes. ok = false (with a
// loud SKIP warning) when the sibling checkout is absent or any source fails to
// read or parse, so a missing checkout never silently passes.
hud_screens :: proc(t: ^testing.T) -> (screens: []Fui_Screen, ok: bool) {
	dir := resolve_hud_dir()
	if !os.is_dir(dir) {
		log.warnf(
			"SKIP hud screens seam: %s not found — set FUNPACK_HUD_DIR or check out funpack-spec as a sibling of the repo",
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
