@doc("Generated UI seam for the Settings screen: its preset row, read contract, write contract, and view builder. Generated from ui/settings.fui — edit the template, not this file.")

import engine.prelude.{Int, String}
import engine.ui.View

@doc("A row of the volume_presets list. Its shape is inferred from the bindings the for-block uses (only p.value, an Int). Generated from settings.fui.")
data SettingsPresetRow { value: Int }

@doc("The read contract for the Settings screen. player_name and volume come from the bind: targets; volume_presets from the for-list.")
data SettingsView { player_name: String, volume: Int, volume_presets: [SettingsPresetRow] }

@doc("The write contract for the Settings screen. SetPlayerName/SetVolume are the two-way bind: lowerings; SetVolume is reused by the preset buttons.")
enum SettingsMsg { SetPlayerName(String), SetVolume(Int), Back }

@doc("Builds the Settings view tree from its view-model. Backed by settings.fui.")
extern fn settings(model: SettingsView) -> View[SettingsMsg]
