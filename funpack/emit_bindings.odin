package funpack

import "core:strings"

emit_bindings :: proc(b: ^strings.Builder, ast: Ast) {
	binds := binding_calls(ast)
	emit_header(b, "bindings", len(binds))
	for bind in binds {
		strings.write_string(b, "bind ")
		strings.write_string(b, bind.kind)
		strings.write_byte(b, ' ')
		strings.write_string(b, bind.player)
		strings.write_byte(b, ' ')
		strings.write_string(b, bind.action)
		emit_line(b, " source:", bind.source)
	}
}

Binding_Record :: struct {
	kind:   string,
	player: string,
	action: string,
	source: string,
}

binding_calls :: proc(ast: Ast) -> []Binding_Record {
	for fn in ast.fns {
		if fn.name != "bindings" {
			continue
		}
		if len(fn.body) != 1 {
			return nil
		}
		ret, is_return := fn.body[0].(Return_Node)
		if !is_return {
			return nil
		}
		binds := make([dynamic]Binding_Record, 0, 4, context.temp_allocator)
		collect_binding_calls(ret.value, &binds)
		return binds[:]
	}
	return nil
}

collect_binding_calls :: proc(expr: Expr, binds: ^[dynamic]Binding_Record) {
	call, is_call := expr.(^Call_Expr)
	if !is_call {
		return
	}
	member, is_member := call.callee.(^Member_Expr)
	if !is_member {
		return
	}
	collect_binding_calls(member.receiver, binds)
	kind := binding_kind(member.member)
	if kind == "" {
		return
	}
	if len(call.args) != 3 {
		return
	}
	player := variant_case(call.args[0])
	action := variant_path(call.args[1])
	if list, is_list := call.args[2].(^List_Expr); is_list {
		for element in list.elements {
			source := device_code_source(element)
			if source == "" {
				continue
			}
			append(binds, Binding_Record{kind = kind, player = player, action = action, source = source})
		}
		return
	}
	append(binds, Binding_Record{
		kind   = kind,
		player = player,
		action = action,
		source = lower_source_call(call.args[2]),
	})
}

device_code_source :: proc(expr: Expr) -> string {
	variant, is_variant := expr.(^Variant_Expr)
	if !is_variant {
		return ""
	}
	helper := ""
	switch variant.type_name {
	case "Key":
		helper = "key"
	case "PadButton":
		helper = "pad"
	case:
		return ""
	}
	return strings.concatenate({helper, "(", variant.type_name, "::", variant.variant, ")"}, context.temp_allocator)
}

lower_source_call :: proc(expr: Expr) -> string {
	call, is_call := expr.(^Call_Expr)
	if !is_call {
		return ""
	}
	if name, is_name := call.callee.(^Name_Expr); is_name {
		if name.name == "wasd" && len(call.args) == 0 {
			return "keys_quad(Key::A,Key::D,Key::W,Key::S)"
		}
		if name.name == "arrows" && len(call.args) == 0 {
			return "keys_quad(Key::Left,Key::Right,Key::Up,Key::Down)"
		}
		if name.name == "dpad" && len(call.args) == 0 {
			return "pad_quad(PadButton::DpadLeft,PadButton::DpadRight,PadButton::DpadUp,PadButton::DpadDown)"
		}
	}
	return builder_call_string(expr)
}

binding_kind :: proc(member: string) -> string {
	switch member {
	case "axis":
		return "axis"
	case "button":
		return "button"
	}
	return ""
}

variant_case :: proc(expr: Expr) -> string {
	if variant, ok := expr.(^Variant_Expr); ok {
		return variant.variant
	}
	return ""
}

variant_path :: proc(expr: Expr) -> string {
	if variant, ok := expr.(^Variant_Expr); ok {
		return strings.concatenate({variant.type_name, "::", variant.variant}, context.temp_allocator)
	}
	return ""
}

builder_call_string :: proc(expr: Expr) -> string {
	call, is_call := expr.(^Call_Expr)
	if !is_call {
		return ""
	}
	name, is_name := call.callee.(^Name_Expr)
	if !is_name {
		return ""
	}
	b := strings.builder_make(context.temp_allocator)
	strings.write_string(&b, name.name)
	strings.write_byte(&b, '(')
	for arg, i in call.args {
		if i > 0 {
			strings.write_byte(&b, ',')
		}
		strings.write_string(&b, variant_path(arg))
	}
	strings.write_byte(&b, ')')
	return strings.to_string(b)
}

emit_entrypoint :: proc(b: ^strings.Builder, entrypoint: Entrypoint_Config) {
	emit_header(b, "entrypoint", 1)
	strings.write_string(b, "entrypoint ")
	strings.write_string(b, entrypoint.name)
	strings.write_string(b, " pipeline:")
	strings.write_string(b, entrypoint.pipeline)
	strings.write_string(b, " tick_hz:")
	strings.write_int(b, entrypoint.tick_hz)
	strings.write_string(b, " logical:")
	strings.write_int(b, entrypoint.logical_w)
	strings.write_byte(b, 'x')
	strings.write_int(b, entrypoint.logical_h)
	strings.write_string(b, " bindings:")
	strings.write_string(b, entrypoint.bindings)
	if entrypoint.has_seed {
		strings.write_string(b, " seed:")
		strings.write_i64(b, entrypoint.seed)
	}
	strings.write_byte(b, '\n')
}

emit_queries :: proc(b: ^strings.Builder, ast: Ast, module: string) {
	emit_header(b, "queries", len(ast.queries))
	for query in ast.queries {
		strings.write_string(b, "query ")
		strings.write_string(b, query.name)
		strings.write_byte(b, ' ')
		strings.write_int(b, len(query.params))
		strings.write_string(b, " return:")
		strings.write_string(b, type_ref_string(query.return_type))
		strings.write_byte(b, ' ')
		strings.write_int(b, len(query.indexes))
		strings.write_byte(b, ' ')
		strings.write_int(b, len(query.body))
		strings.write_string(b, " span:")
		strings.write_string(b, module)
		strings.write_byte(b, ':')
		strings.write_int(b, query.line)
		emit_line(b, "")
		for param in query.params {
			emit_line(b, "param ", param.name, " ", type_ref_string(param.type))
		}
		for directive in query.indexes {
			emit_line(b, "index ", index_directive_tag(directive.kind), " ", directive.thing, " ", directive.field)
		}
		emit_body(b, query.body)
	}
}

index_directive_tag :: proc(kind: Index_Directive_Kind) -> string {
	switch kind {
	case .Index:
		return "index"
	case .Spatial:
		return "spatial"
	}
	return "index"
}
