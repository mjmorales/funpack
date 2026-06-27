package funpack

Fui_Type :: union {
	Fui_Prim,
	Fui_List,
	Fui_Named,
}

Fui_Prim :: enum {
	Int,
	Bool,
	String,
}

Fui_List :: struct {
	row: string,
}

Fui_Named :: struct {
	token: string,
}

Fui_Field :: struct {
	name: string,
	type: Fui_Type,
}

Fui_Variant :: struct {
	name:        string,
	payload:     Fui_Type,
	has_payload: bool,
}

Fui_Record :: struct {
	name:   string,
	fields: []Fui_Field,
}

Inferred_Seam :: struct {
	screen_name:  string,
	view_name:    string,
	msg_name:     string,
	view_fields:  []Fui_Field,
	msg_variants: []Fui_Variant,
	row_types:    []Fui_Record,
}

fui_infer_ctx :: struct {
	screen_name:  string,
	view_fields:  [dynamic]Fui_Field,
	msg_variants: [dynamic]Fui_Variant,
	row_types:    [dynamic]Fui_Record,
}

infer_seam :: proc(screen: Fui_Screen) -> Inferred_Seam {
	ctx := fui_infer_ctx {
		screen_name  = screen.name,
		view_fields  = make([dynamic]Fui_Field, 0, 8, context.temp_allocator),
		msg_variants = make([dynamic]Fui_Variant, 0, 8, context.temp_allocator),
		row_types    = make([dynamic]Fui_Record, 0, 2, context.temp_allocator),
	}
	infer_nodes(&ctx, screen.body, nil)
	return Inferred_Seam {
		screen_name  = screen.name,
		view_name    = fui_concat(screen.name, "View", ""),
		msg_name     = fui_concat(screen.name, "Msg", ""),
		view_fields  = ctx.view_fields[:],
		msg_variants = ctx.msg_variants[:],
		row_types    = ctx.row_types[:],
	}
}

infer_nodes :: proc(ctx: ^fui_infer_ctx, nodes: []Fui_Node, loop_vars: []string) {
	for node in nodes {
		switch n in node {
		case ^Fui_Element:
			infer_element(ctx, n, loop_vars)
		case ^Fui_Text:
			infer_text(ctx, n, loop_vars)
		case ^Fui_If:
			infer_if(ctx, n, loop_vars)
		case ^Fui_For:
			infer_for(ctx, n, loop_vars)
		}
	}
}

infer_element :: proc(ctx: ^fui_infer_ctx, el: ^Fui_Element, loop_vars: []string) {
	for attr in el.attrs {
		switch attr.kind {
		case .Plain:
		case .Bind_In:
			path := attr.value.(Fui_Path)
			infer_read_path(ctx, path, loop_vars, Fui_Prim.String)
		case .Event:
			infer_event(ctx, attr.value.(Fui_Msg_Ref))
		case .Two_Way:
			path := attr.value.(Fui_Path)
			prim := fui_widget_bind_type(el.widget)
			infer_read_path(ctx, path, loop_vars, prim)
			fui_add_variant(ctx, fui_set_variant_name(path), prim, true)
		}
	}
	infer_nodes(ctx, el.children, loop_vars)
}

infer_text :: proc(ctx: ^fui_infer_ctx, t: ^Fui_Text, loop_vars: []string) {
	for hole in t.holes {
		infer_read_path(ctx, hole, loop_vars, Fui_Prim.Int)
	}
}

infer_if :: proc(ctx: ^fui_infer_ctx, n: ^Fui_If, loop_vars: []string) {
	infer_read_path(ctx, n.cond, loop_vars, Fui_Prim.Bool)
	infer_nodes(ctx, n.children, loop_vars)
}

infer_for :: proc(ctx: ^fui_infer_ctx, n: ^Fui_For, loop_vars: []string) {
	row_name := fui_row_record_name_for(ctx.screen_name, n.list)
	fui_add_field(ctx, n.list.segments[0], Fui_List{row = row_name})
	row_idx := fui_ensure_record(ctx, row_name)
	if n.has_row_type {
		for rf in n.row_type {
			fui_add_record_field(ctx, row_idx, rf.name, Fui_Named{token = rf.type})
		}
	}
	inner := fui_push_loop_var(loop_vars, n.var)
	infer_for_body(ctx, n.children, inner, n.var, row_idx, n.has_row_type)
}

infer_for_body :: proc(ctx: ^fui_infer_ctx, nodes: []Fui_Node, loop_vars: []string, loop_var: string, row_idx: int, pinned: bool) {
	for node in nodes {
		switch n in node {
		case ^Fui_Element:
			for attr in n.attrs {
				#partial switch attr.kind {
				case .Bind_In:
					infer_for_path(ctx, attr.value.(Fui_Path), loop_vars, loop_var, row_idx, pinned, Fui_Prim.String)
				case .Event:
					ref := attr.value.(Fui_Msg_Ref)
					fui_record_msg(ctx, ref, loop_vars, loop_var, row_idx, pinned)
				case .Two_Way:
					path := attr.value.(Fui_Path)
					prim := fui_widget_bind_type(n.widget)
					infer_for_path(ctx, path, loop_vars, loop_var, row_idx, pinned, prim)
					fui_add_variant(ctx, fui_set_variant_name(path), prim, true)
				}
			}
			infer_for_body(ctx, n.children, loop_vars, loop_var, row_idx, pinned)
		case ^Fui_Text:
			for hole in n.holes {
				infer_for_path(ctx, hole, loop_vars, loop_var, row_idx, pinned, Fui_Prim.Int)
			}
		case ^Fui_If:
			infer_for_path(ctx, n.cond, loop_vars, loop_var, row_idx, pinned, Fui_Prim.Bool)
			infer_for_body(ctx, n.children, loop_vars, loop_var, row_idx, pinned)
		case ^Fui_For:
			infer_for(ctx, n, loop_vars)
		}
	}
}

infer_event :: proc(ctx: ^fui_infer_ctx, ref: Fui_Msg_Ref) {
	if !ref.has_payload {
		fui_add_variant(ctx, ref.variant, nil, false)
		return
	}
	fui_add_variant(ctx, ref.variant, Fui_Prim.Int, true)
}

fui_record_msg :: proc(ctx: ^fui_infer_ctx, ref: Fui_Msg_Ref, loop_vars: []string, loop_var: string, row_idx: int, pinned: bool) {
	if !ref.has_payload {
		fui_add_variant(ctx, ref.variant, nil, false)
		return
	}
	infer_for_path(ctx, ref.payload, loop_vars, loop_var, row_idx, pinned, Fui_Prim.Int)
	fui_add_variant(ctx, ref.variant, Fui_Prim.Int, true)
}

infer_read_path :: proc(ctx: ^fui_infer_ctx, path: Fui_Path, loop_vars: []string, prim: Fui_Prim) {
	if fui_path_is_loop_rooted(path, loop_vars) {
		return
	}
	fui_add_field(ctx, path.segments[0], prim)
}

infer_for_path :: proc(ctx: ^fui_infer_ctx, path: Fui_Path, loop_vars: []string, loop_var: string, row_idx: int, pinned: bool, prim: Fui_Prim) {
	if len(path.segments) >= 2 && path.segments[0] == loop_var {
		if !pinned {
			leaf := path.segments[len(path.segments)-1]
			fui_add_record_field(ctx, row_idx, leaf, prim)
		}
		return
	}
	infer_read_path(ctx, path, loop_vars, prim)
}

fui_add_field :: proc(ctx: ^fui_infer_ctx, name: string, type: Fui_Type) {
	for f in ctx.view_fields {
		if f.name == name {
			return
		}
	}
	append(&ctx.view_fields, Fui_Field{name = name, type = type})
}

fui_add_variant :: proc(ctx: ^fui_infer_ctx, name: string, payload: Fui_Type, has_payload: bool) {
	for v in ctx.msg_variants {
		if v.name == name {
			return
		}
	}
	append(&ctx.msg_variants, Fui_Variant{name = name, payload = payload, has_payload = has_payload})
}

fui_ensure_record :: proc(ctx: ^fui_infer_ctx, name: string) -> int {
	for r, i in ctx.row_types {
		if r.name == name {
			return i
		}
	}
	append(&ctx.row_types, Fui_Record{name = name, fields = nil})
	return len(ctx.row_types) - 1
}

fui_add_record_field :: proc(ctx: ^fui_infer_ctx, row_idx: int, name: string, type: Fui_Type) {
	rec := &ctx.row_types[row_idx]
	for f in rec.fields {
		if f.name == name {
			return
		}
	}
	fields := make([dynamic]Fui_Field, 0, len(rec.fields)+1, context.temp_allocator)
	append(&fields, ..rec.fields)
	append(&fields, Fui_Field{name = name, type = type})
	rec.fields = fields[:]
}

fui_widget_bind_type :: proc(widget: Fui_Widget_Kind) -> Fui_Prim {
	#partial switch widget {
	case .Field:
		return .String
	case .Slider, .Toggle, .Select:
		return .Int
	}
	return .String
}

fui_set_variant_name :: proc(path: Fui_Path) -> string {
	leaf := path.segments[len(path.segments)-1]
	return fui_concat("Set", fui_upper_camel(leaf), "")
}

fui_row_record_name_for :: proc(screen_name: string, list: Fui_Path) -> string {
	leaf := list.segments[len(list.segments)-1]
	core := fui_upper_camel(fui_singularize(fui_last_word(leaf)))
	return fui_concat(screen_name, core, "Row")
}

fui_last_word :: proc(name: string) -> string {
	last := 0
	for i in 0 ..< len(name) {
		if name[i] == '_' {
			last = i + 1
		}
	}
	return name[last:]
}

fui_singularize :: proc(word: string) -> string {
	if len(word) > 3 && word[len(word)-3:] == "ies" {
		return fui_concat(word[:len(word)-3], "y", "")
	}
	if len(word) > 1 && word[len(word)-1] == 's' {
		return word[:len(word)-1]
	}
	return word
}

fui_upper_camel :: proc(name: string) -> string {
	out := make([dynamic]u8, 0, len(name), context.temp_allocator)
	at_word_start := true
	for i in 0 ..< len(name) {
		ch := name[i]
		if ch == '_' {
			at_word_start = true
			continue
		}
		if at_word_start && ch >= 'a' && ch <= 'z' {
			append(&out, ch - ('a' - 'A'))
		} else {
			append(&out, ch)
		}
		at_word_start = false
	}
	return string(out[:])
}

fui_path_is_loop_rooted :: proc(path: Fui_Path, loop_vars: []string) -> bool {
	if len(path.segments) == 0 {
		return false
	}
	root := path.segments[0]
	for v in loop_vars {
		if v == root {
			return true
		}
	}
	return false
}

fui_push_loop_var :: proc(loop_vars: []string, name: string) -> []string {
	out := make([dynamic]string, 0, len(loop_vars)+1, context.temp_allocator)
	append(&out, ..loop_vars)
	append(&out, name)
	return out[:]
}
