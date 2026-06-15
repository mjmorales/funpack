@doc("Generated UI seam for the Pause screen: its read contract, write contract, and view builder. Generated from ui/pause.fui — edit the template, not this file.")

import engine.ui.View

@doc("The read contract for the Pause screen: it binds nothing, so the view-model is empty. Generated from pause.fui.")
data PauseView {}

@doc("The write contract for the Pause screen.")
enum PauseMsg { Resume, OpenSettings, Quit }

@doc("Builds the Pause view tree. Backed by pause.fui.")
extern fn pause(model: PauseView) -> View[PauseMsg]
