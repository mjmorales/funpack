package funpack

Pipeline_Slot :: enum {
	Update,
	Render,
	Startup,
	Ui,
	Audio,
}

Contract_Error :: enum {
	None,
	Render_Emits,
	Render_Takes_Signal,
	Render_Takes_Rng,
	Render_No_Draw,
	Startup_Reads_Thing,
	Startup_No_Spawn,
	Update_Dead,
	Unknown_Battery,
}

Contract_Verdict :: struct {
	err:      Contract_Error,
	behavior: string,
	line:     int,
}

stage_contracts :: proc(typed: Typed_Ast) -> Contract_Verdict {
	for pipeline in typed.ast.pipelines {
		seen := make(map[string]bool, context.temp_allocator)
		for stage in pipeline.stages {
			if stage.is_battery {
				if !is_engine_battery(stage.battery) {
					return Contract_Verdict{err = .Unknown_Battery, behavior = stage.battery, line = pipeline.line}
				}
				continue
			}
			slot := slot_of_stage(stage.name)
			for member in stage.behaviors {
				if seen[member] {
					continue
				}
				seen[member] = true
				if verdict := check_member(typed.env, slot, member); verdict.err != .None {
					return verdict
				}
			}
		}
	}
	return Contract_Verdict{err = .None}
}

is_engine_battery :: proc(name: string) -> bool {
	switch name {
	case "solve":
		return true
	}
	return false
}

check_member :: proc(env: Type_Env, slot: Pipeline_Slot, member: string) -> Contract_Verdict {
	term, found := env_term_name(env, member)
	if !found || term.signature == nil {
		return Contract_Verdict{err = .None}
	}
	if err := check_contract(slot, term.target, term.signature); err != .None {
		return Contract_Verdict{err = err, behavior = member}
	}
	return Contract_Verdict{err = .None}
}

slot_of_stage :: proc(name: string) -> Pipeline_Slot {
	switch name {
	case "startup":
		return .Startup
	case "render":
		return .Render
	case "ui":
		return .Ui
	case "audio":
		return .Audio
	}
	return .Update
}

check_contract :: proc(slot: Pipeline_Slot, target: string, signature: ^Func_Type) -> Contract_Error {
	switch slot {
	case .Render:
		return check_render(signature)
	case .Startup:
		return check_startup(signature)
	case .Update:
		return check_update(target, signature)
	case .Ui, .Audio:
		return .None
	}
	return .None
}

check_render :: proc(signature: ^Func_Type) -> Contract_Error {
	for param in signature.params {
		if is_signal_list(param) {
			return .Render_Takes_Signal
		}
		if is_engine(param, .Rng) {
			return .Render_Takes_Rng
		}
	}
	if is_command_list(signature.result, .Draw) || is_command_list(signature.result, .Draw3) {
		return .None
	}
	if is_signal_list(signature.result) || is_any_command_list(signature.result) {
		return .Render_Emits
	}
	return .Render_No_Draw
}

check_startup :: proc(signature: ^Func_Type) -> Contract_Error {
	for param in signature.params {
		if is_thing(param) || is_view(param) {
			return .Startup_Reads_Thing
		}
	}
	if !is_command_list(write_of_return(signature.result), .Spawn) {
		return .Startup_No_Spawn
	}
	return .None
}

check_update :: proc(target: string, signature: ^Func_Type) -> Contract_Error {
	if writes_own_blackboard_in_return(signature.result, target) {
		return .None
	}
	result := write_of_return(signature.result)
	if is_signal_list(result) || is_any_command_list(result) {
		return .None
	}
	return .Update_Dead
}

write_of_return :: proc(result: Type) -> Type {
	tuple, is_tuple := result.(^Tuple_Type)
	if !is_tuple {
		return result
	}
	for element in tuple.elements {
		if is_signal_list(element) || is_any_command_list(element) {
			return element
		}
	}
	return result
}

writes_own_blackboard_in_return :: proc(result: Type, target: string) -> bool {
	if writes_own_blackboard(result, target) {
		return true
	}
	tuple, is_tuple := result.(^Tuple_Type)
	if !is_tuple {
		return false
	}
	for element in tuple.elements {
		if writes_own_blackboard(element, target) {
			return true
		}
	}
	return false
}

writes_own_blackboard :: proc(result: Type, target: string) -> bool {
	user, is_user := result.(^User_Type)
	if !is_user || user.kind != .Thing {
		return false
	}
	return target == "" || user.name == target
}

is_thing :: proc(t: Type) -> bool {
	user, is_user := t.(^User_Type)
	return is_user && user.kind == .Thing
}

is_view :: proc(t: Type) -> bool {
	return is_engine(t, .View)
}

is_signal_list :: proc(t: Type) -> bool {
	list, is_list := t.(^List_Type)
	if !is_list {
		return false
	}
	user, is_user := list.elem.(^User_Type)
	return is_user && user.kind == .Signal
}

is_command_list :: proc(t: Type, kind: Engine_Kind) -> bool {
	list, is_list := t.(^List_Type)
	if !is_list {
		return false
	}
	return is_engine(list.elem, kind)
}

is_any_command_list :: proc(t: Type) -> bool {
	return(
		is_command_list(t, .Spawn) ||
		is_command_list(t, .Despawn) ||
		is_command_list(t, .Draw) ||
		is_command_list(t, .Draw3) ||
		is_command_list(t, .Save) ||
		is_command_list(t, .Restore) ||
		is_command_list(t, .ApplySettings) ||
		is_command_list(t, .Sound) ||
		is_command_list(t, .SetTile) ||
		is_command_list(t, .BuildLayer) \
	)
}
