// Bindings resolution: the one place §23 §3 raw device input becomes the
// device-free action snapshot input.odin owns. This layer reads the artifact's
// [bindings] table (the §14 builder form lifted from entrypoints.fcfg), resolves
// each device source against the window of raw events drained since the previous
// tick, and folds the result into an Input through the producer surface — with
// edge/level coalescing (§23 §4) for buttons and engine-deadzone + clamp for
// axes. It is the SOLE device-aware code path on the runtime side; once it hands
// back an Input, no Key/Pad/Stick token survives into sim code (§23 §1, §04 §1).
//
// BOUNDARY: raw input enters through a HEADLESS injected device-event queue — a
// deterministic, testable producer drained per tick — NOT live device polling
// (the live backend is a separate layer that feeds this same queue, §23 §5). This
// file does NOT define the snapshot/producers (input.odin owns them), does NOT
// record the resolved snapshot to a replay log (a separate layer), and does NOT
// read real hardware. runtime/** never imports funpack/**; the artifact bytes are
// the only sanctioned coupling (spec §29, §09).
package funpack_runtime

import "core:strings"

// --- The action registry: minting stable ActionIds (§23 §1, artifact §5) ---

// Action_Kind is the role kind §03 §4 ascribes to an action enum — the bit that
// decides whether a binding resolves to button edge/level bits or an analog axis
// value (§23 §1). Only Axis/Button enums become actions; a plain enum (Side) is
// not bindable, so it never enters the registry.
Action_Kind :: enum {
	Button,
	Axis,
}

// Action_Def is one registered action: its stable ActionId (the key the snapshot
// uses), its full "Enum::Variant" name (what a binding's `action` field carries),
// and its role kind. The snapshot keys generically by ActionId so it stays
// independent of pong's enums (input.odin §ActionId).
Action_Def :: struct {
	id:   ActionId,
	name: string, // "Steer::Move" — the §2.6 enum-variant token a binding targets
	kind: Action_Kind,
}

// Action_Registry maps the artifact's Axis/Button enum variants onto stable
// ActionIds. The id is the variant's position in a deterministic walk of the
// program's enums (declaration order, variant order) restricted to Axis/Button
// enums — so the same artifact always mints the same ids on every machine, which
// the determinism contract requires (§23 §4). `by_name` indexes the same defs by
// their "Enum::Variant" token for binding resolution.
Action_Registry :: struct {
	defs:    []Action_Def,
	by_name: map[string]Action_Def,
}

// build_action_registry walks the program's enums in declaration order and mints
// one ActionId per variant of each Axis/Button-kinded enum, in variant order. A
// non-input enum (Enum_Kind.None / .Num / .Collision_Layer) contributes no
// actions. The minting is a pure function of the artifact, so the ids are stable
// across runs and machines.
build_action_registry :: proc(
	program: Program,
	allocator := context.allocator,
) -> Action_Registry {
	defs := make([dynamic]Action_Def, 0, 0, allocator)
	by_name := make(map[string]Action_Def, allocator)
	next: u32 = 0
	for enum_decl in program.enums {
		kind, is_action := action_kind_from_enum(enum_decl.kind)
		if !is_action {
			continue
		}
		for variant in enum_decl.variants {
			name := strings.concatenate({enum_decl.name, "::", variant.name}, allocator)
			def := Action_Def {
				id   = ActionId(next),
				name = name,
				kind = kind,
			}
			append(&defs, def)
			by_name[name] = def
			next += 1
		}
	}
	return Action_Registry{defs = defs[:], by_name = by_name}
}

// action_kind_from_enum maps an artifact Enum_Kind onto the Action_Kind a
// binding resolves to. `is_action` is false for any kind that is not a §23
// input role (None/Num/Collision_Layer), so those enums are skipped.
action_kind_from_enum :: proc(kind: Enum_Kind) -> (action_kind: Action_Kind, is_action: bool) {
	switch kind {
	case .Axis:
		return .Axis, true
	case .Button:
		return .Button, true
	case .None, .Num, .Collision_Layer:
		return .Button, false
	}
	return .Button, false
}

// delete_action_registry releases the registry's two allocations — the defs
// slice and the name index. Tests that build a registry against a leak-checked
// allocator call this.
delete_action_registry :: proc(registry: Action_Registry) {
	delete(registry.defs)
	reg := registry
	delete(reg.by_name)
}

// --- Resolved bindings: the parsed device-source table (§23 §3) -----------

// Source_Kind is the closed §14 v3 source-form set (artifact-format §14) the
// emitter lowers the §23 §3 builder helpers into. A button-contributing source
// (Key, Pad) drives the edge/level fold; a 1D axis source (Keys_Axis, Stick_X,
// Stick_Y) contributes to the action's single 1D value slot (the x component
// `value` reads); a 2D source (Keys_Quad, Stick) contributes both components of
// the action's Vec2 (the vector `axis` reads). `stick(Stick)` is a FIRST-CLASS
// 2D form — never spread into the 1D stick_x/stick_y halves, whose contributions
// land in the 1D slot (ADR 2026-06-06-binding-source-lowering-2d-quad-and-stick).
Source_Kind :: enum {
	Key, // key(Key::X) — a single digital source
	Pad, // pad(PadButton::A) — a single digital source
	Keys_Axis, // keys_axis(neg, pos) — two keys form one 1D analog axis
	Stick_X, // stick_x(Stick::Left) — the x stick component into a 1D axis
	Stick_Y, // stick_y(Stick::Left) — the y stick component into a 1D axis
	Keys_Quad, // keys_quad(neg_x,pos_x,neg_y,pos_y) — four keys form one 2D axis
	Stick, // stick(Stick::Left) — both stick components into a 2D axis
}

// Device_Source is one parsed binding source resolved from its builder-call
// token. A digital source names one device code (`code`); a Keys_Axis names the
// negative and positive key codes; a Keys_Quad adds the y pair; a stick form
// names the stick code. The codes are opaque interned strings (e.g. "Key::W",
// "Stick::Left") — the resolver matches them against injected raw events by
// equality, so no Key/Pad enum is modeled here, keeping the device vocabulary
// entirely string-keyed and the layer agnostic to the concrete device set.
Device_Source :: struct {
	kind:       Source_Kind,
	code:       string, // Key/Pad: the device code; Stick/Stick_X/Stick_Y: the stick code
	neg_code:   string, // Keys_Axis: the key driving −1; Keys_Quad: the key driving x −1
	pos_code:   string, // Keys_Axis: the key driving +1; Keys_Quad: the key driving x +1
	neg_y_code: string, // Keys_Quad only: the key driving y −1 (up in the y-down draw space)
	pos_y_code: string, // Keys_Quad only: the key driving y +1
}

// Resolved_Binding is one artifact binding parsed into its target and source:
// the resolved action (ActionId + kind), the player, and the parsed device
// source. Multiple resolved bindings for one (player, action) STACK — every one
// contributes to the fold (§23 §3).
Resolved_Binding :: struct {
	player: PlayerId,
	action: Action_Def,
	source: Device_Source,
}

// Bindings_Table is the resolved, device-parsed binding set the per-tick fold
// reads. It is built once from the artifact (resolving the rebinding overlay —
// stubbed to identity here — then parsing each source), then consulted every
// tick. A binding whose action or player does not resolve is dropped silently:
// the artifact is authoritative, so a malformed binding is not load-bearing,
// and dropping it keeps an unknown future source from refusing the table;
// since v3 the schema stamp gates the source vocabulary, so a dropped source
// inside a matching version is malformed data, not a version skew.
Bindings_Table :: struct {
	registry: Action_Registry,
	resolved: []Resolved_Binding,
}

// Rebinding_Overlay is the typed seam §23 §3 reserves for a settings-layer key
// rebinding: a per-machine preference resolved over the bindings() defaults
// BEFORE raw input resolution. Runtime key rebinding is a settings concern
// outside this layer and pong needs none, so the overlay is STUBBED to identity
// (apply returns the defaults unchanged). A real settings overlay drops in by
// implementing apply over this same struct without touching the fold.
Rebinding_Overlay :: struct {
	// Intentionally empty: the identity overlay carries no remapping. The field
	// set a real settings overlay needs (per-source code substitutions) lands
	// here when the settings layer implements it.
}

// IDENTITY_OVERLAY is the §23 §3 defaults-only overlay: it remaps nothing, so
// resolution sees exactly the artifact's bindings(). The live settings layer
// replaces this with a loaded per-machine overlay.
IDENTITY_OVERLAY :: Rebinding_Overlay{}

// apply_overlay resolves the rebinding overlay over the artifact bindings
// BEFORE source resolution (§23 §3). The identity overlay returns the bindings
// unchanged; this is the single seam a settings overlay hooks, so the fold below
// never needs to know whether a rebind happened.
apply_overlay :: proc(
	bindings: []Binding,
	overlay: Rebinding_Overlay,
) -> []Binding {
	// Identity: defaults only. A real overlay rewrites source device codes here.
	return bindings
}

// build_bindings_table resolves the artifact's binding table into the parsed,
// per-tick-ready form: mint the action registry, apply the (identity) rebinding
// overlay over the defaults, then parse each binding's player, action, and device
// source. A binding whose player or action is unknown, or whose source does not
// parse, is dropped — the resolved table carries only fold-ready entries.
build_bindings_table :: proc(
	program: Program,
	overlay := IDENTITY_OVERLAY,
	allocator := context.allocator,
) -> Bindings_Table {
	registry := build_action_registry(program, allocator)
	defaults := apply_overlay(program.bindings, overlay)

	resolved := make([dynamic]Resolved_Binding, 0, 0, allocator)
	for binding in defaults {
		player, player_ok := player_from_string(binding.player)
		if !player_ok {
			continue
		}
		action, action_ok := registry.by_name[binding.action]
		if !action_ok {
			continue
		}
		source, source_ok := parse_source(binding.source, allocator)
		if !source_ok {
			continue
		}
		append(&resolved, Resolved_Binding{player = player, action = action, source = source})
	}
	return Bindings_Table{registry = registry, resolved = resolved[:]}
}

// delete_bindings_table releases the resolved slice and the embedded registry —
// the device codes are sub-strings of the program allocation, so this frees only
// the table's own two allocations.
delete_bindings_table :: proc(table: Bindings_Table) {
	delete(table.resolved)
	delete_action_registry(table.registry)
}

// player_from_string maps the artifact's "P1".."P4" token onto a PlayerId.
// `ok` is false for any other token, so an unrecognized player drops its binding
// rather than mis-resolving it.
player_from_string :: proc(s: string) -> (player: PlayerId, ok: bool) {
	switch s {
	case "P1":
		return .P1, true
	case "P2":
		return .P2, true
	case "P3":
		return .P3, true
	case "P4":
		return .P4, true
	}
	return .P1, false
}

// parse_source parses a §14 v3 source-form token into a Device_Source. The
// token is `helper(args)`: the helper name selects the kind, the comma-split args
// are the device codes. `key`/`pad` take one code; `keys_axis` takes neg,pos;
// `stick_x`/`stick_y` take one stick code; `keys_quad` takes the ratified
// (neg_x, pos_x, neg_y, pos_y) quad; `stick` takes one stick code and is the
// first-class 2D form — the emitter records it verbatim, never spread into the
// 1D stick_x/stick_y halves (artifact-format §14 v3). An unrecognized helper
// returns ok=false.
parse_source :: proc(
	token: string,
	allocator := context.allocator,
) -> (
	source: Device_Source,
	ok: bool,
) {
	open := strings.index_byte(token, '(')
	if open < 0 || !strings.has_suffix(token, ")") {
		return {}, false
	}
	helper := token[:open]
	args := token[open + 1:len(token) - 1] // the comma-separated codes inside (...)
	parts := strings.split(args, ",", allocator)
	defer delete(parts, allocator)

	switch helper {
	case "key":
		if len(parts) != 1 {
			return {}, false
		}
		return Device_Source{kind = .Key, code = strings.clone(strings.trim_space(parts[0]), allocator)},
			true
	case "pad":
		if len(parts) != 1 {
			return {}, false
		}
		return Device_Source{kind = .Pad, code = strings.clone(strings.trim_space(parts[0]), allocator)},
			true
	case "keys_axis":
		if len(parts) != 2 {
			return {}, false
		}
		return Device_Source {
				kind = .Keys_Axis,
				neg_code = strings.clone(strings.trim_space(parts[0]), allocator),
				pos_code = strings.clone(strings.trim_space(parts[1]), allocator),
			},
			true
	case "stick_x":
		if len(parts) != 1 {
			return {}, false
		}
		return Device_Source{kind = .Stick_X, code = strings.clone(strings.trim_space(parts[0]), allocator)},
			true
	case "stick_y":
		if len(parts) != 1 {
			return {}, false
		}
		return Device_Source{kind = .Stick_Y, code = strings.clone(strings.trim_space(parts[0]), allocator)},
			true
	case "keys_quad":
		if len(parts) != 4 {
			return {}, false
		}
		return Device_Source {
				kind = .Keys_Quad,
				neg_code = strings.clone(strings.trim_space(parts[0]), allocator),
				pos_code = strings.clone(strings.trim_space(parts[1]), allocator),
				neg_y_code = strings.clone(strings.trim_space(parts[2]), allocator),
				pos_y_code = strings.clone(strings.trim_space(parts[3]), allocator),
			},
			true
	case "stick":
		if len(parts) != 1 {
			return {}, false
		}
		return Device_Source{kind = .Stick, code = strings.clone(strings.trim_space(parts[0]), allocator)},
			true
	}
	return {}, false
}

// --- The headless injected device-event queue (§23 §5 producer seam) ------

// Device_Event_Kind is the closed set of raw device transitions the resolver
// coalesces: a digital down/up edge on a key or pad button, and an analog stick
// axis sample. These are RAW device events, never actions — they exist only
// inside this device-aware layer and are gone by the time the snapshot is built.
Device_Event_Kind :: enum {
	Key_Down,
	Key_Up,
	Pad_Down,
	Pad_Up,
	Stick_Sample,
}

// Stick_Axis selects which component a Stick_Sample carries — the x or y of a
// named stick. The resolver matches a stick_x source against an X sample and a
// stick_y source against a Y sample on the same stick code.
Stick_Axis :: enum {
	X,
	Y,
}

// Device_Event is one timestamped raw event in the injected queue. `seq` orders
// events within the inter-tick window deterministically (the injection order),
// so the fold is reproducible regardless of how a producer enqueues. A digital
// event names its device `code`; a stick sample names the stick `code`, the
// `stick_axis` component, and the analog `sample` as a fixed-point value (NO
// float ever enters — the producer supplies Fixed bits, §23 §4).
Device_Event :: struct {
	kind:       Device_Event_Kind,
	seq:        int, // injection order within the window — deterministic tie-break
	code:       string, // Key/Pad code, or the Stick code for a sample
	stick_axis: Stick_Axis, // meaningful only for Stick_Sample
	sample:     Fixed, // Stick_Sample analog value, fixed-point; unused otherwise
}

// Device_Queue is the headless injected event source the resolver drains each
// tick. ANY producer (a test, a replay re-feed, the later live SDL backend)
// enqueues raw events here; the resolver folds the window since the previous
// tick into a snapshot, then the queue is cleared for the next window. This is
// the seam that keeps the determinism core verifiable without a live device.
Device_Queue :: struct {
	events:   [dynamic]Device_Event,
	next_seq: int, // monotonic injection counter, the per-event `seq`
}

// new_device_queue allocates an empty injected-event queue. The queue owns its
// dynamic event buffer; delete_device_queue releases it.
new_device_queue :: proc(allocator := context.allocator) -> Device_Queue {
	return Device_Queue{events = make([dynamic]Device_Event, allocator)}
}

// delete_device_queue releases the queue's event buffer.
delete_device_queue :: proc(queue: Device_Queue) {
	q := queue
	delete(q.events)
}

// enqueue_key_down injects a key-down raw event for `code` into the window. The
// resolver coalesces this into a `pressed` edge for any action a binding maps the
// key to (§23 §4).
enqueue_key_down :: proc(queue: ^Device_Queue, code: string) {
	enqueue(queue, Device_Event{kind = .Key_Down, code = code})
}

// enqueue_key_up injects a key-up raw event for `code` — a `released` edge, and
// the level (held) reading goes false at the tick instant unless re-pressed.
enqueue_key_up :: proc(queue: ^Device_Queue, code: string) {
	enqueue(queue, Device_Event{kind = .Key_Up, code = code})
}

// enqueue_pad_down injects a pad-button-down raw event for `code`.
enqueue_pad_down :: proc(queue: ^Device_Queue, code: string) {
	enqueue(queue, Device_Event{kind = .Pad_Down, code = code})
}

// enqueue_pad_up injects a pad-button-up raw event for `code`.
enqueue_pad_up :: proc(queue: ^Device_Queue, code: string) {
	enqueue(queue, Device_Event{kind = .Pad_Up, code = code})
}

// enqueue_stick_sample injects an analog stick sample for `code` on the named
// axis. `sample` is fixed-point and may be out of range or inside the deadzone —
// the resolver deadzones and clamps it, so the producer supplies the raw reading
// unconditioned (§23 §4).
enqueue_stick_sample :: proc(queue: ^Device_Queue, code: string, stick_axis: Stick_Axis, sample: Fixed) {
	enqueue(
		queue,
		Device_Event{kind = .Stick_Sample, code = code, stick_axis = stick_axis, sample = sample},
	)
}

// enqueue appends one raw event, stamping it with the next deterministic seq.
@(private = "file")
enqueue :: proc(queue: ^Device_Queue, event: Device_Event) {
	ev := event
	ev.seq = queue.next_seq
	queue.next_seq += 1
	append(&queue.events, ev)
}

// clear_window resets the queue for the next inter-tick window: drop the drained
// events and reset the seq counter, so each window's events order from zero
// independently. The resolver calls this after folding, so a caller that drives
// many ticks reuses one queue.
clear_window :: proc(queue: ^Device_Queue) {
	clear(&queue.events)
	queue.next_seq = 0
}

// --- Persistent raw device levels across ticks (§23 §4 LEVEL semantics) ----

// Device_Levels is the raw device state that SURVIVES an event-less window: which
// device codes are down at the tick instant, and the last analog sample per stick
// component. §23 §4 makes `held` a LEVEL (down at the tick instant), so a real
// device that emits a single KEYDOWN edge and then nothing must keep reading held
// on every event-less tick that follows — the edge is gone from later windows but
// the level persists. The window fold (resolve_window) seeds from this carrier and
// updates it, so a held key's level and a held stick's sample outlive the window
// that produced them. This is the device-side analog of prev_held: it is threaded
// in/out of resolve_tick, NOT the action-level held set (that stays prev_held).
Device_Levels :: struct {
	down:         map[string]bool, // device code → down at the tick instant, surviving event-less windows
	stick_sample: map[Stick_Sample_Key]Fixed, // (code, axis) → last analog sample, surviving event-less windows
}

// new_device_levels allocates an empty persistent device-level carrier — the
// tick-0 seed (no code down, no stick sampled before the first tick). The live
// loop and each test thread one of these through resolve_tick like prev_held.
new_device_levels :: proc(allocator := context.allocator) -> Device_Levels {
	return Device_Levels {
		down = make(map[string]bool, allocator),
		stick_sample = make(map[Stick_Sample_Key]Fixed, allocator),
	}
}

// delete_device_levels releases the carrier's two maps. A leak-checked test that
// threads an explicit carrier calls this on the final level set.
delete_device_levels :: proc(levels: Device_Levels) {
	lv := levels
	delete(lv.down)
	delete(lv.stick_sample)
}

// --- The per-tick fold: window of raw events → action snapshot (§23 §4) ---

// AXIS_DEADZONE is the engine deadzone §23 §4 applies to every analog axis: a
// stick reading whose magnitude is at or below this threshold resolves to exactly
// zero, so stick drift never leaks a nonzero action. 0.1 in Q32.32, derived
// through the kernel so no float reaches the comparison.
AXIS_DEADZONE :: proc() -> Fixed {
	return fixed_from_decimal(0, "1")
}

// resolve_tick folds the window of injected events into the per-tick action
// snapshot through the §23 §4 coalescing rules, then clears the window for the
// next tick. Two carriers thread across ticks:
//
//   - `prev_held` carries which (player, action) buttons were down at the END of
//     the previous tick — the level/edge distinction needs the prior ACTION level
//     to decide `released`; the returned `held_after` feeds the next tick.
//   - `prev_levels` carries the persistent RAW DEVICE state that survives an
//     event-less window: which device codes are down and each stick's last sample
//     (§23 §4 LEVEL semantics — a single KEYDOWN edge keeps reading held on every
//     later event-less tick). The returned `levels_after` feeds the next tick.
//
// The two are distinct: prev_held is the device-free action level the snapshot
// derives `released` from; prev_levels is the device-code level the WINDOW seeds
// from so a held key's level survives a window with no events.
//
// Resolution is two-pass so STACKED sources combine correctly (§23 §3): pass one
// aggregates every binding for each (player, action) into a per-action accumulator
// (button down/level OR'd across sources, axis contributions summed); pass two
// derives the final snapshot bits from each accumulator against prev_held. A
// single pass would mis-fire `released` when a later stacked source still holds the
// action, and would clamp the axis per-source instead of once after the sum.
//
// Button coalescing (§23 §4): an action is `pressed` if ANY bound source went
// down in the window (even if it also went up — a tap still registers);
// `released` if it was down before and is up across ALL sources at the tick
// instant; `held` if any source is down at the tick instant (a code down in a
// PRIOR window with no edge since still counts — the level persists). Axis
// coalescing: every stacked source contributes into the action's Vec2
// accumulator — a 1D source (keys_axis ±1 key levels, a stick component's
// deadzoned last sample) feeds the x slot `value` reads; a 2D source
// (keys_quad, stick) feeds both components (§14 v3). Last samples persist
// across event-less windows; the contributions sum, then clamp to [-1,1] per
// component.
resolve_tick :: proc(
	table: Bindings_Table,
	queue: ^Device_Queue,
	prev_held: map[Player_Action]bool,
	prev_levels: Device_Levels,
	allocator := context.allocator,
) -> (
	snapshot: Input,
	held_after: map[Player_Action]bool,
	levels_after: Device_Levels,
) {
	window := resolve_window(queue, prev_levels, allocator)
	defer delete_window(window)

	// Pass one: aggregate stacked sources per (player, action). The axis
	// accumulator is a Vec2: a 1D source contributes to x (the slot `value`
	// reads), a 2D source (keys_quad, stick) to both components (§14 v3).
	buttons := make(map[Player_Action]Button_Accum, allocator)
	defer delete(buttons)
	axes := make(map[Player_Action]Vec2, allocator)
	defer delete(axes)

	for binding in table.resolved {
		key := Player_Action{binding.player, binding.action.id}
		switch binding.action.kind {
		case .Button:
			accumulate_button(&buttons, key, binding.source, window)
		case .Axis:
			accumulate_axis(&axes, key, binding.source, window)
		}
	}

	// Pass two: derive the snapshot bits from the per-action accumulators.
	snapshot = empty()
	held_after = make(map[Player_Action]bool, allocator)

	for key, accum in buttons {
		state := Button_State {
			pressed  = accum.went_down,
			held     = accum.level_now,
			released = prev_held[key] && !accum.level_now,
		}
		snapshot.buttons[key] = state
		if accum.level_now {
			held_after[key] = true
		}
	}
	for key, total in axes {
		// Clamp ONCE per component after all stacked sources summed (§23 §3).
		snapshot.axes[key] = Vec2 {
			x = fixed_clamp(total.x, fixed_neg(to_fixed(1)), to_fixed(1)),
			y = fixed_clamp(total.y, fixed_neg(to_fixed(1)), to_fixed(1)),
		}
	}

	// Carry the device-code levels and stick samples forward: the window's level
	// map already folded prev_levels' persisted state plus this window's edges, so
	// the tick-instant down set and last samples ARE the next tick's seed (§23 §4).
	levels_after = level_set_from_window(window, allocator)

	clear_window(queue)
	return snapshot, held_after, levels_after
}

// level_set_from_window snapshots the window's tick-instant device levels into the
// persistent carrier the next tick seeds from: the down set is the codes still down
// after folding (the level map, which already merged the prior persisted state),
// and the stick samples are the last reading per (code, axis). Cloning into fresh
// maps decouples the carrier's lifetime from the window's (the window is deleted at
// tick end).
@(private = "file")
level_set_from_window :: proc(window: Window_Levels, allocator := context.allocator) -> Device_Levels {
	levels := new_device_levels(allocator)
	for code, is_down in window.level {
		if is_down {
			levels.down[code] = true
		}
	}
	for key, sample in window.stick_sample {
		levels.stick_sample[key] = sample
	}
	return levels
}

// Window_Levels is the coalesced device state derived from one inter-tick window:
// per device code, whether it went down in the window (the `pressed` edge), and
// its level at the tick instant (the last edge wins, seeded from the persisted
// cross-tick level). Stick samples keep the last reading per (code, axis), seeded
// from the last persisted sample so a held stick keeps reading without a fresh
// CONTROLLERAXISMOTION. This is the intermediate the per-binding fold reads,
// computed once per tick so each stacked binding shares it.
@(private = "file")
Window_Levels :: struct {
	went_down:    map[string]bool, // code → went down IN this window (the pressed edge; never seeded)
	level:        map[string]bool, // code → down at the tick instant (persisted level, then last edge wins)
	stick_sample: map[Stick_Sample_Key]Fixed, // (code, axis) → last sample (persisted, then last in-window)
}

// Stick_Sample_Key keys the per-window last-sample table by stick code and axis
// component, so stick_x and stick_y on the same stick stay independent.
@(private = "file")
Stick_Sample_Key :: struct {
	code:       string,
	stick_axis: Stick_Axis,
}

// resolve_window replays the window's raw events in injection order into the
// coalesced Window_Levels, SEEDED from the persistent cross-tick state: the level
// map starts with every persisted-down code (so a held key with no event this
// window keeps reading down) and the sample map with each persisted last sample (so
// a held stick keeps its reading). Then each down sets went_down and level, each up
// clears level (leaving went_down latched so a down-then-up tap still reads
// pressed), each stick sample overwrites the last reading for its (code, axis).
// went_down is NEVER seeded — only an edge IN this window is the pressed edge.
// Events fold in `seq` order, the injection order the queue stamped.
@(private = "file")
resolve_window :: proc(
	queue: ^Device_Queue,
	prev_levels: Device_Levels,
	allocator := context.allocator,
) -> Window_Levels {
	levels := Window_Levels {
		went_down    = make(map[string]bool, allocator),
		level        = make(map[string]bool, allocator),
		stick_sample = make(map[Stick_Sample_Key]Fixed, allocator),
	}
	// Seed the tick-instant level and last sample from the persisted carrier: a code
	// down at the end of the previous tick is still down until an up edge clears it,
	// and a stick's last sample holds until a fresh sample replaces it (§23 §4).
	for code, is_down in prev_levels.down {
		if is_down {
			levels.level[code] = true
		}
	}
	for key, sample in prev_levels.stick_sample {
		levels.stick_sample[key] = sample
	}
	// The queue stamps seq in append order, so the events buffer is already in
	// injection order; folding it in place is the deterministic replay.
	for event in queue.events {
		switch event.kind {
		case .Key_Down, .Pad_Down:
			levels.went_down[event.code] = true
			levels.level[event.code] = true
		case .Key_Up, .Pad_Up:
			levels.level[event.code] = false
		case .Stick_Sample:
			levels.stick_sample[Stick_Sample_Key{event.code, event.stick_axis}] = event.sample
		}
	}
	return levels
}

@(private = "file")
delete_window :: proc(levels: Window_Levels) {
	lv := levels
	delete(lv.went_down)
	delete(lv.level)
	delete(lv.stick_sample)
}

// Button_Accum is the per-(player, action) coalescing of every stacked button
// source over one window: `went_down` is the OR of "any source went down"
// (tap-safe pressed edge), `level_now` is the OR of "any source down at the tick
// instant" (held). Deriving the snapshot bits from this aggregate — not per
// source — is what makes a stacked source that still holds the action suppress a
// spurious `released` (§23 §3 stacking, §23 §4 coalescing).
@(private = "file")
Button_Accum :: struct {
	went_down: bool,
	level_now: bool,
}

// accumulate_button ORs one button-source binding's window readings into the
// (player, action) accumulator. A non-digital source contributes nothing to a
// button action. The map is taken by pointer: inserting a NEW key may reallocate
// the map's backing store, and a by-value map header would lose that growth.
@(private = "file")
accumulate_button :: proc(
	buttons: ^map[Player_Action]Button_Accum,
	key: Player_Action,
	source: Device_Source,
	window: Window_Levels,
) {
	if source.kind != .Key && source.kind != .Pad {
		return
	}
	accum := buttons[key]
	if window.went_down[source.code] {
		accum.went_down = true
	}
	if window.level[source.code] {
		accum.level_now = true
	}
	buttons[key] = accum
}

// accumulate_axis SUMS one axis-source binding's contribution into the
// (player, action) running Vec2 total (§23 §3 stacking). A 1D source feeds the
// x component — the single 1D value slot `value` reads — regardless of WHICH
// device axis it samples (pong's stick_y is a 1D paddle axis, not a y
// contribution); a 2D source (keys_quad, stick) feeds both components. A
// keys_axis/keys_quad folds key levels to digital −1/0/+1 per component; a
// stick form takes engine-deadzoned last samples. The total is clamped to
// [-1, 1] per component ONCE after all stacked sources are summed (resolve_tick
// pass two), so two stacked sources never each clamp independently. A digital
// button source contributes nothing.
@(private = "file")
accumulate_axis :: proc(
	axes: ^map[Player_Action]Vec2,
	key: Player_Action,
	source: Device_Source,
	window: Window_Levels,
) {
	contribution: Vec2
	switch source.kind {
	case .Keys_Axis:
		// Digital 1D axis: pos key adds +1, neg key adds −1, both/neither cancel.
		contribution.x = key_pair_level(window, source.neg_code, source.pos_code)
	case .Stick_X, .Stick_Y:
		// A 1D stick component: the suffix selects the DEVICE sample read; the
		// contribution still lands in the action's 1D slot (x).
		axis_component := source.kind == .Stick_X ? Stick_Axis.X : Stick_Axis.Y
		sample, sampled := window.stick_sample[Stick_Sample_Key{source.code, axis_component}]
		if sampled {
			contribution.x = apply_deadzone(sample)
		}
	case .Keys_Quad:
		// Digital 2D quad: each component is its own neg/pos key pair (§14 v3,
		// order neg_x,pos_x,neg_y,pos_y; up = neg_y in the y-down draw space).
		contribution.x = key_pair_level(window, source.neg_code, source.pos_code)
		contribution.y = key_pair_level(window, source.neg_y_code, source.pos_y_code)
	case .Stick:
		// First-class 2D stick: both deadzoned components of the named stick.
		if sample, sampled := window.stick_sample[Stick_Sample_Key{source.code, .X}]; sampled {
			contribution.x = apply_deadzone(sample)
		}
		if sample, sampled := window.stick_sample[Stick_Sample_Key{source.code, .Y}]; sampled {
			contribution.y = apply_deadzone(sample)
		}
	case .Key, .Pad:
		return
	}
	total := axes[key]
	axes[key] = Vec2{fixed_add(total.x, contribution.x), fixed_add(total.y, contribution.y)}
}

// key_pair_level folds a neg/pos key pair's tick-instant levels into a digital
// −1/0/+1 contribution: the pos key adds +1, the neg key adds −1, both or
// neither cancel to 0. Shared by the keys_axis 1D arm and each keys_quad
// component.
@(private = "file")
key_pair_level :: proc(window: Window_Levels, neg_code: string, pos_code: string) -> Fixed {
	level: Fixed
	if window.level[pos_code] {
		level = fixed_add(level, to_fixed(1))
	}
	if window.level[neg_code] {
		level = fixed_sub(level, to_fixed(1))
	}
	return level
}

// apply_deadzone zeroes an analog sample whose magnitude is within the engine
// deadzone, then leaves the rest unchanged (the final clamp happens in
// resolve_tick's second pass, after stacking). A keys_axis ±1 never passes through here — it is
// digital, not a drifting analog reading — so the deadzone applies only to a raw
// stick sample, exactly §23 §4's "engine-deadzoned" analog rail.
@(private = "file")
apply_deadzone :: proc(sample: Fixed) -> Fixed {
	dz := AXIS_DEADZONE()
	magnitude := sample < 0 ? fixed_neg(sample) : sample
	if magnitude <= dz {
		return Fixed(0)
	}
	return sample
}
