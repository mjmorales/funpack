package funpack

import "core:strings"

Level_Spawn_Batch :: struct {
	fn_name: string,
	spawns:  []Baked_Spawn,
}

level_setup_batch :: proc(ast: Ast, batches: []Level_Spawn_Batch) -> (batch: Level_Spawn_Batch, found: bool) {
	if len(batches) == 0 {
		return Level_Spawn_Batch{}, false
	}
	for fn in ast.fns {
		if fn.name != "setup" {
			continue
		}
		ret, has_return := single_return_expr(fn.body)
		if !has_return {
			return Level_Spawn_Batch{}, false
		}
		call, is_call := ret.(^Call_Expr)
		if !is_call || len(call.args) != 0 {
			return Level_Spawn_Batch{}, false
		}
		name, is_name := call.callee.(^Name_Expr)
		if !is_name {
			return Level_Spawn_Batch{}, false
		}
		for candidate in batches {
			if candidate.fn_name == name.name {
				return candidate, true
			}
		}
		return Level_Spawn_Batch{}, false
	}
	return Level_Spawn_Batch{}, false
}

emit_level_setup :: proc(b: ^strings.Builder, batch: Level_Spawn_Batch, own_things: []Thing_Node, imported_things: []Thing_Node) {
	emit_header(b, "setup", len(batch.spawns))
	for spawn in batch.spawns {
		params := emittable_params(spawn.params)
		count := 1 + len(params)
		if spawn.has_facing {
			count += 1
		}
		strings.write_string(b, "spawn ")
		strings.write_string(b, spawn.thing_type)
		strings.write_byte(b, ' ')
		strings.write_int(b, count)
		emit_line(b, "")
		emit_line(b, "set pos =vec2 ", encode_fixed(spawn.pos.x, context.temp_allocator), " ", encode_fixed(spawn.pos.y, context.temp_allocator))
		if spawn.has_facing {
			emit_line(b, "set facing =", encode_fixed(spawn.facing, context.temp_allocator))
		}
		for param in params {
			emit_line(b, "set ", param.field, " =", encode_level_param(spawn.thing_type, param, own_things, imported_things))
		}
	}
}

emittable_params :: proc(params: []Baked_Param) -> []Baked_Param {
	out := make([dynamic]Baked_Param, 0, len(params), context.temp_allocator)
	for param in params {
		if param.is_ref {
			continue
		}
		append(&out, param)
	}
	return out[:]
}

encode_level_param :: proc(thing_type: string, param: Baked_Param, own_things: []Thing_Node, imported_things: []Thing_Node) -> string {
	field, found := level_param_field(thing_type, param.field, own_things, imported_things)
	if found {
		switch type_ref_string(field.type) {
		case "Int":
			return encode_int(fixed_trunc(param.value), context.temp_allocator)
		case "Bool":
			return encode_bool(param.value != Fixed(0))
		}
	}
	return encode_fixed(param.value, context.temp_allocator)
}

level_param_field :: proc(thing_type: string, field_name: string, own_things: []Thing_Node, imported_things: []Thing_Node) -> (field: Field_Decl, found: bool) {
	for thing in own_things {
		if thing.name == thing_type {
			return flvl_schema_field(thing, field_name)
		}
	}
	for thing in imported_things {
		if thing.name == thing_type {
			return flvl_schema_field(thing, field_name)
		}
	}
	return Field_Decl{}, false
}
