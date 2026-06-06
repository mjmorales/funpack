// Per-screen contract inference for the §21 UI seam: it walks a parsed
// Fui_Screen and INFERS the two typed edges the bake materializes — the
// view-model READ contract (a `data` of every value the template binds) and the
// message WRITE contract (an `enum` of every Msg the template can emit) — plus the
// for-list row records the reads reference. "The template *is* the schema" (§21
// §1): nothing is hand-declared; the data contract falls out of usage.
//
// This is the inference stage ONLY: it produces an in-memory Inferred_Seam, NOT
// the .gen.fun bytes (the emitter story projects this model into a gen_emit Seam)
// and NOT the set-level Screen/AppMsg routing union (a later story over the set of
// screens). The naming the emitter needs — `HudView`/`HudMsg`, the `<Screen>` +
// singular + `Row` for-list record — is derived here so the projection downstream
// is a pure rename-free render.
//
// The inference rules (§21 §1 directive table, anchored on the committed
// examples/hud/gen/*.gen.fun shapes):
//   - an interpolation hole `"{score}"` on a VIEW-MODEL path  -> a read, Int
//   - `if game_over`                                          -> a read, Bool
//   - `:attr=tone` (bind-in)                                  -> a read, String
//   - `bind:value=player_name` on a `field`                   -> a read String + Set<Field>(String)
//   - `bind:value=volume`      on a `slider`                  -> a read Int    + Set<Field>(Int)
//   - `@click=Coin`                                           -> a nullary Msg variant
//   - `@click=SetVolume(p.value)`                             -> a payload Msg variant, type from the path
//   - `for p in volume_presets { … }`                         -> a read `[<Row>]` + the inferred Row record
// A hole or event-payload path ROOTED at a for-loop var (`p.value`) is NOT a
// view-model read — it contributes to that loop's row type. The SAME variant
// inferred from two emitters (the `bind:value` lowering and the preset button)
// collapses to ONE variant; an already-seen read or variant name is deduplicated,
// so emitting `SetVolume` twice yields a single `SetVolume(Int)`.
package funpack

// Fui_Type is the closed set of inferred seam types (§21 §1 table). The
// primitives are the directive-table results; List wraps a named row record for a
// for-list field; Named carries an explicit row-type ascription's rendered token
// (`Ref[Difficulty]`). It renders to a single source-type token for the emitter.
Fui_Type :: union {
	Fui_Prim,  // Int / Bool / String — the inferred primitive reads
	Fui_List,  // `[RowRecordName]` — a for-list field's element type
	Fui_Named, // a row-payload type pinned by an inline ascription, rendered token
}

// Fui_Prim is the closed primitive read set the directive table infers.
Fui_Prim :: enum {
	Int,
	Bool,
	String,
}

// Fui_List is a for-list field's `[Row]` element type: the row record name the
// field's elements have (`SettingsPresetRow`). The row record itself rides
// Inferred_Seam.row_types.
Fui_List :: struct {
	row: string,
}

// Fui_Named is an explicit row-payload type ascription's rendered token — the
// §21 §5 "domain type named once" form (`Ref[Difficulty]`). The inference never
// synthesizes a Named for a primitive; it only carries one an author wrote.
Fui_Named :: struct {
	token: string,
}

// Fui_Field is one inferred view-model read: the bound field name and its inferred
// type. The order across an Inferred_Seam.view_fields slice is first-seen source
// order, so the emitted `data` record column matches the template's binding order.
Fui_Field :: struct {
	name: string,
	type: Fui_Type,
}

// Fui_Variant is one inferred Msg write: the variant name and an optional single
// payload type. has_payload distinguishes a nullary variant (`Coin`) from a
// payload variant (`SetVolume(Int)`). A variant inferred more than once (the
// reused `SetVolume`) appears once.
Fui_Variant :: struct {
	name:        string,
	payload:     Fui_Type,
	has_payload: bool,
}

// Fui_Record is one inferred for-list row record: its name (`SettingsPresetRow`)
// and its fields, inferred from the `var.*` bindings used inside the loop. The
// reads' for-list field type references the record by name through a Fui_List.
Fui_Record :: struct {
	name:   string,
	fields: []Fui_Field,
}

// Inferred_Seam is the per-screen typed contract the inference produces from one
// Fui_Screen: the view-model read contract (view_fields), the message write
// contract (msg_variants), and the for-list row records the reads reference
// (row_types). screen_name is the source screen name; view_name/msg_name are the
// derived `<Screen>View`/`<Screen>Msg` type names the emitter renders. An empty
// view_fields is the legitimate empty-view edge case (Pause), not a failure.
Inferred_Seam :: struct {
	screen_name:  string,
	view_name:    string,
	msg_name:     string,
	view_fields:  []Fui_Field,
	msg_variants: []Fui_Variant,
	row_types:    []Fui_Record,
}

// fui_infer_ctx accumulates the inference as the walk descends. The dynamic
// builders collect first-seen-order fields/variants/records; screen_name is the
// row-record naming prefix (`Settings` -> `SettingsPresetRow`). The in-scope
// for-loop vars (whose `var.*` paths route to a row type, not a view-model read)
// travel as a per-call argument, not ctx state, since they nest with the walk.
fui_infer_ctx :: struct {
	screen_name:  string,
	view_fields:  [dynamic]Fui_Field,
	msg_variants: [dynamic]Fui_Variant,
	row_types:    [dynamic]Fui_Record,
}

// infer_seam infers the per-screen typed contract from a parsed Fui_Screen (§21
// §2). It walks the body collecting reads, writes, and for-list rows in first-seen
// source order, then returns the assembled Inferred_Seam. The walk is pure: it
// reads only the AST, allocating the result in the temp allocator like the rest of
// the frontend stages.
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

// infer_nodes walks a node sequence under a stack of in-scope for-loop vars,
// dispatching each node to its per-kind inference. loop_vars is the current
// for-loop variable scope: a path rooted at one of these names is a row binding
// for the innermost matching loop, not a view-model read.
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

// infer_element infers from one element's attributes (the directive edges) then
// recurses into its child block. The four attribute kinds infer disjoint edges:
// a Plain attr contributes nothing to the seam (style/layout); a Bind_In a String
// read; an Event a Msg variant (with an optional payload type); a Two_Way both a
// read AND a `Set<Field>` variant, whose primitive type is the widget's bind type
// (`field` -> String, `slider`/`toggle`/`select` -> Int).
infer_element :: proc(ctx: ^fui_infer_ctx, el: ^Fui_Element, loop_vars: []string) {
	for attr in el.attrs {
		switch attr.kind {
		case .Plain:
			// Style tokens, placeholders, and numeric bounds carry no seam edge.
		case .Bind_In:
			// `:attr=path` — a typed read feeding the attribute (String, §21 §1).
			path := attr.value.(Fui_Path)
			infer_read_path(ctx, path, loop_vars, Fui_Prim.String)
		case .Event:
			infer_event(ctx, attr.value.(Fui_Msg_Ref))
		case .Two_Way:
			// `bind:value=field` lowers to BOTH a read of the bound path AND a
			// `Set<Field>` variant — one attribute, two edges (§21 §1). The
			// primitive type is the widget's bind type.
			path := attr.value.(Fui_Path)
			prim := fui_widget_bind_type(el.widget)
			infer_read_path(ctx, path, loop_vars, prim)
			fui_add_variant(ctx, fui_set_variant_name(path), prim, true)
		}
	}
	infer_nodes(ctx, el.children, loop_vars)
}

// infer_text infers a view-model read per interpolation hole (§21 §5). A hole on
// a view-model path is an Int read by default (the bare `"{score}"` form,
// matching the committed `score: Int`); a hole rooted at a for-loop var is a row
// binding, routed by infer_read_path to the loop's row type.
infer_text :: proc(ctx: ^fui_infer_ctx, t: ^Fui_Text, loop_vars: []string) {
	for hole in t.holes {
		infer_read_path(ctx, hole, loop_vars, Fui_Prim.Int)
	}
}

// infer_if infers a Bool view-model read from the condition path (§21 §1
// `if game_over` -> `game_over: Bool`), then recurses into the gated block.
infer_if :: proc(ctx: ^fui_infer_ctx, n: ^Fui_If, loop_vars: []string) {
	infer_read_path(ctx, n.cond, loop_vars, Fui_Prim.Bool)
	infer_nodes(ctx, n.children, loop_vars)
}

// infer_for infers a for-list view-model field whose element type is the loop's
// inferred row record, registers that record, and recurses into the body with the
// loop var added to scope so the body's `var.*` bindings populate the row type
// rather than the view model. An explicit inline row-type ascription pins the row
// fields directly; otherwise the body's `var.*` uses infer the row's primitives.
infer_for :: proc(ctx: ^fui_infer_ctx, n: ^Fui_For, loop_vars: []string) {
	row_name := fui_row_record_name_for(ctx.screen_name, n.list)
	// The for-list field: `<list_path_root>: [<Row>]`. The list path is a
	// view-model read (the list itself is bound from the view model).
	fui_add_field(ctx, n.list.segments[0], Fui_List{row = row_name})
	// Register the row record up front so body bindings append to it.
	row_idx := fui_ensure_record(ctx, row_name)
	if n.has_row_type {
		// An explicit ascription pins every row field; the body's `var.*` uses do
		// not add to it (§21 §5 — the domain type named once).
		for rf in n.row_type {
			fui_add_record_field(ctx, row_idx, rf.name, Fui_Named{token = rf.type})
		}
	}
	inner := fui_push_loop_var(loop_vars, n.var)
	infer_for_body(ctx, n.children, inner, n.var, row_idx, n.has_row_type)
}

// infer_for_body walks a for-loop's body, routing the loop var's `var.field`
// bindings into the row record and every other binding to the view model (or an
// outer loop's row). It re-walks the body like infer_nodes but knows the active
// row record so a `var.*` path lands as a row field. When the row type is pinned
// by an explicit ascription, `var.*` uses are NOT added (the ascription is the
// authority).
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
			// A nested for-list: its own row scope, handled by the general inferer
			// with the current loop var still in the outer scope.
			infer_for(ctx, n, loop_vars)
		}
	}
}

// infer_event infers a Msg variant from an event directive on an element OUTSIDE
// any for-loop body (§21 §1): a nullary variant (`Coin`) or a payload variant
// whose type is the payload path's inferred type. An in-loop event runs through
// fui_record_msg instead, which also feeds the loop's row type — so a payload
// here is a view-model-rooted primitive, inferred Int.
infer_event :: proc(ctx: ^fui_infer_ctx, ref: Fui_Msg_Ref) {
	if !ref.has_payload {
		fui_add_variant(ctx, ref.variant, nil, false)
		return
	}
	// The payload type is the inferred type of its path. A primitive payload path
	// infers Int (the only displayed-payload form the examples carry).
	fui_add_variant(ctx, ref.variant, Fui_Prim.Int, true)
}

// fui_record_msg infers a Msg variant inside a for-loop body — the same dedup as
// infer_event, but a `var.*` payload also feeds the loop's row type so the preset
// button's `SetVolume(p.value)` both reuses the existing `SetVolume` variant AND
// confirms the row's `value` field.
fui_record_msg :: proc(ctx: ^fui_infer_ctx, ref: Fui_Msg_Ref, loop_vars: []string, loop_var: string, row_idx: int, pinned: bool) {
	if !ref.has_payload {
		fui_add_variant(ctx, ref.variant, nil, false)
		return
	}
	// The payload path may be a row binding (`p.value`); record it into the row so
	// the row type is confirmed, and add (or reuse) the payload variant.
	infer_for_path(ctx, ref.payload, loop_vars, loop_var, row_idx, pinned, Fui_Prim.Int)
	fui_add_variant(ctx, ref.variant, Fui_Prim.Int, true)
}

// infer_read_path routes a bound path to its read target: a path rooted at an
// in-scope for-loop var is NOT a view-model read (it is a row binding handled by
// the for-body inferer); any other path's root is a view-model field of the given
// primitive type, deduplicated by name in first-seen order.
infer_read_path :: proc(ctx: ^fui_infer_ctx, path: Fui_Path, loop_vars: []string, prim: Fui_Prim) {
	if fui_path_is_loop_rooted(path, loop_vars) {
		// A row binding outside the row's own for-body walk — the for-body inferer
		// owns row fields, so here it is a no-op (the read is the loop var's, not
		// the view model's).
		return
	}
	fui_add_field(ctx, path.segments[0], prim)
}

// infer_for_path routes a path used inside a for-loop body: a path rooted at the
// active loop var (`p.value`) is a row field on the loop's record (its leaf
// segment is the field name); any other path is a view-model read (or an outer
// loop's row, decided by infer_read_path against the remaining scope). A pinned
// row type ignores the loop var's `var.*` uses — the ascription is authoritative.
infer_for_path :: proc(ctx: ^fui_infer_ctx, path: Fui_Path, loop_vars: []string, loop_var: string, row_idx: int, pinned: bool, prim: Fui_Prim) {
	if len(path.segments) >= 2 && path.segments[0] == loop_var {
		if !pinned {
			// The row field is the path's leaf segment (`p.value` -> `value`).
			leaf := path.segments[len(path.segments)-1]
			fui_add_record_field(ctx, row_idx, leaf, prim)
		}
		return
	}
	// Not a binding on the active loop var: it is a view-model read (or an outer
	// loop's row), routed against the remaining loop scope.
	infer_read_path(ctx, path, loop_vars, prim)
}

// ── Accumulation helpers (first-seen dedup) ─────────────────────────────────

// fui_add_field adds a view-model field, deduplicating by name in first-seen
// order. A repeated binding of the same path (`"{score}"` shown twice) yields a
// single field; the first inferred type wins, so an interpolation Int read is not
// overwritten by a later read of the same name.
fui_add_field :: proc(ctx: ^fui_infer_ctx, name: string, type: Fui_Type) {
	for f in ctx.view_fields {
		if f.name == name {
			return
		}
	}
	append(&ctx.view_fields, Fui_Field{name = name, type = type})
}

// fui_add_variant adds a Msg variant, deduplicating by name in first-seen order —
// the mechanism that collapses the reused `SetVolume` (the `bind:value` lowering
// and the preset button) into ONE `SetVolume(Int)` variant. The first occurrence
// fixes the payload, so the order is stable regardless of which emitter is seen
// first.
fui_add_variant :: proc(ctx: ^fui_infer_ctx, name: string, payload: Fui_Type, has_payload: bool) {
	for v in ctx.msg_variants {
		if v.name == name {
			return
		}
	}
	append(&ctx.msg_variants, Fui_Variant{name = name, payload = payload, has_payload = has_payload})
}

// fui_ensure_record returns the index of the named row record, creating it (empty)
// if absent. The for-list field's `[Row]` type references this record by name, so
// the record must exist before the body walk fills its fields.
fui_ensure_record :: proc(ctx: ^fui_infer_ctx, name: string) -> int {
	for r, i in ctx.row_types {
		if r.name == name {
			return i
		}
	}
	append(&ctx.row_types, Fui_Record{name = name, fields = nil})
	return len(ctx.row_types) - 1
}

// fui_add_record_field adds a field to a row record, deduplicating by name in
// first-seen order. The row's `fields` slice is rebuilt with the appended field
// (a record value holds a slice, so a re-slice-and-store keeps the value-semantics
// dynamic array stable across the walk).
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

// ── Naming + type helpers ───────────────────────────────────────────────────

// fui_widget_bind_type returns the primitive type a `bind:value` on a widget
// lowers to (§21 §1): a `field` is text (String); a `slider`, `toggle`, or
// `select` is a numeric index (Int). A `bind:` on a non-input widget never
// appears in a well-formed template; it defaults to String here, the safe text
// read.
fui_widget_bind_type :: proc(widget: Fui_Widget_Kind) -> Fui_Prim {
	#partial switch widget {
	case .Field:
		return .String
	case .Slider, .Toggle, .Select:
		return .Int
	}
	return .String
}

// fui_set_variant_name renders the `Set<Field>` two-way variant name from the
// bound path: `bind:value=volume` -> `SetVolume`, `bind:value=player_name` ->
// `SetPlayerName`. The field is the path's LEAF segment, UpperCamel-cased on its
// `_`-separated words (`player_name` -> `PlayerName`), prefixed with `Set`.
fui_set_variant_name :: proc(path: Fui_Path) -> string {
	leaf := path.segments[len(path.segments)-1]
	return fui_concat("Set", fui_upper_camel(leaf), "")
}

// fui_row_record_name_for renders the for-list row record name from the screen
// name and the list path, matching the committed exemplar `SettingsPresetRow`
// from screen `Settings` + list `volume_presets`: the screen name, then the
// SINGULAR UpperCamel of the list's leaf word, then `Row` (`presets` -> `Preset`
// -> `SettingsPresetRow`).
fui_row_record_name_for :: proc(screen_name: string, list: Fui_Path) -> string {
	// The list field's leaf segment names the collection (`volume_presets`); the
	// row record is the screen + the leaf's SINGULAR UpperCamel + `Row`.
	leaf := list.segments[len(list.segments)-1]
	core := fui_upper_camel(fui_singularize(fui_last_word(leaf)))
	return fui_concat(screen_name, core, "Row")
}

// fui_last_word returns the final `_`-separated word of a name (`volume_presets`
// -> `presets`), the noun the row record is named after.
fui_last_word :: proc(name: string) -> string {
	last := 0
	for i in 0 ..< len(name) {
		if name[i] == '_' {
			last = i + 1
		}
	}
	return name[last:]
}

// fui_singularize singularizes a plural collection noun for the row-record name:
// the `-ies` -> `-y` rule (`difficulties` -> `difficulty`) and the plain trailing
// `-s` strip (`presets` -> `preset`). A non-`s` word is unchanged. These two
// regular forms cover the §21 for-list collection names (the spec's
// `volume_presets` and `difficulties`); an irregular plural would be pinned by an
// explicit inline row-type ascription, which bypasses this naming entirely.
fui_singularize :: proc(word: string) -> string {
	if len(word) > 3 && word[len(word)-3:] == "ies" {
		// `-ies` -> `-y` (difficulties -> difficulty).
		return fui_concat(word[:len(word)-3], "y", "")
	}
	if len(word) > 1 && word[len(word)-1] == 's' {
		return word[:len(word)-1]
	}
	return word
}

// fui_upper_camel renders a `_`-separated lower name to UpperCamelCase
// (`player_name` -> `PlayerName`, `value` -> `Value`): each `_`-separated word's
// first letter is upper-cased, the rest kept, and the separators dropped. The
// UpperCamel band the seam type/variant names ride (§02 naming).
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

// fui_path_is_loop_rooted reports whether a path's root segment is one of the
// in-scope for-loop vars — i.e. it is a row binding, not a view-model read.
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

// fui_push_loop_var returns a new loop-var scope with `name` appended — the scope
// the for-loop body walks under so its `var.*` bindings route to the row type.
fui_push_loop_var :: proc(loop_vars: []string, name: string) -> []string {
	out := make([dynamic]string, 0, len(loop_vars)+1, context.temp_allocator)
	append(&out, ..loop_vars)
	append(&out, name)
	return out[:]
}
