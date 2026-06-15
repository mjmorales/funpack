@doc("Generated navigation seam: the set of screens and the app message union over them. Generated from the .fui files — adding a screen extends these enums.")

import hud.HudMsg
import pause.PauseMsg
import settings.SettingsMsg

@doc("Every screen in the app. Generated from the set of .fui files; navigation is just setting this value in state, so the route table cannot drift from the screens that exist.")
enum Screen { Hud, Pause, Settings }

@doc("The app message union: each screen's messages, tagged by screen. The mount lifts a child screen's Msg into this with View.map; the update unwraps and delegates. Adding a screen extends this enum, so the update's match stops compiling until the new screen is handled.")
enum AppMsg { Hud(HudMsg), Pause(PauseMsg), Settings(SettingsMsg) }
