@doc("Retained-mode UI as data. A screen is a pure fn(viewmodel) -> View[Msg]: the Elm/React architecture, which is already funpack's functional core. Pointer events are routed by the engine into the screen's Msg signals, so user code never touches a raw cursor — the .fui template is the only device-aware UI surface, exactly as the bindings function is for gameplay input. View is generic over the screen's message type, so the read end (the viewmodel) and the write end (Msg) are both typed. Authoring is normally a .fui template that bakes to this surface (see spec/21-ui.md); these builders are the hand-authored escape hatch and the target the generated code lowers to.")

import engine.prelude.{Bool, Int, String}
import engine.assets.TextureHandle

@doc("A view subtree, generic over the screen's message type Msg. Immutable value; the engine diffs it.")
extern type View[Msg]

@doc("A text run. Build its content with interpolation (\"{m.score}\").")
extern fn text(content: String) -> View[Msg]
@doc("A button that emits a message when clicked.")
extern fn button(label: String, on_click: Msg) -> View[Msg]
@doc("An image from a texture handle.")
extern fn image(handle: TextureHandle) -> View[Msg]
@doc("A flexible empty cell that absorbs leftover space.")
extern fn spacer() -> View[Msg]

@doc("A neutral styled box; children stack vertically unless a class says otherwise.")
extern fn panel(children: [View[Msg]]) -> View[Msg]
@doc("A horizontal run of children (flex row).")
extern fn row(children: [View[Msg]]) -> View[Msg]
@doc("A vertical stack of children (flex column).")
extern fn col(children: [View[Msg]]) -> View[Msg]
@doc("A 2D grid; column count and gaps come from class tokens (cols-N, gap-N).")
extern fn grid(children: [View[Msg]]) -> View[Msg]
@doc("Layered children, back-to-front in list order — for overlays and modals.")
extern fn stack(children: [View[Msg]]) -> View[Msg]
@doc("A clipped, scrollable viewport around one child.")
extern fn scroll(child: View[Msg]) -> View[Msg]
@doc("A named theme icon.")
extern fn icon(name: String) -> View[Msg]

@doc("A single-line text field. on_input maps the new text to a message (the two-way bind: lowering).")
extern fn field(value: String, on_input: fn(String) -> Msg) -> View[Msg]
@doc("An integer slider over [min, max]. on_change maps the new value to a message.")
extern fn slider(value: Int, min: Int, max: Int, on_change: fn(Int) -> Msg) -> View[Msg]
@doc("A boolean toggle. on_change maps the new state to a message.")
extern fn toggle(on: Bool, on_change: fn(Bool) -> Msg) -> View[Msg]
@doc("One labelled option in a select, carrying a domain value the on_pick echoes back.")
data Choice[T] { label: String, value: T }

@doc("A one-of-many chooser; the option whose value equals chosen is highlighted. on_pick maps the picked value to a message.")
extern fn select(options: [Choice[T]], chosen: T, on_pick: fn(T) -> Msg) -> View[Msg]

@doc("Applies space-separated style tokens (validated against the project theme at bake; an unknown token is a compile error).")
extern fn class(self: View[Msg], tokens: String) -> View[Msg]
@doc("Shows the view only when cond holds; otherwise it occupies no space.")
extern fn when(self: View[Msg], cond: Bool) -> View[Msg]

@doc("Re-tags every message a view can emit through `into`, lifting a child screen's Msg into a parent's union. The Elm Html.map composition primitive — this is how a router mounts screens with different message types into one view.")
extern fn map(self: View[Msg], into: fn(Msg) -> Other) -> View[Other]

@doc("The engine-defined UI navigation actions, bound in the same bindings function as gameplay input (keyboard arrows, d-pad, stick all map here). The engine manages a deterministic focus cursor over the mounted view's focusable widgets in document order; Confirm on the focused widget emits that widget's @click message, so one binding is reachable by pointer, keyboard, and gamepad alike.")
enum UiAction: Button { NavUp, NavDown, NavLeft, NavRight, Confirm, Cancel }

@doc("The closed style-token vocabulary of a project, declared once and checked against every class=. Semantic roles, not raw values; swappable behind unchanged templates. See spec/21-ui.md.")
extern type Theme
