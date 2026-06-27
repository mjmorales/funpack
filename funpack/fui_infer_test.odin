package funpack

import "core:testing"

HUD_FUI :: `screen Hud {
  row class="top-bar p-3 gap-4 bg-panel" {
    text class="font-bold" { "Score: {score}" }
    text class="ml-auto" { "{time_left}" }
    button class="btn" @click=Coin { "+1" }
    button class="btn" @click=Pause { "II" }
  }
  if game_over {
    col class="overlay center gap-3 bg-scrim" {
      text class="text-2xl" { "Game Over" }
      text { "You scored {score}" }
      button class="btn-primary" @click=Retry { "Play again" }
    }
  }
}`

PAUSE_FUI :: `screen Pause {
  col class="overlay center gap-3 bg-scrim" {
    text class="text-2xl" { "Paused" }
    button class="btn-primary" @click=Resume { "Resume" }
    button class="btn" @click=OpenSettings { "Settings" }
    button class="btn" @click=Quit { "Quit to title" }
  }
}`

SETTINGS_FUI :: `screen Settings {
  col class="panel p-4 gap-3" {
    text class="text-2xl" { "Settings" }
    field placeholder="name" bind:value=player_name
    slider min=0 max=100 bind:value=volume
    text { "Quick volume" }
    row class="gap-2" {
      for p in volume_presets {
        button class="btn" @click=SetVolume(p.value) { "{p.value}" }
      }
    }
    button class="btn" @click=Back { "Back" }
  }
}`

@(test)
test_infer_hud :: proc(t: ^testing.T) {
	screen, perr := parse_fui(HUD_FUI)
	testing.expect_value(t, perr, Fui_Parse_Error.None)
	seam := infer_seam(screen)
	testing.expect_value(t, seam.view_name, "HudView")
	testing.expect_value(t, seam.msg_name, "HudMsg")

	testing.expect_value(t, len(seam.view_fields), 3)
	expect_prim_field(t, seam.view_fields[0], "score", .Int)
	expect_prim_field(t, seam.view_fields[1], "time_left", .Int)
	expect_prim_field(t, seam.view_fields[2], "game_over", .Bool)

	testing.expect_value(t, len(seam.msg_variants), 3)
	expect_nullary_variant(t, seam.msg_variants[0], "Coin")
	expect_nullary_variant(t, seam.msg_variants[1], "Pause")
	expect_nullary_variant(t, seam.msg_variants[2], "Retry")

	testing.expect_value(t, len(seam.row_types), 0)
}

@(test)
test_infer_pause_empty_view :: proc(t: ^testing.T) {
	screen, perr := parse_fui(PAUSE_FUI)
	testing.expect_value(t, perr, Fui_Parse_Error.None)
	seam := infer_seam(screen)
	testing.expect_value(t, seam.view_name, "PauseView")

	testing.expect_value(t, len(seam.view_fields), 0)
	testing.expect_value(t, len(seam.row_types), 0)

	testing.expect_value(t, len(seam.msg_variants), 3)
	expect_nullary_variant(t, seam.msg_variants[0], "Resume")
	expect_nullary_variant(t, seam.msg_variants[1], "OpenSettings")
	expect_nullary_variant(t, seam.msg_variants[2], "Quit")
}

@(test)
test_infer_settings :: proc(t: ^testing.T) {
	screen, perr := parse_fui(SETTINGS_FUI)
	testing.expect_value(t, perr, Fui_Parse_Error.None)
	seam := infer_seam(screen)
	testing.expect_value(t, seam.view_name, "SettingsView")
	testing.expect_value(t, seam.msg_name, "SettingsMsg")

	testing.expect_value(t, len(seam.view_fields), 3)
	expect_prim_field(t, seam.view_fields[0], "player_name", .String)
	expect_prim_field(t, seam.view_fields[1], "volume", .Int)
	testing.expect_value(t, seam.view_fields[2].name, "volume_presets")
	list, is_list := seam.view_fields[2].type.(Fui_List)
	testing.expect(t, is_list, "volume_presets is a list field")
	testing.expect_value(t, list.row, "SettingsPresetRow")

	testing.expect_value(t, len(seam.msg_variants), 3)
	expect_payload_variant(t, seam.msg_variants[0], "SetPlayerName", .String)
	expect_payload_variant(t, seam.msg_variants[1], "SetVolume", .Int)
	expect_nullary_variant(t, seam.msg_variants[2], "Back")

	testing.expect_value(t, len(seam.row_types), 1)
	row := seam.row_types[0]
	testing.expect_value(t, row.name, "SettingsPresetRow")
	testing.expect_value(t, len(row.fields), 1)
	expect_prim_field(t, row.fields[0], "value", .Int)
}

@(test)
test_infer_setvolume_inferred_once :: proc(t: ^testing.T) {
	screen, perr := parse_fui(SETTINGS_FUI)
	testing.expect_value(t, perr, Fui_Parse_Error.None)
	seam := infer_seam(screen)

	count := 0
	for v in seam.msg_variants {
		if v.name == "SetVolume" {
			count += 1
			expect_payload_variant(t, v, "SetVolume", .Int)
		}
	}
	testing.expect_value(t, count, 1)
}

@(test)
test_infer_explicit_row_type_ascription :: proc(t: ^testing.T) {
	src := `screen Picker {
  col {
    for opt in difficulties : { id: Ref[Difficulty] } {
      button @click=Pick(opt.id) { "{opt.label}" }
    }
  }
}`
	screen, perr := parse_fui(src)
	testing.expect_value(t, perr, Fui_Parse_Error.None)
	seam := infer_seam(screen)

	testing.expect_value(t, len(seam.view_fields), 1)
	list, is_list := seam.view_fields[0].type.(Fui_List)
	testing.expect(t, is_list, "difficulties is a list field")
	testing.expect_value(t, list.row, "PickerDifficultyRow")

	testing.expect_value(t, len(seam.row_types), 1)
	row := seam.row_types[0]
	testing.expect_value(t, len(row.fields), 1)
	testing.expect_value(t, row.fields[0].name, "id")
	named, is_named := row.fields[0].type.(Fui_Named)
	testing.expect(t, is_named, "ascribed row field carries a Named type token")
	testing.expect_value(t, named.token, "Ref[Difficulty]")
}

expect_prim_field :: proc(t: ^testing.T, f: Fui_Field, name: string, prim: Fui_Prim) {
	testing.expect_value(t, f.name, name)
	p, ok := f.type.(Fui_Prim)
	testing.expect(t, ok, "field type is a primitive")
	testing.expect_value(t, p, prim)
}

expect_nullary_variant :: proc(t: ^testing.T, v: Fui_Variant, name: string) {
	testing.expect_value(t, v.name, name)
	testing.expect_value(t, v.has_payload, false)
}

expect_payload_variant :: proc(t: ^testing.T, v: Fui_Variant, name: string, prim: Fui_Prim) {
	testing.expect_value(t, v.name, name)
	testing.expect_value(t, v.has_payload, true)
	p, ok := v.payload.(Fui_Prim)
	testing.expect(t, ok, "variant payload is a primitive")
	testing.expect_value(t, p, prim)
}
