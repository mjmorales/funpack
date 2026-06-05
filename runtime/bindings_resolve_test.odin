// Bindings-resolution proof for the §23 input layer: the headless injected
// device-event queue folds through the artifact's bindings table into the
// device-free action snapshot, with the §23 §4 coalescing rules. The tests prove
// the four load-bearing behaviors — a W-down resolves Steer::Move to −1 for P1
// (S to +1); a tap (down then up within one window) still registers as pressed on
// a button action; stacked keyboard + stick bindings both contribute; the engine
// deadzone clamps a tiny stick sample to 0 and an out-of-range sample into
// [-1, 1] — and that pong's Steer::Move axis resolves to a fixed-point reading in
// [-1, 1] through input.value. Every assertion is in the device-free query
// vocabulary §23 §5 demands; raw device codes appear only on the producer side
// (the injected queue), never in a query.
package funpack_runtime

import "core:testing"

// steer_move_id mints the action registry from the loaded golden pong artifact and
// returns the ActionId for Steer::Move — the one Axis action pong binds. Resolving
// the id from the real artifact (not a hard-coded constant) is what proves the
// minting maps the artifact's enum variants onto the snapshot's keys.
@(private = "file")
steer_move_id :: proc(t: ^testing.T, registry: Action_Registry) -> (id: ActionId, ok: bool) {
	def, found := registry.by_name["Steer::Move"]
	if !testing.expect(t, found) {
		return {}, false
	}
	if !testing.expect_value(t, def.kind, Action_Kind.Axis) {
		return {}, false
	}
	return def.id, true
}

// button_program builds a synthetic Program with one Button-kinded action and one
// keyboard binding for it — pong binds no button action, so the button-coalescing
// path needs its own minimal fixture. P1.Fire is bound to key(Key::Space). The
// descriptor slices are allocated on the passed allocator (NOT slice literals,
// which are stack-temporary and garbage after the helper returns).
@(private = "file")
button_program :: proc(allocator := context.allocator) -> Program {
	variants := make([]Enum_Variant, 1, allocator)
	variants[0] = Enum_Variant{name = "Fire", payload = "unit"}
	enums := make([]Enum_Decl, 1, allocator)
	enums[0] = Enum_Decl{name = "Trigger", kind = .Button, variants = variants}
	bindings := make([]Binding, 1, allocator)
	bindings[0] = Binding {
		kind   = "button",
		player = "P1",
		action = "Trigger::Fire",
		source = "key(Key::Space)",
	}
	return Program{enums = enums, bindings = bindings}
}

// test_keys_axis_w_resolves_negative proves the load-bearing pong path: a W-down
// injected event resolves P1 Steer::Move to −1 through input.value, and an S-down
// resolves it to +1. keys_axis(Key::W, Key::S) is the §23 §3 digital axis — W is
// the neg key, S is the pos key — so the sign is fixed by the binding, not the
// device.
@(test)
test_keys_axis_w_resolves_negative :: proc(t: ^testing.T) {
	program, ok := load_golden(t)
	if !ok {
		return
	}
	table := build_bindings_table(program, IDENTITY_OVERLAY, context.temp_allocator)
	steer, sok := steer_move_id(t, table.registry)
	if !sok {
		return
	}

	prev := make(map[Player_Action]bool, context.temp_allocator)
	queue := new_device_queue(context.temp_allocator)

	// W down → P1 Steer::Move reads −1 (W is the negative key of keys_axis(W, S)).
	enqueue_key_down(&queue, "Key::W")
	snap_w, held_w := resolve_tick(table, &queue, prev, context.temp_allocator)
	defer delete_input(snap_w)
	testing.expect_value(t, value(snap_w, .P1, steer), fixed_neg(to_fixed(1)))

	// S down (W released) → P1 Steer::Move reads +1.
	enqueue_key_up(&queue, "Key::W")
	enqueue_key_down(&queue, "Key::S")
	snap_s, _ := resolve_tick(table, &queue, held_w, context.temp_allocator)
	defer delete_input(snap_s)
	testing.expect_value(t, value(snap_s, .P1, steer), to_fixed(1))
}

// test_pong_steer_move_in_unit_range proves AC-3: pong's Steer::Move axis
// resolves to a fixed-point value in [-1, 1] via input.value across the keys_axis
// and stick_y sources P1/P2 bind. The reading is always within the rail, and no
// Float ever reaches the query (the snapshot is Fixed-only).
@(test)
test_pong_steer_move_in_unit_range :: proc(t: ^testing.T) {
	program, ok := load_golden(t)
	if !ok {
		return
	}
	table := build_bindings_table(program, IDENTITY_OVERLAY, context.temp_allocator)
	steer, sok := steer_move_id(t, table.registry)
	if !sok {
		return
	}

	prev := make(map[Player_Action]bool, context.temp_allocator)
	queue := new_device_queue(context.temp_allocator)

	// P2 uses keys_axis(Up, Down) + stick_y(Stick::Left). Up down + a large stick
	// sample would push past −2; the resolver clamps the stacked sum to −1.
	enqueue_key_down(&queue, "Key::Up")
	enqueue_stick_sample(&queue, "Stick::Left", .Y, fixed_neg(to_fixed(5)))
	snap, _ := resolve_tick(table, &queue, prev, context.temp_allocator)
	defer delete_input(snap)

	v := value(snap, .P2, steer)
	// In [-1, 1]: not below −1, not above +1 (the clamp held).
	testing.expect(t, v >= fixed_neg(to_fixed(1)))
	testing.expect(t, v <= to_fixed(1))
	// Stacked Up (−1) + clamped stick (−1) sum to −2, clamped to −1.
	testing.expect_value(t, v, fixed_neg(to_fixed(1)))
}

// test_stacked_keyboard_and_stick_both_contribute proves §23 §3 stacking: P1
// Steer::Move binds keys_axis(W, S) AND stick_y(Stick::Left); a half-magnitude
// stick sample alone (no key) resolves through the stick source, proving the stick
// binding contributes independently of the keyboard one.
@(test)
test_stacked_keyboard_and_stick_both_contribute :: proc(t: ^testing.T) {
	program, ok := load_golden(t)
	if !ok {
		return
	}
	table := build_bindings_table(program, IDENTITY_OVERLAY, context.temp_allocator)
	steer, sok := steer_move_id(t, table.registry)
	if !sok {
		return
	}

	prev := make(map[Player_Action]bool, context.temp_allocator)
	queue := new_device_queue(context.temp_allocator)

	// Stick only, half magnitude (above the 0.1 deadzone) → the stick binding alone
	// drives the axis; no key is pressed.
	half := fixed_from_decimal(0, "5")
	enqueue_stick_sample(&queue, "Stick::Left", .Y, half)
	snap, _ := resolve_tick(table, &queue, prev, context.temp_allocator)
	defer delete_input(snap)
	testing.expect_value(t, value(snap, .P1, steer), half)
}

// test_deadzone_clamps_tiny_and_out_of_range proves §23 §4's engine deadzone and
// rail: a tiny stick sample inside the deadzone resolves to exactly 0, and an
// out-of-range sample is clamped into [-1, 1]. Both go through the stick_y(Left)
// source on P1's Steer::Move.
@(test)
test_deadzone_clamps_tiny_and_out_of_range :: proc(t: ^testing.T) {
	program, ok := load_golden(t)
	if !ok {
		return
	}
	table := build_bindings_table(program, IDENTITY_OVERLAY, context.temp_allocator)
	steer, sok := steer_move_id(t, table.registry)
	if !sok {
		return
	}

	prev := make(map[Player_Action]bool, context.temp_allocator)
	queue := new_device_queue(context.temp_allocator)

	// A tiny sample (0.05, below the 0.1 deadzone) → exactly 0.
	tiny := fixed_from_decimal(0, "05")
	enqueue_stick_sample(&queue, "Stick::Left", .Y, tiny)
	snap_tiny, held_tiny := resolve_tick(table, &queue, prev, context.temp_allocator)
	defer delete_input(snap_tiny)
	testing.expect_value(t, value(snap_tiny, .P1, steer), Fixed(0))

	// An out-of-range sample (+3) → clamped to +1.
	enqueue_stick_sample(&queue, "Stick::Left", .Y, to_fixed(3))
	snap_hi, _ := resolve_tick(table, &queue, held_tiny, context.temp_allocator)
	defer delete_input(snap_hi)
	testing.expect_value(t, value(snap_hi, .P1, steer), to_fixed(1))
}

// test_button_tap_within_window_registers_pressed proves §23 §4's coalescing: a
// button source that goes DOWN then UP within a single inter-tick window still
// registers as `pressed` (a tap between two ticks is not lost), and is not held at
// the tick instant. Uses the synthetic button fixture — pong binds no button.
@(test)
test_button_tap_within_window_registers_pressed :: proc(t: ^testing.T) {
	program := button_program(context.temp_allocator)
	table := build_bindings_table(program, IDENTITY_OVERLAY, context.temp_allocator)

	fire, found := table.registry.by_name["Trigger::Fire"]
	if !testing.expect(t, found) {
		return
	}

	prev := make(map[Player_Action]bool, context.temp_allocator)
	queue := new_device_queue(context.temp_allocator)

	// Down then up inside one window: pressed latches (the tap registered), held is
	// false (up at the tick instant).
	enqueue_key_down(&queue, "Key::Space")
	enqueue_key_up(&queue, "Key::Space")
	snap, _ := resolve_tick(table, &queue, prev, context.temp_allocator)
	defer delete_input(snap)
	testing.expect(t, pressed(snap, .P1, fire.id))
	testing.expect(t, !held(snap, .P1, fire.id))
}

// test_button_release_edge_after_hold proves the §23 §2 released edge: a button
// held into a tick, then released, reads `released` on the tick where it goes up —
// derived from prev_held, the level carried out of the prior tick.
@(test)
test_button_release_edge_after_hold :: proc(t: ^testing.T) {
	program := button_program(context.temp_allocator)
	table := build_bindings_table(program, IDENTITY_OVERLAY, context.temp_allocator)

	fire, found := table.registry.by_name["Trigger::Fire"]
	if !testing.expect(t, found) {
		return
	}

	prev := make(map[Player_Action]bool, context.temp_allocator)
	queue := new_device_queue(context.temp_allocator)

	// Tick 1: press and hold. pressed + held, not released.
	enqueue_key_down(&queue, "Key::Space")
	snap1, held1 := resolve_tick(table, &queue, prev, context.temp_allocator)
	defer delete_input(snap1)
	testing.expect(t, pressed(snap1, .P1, fire.id))
	testing.expect(t, held(snap1, .P1, fire.id))
	testing.expect(t, !released(snap1, .P1, fire.id))

	// Tick 2: release. released edge (was held, now up), not pressed, not held.
	enqueue_key_up(&queue, "Key::Space")
	snap2, _ := resolve_tick(table, &queue, held1, context.temp_allocator)
	defer delete_input(snap2)
	testing.expect(t, released(snap2, .P1, fire.id))
	testing.expect(t, !pressed(snap2, .P1, fire.id))
	testing.expect(t, !held(snap2, .P1, fire.id))
}

// test_action_registry_skips_non_input_enums proves the minting boundary: only
// Axis/Button enums become actions. The pong artifact declares Side (a plain enum,
// no role kind) and Steer (Axis) — Side contributes no ActionId, Steer::Move does.
@(test)
test_action_registry_skips_non_input_enums :: proc(t: ^testing.T) {
	program, ok := load_golden(t)
	if !ok {
		return
	}
	registry := build_action_registry(program, context.temp_allocator)
	// Steer::Move is registered (Axis)...
	_, has_steer := registry.by_name["Steer::Move"]
	testing.expect(t, has_steer)
	// ...Side::Left is NOT (a plain enum is not bindable).
	_, has_side := registry.by_name["Side::Left"]
	testing.expect(t, !has_side)
	// Exactly one action minted from pong's enums.
	testing.expect_value(t, len(registry.defs), 1)
}
