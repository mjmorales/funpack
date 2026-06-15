@doc("Generated UI seam for the Hud screen: its read contract, write contract, and view builder. Generated from ui/hud.fui — edit the template, not this file.")

import engine.prelude.{Int, Bool}
import engine.ui.View

@doc("The read contract for the Hud screen: every value its template binds. Generated from hud.fui — edit the template, not this file.")
data HudView { score: Int, time_left: Int, game_over: Bool }

@doc("The write contract for the Hud screen: every message its template can emit.")
enum HudMsg { Coin, Pause, Retry }

@doc("Builds the Hud view tree from its view-model. Backed by hud.fui.")
extern fn hud(model: HudView) -> View[HudMsg]
