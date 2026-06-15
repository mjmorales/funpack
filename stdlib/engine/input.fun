@doc("Device-agnostic input. Logic queries semantic actions (an Axis or Button you declare), never a physical key — devices live only in the one bindings function. Input is a recorded per-tick snapshot, so replays are device-independent.")

import engine.prelude.{Fixed, Bool}
import engine.math.{Vec2}

@doc("The role kind for an enum of analog actions (e.g. Move, Strafe). Ascription-only — written after the colon, enum Drive: Axis { Strafe, Forward }, never imported as a member.")
extern type Axis

@doc("The role kind for an enum of digital actions (e.g. Jump, Fire). Ascription-only — written after the colon, enum Act: Button { Jump }, never imported as a member.")
extern type Button

@doc("A local player slot. Input is always queried per player.")
enum PlayerId { P1, P2, P3, P4 }

@doc("A physical key, used only inside bindings.")
enum Key { A, B, C, D, E, F, G, H, I, J, K, L, M, N, O, P, Q, R, S, T, U, V, W, X, Y, Z, Up, Down, Left, Right, Space, Enter, Escape, Shift, Tab }

@doc("A gamepad analog stick, used only inside bindings.")
enum Stick { Left, Right }

@doc("A gamepad digital button, used only inside bindings.")
enum PadButton { A, B, X, Y, Start, Back, LeftShoulder, RightShoulder, DpadUp, DpadDown, DpadLeft, DpadRight }

@doc("A mouse button, used only inside bindings.")
enum MouseButton { Left, Middle, Right }

@doc("The per-tick recorded input snapshot. A read-only resource.")
extern type Input

@doc("An axis-to-device mapping for one player. Built fluently, applied by the engine.")
extern type Bindings

@doc("A 1D axis source: two keys forming a -1..+1 axis (neg, pos). Read via value.")
extern fn keys_axis(neg: Key, pos: Key) -> AxisSource
@doc("A 1D axis source: the horizontal component of a stick. Read via value.")
extern fn stick_x(stick: Stick) -> AxisSource
@doc("A 1D axis source: the vertical component of a stick. Read via value.")
extern fn stick_y(stick: Stick) -> AxisSource
@doc("A 2D axis source: the WASD keys as a Vec2 (A/D drive x -/+, W/S drive y -/+, y-down). Read via axis.")
extern fn wasd() -> AxisSource
@doc("A 2D axis source: the arrow keys as a Vec2 — the only arrow-key 2D path, keys_axis is 1D. Read via axis.")
extern fn arrows() -> AxisSource
@doc("A 2D axis source: a full gamepad stick as a Vec2. Read via axis.")
extern fn stick(stick: Stick) -> AxisSource
@doc("A button source: a gamepad digital button. A single keyboard key is the [Key::W] list literal passed to .button, not a helper.")
extern fn pad(button: PadButton) -> ButtonSource
@doc("A button source: a mouse button.")
extern fn mouse(button: MouseButton) -> ButtonSource

@doc("An empty binding set to chain .axis / .button onto.")
extern fn empty() -> Bindings
@doc("Binds an analog action for a player to a device source. Multiple sources for one action are summed/clamped.")
extern fn axis(self: Bindings, player: PlayerId, action: Axis, source: AxisSource) -> Bindings
@doc("Binds a digital action for a player to a device source.")
extern fn button(self: Bindings, player: PlayerId, action: Button, source: ButtonSource) -> Bindings

@doc("Edge: whether a digital action went down this tick, coalesced over the window since the previous tick.")
extern fn pressed(self: Input, player: PlayerId, action: Button) -> Bool
@doc("Edge: whether a digital action went up this tick, coalesced over the window since the previous tick.")
extern fn released(self: Input, player: PlayerId, action: Button) -> Bool
@doc("Level: whether a digital action is down at the tick instant.")
extern fn held(self: Input, player: PlayerId, action: Button) -> Bool
@doc("The current value of a 1D analog action for a player, in -1..+1. Total.")
extern fn value(self: Input, player: PlayerId, action: Axis) -> Fixed
@doc("The current value of a 2D analog action for a player, each component in -1..+1. Total.")
extern fn axis(self: Input, player: PlayerId, action: Axis) -> Vec2

@doc("An Input double for tests: no actions active. Chain .with_pressed / .with_released / .with_held / .with_value / .with_axis to set values. Invoked Input.empty().")
extern fn empty() -> Input
@doc("Marks a digital action pressed (the down edge, and held) this tick on a test Input, returning the updated snapshot.")
extern fn with_pressed(self: Input, player: PlayerId, action: Button) -> Input
@doc("Marks a digital action released (the up edge) this tick on a test Input, clearing the held level — released implies not-held. Chained after with_pressed on the same action it produces the same-tick tap.")
extern fn with_released(self: Input, player: PlayerId, action: Button) -> Input
@doc("Marks a digital action held this tick on a test Input, without the pressed edge.")
extern fn with_held(self: Input, player: PlayerId, action: Button) -> Input
@doc("Sets an analog action's scalar value on a test Input, in -1..+1.")
extern fn with_value(self: Input, player: PlayerId, action: Axis, value: Fixed) -> Input
@doc("Sets a two-axis action's vector value on a test Input.")
extern fn with_axis(self: Input, player: PlayerId, action: Axis, value: Vec2) -> Input
