@doc("A tiny arcade demo with three screens — HUD, pause menu, settings — wired only through the generated .fui seams. Exercises every UI binding kind, routing as plain state, one-shot interaction sounds, and a continuous music bed.")

import engine.prelude.{Int, Bool, String, Option, to_fixed}
import engine.input.Bindings
import engine.math.max
import engine.core.Time
import engine.world.Spawn
import engine.ui.{View, map}
import engine.audio.{Sound, Audio, Bus}
import engine.assets.sound
import engine.list.get
import hud.{HudView, HudMsg, hud}
import pause.{PauseView, PauseMsg, pause}
import settings.{SettingsView, SettingsPresetRow, SettingsMsg, settings}
import screens.{Screen, AppMsg}

@doc("The whole demo state: the active screen plus every value the three screens read. Navigation is the `screen` field; there is no separate router.")
@gtag("ui")
thing App {
  screen:      Screen = Screen::Hud
  score:       Int    = 0
  clock:       Int    = 60
  paused:      Bool   = false
  game_over:   Bool   = false
  player_name: String = "Glorbo"
  volume:      Int    = 80
}

@doc("Projects state into the Hud read contract. Pure; trivially testable.")
fn hud_view(self: App) -> HudView {
  return HudView{ score: self.score, time_left: self.clock, game_over: self.game_over }
}

@doc("The Pause screen reads nothing, so its view-model is the empty value.")
fn pause_view(self: App) -> PauseView {
  return PauseView{}
}

@doc("Projects state into the Settings read contract, including the quick-volume presets.")
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

@doc("Handles the Hud's messages. Coin scores; Pause routes to the pause screen; Retry resets.")
fn on_hud(self: App, msg: HudMsg) -> App {
  return match msg {
    HudMsg::Coin  => self with { score: self.score + 1 }
    HudMsg::Pause => self with { screen: Screen::Pause, paused: true }
    HudMsg::Retry => App{}
  }
}

@doc("Handles the Pause menu's messages — each one is a navigation.")
fn on_pause(self: App, msg: PauseMsg) -> App {
  return match msg {
    PauseMsg::Resume       => self with { screen: Screen::Hud, paused: false }
    PauseMsg::OpenSettings => self with { screen: Screen::Settings }
    PauseMsg::Quit         => App{}
  }
}

@doc("Handles the Settings messages: the two-way binds and the Back navigation.")
fn on_settings(self: App, msg: SettingsMsg) -> App {
  return match msg {
    SettingsMsg::SetPlayerName(name) => self with { player_name: name }
    SettingsMsg::SetVolume(v)        => self with { volume: v }
    SettingsMsg::Back                => self with { screen: Screen::Pause }
  }
}

@doc("Applies a UI message to app state: unwrap the screen tag and delegate. The pure, sound-free transition. Exhaustive over the generated union.")
fn route(self: App, msg: AppMsg) -> App {
  return match msg {
    AppMsg::Hud(m)      => on_hud(self, m)
    AppMsg::Pause(m)    => on_pause(self, m)
    AppMsg::Settings(m) => on_settings(self, m)
  }
}

@doc("A one-shot interaction sound: a coin chime for scoring, a click for everything else.")
fn click_sfx(msg: AppMsg) -> [Sound] {
  return match msg {
    AppMsg::Hud(HudMsg::Coin) => [Sound.sfx(sound("coin")).bus(Bus::Ui)]
    _                         => [Sound.sfx(sound("click")).bus(Bus::Ui)]
  }
}

@doc("Routes a UI message and plays its one-shot interaction sound. The [Sound] return is a fire-and-forget command.")
@gtag("ui")
behavior on_msg on App {
  fn step(self: App, msg: AppMsg) -> (App, [Sound]) {
    return (route(self, msg), click_sfx(msg))
  }
}

@doc("The continuous music bed: one keyed track whose clip follows the active screen (the engine crossfades on change) and whose gain follows the settings volume. No mixer to mutate — the desired gain is part of the projection.")
@gtag("audio")
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

@doc("Counts the clock down while playing; ends the game at zero.")
@gtag("clock")
behavior tick_clock on App {
  fn step(self: App, time: Time) -> App {
    if self.paused or self.game_over { return self }
    let next = max(self.clock - 1, 0)
    return self with { clock: next, game_over: next == 0 }
  }
}

@doc("Mounts the active screen, lifting each screen's messages into the AppMsg union.")
@gtag("ui")
behavior view on App {
  fn step(self: App) -> View[AppMsg] {
    return match self.screen {
      Screen::Hud      => hud(self.hud_view()).map(AppMsg::Hud)
      Screen::Pause    => pause(self.pause_view()).map(AppMsg::Pause)
      Screen::Settings => settings(self.settings_view()).map(AppMsg::Settings)
    }
  }
}

@doc("No device-driven input: every interaction arrives as a routed UI message through the generated seams, so the bindings table is empty.")
@gtag("input")
fn bindings() -> Bindings {
  return Bindings.empty()
}

@doc("Spawns the single App thing.")
@gtag("startup")
fn setup() -> [Spawn] {
  return [Spawn( App{} )]
}

@doc("A tiny arcade loop with a HUD, pause menu, and settings — every UI binding kind, wired only through the generated seam.")
@gtag("game")
pipeline Arcade {
  startup: [setup]
  input:   [on_msg]
  update:  [tick_clock]
  ui:      [view]
  audio:   [music]
}

@doc("The coin button scores a point and stays on the HUD.")
test "hud coin adds a point" {
  let a = on_hud(App{}, HudMsg::Coin)
  assert a.score == 1
  assert a.screen == Screen::Hud
}

@doc("Pausing routes to the pause screen and freezes the clock.")
test "hud pause opens the pause screen" {
  let a = on_hud(App{}, HudMsg::Pause)
  assert a.screen == Screen::Pause
  assert a.paused
}

@doc("The two-way volume bind — and the preset buttons that reuse its message — both set volume.")
test "settings volume message updates state" {
  assert on_settings(App{}, SettingsMsg::SetVolume(50)).volume == 50
}

@doc("Navigation is plain state: Settings Back returns to the pause screen.")
test "settings back returns to pause" {
  assert on_settings(App{}, SettingsMsg::Back).screen == Screen::Pause
}

@doc("The Settings projection emits one preset row per quick-volume value.")
test "settings projection lists the volume presets" {
  assert get(App{}.settings_view().volume_presets, 1) == Option::Some(SettingsPresetRow{value: 50})
}

@doc("The Pause view-model is empty and constant — the no-reads edge case.")
test "pause view is empty" {
  assert App{}.pause_view() == PauseView{}
}

@doc("The clock counts down each tick while playing.")
test "tick_clock counts down while playing" {
  assert tick_clock.step(App{clock: 10}, Time.at(0.016)).clock == 9
}

@doc("A paused game does not advance the clock.")
test "tick_clock is frozen while paused" {
  assert tick_clock.step(App{clock: 10, paused: true}, Time.at(0.016)).clock == 10
}

@doc("Scoring plays the coin chime; the one-shot is a plain command, asserted directly.")
test "coin interaction plays the coin sound" {
  assert click_sfx(AppMsg::Hud(HudMsg::Coin)) == [Sound.sfx(sound("coin")).bus(Bus::Ui)]
}

@doc("The music bed keeps one stable key while the clip follows the screen, so the engine crossfades; gain tracks the volume.")
test "pause swaps the music clip under a stable key" {
  assert music.step(App{screen: Screen::Pause, volume: 100}) == [Audio.track("music", sound("bgm_menu")).gain(1.0).bus(Bus::Music)]
}
