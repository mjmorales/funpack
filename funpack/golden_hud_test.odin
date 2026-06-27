package funpack

import "core:testing"

HUD_DEMO_SOURCE :: `import engine.prelude.{Int, Bool, String, Option}
import engine.math.{max, to_fixed}
import engine.core.Time
import engine.world.Spawn
import engine.ui.{View, map}
import engine.audio.{Sound, Audio, Bus}
import engine.assets.sound
import engine.list.get

data HudView { score: Int, time_left: Int, game_over: Bool }
enum HudMsg { Coin, Pause, Retry }
extern fn hud(model: HudView) -> View[HudMsg]

data PauseView {}
enum PauseMsg { Resume, OpenSettings, Quit }
extern fn pause(model: PauseView) -> View[PauseMsg]

data SettingsPresetRow { value: Int }
data SettingsView { player_name: String, volume: Int, volume_presets: [SettingsPresetRow] }
enum SettingsMsg { SetPlayerName(String), SetVolume(Int), Back }
extern fn settings(model: SettingsView) -> View[SettingsMsg]

enum Screen { Hud, Pause, Settings }
enum AppMsg { Hud(HudMsg), Pause(PauseMsg), Settings(SettingsMsg) }

thing App {
  screen:      Screen = Screen::Hud
  score:       Int    = 0
  clock:       Int    = 60
  paused:      Bool   = false
  game_over:   Bool   = false
  player_name: String = "Glorbo"
  volume:      Int    = 80
}

fn hud_view(self: App) -> HudView {
  return HudView{ score: self.score, time_left: self.clock, game_over: self.game_over }
}

fn pause_view(self: App) -> PauseView {
  return PauseView{}
}

fn settings_view(self: App) -> SettingsView {
  return SettingsView{
    player_name: self.player_name,
    volume: self.volume,
    volume_presets: [
      SettingsPresetRow{ value: 0 },
      SettingsPresetRow{ value: 50 },
      SettingsPresetRow{ value: 100 }
    ]
  }
}

fn on_hud(self: App, msg: HudMsg) -> App {
  return match msg {
    HudMsg::Coin  => self with { score: self.score + 1 }
    HudMsg::Pause => self with { screen: Screen::Pause, paused: true }
    HudMsg::Retry => App{}
  }
}

fn on_pause(self: App, msg: PauseMsg) -> App {
  return match msg {
    PauseMsg::Resume       => self with { screen: Screen::Hud, paused: false }
    PauseMsg::OpenSettings => self with { screen: Screen::Settings }
    PauseMsg::Quit         => App{}
  }
}

fn on_settings(self: App, msg: SettingsMsg) -> App {
  return match msg {
    SettingsMsg::SetPlayerName(name) => self with { player_name: name }
    SettingsMsg::SetVolume(v)        => self with { volume: v }
    SettingsMsg::Back                => self with { screen: Screen::Pause }
  }
}

fn route(self: App, msg: AppMsg) -> App {
  return match msg {
    AppMsg::Hud(m)      => on_hud(self, m)
    AppMsg::Pause(m)    => on_pause(self, m)
    AppMsg::Settings(m) => on_settings(self, m)
  }
}

fn click_sfx(msg: AppMsg) -> [Sound] {
  return match msg {
    AppMsg::Hud(HudMsg::Coin) => [Sound.sfx(sound("coin")).bus(Bus::Ui)]
    _                         => [Sound.sfx(sound("click")).bus(Bus::Ui)]
  }
}

behavior on_msg on App {
  fn step(self: App, msg: AppMsg) -> (App, [Sound]) {
    return (route(self, msg), click_sfx(msg))
  }
}

behavior music on App {
  fn step(self: App) -> [Audio] {
    let clip = match self.screen {
      Screen::Hud      => "bgm_play"
      Screen::Pause    => "bgm_menu"
      Screen::Settings => "bgm_menu"
    }
    return [Audio.track("music", sound(clip)).gain(to_fixed(self.volume) / 100.0).bus(Bus::Music)]
  }
}

behavior tick_clock on App {
  fn step(self: App, time: Time) -> App {
    if self.paused or self.game_over { return self }
    let next = max(self.clock - 1, 0)
    return self with { clock: next, game_over: next == 0 }
  }
}

behavior view on App {
  fn step(self: App) -> View[AppMsg] {
    return match self.screen {
      Screen::Hud      => hud(self.hud_view()).map(AppMsg::Hud)
      Screen::Pause    => pause(self.pause_view()).map(AppMsg::Pause)
      Screen::Settings => settings(self.settings_view()).map(AppMsg::Settings)
    }
  }
}

test "hud coin adds a point" {
  let a = on_hud(App{}, HudMsg::Coin)
  assert a.score == 1
  assert a.screen == Screen::Hud
}

test "hud pause opens the pause screen" {
  let a = on_hud(App{}, HudMsg::Pause)
  assert a.screen == Screen::Pause
  assert a.paused
}

test "settings volume message updates state" {
  assert on_settings(App{}, SettingsMsg::SetVolume(50)).volume == 50
}

test "settings back returns to pause" {
  assert on_settings(App{}, SettingsMsg::Back).screen == Screen::Pause
}

test "settings projection lists the volume presets" {
  assert get(App{}.settings_view().volume_presets, 1) == Option::Some(SettingsPresetRow{value: 50})
}

test "pause view is empty" {
  assert App{}.pause_view() == PauseView{}
}

test "tick_clock counts down while playing" {
  assert tick_clock.step(App{clock: 10}, Time.at(0.016)).clock == 9
}

test "tick_clock is frozen while paused" {
  assert tick_clock.step(App{clock: 10, paused: true}, Time.at(0.016)).clock == 10
}

test "coin interaction plays the coin sound" {
  assert click_sfx(AppMsg::Hud(HudMsg::Coin)) == [Sound.sfx(sound("coin")).bus(Bus::Ui)]
}

test "pause swaps the music clip under a stable key" {
  assert music.step(App{screen: Screen::Pause, volume: 100}) == [Audio.track("music", sound("bgm_menu")).gain(1.0).bus(Bus::Music)]
}
`

HUD_DEMO_ASSERT_COUNT :: 12

@(test)
test_hud_demo_inline_tests_all_pass :: proc(t: ^testing.T) {
	report, err := run_test_pipeline(HUD_DEMO_SOURCE)
	testing.expect_value(t, err, Pipeline_Error.None)
	testing.expect_value(t, report.passed, HUD_DEMO_ASSERT_COUNT)
	testing.expect_value(t, report.failed, 0)
	testing.expect_value(t, report.exit_code, 0)
}

@(test)
test_engine_ui_surface_resolves_all_names :: proc(t: ^testing.T) {
	source := "import engine.ui.{View, UiAction, Theme, text, button, image, spacer, panel, row, col, grid, stack, scroll, icon, field, slider, toggle, select, class, when, map}\n"
	ast, parse_err := stage_parse(stage_lex(source))
	testing.expect_value(t, parse_err, Parse_Error.None)
	bindings, err := resolve_imports(ast)
	testing.expect_value(t, err, Type_Error.None)
	if err != .None {
		return
	}

	expectations := []Surface_Expectation {
		{"View", "engine.world", .Type_Name},
		{"map", "engine.list", .Func},
		{"UiAction", "engine.ui", .Type_Name},
		{"Theme", "engine.ui", .Type_Name},
		{"text", "engine.ui", .Func},
		{"button", "engine.ui", .Func},
		{"image", "engine.ui", .Func},
		{"spacer", "engine.ui", .Func},
		{"panel", "engine.ui", .Func},
		{"row", "engine.ui", .Func},
		{"col", "engine.ui", .Func},
		{"grid", "engine.ui", .Func},
		{"stack", "engine.ui", .Func},
		{"scroll", "engine.ui", .Func},
		{"icon", "engine.ui", .Func},
		{"field", "engine.ui", .Func},
		{"slider", "engine.ui", .Func},
		{"toggle", "engine.ui", .Func},
		{"select", "engine.ui", .Func},
		{"class", "engine.ui", .Func},
		{"when", "engine.ui", .Func},
	}
	for want in expectations {
		binding, bound := bindings.names[want.name]
		testing.expectf(t, bound, "%s did not bind", want.name)
		testing.expect_value(t, binding.module, want.module)
		testing.expect_value(t, binding.kind, want.kind)
	}
}

@(test)
test_engine_ui_unknown_member_rejects :: proc(t: ^testing.T) {
	source := "import engine.ui.{View, dropdown}\n"
	ast, parse_err := stage_parse(stage_lex(source))
	testing.expect_value(t, parse_err, Parse_Error.None)
	_, err := resolve_imports(ast)
	testing.expect_value(t, err, Type_Error.Unknown_Member)
}

@(test)
test_engine_audio_surface_resolves_all_names :: proc(t: ^testing.T) {
	source := "import engine.audio.{Sound, Audio, Bus}\n"
	ast, parse_err := stage_parse(stage_lex(source))
	testing.expect_value(t, parse_err, Parse_Error.None)
	bindings, err := resolve_imports(ast)
	testing.expect_value(t, err, Type_Error.None)
	if err != .None {
		return
	}

	expectations := []Surface_Expectation {
		{"Sound", "engine.audio", .Type_Name},
		{"Audio", "engine.audio", .Type_Name},
		{"Bus", "engine.audio", .Type_Name},
	}
	for want in expectations {
		binding, bound := bindings.names[want.name]
		testing.expectf(t, bound, "%s did not bind", want.name)
		testing.expect_value(t, binding.module, want.module)
		testing.expect_value(t, binding.kind, want.kind)
	}
}

@(test)
test_engine_audio_unknown_member_rejects :: proc(t: ^testing.T) {
	source := "import engine.audio.{Sound, Mixer}\n"
	ast, parse_err := stage_parse(stage_lex(source))
	testing.expect_value(t, parse_err, Parse_Error.None)
	_, err := resolve_imports(ast)
	testing.expect_value(t, err, Type_Error.Unknown_Member)
}
