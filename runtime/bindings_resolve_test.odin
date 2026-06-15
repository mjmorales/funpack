// Bindings-resolution proof for the §23 input layer: the headless injected
// device-event queue folds through the artifact's bindings table into the
// device-free action snapshot, with the §23 §4 coalescing rules. The tests prove
// the four load-bearing behaviors — a W-down resolves Steer::Move to −1 for P1
// (S to +1); a tap (down then up within one window) still registers as pressed on
// a button action; stacked keyboard + stick bindings both contribute; the engine
// deadzone clamps a tiny stick sample to 0 and an out-of-range sample into
// [-1, 1] — and that pong's Steer::Move axis resolves to a fixed-point reading in
// [-1, 1] through input.value. The §14 v3 2D forms get their own fixtures: a
// keys_quad drives each Vec2 component from its ratified key pair, a first-class
// stick(...) reads both deadzoned components, and stacked 2D sources sum then
// clamp per component through input.axis. Every assertion is in the device-free
// query vocabulary §23 §5 demands; raw device codes appear only on the producer
// side (the injected queue), never in a query.
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
	levels := new_device_levels(context.temp_allocator)
	queue := new_device_queue(context.temp_allocator)

	// W down → P1 Steer::Move reads −1 (W is the negative key of keys_axis(W, S)).
	enqueue_key_down(&queue, "Key::W")
	snap_w, held_w, levels_w := resolve_tick(table, &queue, prev, levels, context.temp_allocator)
	defer delete_input(snap_w)
	testing.expect_value(t, value(snap_w, .P1, steer), fixed_neg(to_fixed(1)))

	// S down (W released) → P1 Steer::Move reads +1.
	enqueue_key_up(&queue, "Key::W")
	enqueue_key_down(&queue, "Key::S")
	snap_s, _, _ := resolve_tick(table, &queue, held_w, levels_w, context.temp_allocator)
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
	levels := new_device_levels(context.temp_allocator)
	queue := new_device_queue(context.temp_allocator)

	// P2 uses keys_axis(Up, Down) + stick_y(Stick::Left). Up down + a large stick
	// sample would push past −2; the resolver clamps the stacked sum to −1.
	enqueue_key_down(&queue, "Key::Up")
	enqueue_stick_sample(&queue, "Stick::Left", .Y, fixed_neg(to_fixed(5)))
	snap, _, _ := resolve_tick(table, &queue, prev, levels, context.temp_allocator)
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
	levels := new_device_levels(context.temp_allocator)
	queue := new_device_queue(context.temp_allocator)

	// Stick only, half magnitude (above the 0.1 deadzone) → the stick binding alone
	// drives the axis; no key is pressed.
	half := fixed_from_decimal(0, "5")
	enqueue_stick_sample(&queue, "Stick::Left", .Y, half)
	snap, _, _ := resolve_tick(table, &queue, prev, levels, context.temp_allocator)
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
	levels := new_device_levels(context.temp_allocator)
	queue := new_device_queue(context.temp_allocator)

	// A tiny sample (0.05, below the 0.1 deadzone) → exactly 0.
	tiny := fixed_from_decimal(0, "05")
	enqueue_stick_sample(&queue, "Stick::Left", .Y, tiny)
	snap_tiny, held_tiny, levels_tiny := resolve_tick(table, &queue, prev, levels, context.temp_allocator)
	defer delete_input(snap_tiny)
	testing.expect_value(t, value(snap_tiny, .P1, steer), Fixed(0))

	// An out-of-range sample (+3) → clamped to +1.
	enqueue_stick_sample(&queue, "Stick::Left", .Y, to_fixed(3))
	snap_hi, _, _ := resolve_tick(table, &queue, held_tiny, levels_tiny, context.temp_allocator)
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
	levels := new_device_levels(context.temp_allocator)
	queue := new_device_queue(context.temp_allocator)

	// Down then up inside one window: pressed latches (the tap registered), held is
	// false (up at the tick instant).
	enqueue_key_down(&queue, "Key::Space")
	enqueue_key_up(&queue, "Key::Space")
	snap, _, _ := resolve_tick(table, &queue, prev, levels, context.temp_allocator)
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
	levels := new_device_levels(context.temp_allocator)
	queue := new_device_queue(context.temp_allocator)

	// Tick 1: press and hold. pressed + held, not released.
	enqueue_key_down(&queue, "Key::Space")
	snap1, held1, levels1 := resolve_tick(table, &queue, prev, levels, context.temp_allocator)
	defer delete_input(snap1)
	testing.expect(t, pressed(snap1, .P1, fire.id))
	testing.expect(t, held(snap1, .P1, fire.id))
	testing.expect(t, !released(snap1, .P1, fire.id))

	// Tick 2: release. released edge (was held, now up), not pressed, not held.
	enqueue_key_up(&queue, "Key::Space")
	snap2, _, _ := resolve_tick(table, &queue, held1, levels1, context.temp_allocator)
	defer delete_input(snap2)
	testing.expect(t, released(snap2, .P1, fire.id))
	testing.expect(t, !pressed(snap2, .P1, fire.id))
	testing.expect(t, !held(snap2, .P1, fire.id))
}

// test_held_key_persists_across_eventless_window proves §23 §4 LEVEL semantics for
// a button held across an EVENT-LESS window: a real device emits one KEYDOWN edge,
// then nothing while the key stays down. Window N injects the down; window N+1
// injects NOTHING. The action must still read `held` in window N+1 (the level
// persists), `pressed` only in window N (the edge is gone), and `released` in
// neither (no up edge yet). Threading the Device_Levels carrier is what survives
// the event-less window — without it the level would die after window N.
@(test)
test_held_key_persists_across_eventless_window :: proc(t: ^testing.T) {
	program := button_program(context.temp_allocator)
	table := build_bindings_table(program, IDENTITY_OVERLAY, context.temp_allocator)

	fire, found := table.registry.by_name["Trigger::Fire"]
	if !testing.expect(t, found) {
		return
	}

	prev := make(map[Player_Action]bool, context.temp_allocator)
	levels := new_device_levels(context.temp_allocator)
	queue := new_device_queue(context.temp_allocator)

	// Window N: key down — pressed + held, not released.
	enqueue_key_down(&queue, "Key::Space")
	snap_n, held_n, levels_n := resolve_tick(table, &queue, prev, levels, context.temp_allocator)
	defer delete_input(snap_n)
	testing.expect(t, pressed(snap_n, .P1, fire.id))
	testing.expect(t, held(snap_n, .P1, fire.id))
	testing.expect(t, !released(snap_n, .P1, fire.id))

	// Window N+1: NO events — the level persists, so still held, no new pressed edge,
	// and not released (no up edge happened).
	snap_n1, _, _ := resolve_tick(table, &queue, held_n, levels_n, context.temp_allocator)
	defer delete_input(snap_n1)
	testing.expect(t, held(snap_n1, .P1, fire.id))
	testing.expect(t, !pressed(snap_n1, .P1, fire.id))
	testing.expect(t, !released(snap_n1, .P1, fire.id))
}

// test_held_keys_axis_value_persists_at_rail proves the axis twin of the level
// persistence: a keys_axis key held across an EVENT-LESS window keeps its rail
// value, where without the carrier the digital axis contribution would drop to 0
// the moment the down edge left the window. Window N injects W down → P1
// Steer::Move reads −1; window N+1 injects nothing → it still reads −1; window N+2
// injects W up → it returns to 0. This is the live-device failure mode the carrier
// exists for: a held W emits one edge, and without the persisted level the axis
// dies after one tick.
@(test)
test_held_keys_axis_value_persists_at_rail :: proc(t: ^testing.T) {
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
	levels := new_device_levels(context.temp_allocator)
	queue := new_device_queue(context.temp_allocator)

	// Window N: W down → P1 Steer::Move reads −1 (W is the negative keys_axis key).
	enqueue_key_down(&queue, "Key::W")
	snap_n, held_n, levels_n := resolve_tick(table, &queue, prev, levels, context.temp_allocator)
	defer delete_input(snap_n)
	testing.expect_value(t, value(snap_n, .P1, steer), fixed_neg(to_fixed(1)))

	// Window N+1: NO events — the held W keeps the axis at the −1 rail.
	snap_n1, held_n1, levels_n1 := resolve_tick(table, &queue, held_n, levels_n, context.temp_allocator)
	defer delete_input(snap_n1)
	testing.expect_value(t, value(snap_n1, .P1, steer), fixed_neg(to_fixed(1)))

	// Window N+2: W up → the level drops, so the axis returns to 0.
	enqueue_key_up(&queue, "Key::W")
	snap_n2, _, _ := resolve_tick(table, &queue, held_n1, levels_n1, context.temp_allocator)
	defer delete_input(snap_n2)
	testing.expect_value(t, value(snap_n2, .P1, steer), Fixed(0))
}

// test_stick_sample_persists_across_eventless_window proves §23 §4 LEVEL semantics
// for an ANALOG stick: a stick held at a rail emits one CONTROLLERAXISMOTION sample,
// then nothing while it stays there. Window N injects the sample → the axis reads
// it; window N+1 injects nothing → the axis still reads the last sample (the stick
// did not re-center). Without the persisted sample the axis would snap to 0 the
// moment the sample left the window — the analog counterpart of the held-key bug.
@(test)
test_stick_sample_persists_across_eventless_window :: proc(t: ^testing.T) {
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
	levels := new_device_levels(context.temp_allocator)
	queue := new_device_queue(context.temp_allocator)

	// Window N: a half-magnitude stick sample (above the deadzone) → P1 reads it.
	half := fixed_from_decimal(0, "5")
	enqueue_stick_sample(&queue, "Stick::Left", .Y, half)
	snap_n, held_n, levels_n := resolve_tick(table, &queue, prev, levels, context.temp_allocator)
	defer delete_input(snap_n)
	testing.expect_value(t, value(snap_n, .P1, steer), half)

	// Window N+1: NO events — the held stick keeps reading its last sample.
	snap_n1, _, _ := resolve_tick(table, &queue, held_n, levels_n, context.temp_allocator)
	defer delete_input(snap_n1)
	testing.expect_value(t, value(snap_n1, .P1, steer), half)
}

// axis2d_program builds a synthetic Program with one Axis-kinded action bound to
// the two §14 v3 2D source forms — the hunt shape: P1 Drive::Move reads
// keys_quad(Key::A,Key::D,Key::W,Key::S) stacked with stick(Stick::Left). Pong
// binds only 1D sources, so the 2D fold (both Vec2 components) needs its own
// minimal fixture, built like button_program on the passed allocator.
@(private = "file")
axis2d_program :: proc(allocator := context.allocator) -> Program {
	variants := make([]Enum_Variant, 1, allocator)
	variants[0] = Enum_Variant{name = "Move", payload = "unit"}
	enums := make([]Enum_Decl, 1, allocator)
	enums[0] = Enum_Decl{name = "Drive", kind = .Axis, variants = variants}
	bindings := make([]Binding, 2, allocator)
	bindings[0] = Binding {
		kind   = "axis",
		player = "P1",
		action = "Drive::Move",
		source = "keys_quad(Key::A,Key::D,Key::W,Key::S)",
	}
	bindings[1] = Binding {
		kind   = "axis",
		player = "P1",
		action = "Drive::Move",
		source = "stick(Stick::Left)",
	}
	return Program{enums = enums, bindings = bindings}
}

// test_keys_quad_resolves_components proves the §14 v3 keys_quad 2D fold: each
// key drives its own component with the ratified (neg_x,pos_x,neg_y,pos_y)
// order — W (neg_y, up in the y-down draw space) reads y = −1 with x untouched,
// D (pos_x) reads x = +1, and an opposing pair (W + S) cancels its component to
// 0. The 2D reading comes through input.axis; the components never bleed into
// each other.
@(test)
test_keys_quad_resolves_components :: proc(t: ^testing.T) {
	program := axis2d_program(context.temp_allocator)
	table := build_bindings_table(program, IDENTITY_OVERLAY, context.temp_allocator)

	drive, found := table.registry.by_name["Drive::Move"]
	if !testing.expect(t, found) {
		return
	}

	prev := make(map[Player_Action]bool, context.temp_allocator)
	levels := new_device_levels(context.temp_allocator)
	queue := new_device_queue(context.temp_allocator)

	// W down (neg_y) → y reads −1, x stays 0.
	enqueue_key_down(&queue, "Key::W")
	snap_w, held_w, levels_w := resolve_tick(table, &queue, prev, levels, context.temp_allocator)
	defer delete_input(snap_w)
	testing.expect_value(t, axis(snap_w, .P1, drive.id), Vec2{Fixed(0), fixed_neg(to_fixed(1))})

	// D down too (pos_x) → x reads +1 alongside the held W's y = −1.
	enqueue_key_down(&queue, "Key::D")
	snap_wd, held_wd, levels_wd := resolve_tick(table, &queue, held_w, levels_w, context.temp_allocator)
	defer delete_input(snap_wd)
	testing.expect_value(t, axis(snap_wd, .P1, drive.id), Vec2{to_fixed(1), fixed_neg(to_fixed(1))})

	// S down (pos_y) while W is still held → the y pair cancels to 0; x keeps +1.
	enqueue_key_down(&queue, "Key::S")
	snap_ws, _, _ := resolve_tick(table, &queue, held_wd, levels_wd, context.temp_allocator)
	defer delete_input(snap_ws)
	testing.expect_value(t, axis(snap_ws, .P1, drive.id), Vec2{to_fixed(1), Fixed(0)})
}

// test_stick_2d_resolves_both_components proves the §14 v3 first-class stick
// fold: one stick(Stick::Left) binding reads BOTH the X and Y samples of the
// named stick into the action's Vec2 — never spread into 1D stick_x/stick_y
// halves — with the engine deadzone applied per component (a tiny X sample
// zeroes while a real Y sample passes).
@(test)
test_stick_2d_resolves_both_components :: proc(t: ^testing.T) {
	program := axis2d_program(context.temp_allocator)
	table := build_bindings_table(program, IDENTITY_OVERLAY, context.temp_allocator)

	drive, found := table.registry.by_name["Drive::Move"]
	if !testing.expect(t, found) {
		return
	}

	prev := make(map[Player_Action]bool, context.temp_allocator)
	levels := new_device_levels(context.temp_allocator)
	queue := new_device_queue(context.temp_allocator)

	// Both components sampled: x at half magnitude, y at the −1 rail.
	half := fixed_from_decimal(0, "5")
	enqueue_stick_sample(&queue, "Stick::Left", .X, half)
	enqueue_stick_sample(&queue, "Stick::Left", .Y, fixed_neg(to_fixed(1)))
	snap, held_n, levels_n := resolve_tick(table, &queue, prev, levels, context.temp_allocator)
	defer delete_input(snap)
	testing.expect_value(t, axis(snap, .P1, drive.id), Vec2{half, fixed_neg(to_fixed(1))})

	// A tiny X sample (inside the 0.1 deadzone) zeroes that component only; the
	// persisted Y sample keeps reading.
	tiny := fixed_from_decimal(0, "05")
	enqueue_stick_sample(&queue, "Stick::Left", .X, tiny)
	snap_dz, _, _ := resolve_tick(table, &queue, held_n, levels_n, context.temp_allocator)
	defer delete_input(snap_dz)
	testing.expect_value(t, axis(snap_dz, .P1, drive.id), Vec2{Fixed(0), fixed_neg(to_fixed(1))})
}

// test_stacked_quad_and_stick_sum_per_component proves §23 §3 stacking across
// the two 2D sources: a held W (keys_quad y −1) and a stick Y sample (−0.5) sum
// to −1.5 and clamp to the −1 rail per component, while the untouched x
// component stays 0 — the clamp is per component AFTER the stacked sum, exactly
// the 1D rule lifted to Vec2.
@(test)
test_stacked_quad_and_stick_sum_per_component :: proc(t: ^testing.T) {
	program := axis2d_program(context.temp_allocator)
	table := build_bindings_table(program, IDENTITY_OVERLAY, context.temp_allocator)

	drive, found := table.registry.by_name["Drive::Move"]
	if !testing.expect(t, found) {
		return
	}

	prev := make(map[Player_Action]bool, context.temp_allocator)
	levels := new_device_levels(context.temp_allocator)
	queue := new_device_queue(context.temp_allocator)

	half := fixed_from_decimal(0, "5")
	enqueue_key_down(&queue, "Key::W")
	enqueue_stick_sample(&queue, "Stick::Left", .Y, fixed_neg(half))
	snap, _, _ := resolve_tick(table, &queue, prev, levels, context.temp_allocator)
	defer delete_input(snap)
	testing.expect_value(t, axis(snap, .P1, drive.id), Vec2{Fixed(0), fixed_neg(to_fixed(1))})
}

// test_parse_source_v3_forms pins the §14 v3 parse arms directly: keys_quad
// parses its ratified four-code order into the x/y pairs, stick parses as the
// first-class 2D kind, and the closed-set discipline still drops a malformed
// quad (wrong arity) and an unknown helper.
@(test)
test_parse_source_v3_forms :: proc(t: ^testing.T) {
	quad, quad_ok := parse_source("keys_quad(Key::A,Key::D,Key::W,Key::S)", context.temp_allocator)
	testing.expect(t, quad_ok)
	testing.expect_value(t, quad.kind, Source_Kind.Keys_Quad)
	testing.expect_value(t, quad.neg_code, "Key::A")
	testing.expect_value(t, quad.pos_code, "Key::D")
	testing.expect_value(t, quad.neg_y_code, "Key::W")
	testing.expect_value(t, quad.pos_y_code, "Key::S")

	stick, stick_ok := parse_source("stick(Stick::Left)", context.temp_allocator)
	testing.expect(t, stick_ok)
	testing.expect_value(t, stick.kind, Source_Kind.Stick)
	testing.expect_value(t, stick.code, "Stick::Left")

	_, bad_arity := parse_source("keys_quad(Key::A,Key::D)", context.temp_allocator)
	testing.expect(t, !bad_arity)
	_, unknown := parse_source("wasd()", context.temp_allocator)
	testing.expect(t, !unknown)
}

// test_parse_source_digital_button_forms pins the single-code digital arms:
// pad(PadButton::A) and mouse(MouseButton::Left) each parse to their own kind
// with the device code intact (ADR 2026-06-15-engine-input-source-helpers-split).
// mouse is the parse mirror of pad; a wrong-arity mouse drops on the closed-set
// discipline.
@(test)
test_parse_source_digital_button_forms :: proc(t: ^testing.T) {
	pad, pad_ok := parse_source("pad(PadButton::A)", context.temp_allocator)
	testing.expect(t, pad_ok)
	testing.expect_value(t, pad.kind, Source_Kind.Pad)
	testing.expect_value(t, pad.code, "PadButton::A")

	mouse, mouse_ok := parse_source("mouse(MouseButton::Left)", context.temp_allocator)
	testing.expect(t, mouse_ok)
	testing.expect_value(t, mouse.kind, Source_Kind.Mouse)
	testing.expect_value(t, mouse.code, "MouseButton::Left")

	_, bad_arity := parse_source("mouse(MouseButton::Left,MouseButton::Right)", context.temp_allocator)
	testing.expect(t, !bad_arity)
}

// mouse_button_program builds a synthetic Program with one Button-kinded action
// bound to a mouse(MouseButton::Left) source — the §23 §3 mouse-button source no
// committed golden exercises (ADR 2026-06-15-engine-input-source-helpers-split).
// P1.Fire is bound to mouse(MouseButton::Left); the descriptor slices are
// allocated on the passed allocator (not stack-temporary slice literals).
@(private = "file")
mouse_button_program :: proc(allocator := context.allocator) -> Program {
	variants := make([]Enum_Variant, 1, allocator)
	variants[0] = Enum_Variant{name = "Fire", payload = "unit"}
	enums := make([]Enum_Decl, 1, allocator)
	enums[0] = Enum_Decl{name = "Trigger", kind = .Button, variants = variants}
	bindings := make([]Binding, 1, allocator)
	bindings[0] = Binding {
		kind   = "button",
		player = "P1",
		action = "Trigger::Fire",
		source = "mouse(MouseButton::Left)",
	}
	return Program{enums = enums, bindings = bindings}
}

// test_mouse_button_resolves_pressed_held_released proves the §23 §4 fold for the
// mouse source end-to-end (parse → window fold → snapshot): a mouse-down latches
// `pressed` + `held`, and a mouse-up on the next tick reads `released` (was held,
// now up) — the exact edge/level semantics the pad/key sources fold, since Mouse
// is a digital source in the same Button_Accum path. This is the runtime half of
// the cross-team mouse mirror; the device-free query vocabulary reads the action,
// never the device code.
@(test)
test_mouse_button_resolves_pressed_held_released :: proc(t: ^testing.T) {
	program := mouse_button_program(context.temp_allocator)
	table := build_bindings_table(program, IDENTITY_OVERLAY, context.temp_allocator)

	fire, found := table.registry.by_name["Trigger::Fire"]
	if !testing.expect(t, found) {
		return
	}

	prev := make(map[Player_Action]bool, context.temp_allocator)
	levels := new_device_levels(context.temp_allocator)
	queue := new_device_queue(context.temp_allocator)

	// Tick 1: mouse-down. pressed + held, not released.
	enqueue_mouse_down(&queue, "MouseButton::Left")
	snap1, held1, levels1 := resolve_tick(table, &queue, prev, levels, context.temp_allocator)
	defer delete_input(snap1)
	testing.expect(t, pressed(snap1, .P1, fire.id))
	testing.expect(t, held(snap1, .P1, fire.id))
	testing.expect(t, !released(snap1, .P1, fire.id))

	// Tick 2: mouse-up. released edge (was held, now up), not pressed, not held.
	enqueue_mouse_up(&queue, "MouseButton::Left")
	snap2, _, _ := resolve_tick(table, &queue, held1, levels1, context.temp_allocator)
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
