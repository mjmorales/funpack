// Input is the §23 read-only action snapshot — the ONLY source of
// nondeterminism a behavior observes (spec §23 §intro, §04 §1). A behavior
// queries semantic actions (Move, Fire, Steer), never a Key/Pad/Mouse: the
// device-agnostic action stream is what records, replays, and lockstep peers
// agree on. This file owns the device-free heart of that layer — the
// immutable per-tick snapshot value, the read-only query API behaviors call,
// and the producer surface that builds a snapshot in the same vocabulary
// (spec §23 §5: any producer is interchangeable with the live engine).
//
// BOUNDARY (spec §04 §1, §23 §intro): observing the world ⇔ taking an engine
// resource. Input is that resource, passed read-only into a behavior step —
// no Key/MouseButton/Pad type ever reaches sim code. This story owns the
// snapshot + query + producers ONLY. Reading devices, resolving bindings, and
// recording the replay log are separate layers that feed this same vocabulary.
// runtime/** must never import funpack/** — the artifact file is the only
// sanctioned coupling (spec §29, §09).
package funpack_runtime

import "core:slice"

// PlayerId is the §23 §1 per-player axis, always explicit (P1..P4) including
// in single player. Closed enum — the four hardware-player slots the input
// layer addresses, never more.
PlayerId :: enum {
	P1,
	P2,
	P3,
	P4,
}

// ActionId is the runtime-owned action identity the snapshot keys on. The
// artifact names an action by its enum variant (Steer::Move) and records the
// enum's role kind (Axis/Button) (artifact-format §5, §14); the artifact
// loader maps each (enum, variant) definition onto one stable ActionId. Keying
// generically by identity here — NOT by hard-coding pong's Steer/Move enums —
// is what keeps the snapshot independent of the artifact loader. A distinct
// u32 so a raw index can never be passed
// where an ActionId is meant.
ActionId :: distinct u32

// Vec2 is the minimal runtime-owned fixed-point vector the axis snapshot needs
// (spec §10: Vec2 is two transparent Fixed components, the Num kind). The full
// sim Vec2 math surface (length, normalize, dot) belongs to the world state
// layer; the input snapshot needs only the value and its zero, so this carries
// exactly that — no float ever (spec §23 §4, §09 §6).
Vec2 :: struct {
	x: Fixed,
	y: Fixed,
}

VEC2_ZERO :: Vec2{Fixed(0), Fixed(0)}

// Button_State is the digital edge/level record §23 §2 exposes through
// pressed/released/held. The three bits are coalesced over the window since
// the previous tick by bindings resolution (spec §23 §4); this layer stores and
// reads them as given. A never-touched action reads the all-false zero value,
// so the map's absence-default is exactly "action not seen this tick".
Button_State :: struct {
	pressed:  bool, // edge: went down this tick (§23 §2)
	released: bool, // edge: went up this tick (§23 §2)
	held:     bool, // level: down at the tick instant (§23 §2)
}

// Player_Action is the (player, action) composite the snapshot keys on. Both
// components are value types, so the key is a plain comparable struct — Odin
// hashes it directly, no custom hasher needed.
Player_Action :: struct {
	player: PlayerId,
	action: ActionId,
}

// Input is the immutable per-tick action snapshot (spec §23 §4). It is a value:
// every producer (with_*) returns a NEW Input over a cloned table, so the
// snapshot a behavior holds can never be mutated underneath it. The two tables
// are keyed by (player, action) — buttons carry edge/level bits, axes carry a
// clamped fixed-point Vec2 whose 1D reading is the x component (§23 §2). An
// action absent from a table reads its zero/false default, so an unqueried
// action and an explicitly-zero action are observably identical, as §23 §5
// demands of Input.empty().
Input :: struct {
	buttons: map[Player_Action]Button_State,
	axes:    map[Player_Action]Vec2,
}

// --- Producer surface (spec §23 §5) --------------------------------------
// The interchangeable vocabulary tests, replays, bots, and headless runs build
// snapshots with — the same names the live engine's recorder uses, so a test
// reads cleanly and never mentions a device.

// empty is the all-zero snapshot: every query returns its default (spec §23 §5
// Input.empty()). Allocates the two empty tables that with_* clone forward.
empty :: proc() -> Input {
	return Input{buttons = make(map[Player_Action]Button_State), axes = make(map[Player_Action]Vec2)}
}

// with_pressed marks a button down-this-tick for (player, action), returning a
// new snapshot. pressed implies held within the same tick (§23 §2: a press is
// also down at the tick instant), so this sets both bits — the invariant the
// tests assert.
with_pressed :: proc(input: Input, player: PlayerId, action: ActionId) -> Input {
	next := clone_input(input)
	key := Player_Action{player, action}
	state := next.buttons[key]
	state.pressed = true
	state.held = true
	next.buttons[key] = state
	return next
}

// with_held marks a button held (level: down at the tick instant) for
// (player, action) without asserting the press edge — the engine sets this for
// a button that was already down on the previous tick (spec §23 §2).
with_held :: proc(input: Input, player: PlayerId, action: ActionId) -> Input {
	next := clone_input(input)
	key := Player_Action{player, action}
	state := next.buttons[key]
	state.held = true
	next.buttons[key] = state
	return next
}

// with_value sets a 1D axis reading for (player, action), clamped into [-1, 1]
// on construction (spec §23 §4: analog values are engine-deadzoned and in
// range). The 1D value lives in the Vec2's x component (§23 §2: an Axis-kinded
// action reads either 1D via value or 2D via axis); y is left at zero so a
// later with_axis or a 2D read sees a consistent vector.
with_value :: proc(input: Input, player: PlayerId, action: ActionId, value: Fixed) -> Input {
	next := clone_input(input)
	key := Player_Action{player, action}
	vec := next.axes[key]
	vec.x = clamp_unit(value)
	next.axes[key] = vec
	return next
}

// with_axis sets a 2D axis reading for (player, action), each component clamped
// into [-1, 1] on construction (spec §23 §4). The whole Vec2 is replaced, so
// the 1D value (x) and the second component move together.
with_axis :: proc(input: Input, player: PlayerId, action: ActionId, axis: Vec2) -> Input {
	next := clone_input(input)
	key := Player_Action{player, action}
	next.axes[key] = Vec2{clamp_unit(axis.x), clamp_unit(axis.y)}
	return next
}

// --- Query API (the entire surface a behavior sees, spec §23 §2) ---------
// All five queries take a PlayerId so the per-player axis is always explicit
// (§23 §6). An action never written returns the zero/false default.

// pressed is the §23 §2 down-this-tick edge for a Button action.
pressed :: proc(input: Input, player: PlayerId, action: ActionId) -> bool {
	return input.buttons[Player_Action{player, action}].pressed
}

// released is the §23 §2 up-this-tick edge for a Button action.
released :: proc(input: Input, player: PlayerId, action: ActionId) -> bool {
	return input.buttons[Player_Action{player, action}].released
}

// held is the §23 §2 down-at-the-tick-instant level for a Button action.
held :: proc(input: Input, player: PlayerId, action: ActionId) -> bool {
	return input.buttons[Player_Action{player, action}].held
}

// value is the §23 §2 1D analog reading for an Axis action, a Fixed in [-1, 1].
// The 1D reading is the Vec2's x component (§23 §2); an unwritten axis reads
// zero (the map default).
value :: proc(input: Input, player: PlayerId, action: ActionId) -> Fixed {
	return input.axes[Player_Action{player, action}].x
}

// axis is the §23 §2 2D analog reading for an Axis action, each component in
// [-1, 1]. An unwritten axis reads VEC2_ZERO (the map default).
axis :: proc(input: Input, player: PlayerId, action: ActionId) -> Vec2 {
	return input.axes[Player_Action{player, action}]
}

// --- Internal helpers -----------------------------------------------------

// clamp_unit pins an analog reading into the §23 §4 [-1, 1] range on the
// fixed-point kernel — never a Float comparison (spec §23 §4, §09 §6). Reuses
// the kernel's fixed_clamp so the rail rule is defined in exactly one place.
@(private = "file")
clamp_unit :: proc(v: Fixed) -> Fixed {
	return fixed_clamp(v, fixed_neg(to_fixed(1)), to_fixed(1))
}

// clone_input materializes a fresh, independent snapshot from an existing one.
// Odin maps are reference types, so a bare struct copy would alias the tables
// and let a producer mutate the input it was handed; cloning both tables is
// what makes every with_* return a genuinely new immutable Input (spec §23 §5).
@(private = "file")
clone_input :: proc(input: Input) -> Input {
	out := empty()
	for key, state in input.buttons {
		out.buttons[key] = state
	}
	for key, vec in input.axes {
		out.axes[key] = vec
	}
	return out
}

// delete_input releases a snapshot's two tables. The producer chain leaks the
// intermediates it clones from by design (a built snapshot owns its tables);
// tests that build many snapshots call this to keep the leak-checked test
// allocator clean. Iteration-order-free — it frees, never reads order.
delete_input :: proc(input: Input) {
	snap := input
	delete(snap.buttons)
	delete(snap.axes)
}

// keys_of returns a snapshot's button keys in a stable, deterministic order.
// Map iteration order in Odin is unspecified; any code that must enumerate the
// snapshot (a recorder, a digest) sorts first so the byte output is identical
// run to run (spec §23 §4: the recorded snapshot is the determinism record).
// Provided here so the recorder keys on one canonical order.
keys_of :: proc(input: Input, allocator := context.allocator) -> []Player_Action {
	out := make([dynamic]Player_Action, 0, len(input.buttons) + len(input.axes), allocator)
	seen := make(map[Player_Action]bool, allocator = context.temp_allocator)
	for key in input.buttons {
		if !seen[key] {
			seen[key] = true
			append(&out, key)
		}
	}
	for key in input.axes {
		if !seen[key] {
			seen[key] = true
			append(&out, key)
		}
	}
	slice.sort_by(out[:], proc(a, b: Player_Action) -> bool {
		if a.player != b.player {
			return a.player < b.player
		}
		return a.action < b.action
	})
	return out[:]
}
