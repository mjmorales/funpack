package funpack_runtime

PlayerId :: enum {
	P1,
	P2,
	P3,
	P4,
}

ActionId :: distinct u32

Vec2 :: struct {
	x: Fixed,
	y: Fixed,
}

VEC2_ZERO :: Vec2{Fixed(0), Fixed(0)}

Button_State :: struct {
	pressed:  bool,
	released: bool,
	held:     bool,
}

Player_Action :: struct {
	player: PlayerId,
	action: ActionId,
}

Input :: struct {
	buttons: map[Player_Action]Button_State,
	axes:    map[Player_Action]Vec2,
}

empty :: proc() -> Input {
	return Input{buttons = make(map[Player_Action]Button_State), axes = make(map[Player_Action]Vec2)}
}

with_pressed :: proc(input: Input, player: PlayerId, action: ActionId) -> Input {
	next := clone_input(input)
	key := Player_Action{player, action}
	state := next.buttons[key]
	state.pressed = true
	state.held = true
	next.buttons[key] = state
	return next
}

with_held :: proc(input: Input, player: PlayerId, action: ActionId) -> Input {
	next := clone_input(input)
	key := Player_Action{player, action}
	state := next.buttons[key]
	state.held = true
	next.buttons[key] = state
	return next
}

with_value :: proc(input: Input, player: PlayerId, action: ActionId, value: Fixed) -> Input {
	next := clone_input(input)
	key := Player_Action{player, action}
	vec := next.axes[key]
	vec.x = clamp_unit(value)
	next.axes[key] = vec
	return next
}

with_axis :: proc(input: Input, player: PlayerId, action: ActionId, axis: Vec2) -> Input {
	next := clone_input(input)
	key := Player_Action{player, action}
	next.axes[key] = Vec2{clamp_unit(axis.x), clamp_unit(axis.y)}
	return next
}

pressed :: proc(input: Input, player: PlayerId, action: ActionId) -> bool {
	return input.buttons[Player_Action{player, action}].pressed
}

released :: proc(input: Input, player: PlayerId, action: ActionId) -> bool {
	return input.buttons[Player_Action{player, action}].released
}

held :: proc(input: Input, player: PlayerId, action: ActionId) -> bool {
	return input.buttons[Player_Action{player, action}].held
}

value :: proc(input: Input, player: PlayerId, action: ActionId) -> Fixed {
	return input.axes[Player_Action{player, action}].x
}

axis :: proc(input: Input, player: PlayerId, action: ActionId) -> Vec2 {
	return input.axes[Player_Action{player, action}]
}

@(private = "file")
clamp_unit :: proc(v: Fixed) -> Fixed {
	return fixed_clamp(v, fixed_neg(to_fixed(1)), to_fixed(1))
}

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

delete_input :: proc(input: Input) {
	snap := input
	delete(snap.buttons)
	delete(snap.axes)
}
