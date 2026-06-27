package funpack_runtime

import "core:strings"

Action_Kind :: enum {
	Button,
	Axis,
}

Action_Def :: struct {
	id:   ActionId,
	name: string,
	kind: Action_Kind,
}

Action_Key :: struct {
	enum_type: string,
	case_name: string,
}

Action_Registry :: struct {
	defs:   []Action_Def,
	by_key: map[Action_Key]Action_Def,
}

build_action_registry :: proc(
	program: Program,
	allocator := context.allocator,
) -> Action_Registry {
	defs := make([dynamic]Action_Def, 0, 0, allocator)
	by_key := make(map[Action_Key]Action_Def, allocator)
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
			by_key[Action_Key{enum_type = enum_decl.name, case_name = variant.name}] = def
			next += 1
		}
	}
	return Action_Registry{defs = defs[:], by_key = by_key}
}

registry_find :: proc(registry: Action_Registry, enum_type, case_name: string) -> (def: Action_Def, found: bool) {
	def, found = registry.by_key[Action_Key{enum_type = enum_type, case_name = case_name}]
	return
}

registry_find_token :: proc(registry: Action_Registry, token: string) -> (def: Action_Def, found: bool) {
	variant := variant_from_token(token)
	return registry_find(registry, variant.enum_type, variant.case_name)
}

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

delete_action_registry :: proc(registry: Action_Registry) {
	delete(registry.defs)
	reg := registry
	delete(reg.by_key)
}

Source_Kind :: enum {
	Key,
	Pad,
	Mouse,
	Keys_Axis,
	Stick_X,
	Stick_Y,
	Keys_Quad,
	Pad_Quad,
	Stick,
}

Device_Source :: struct {
	kind:       Source_Kind,
	code:       string,
	neg_code:   string,
	pos_code:   string,
	neg_y_code: string,
	pos_y_code: string,
}

Resolved_Binding :: struct {
	player: PlayerId,
	action: Action_Def,
	source: Device_Source,
}

Bindings_Table :: struct {
	registry:      Action_Registry,
	resolved:      []Resolved_Binding,
	owns_registry: bool,
}

Rebinding_Overlay :: struct {
}

IDENTITY_OVERLAY :: Rebinding_Overlay{}

apply_overlay :: proc(
	bindings: []Binding,
	overlay: Rebinding_Overlay,
) -> []Binding {
	return bindings
}

build_bindings_table :: proc(
	program: Program,
	overlay := IDENTITY_OVERLAY,
	allocator := context.allocator,
) -> Bindings_Table {
	registry := program.registry
	owns_registry := false
	if registry.by_key == nil {
		registry = build_action_registry(program, allocator)
		owns_registry = true
	}
	defaults := apply_overlay(program.bindings, overlay)

	resolved := make([dynamic]Resolved_Binding, 0, 0, allocator)
	for binding in defaults {
		player, player_ok := player_from_string(binding.player)
		if !player_ok {
			continue
		}
		action, action_ok := registry_find_token(registry, binding.action)
		if !action_ok {
			continue
		}
		source, source_ok := parse_source(binding.source, allocator)
		if !source_ok {
			continue
		}
		append(&resolved, Resolved_Binding{player = player, action = action, source = source})
	}
	return Bindings_Table{registry = registry, resolved = resolved[:], owns_registry = owns_registry}
}

delete_bindings_table :: proc(table: Bindings_Table) {
	delete(table.resolved)
	if table.owns_registry {
		delete_action_registry(table.registry)
	}
}

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
	args := token[open + 1:len(token) - 1]
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
	case "mouse":
		if len(parts) != 1 {
			return {}, false
		}
		return Device_Source{kind = .Mouse, code = strings.clone(strings.trim_space(parts[0]), allocator)},
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
	case "pad_quad":
		if len(parts) != 4 {
			return {}, false
		}
		return Device_Source {
				kind = .Pad_Quad,
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

Device_Event_Kind :: enum {
	Key_Down,
	Key_Up,
	Pad_Down,
	Pad_Up,
	Mouse_Down,
	Mouse_Up,
	Stick_Sample,
}

Stick_Axis :: enum {
	X,
	Y,
}

Device_Event :: struct {
	kind:       Device_Event_Kind,
	seq:        int,
	code:       string,
	stick_axis: Stick_Axis,
	sample:     Fixed,
}

Device_Queue :: struct {
	events:   [dynamic]Device_Event,
	next_seq: int,
}

new_device_queue :: proc(allocator := context.allocator) -> Device_Queue {
	return Device_Queue{events = make([dynamic]Device_Event, allocator)}
}

delete_device_queue :: proc(queue: Device_Queue) {
	q := queue
	delete(q.events)
}

enqueue_key_down :: proc(queue: ^Device_Queue, code: string) {
	enqueue(queue, Device_Event{kind = .Key_Down, code = code})
}

enqueue_key_up :: proc(queue: ^Device_Queue, code: string) {
	enqueue(queue, Device_Event{kind = .Key_Up, code = code})
}

enqueue_pad_down :: proc(queue: ^Device_Queue, code: string) {
	enqueue(queue, Device_Event{kind = .Pad_Down, code = code})
}

enqueue_pad_up :: proc(queue: ^Device_Queue, code: string) {
	enqueue(queue, Device_Event{kind = .Pad_Up, code = code})
}

enqueue_mouse_down :: proc(queue: ^Device_Queue, code: string) {
	enqueue(queue, Device_Event{kind = .Mouse_Down, code = code})
}

enqueue_mouse_up :: proc(queue: ^Device_Queue, code: string) {
	enqueue(queue, Device_Event{kind = .Mouse_Up, code = code})
}

enqueue_stick_sample :: proc(queue: ^Device_Queue, code: string, stick_axis: Stick_Axis, sample: Fixed) {
	enqueue(
		queue,
		Device_Event{kind = .Stick_Sample, code = code, stick_axis = stick_axis, sample = sample},
	)
}

@(private = "file")
enqueue :: proc(queue: ^Device_Queue, event: Device_Event) {
	ev := event
	ev.seq = queue.next_seq
	queue.next_seq += 1
	append(&queue.events, ev)
}

clear_window :: proc(queue: ^Device_Queue) {
	clear(&queue.events)
	queue.next_seq = 0
}

Device_Levels :: struct {
	down:         map[string]bool,
	stick_sample: map[Stick_Sample_Key]Fixed,
}

new_device_levels :: proc(allocator := context.allocator) -> Device_Levels {
	return Device_Levels {
		down = make(map[string]bool, allocator),
		stick_sample = make(map[Stick_Sample_Key]Fixed, allocator),
	}
}

delete_device_levels :: proc(levels: Device_Levels) {
	lv := levels
	delete(lv.down)
	delete(lv.stick_sample)
}

AXIS_DEADZONE :: proc() -> Fixed {
	return fixed_from_decimal(0, "1")
}

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
		snapshot.axes[key] = Vec2 {
			x = fixed_clamp(total.x, fixed_neg(to_fixed(1)), to_fixed(1)),
			y = fixed_clamp(total.y, fixed_neg(to_fixed(1)), to_fixed(1)),
		}
	}

	levels_after = level_set_from_window(window, allocator)

	clear_window(queue)
	return snapshot, held_after, levels_after
}

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

@(private = "file")
Window_Levels :: struct {
	went_down:    map[string]bool,
	level:        map[string]bool,
	stick_sample: map[Stick_Sample_Key]Fixed,
}

@(private = "file")
Stick_Sample_Key :: struct {
	code:       string,
	stick_axis: Stick_Axis,
}

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
	for code, is_down in prev_levels.down {
		if is_down {
			levels.level[code] = true
		}
	}
	for key, sample in prev_levels.stick_sample {
		levels.stick_sample[key] = sample
	}
	for event in queue.events {
		switch event.kind {
		case .Key_Down, .Pad_Down, .Mouse_Down:
			levels.went_down[event.code] = true
			levels.level[event.code] = true
		case .Key_Up, .Pad_Up, .Mouse_Up:
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

@(private = "file")
Button_Accum :: struct {
	went_down: bool,
	level_now: bool,
}

@(private = "file")
accumulate_button :: proc(
	buttons: ^map[Player_Action]Button_Accum,
	key: Player_Action,
	source: Device_Source,
	window: Window_Levels,
) {
	if source.kind != .Key && source.kind != .Pad && source.kind != .Mouse {
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
		contribution.x = key_pair_level(window, source.neg_code, source.pos_code)
	case .Stick_X, .Stick_Y:
		axis_component := source.kind == .Stick_X ? Stick_Axis.X : Stick_Axis.Y
		sample, sampled := window.stick_sample[Stick_Sample_Key{source.code, axis_component}]
		if sampled {
			contribution.x = apply_deadzone(sample)
		}
	case .Keys_Quad, .Pad_Quad:
		contribution.x = key_pair_level(window, source.neg_code, source.pos_code)
		contribution.y = key_pair_level(window, source.neg_y_code, source.pos_y_code)
	case .Stick:
		if sample, sampled := window.stick_sample[Stick_Sample_Key{source.code, .X}]; sampled {
			contribution.x = apply_deadzone(sample)
		}
		if sample, sampled := window.stick_sample[Stick_Sample_Key{source.code, .Y}]; sampled {
			contribution.y = apply_deadzone(sample)
		}
	case .Key, .Pad, .Mouse:
		return
	}
	total := axes[key]
	axes[key] = Vec2{fixed_add(total.x, contribution.x), fixed_add(total.y, contribution.y)}
}

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

@(private = "file")
apply_deadzone :: proc(sample: Fixed) -> Fixed {
	dz := AXIS_DEADZONE()
	magnitude := sample < 0 ? fixed_neg(sample) : sample
	if magnitude <= dz {
		return Fixed(0)
	}
	return sample
}
