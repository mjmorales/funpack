// The §21 UI-seam emitter: the screen pipeline's source-TEXT serializer for a
// parsed+inferred Fui_Screen (fui_infer.odin's Inferred_Seam) → the committed
// gen/<screen>.gen.fun seam. It is the UI analogue of flvl_emit.odin (levels) and
// fpm_emit.odin (modeling) for the screen form examples/hud bakes, and the byte
// target is the committed exemplars funpack-spec/examples/hud/gen/{hud,settings,
// pause}.gen.fun.
//
// DISTINCT FROM gen_emit.odin: that emitter renders the `data`/`extern fn`
// declaration shape the levels/assets seams use; the screen seam adds an
// `enum <Name>Msg { … }` (with payload variants), a PARAMETERIZED extern fn
// (`extern fn <screen>(model: <Name>View) -> View[<Name>Msg]`), and a brace-less
// single-symbol import (`import engine.ui.View`) — none of which the Seam_Decl_Kind
// union or the always-braced emit_seam_import model. Following fpm_emit.odin's
// precedent (the rig form likewise rides its own model + emitter rather than being
// forced into the shared union), this file reuses gen_emit.odin's shared @doc line
// emitter (emit_seam_doc) and adds the screen-specific declaration emission
// locally, so the screen pipeline shares the file-leading-@doc byte contract
// without distorting the shared seam grammar.
//
// "The template IS the schema" (§21 §1): the read contract (data <Name>View),
// write contract (enum <Name>Msg), and per-list row records (data SettingsPresetRow)
// all fall out of the Inferred_Seam the inference produced from the template — the
// emitter declares nothing the template did not imply. The @doc prose is the one
// thing the bytes carry that the .fui does not encode, so it rides as bake metadata
// the caller supplies (the flvl/fpm seams carry their docs the same way).
//
// DETERMINISM (§29): emission walks the Inferred_Seam's ordered slices only
// (view_fields/msg_variants/row_types in first-seen template order, never a map),
// and the engine.prelude import members are accumulated in declaration-emission
// order. Two emissions of the same Inferred_Seam are byte-identical — the §29
// determinism tripwire is that field/variant ordering is template order, never map
// order.
package funpack

import "core:strings"

// Screen_Seam_Docs carries the authored @doc strings the screen emitter stamps onto
// the seam — bake metadata a faithful bake passes through from the committed
// exemplar (the seam's prose is not derivable from the template alone, matching
// flvl_emit.odin's Level_Seam_Docs). file heads the file; row/view/msg/builder head
// the four declaration kinds in emission order. row is empty for a screen with no
// for-list (Hud, Pause).
Screen_Seam_Docs :: struct {
	file:    string, // the file-leading @doc
	row:     string, // the `data <Screen><Singular>Row` for-list row record @doc (empty when no for-list)
	view:    string, // the `data <Name>View` read-contract @doc
	msg:     string, // the `enum <Name>Msg` write-contract @doc
	builder: string, // the `extern fn <screen>` view-builder @doc
}

// emit_screen_seam renders one screen's Inferred_Seam to canonical .gen.fun source
// bytes, matching the committed per-screen exemplar byte-for-byte (§21 §2). Layout:
// the file-leading @doc, a blank line, the import block (engine.prelude primitives
// when any are used, then the brace-less engine.ui.View), a blank line, then each
// @doc-headed declaration in emission order — the for-list row records first, the
// `data <Name>View` read contract, the `enum <Name>Msg` write contract, and the
// `extern fn <screen>(model: <Name>View) -> View[<Name>Msg]` builder — each offset
// by a single blank line. The output ends in exactly one trailing newline. The
// returned string is allocated in `allocator`.
emit_screen_seam :: proc(seam: Inferred_Seam, docs: Screen_Seam_Docs, allocator := context.allocator) -> string {
	b := strings.builder_make(allocator)
	emit_seam_doc(&b, docs.file)
	// Blank line between the file-leading @doc and the import block (the screen
	// seam's formatter-canonical header spacing).
	strings.write_string(&b, "\n")
	emit_screen_imports(&b, seam)

	// The row records first (a for-list field references its row by name), then the
	// read contract, the write contract, and the view builder — each offset by a
	// leading blank line.
	for record in seam.row_types {
		strings.write_string(&b, "\n")
		emit_seam_doc(&b, docs.row)
		emit_screen_row_data(&b, record)
	}
	strings.write_string(&b, "\n")
	emit_seam_doc(&b, docs.view)
	emit_screen_view_data(&b, seam)
	strings.write_string(&b, "\n")
	emit_seam_doc(&b, docs.msg)
	emit_screen_msg_enum(&b, seam)
	strings.write_string(&b, "\n")
	emit_seam_doc(&b, docs.builder)
	emit_screen_builder_fn(&b, seam)
	return strings.to_string(b)
}

// emit_screen_imports writes the screen seam's import block: `import
// engine.prelude.{<prims>}` ONLY when the seam's declarations use primitive types
// (Pause's empty view uses none, so it gets no prelude import), then the always-
// present brace-less `import engine.ui.View`. The prelude member list is the
// distinct primitives in declaration-emission order (row records first, then the
// view), so the order matches the committed exemplar's first-use order.
emit_screen_imports :: proc(b: ^strings.Builder, seam: Inferred_Seam) {
	prims := screen_prelude_prims(seam)
	if len(prims) > 0 {
		strings.write_string(b, "import engine.prelude.{")
		for prim, i in prims {
			if i > 0 {
				strings.write_string(b, ", ")
			}
			strings.write_string(b, prim)
		}
		strings.write_string(b, "}\n")
	}
	// The view-tree type is always imported, brace-less single-symbol form.
	strings.write_string(b, "import engine.ui.View\n")
}

// screen_prelude_prims collects the distinct primitive type tokens the seam's data
// declarations use, in declaration-emission order: each for-list row record (in
// row_types order) first, then the read-contract view fields. A field's primitive
// is the Fui_Prim token (Int/Bool/String); a list field's element type is a row
// record name (not a primitive) and a Named field is an ascribed domain token
// (not a primitive), so neither contributes a prelude member. Dedup is first-seen,
// matching the committed import order ({Int, Bool}, {Int, String}).
screen_prelude_prims :: proc(seam: Inferred_Seam) -> []string {
	out := make([dynamic]string, 0, 3, context.temp_allocator)
	for record in seam.row_types {
		for field in record.fields {
			add_prelude_prim(&out, field.type)
		}
	}
	for field in seam.view_fields {
		add_prelude_prim(&out, field.type)
	}
	return out[:]
}

// add_prelude_prim appends a field type's primitive token to the prelude member
// accumulator, deduplicated by name in first-seen order. Only a Fui_Prim
// contributes — a Fui_List (a row-record element type) and a Fui_Named (an ascribed
// domain token) are not prelude primitives, so they are skipped.
add_prelude_prim :: proc(out: ^[dynamic]string, type: Fui_Type) {
	prim, is_prim := type.(Fui_Prim)
	if !is_prim {
		return
	}
	token := fui_prim_token(prim)
	for seen in out {
		if seen == token {
			return
		}
	}
	append(out, token)
}

// emit_screen_row_data writes one for-list row record: `data <Name> { f: T, … }` on
// one line (the SettingsPresetRow inline form). Fields are comma-and-space
// separated with a single space inside each brace, matching the inline data layout.
emit_screen_row_data :: proc(b: ^strings.Builder, record: Fui_Record) {
	emit_screen_data_inline(b, record.name, record.fields)
}

// emit_screen_view_data writes the `data <Name>View { … }` read contract. An empty
// view emits `data <Name>View {}` exactly (no inner spaces) — the deliberate Pause
// edge case; a non-empty view emits the inline `{ f: T, g: U }` form.
emit_screen_view_data :: proc(b: ^strings.Builder, seam: Inferred_Seam) {
	emit_screen_data_inline(b, seam.view_name, seam.view_fields)
}

// emit_screen_data_inline writes a `data Name { f: T, g: U }` record on one line, or
// the empty `data Name {}` form (no inner spaces) when there are no fields. Field
// types render through screen_field_type_token (a primitive, a `[Row]` list, or an
// ascribed domain token).
emit_screen_data_inline :: proc(b: ^strings.Builder, name: string, fields: []Fui_Field) {
	strings.write_string(b, "data ")
	strings.write_string(b, name)
	if len(fields) == 0 {
		// The empty-view edge case (Pause): `data PauseView {}` — no inner spaces,
		// no dangling fields.
		strings.write_string(b, " {}\n")
		return
	}
	strings.write_string(b, " { ")
	for field, i in fields {
		if i > 0 {
			strings.write_string(b, ", ")
		}
		strings.write_string(b, field.name)
		strings.write_string(b, ": ")
		strings.write_string(b, screen_field_type_token(field.type))
	}
	strings.write_string(b, " }\n")
}

// emit_screen_msg_enum writes the `enum <Name>Msg { V0, V1(T), … }` write contract:
// the variants comma-and-space separated, a single space inside each brace, a
// nullary variant as its bare name and a payload variant as `Name(Type)`. A screen
// always has at least one variant in the §21 examples, so the enum is never empty.
emit_screen_msg_enum :: proc(b: ^strings.Builder, seam: Inferred_Seam) {
	strings.write_string(b, "enum ")
	strings.write_string(b, seam.msg_name)
	strings.write_string(b, " { ")
	for variant, i in seam.msg_variants {
		if i > 0 {
			strings.write_string(b, ", ")
		}
		strings.write_string(b, variant.name)
		if variant.has_payload {
			strings.write_string(b, "(")
			strings.write_string(b, screen_field_type_token(variant.payload))
			strings.write_string(b, ")")
		}
	}
	strings.write_string(b, " }\n")
}

// emit_screen_builder_fn writes the screen's view-builder accessor: `extern fn
// <screen>(model: <Name>View) -> View[<Name>Msg]` on one line — the §21 §2 screen
// function the runtime calls to build the view tree from the view-model. The fn name
// is the lowercase screen name (the source screen name in the examples), the param
// is the read contract, and the return is the message-parameterized View.
emit_screen_builder_fn :: proc(b: ^strings.Builder, seam: Inferred_Seam) {
	strings.write_string(b, "extern fn ")
	strings.write_string(b, screen_builder_fn_name(seam.screen_name))
	strings.write_string(b, "(model: ")
	strings.write_string(b, seam.view_name)
	strings.write_string(b, ") -> View[")
	strings.write_string(b, seam.msg_name)
	strings.write_string(b, "]\n")
}

// screen_field_type_token renders a Fui_Type to its single source-type token: a
// primitive (Int/Bool/String), a list as `[<Row>]` (the row record name in
// brackets), or a Named's pre-rendered domain token (`Ref[Difficulty]`). It is the
// projection from the inferred type to the byte the seam carries.
screen_field_type_token :: proc(type: Fui_Type) -> string {
	switch t in type {
	case Fui_Prim:
		return fui_prim_token(t)
	case Fui_List:
		return fui_concat("[", t.row, "]")
	case Fui_Named:
		return t.token
	}
	return ""
}

// fui_prim_token renders an inferred primitive to its prelude type token: Int, Bool,
// String — the engine.prelude names the seam imports and the field types carry.
fui_prim_token :: proc(prim: Fui_Prim) -> string {
	switch prim {
	case .Int:
		return "Int"
	case .Bool:
		return "Bool"
	case .String:
		return "String"
	}
	return ""
}

// screen_builder_fn_name is the view-builder fn name: the lowercase screen name
// (`Hud` → `hud`), the module-named entry point the runtime calls (§21 §2).
screen_builder_fn_name :: proc(screen_name: string, allocator := context.temp_allocator) -> string {
	return strings.to_lower(screen_name, allocator)
}
