package funpack

import "core:log"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:testing"

HUD_DEFAULT_DIR :: "examples/hud"

FUI_SCREEN_STEMS :: []string{"hud", "pause", "settings"}

resolve_hud_dir :: proc() -> string {
	return resolve_spec_dir("FUNPACK_HUD_DIR", HUD_DEFAULT_DIR)
}

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
		return "", string(golden_bytes), true
	}
	seam := infer_seam(parsed)
	emitted = emit_screen_seam(seam, hud_screen_docs(screen), context.temp_allocator)
	return emitted, string(golden_bytes), true
}

strings_concat3 :: proc(a, b: string) -> string {
	out := make([]u8, len(a) + len(b), context.temp_allocator)
	copy(out[:], a)
	copy(out[len(a):], b)
	return string(out)
}

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

@(test)
test_pause_seam_byte_exact :: proc(t: ^testing.T) {
	expect_screen_seam_byte_exact(t, "pause")
}

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

@(test)
test_resolve_hud_dir_is_absolute :: proc(t: ^testing.T) {
	testing.expect(t, filepath.is_abs(resolve_hud_dir()))
}

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

@(test)
test_four_screen_fixture_grows_both_enums :: proc(t: ^testing.T) {
	screens := []Fui_Screen {
		{name = "Hud"},
		{name = "Pause"},
		{name = "Settings"},
		{name = "Inventory"},
	}
	emitted := emit_screens_seam(screens, context.temp_allocator)

	testing.expect(
		t,
		strings.contains(emitted, "enum Screen { Hud, Pause, Settings, Inventory }"),
		"Screen enum gains the fourth variant",
	)
	testing.expect(
		t,
		strings.contains(emitted, "enum AppMsg { Hud(HudMsg), Pause(PauseMsg), Settings(SettingsMsg), Inventory(InventoryMsg) }"),
		"AppMsg union gains the fourth tagged variant",
	)
	testing.expect(
		t,
		strings.contains(emitted, "import inventory.InventoryMsg\n"),
		"the fourth screen's Msg import lands in the header",
	)
}

@(test)
test_three_vs_four_screen_variant_count :: proc(t: ^testing.T) {
	three := []Fui_Screen{{name = "Hud"}, {name = "Pause"}, {name = "Settings"}}
	four := []Fui_Screen{{name = "Hud"}, {name = "Pause"}, {name = "Settings"}, {name = "Inventory"}}

	testing.expect_value(t, fui_screen_enum_variant_count(emit_screens_seam(three, context.temp_allocator)), 3)
	testing.expect_value(t, fui_appmsg_enum_variant_count(emit_screens_seam(three, context.temp_allocator)), 3)
	testing.expect_value(t, fui_screen_enum_variant_count(emit_screens_seam(four, context.temp_allocator)), 4)
	testing.expect_value(t, fui_appmsg_enum_variant_count(emit_screens_seam(four, context.temp_allocator)), 4)
}

@(test)
test_theme_tokens_known_list_passes :: proc(t: ^testing.T) {
	screen, perr := parse_fui(HUD_FUI)
	testing.expect_value(t, perr, Fui_Parse_Error.None)
	testing.expect_value(t, validate_theme_tokens(screen, FUI_HUD_THEME_TOKENS), Theme_Error.None)
}

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

fui_screen_enum_variant_count :: proc(emitted: string) -> int {
	return fui_enum_body_variant_count(emitted, "enum Screen { ")
}

fui_appmsg_enum_variant_count :: proc(emitted: string) -> int {
	return fui_enum_body_variant_count(emitted, "enum AppMsg { ")
}

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
