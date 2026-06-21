// Compile-time evaluation of the §06 §6 Startup [Spawn] batch (the [setup]
// section, docs/artifact-format.md §13). The setup program carries NO expressions
// — every field is a fully-evaluated, primitive-encoded value (§13, §29 purity) —
// but yard's setup() is NOT a flat list of record literals: it spawns through user
// helper fns (`crate_at(...)`, `wall_body(size)`, `player_body()`) and constructs
// engine Body records with §11 §2 field defaults left implicit. So the emitter
// must CONSTANT-FOLD the batch at compile time: inline each user-fn-call spawn
// argument, resolve every nested record, and apply the §11 §2 Body defaults the
// source omits — producing a closed value tree the §13 encoder writes without
// interpreting an initializer at load time.
//
// This is a pure AST → AST fold over the checked module (the gate/typecheck stages
// already proved the spawn forms well-typed and the fn calls resolvable), not a
// runtime value evaluator: it substitutes a fn call by its body's `return`
// expression with the call arguments bound, so it handles the single-return helper
// shape §06 setup helpers use. A form it cannot fold (an unexpected body shape)
// folds to itself, so the gameplay path degrades to the prior literal-only
// behavior rather than faulting.
package funpack

import "core:strings"

// Setup_Fold is the per-spawn folding context: the module's user fns (the inline
// targets) and a binding frame mapping a fn's parameter names to the
// already-folded argument expressions. The frame is replaced (not chained) on each
// fn inline — a setup helper body reads only its own params and module constants,
// never an outer frame — so a fresh frame per inline keeps substitutions isolated.
Setup_Fold :: struct {
	ast:   Ast,
	binds: map[string]Expr,
}

// Resolved_Spawn is one fully-folded spawn: the thing type and its resolved
// field set (every value a closed literal/variant/record/list Expr), in the
// source field order of the constructed record. It is the §13 row the encoder
// writes.
Resolved_Spawn :: struct {
	type_name: string,
	fields:    []Record_Field,
}

// resolve_setup_spawns folds yard's setup() body into the fully-evaluated §13
// batch: each `Spawn(arg)` element's argument is constant-folded to a thing
// Record_Expr (a literal, or a user-fn call inlined to one), then the §11 §2
// engine-record defaults are applied to any nested Body field. The result is the
// closed spawn batch in source list order — the 9-row yard population (4 Walls, 1
// Pad, 1 Player, 3 Crates). A source with no setup() (or an unfoldable body) yields
// an empty batch, mirroring the prior setup_spawns behavior.
resolve_setup_spawns :: proc(ast: Ast) -> []Resolved_Spawn {
	for fn in ast.fns {
		if fn.name != "setup" {
			continue
		}
		list, ok := single_return_list(fn.body)
		if !ok {
			return nil
		}
		out := make([dynamic]Resolved_Spawn, 0, len(list.elements), context.temp_allocator)
		for element in list.elements {
			arg, found := spawn_argument(element)
			if !found {
				continue
			}
			fold := Setup_Fold{ast = ast, binds = make(map[string]Expr, context.temp_allocator)}
			record, resolved := fold_to_record(&fold, arg)
			if !resolved {
				continue
			}
			append(
				&out,
				Resolved_Spawn{type_name = record.type_name, fields = with_engine_defaults(record)},
			)
		}
		return out[:]
	}
	return nil
}

// spawn_argument reads the single argument out of a `Spawn(arg)` call. Unlike the
// prior spawn_record, the argument is NOT required to be a record literal — it may
// be a user-fn call (yard's `Spawn(crate_at(...))`) the folder inlines downstream.
spawn_argument :: proc(element: Expr) -> (arg: Expr, ok: bool) {
	call, is_call := element.(^Call_Expr)
	if !is_call || len(call.args) != 1 {
		return nil, false
	}
	name, is_name := call.callee.(^Name_Expr)
	if !is_name || name.name != "Spawn" {
		return nil, false
	}
	return call.args[0], true
}

// fold_to_record folds an expression to a constant Record_Expr: a record literal
// (its fields folded), or a user-fn call whose body returns one (inlined). It is
// the spawn-argument entry point — the §13 batch's elements are all things, so the
// top of every fold is a record.
fold_to_record :: proc(fold: ^Setup_Fold, expr: Expr) -> (record: ^Record_Expr, ok: bool) {
	folded, resolved := fold_expr(fold, expr)
	if !resolved {
		return nil, false
	}
	rec, is_rec := folded.(^Record_Expr)
	return rec, is_rec
}

// fold_expr constant-folds one setup expression to a closed value Expr (spec §29
// purity — the batch carries no live expressions). The folded forms:
//   - a literal (Int/Fixed/String) or a bare Bool name → itself;
//   - a bound parameter Name → its already-folded argument (the fn-inline substitution);
//   - a record literal → the record with each field folded;
//   - an enum variant (bare / struct-payload) → the variant with payloads folded;
//   - a list → the list with each element folded;
//   - a user-fn call → the fn's return expression folded with arguments bound.
// A form outside this closed setup vocabulary folds to ok=false, so the caller drops
// that spawn rather than emitting a half-built row.
fold_expr :: proc(fold: ^Setup_Fold, expr: Expr) -> (folded: Expr, ok: bool) {
	#partial switch e in expr {
	case ^Int_Lit_Expr, ^Fixed_Lit_Expr, ^String_Lit_Expr:
		return expr, true
	case ^Name_Expr:
		if e.name == "true" || e.name == "false" {
			return expr, true
		}
		// A parameter bound by an inlined fn call resolves to its folded argument; a
		// module-level `let` constant resolves to its (already-constant) value.
		if bound, found := fold.binds[e.name]; found {
			return bound, true
		}
		if constant, found := fold_module_const(fold, e.name); found {
			return constant, true
		}
		return nil, false
	case ^Record_Expr:
		return fold_record(fold, e)
	case ^Variant_Expr:
		return fold_variant(fold, e)
	case ^List_Expr:
		return fold_list(fold, e)
	case ^Call_Expr:
		return fold_call(fold, e)
	}
	return nil, false
}

// fold_record folds a record literal's fields, returning a fresh Record_Expr with
// every field a closed value. Vec2/Shape2/Body/thing records all flow through here
// — the type name is preserved so the encoder distinguishes a Vec2 (the §13 spread)
// from a composite Body (the §6 single-token form).
fold_record :: proc(fold: ^Setup_Fold, e: ^Record_Expr) -> (folded: Expr, ok: bool) {
	fields := make([]Record_Field, len(e.fields), context.temp_allocator)
	for field, i in e.fields {
		value, resolved := fold_expr(fold, field.value)
		if !resolved {
			return nil, false
		}
		fields[i] = Record_Field{name = field.name, value = value}
	}
	node := new(Record_Expr, context.temp_allocator)
	node^ = Record_Expr{type_name = e.type_name, fields = fields}
	return node, true
}

// fold_variant folds an enum-variant value: a bare variant (Layer::Wall,
// BodyKind::Static) is already closed; a struct-payload variant (Shape2::Box{size:
// …}) folds its named fields. Tuple-payload variants do not appear in a setup
// thing, so they fold to ok=false.
fold_variant :: proc(fold: ^Setup_Fold, e: ^Variant_Expr) -> (folded: Expr, ok: bool) {
	if e.has_payload {
		return nil, false
	}
	if !e.has_fields {
		return e, true
	}
	fields := make([]Record_Field, len(e.fields), context.temp_allocator)
	for field, i in e.fields {
		value, resolved := fold_expr(fold, field.value)
		if !resolved {
			return nil, false
		}
		fields[i] = Record_Field{name = field.name, value = value}
	}
	node := new(Variant_Expr, context.temp_allocator)
	node^ = Variant_Expr{
		type_name  = e.type_name,
		variant    = e.variant,
		fields     = fields,
		has_fields = true,
	}
	return node, true
}

// fold_list folds a list literal's elements (yard's `mask: [Layer::Wall, …]`), each
// to a closed value. The element order is preserved — a CollisionLayer mask is a
// deterministic ordered set in the artifact.
fold_list :: proc(fold: ^Setup_Fold, e: ^List_Expr) -> (folded: Expr, ok: bool) {
	elements := make([]Expr, len(e.elements), context.temp_allocator)
	for element, i in e.elements {
		value, resolved := fold_expr(fold, element)
		if !resolved {
			return nil, false
		}
		elements[i] = value
	}
	node := new(List_Expr, context.temp_allocator)
	node^ = List_Expr{elements = elements}
	return node, true
}

// fold_call inlines a user-fn call: it folds each argument, binds them to the fn's
// parameter names in a FRESH frame (a setup helper body reads only its own params
// and module constants), and folds the fn's single-return body against that frame.
// This is the substitution that turns `crate_at(Vec2{…})` into the constructed Crate
// record and `wall_body(size)` into the constructed Body. A callee that is not a
// resolvable user fn, or a body that is not a single `return`, folds to ok=false.
fold_call :: proc(fold: ^Setup_Fold, e: ^Call_Expr) -> (folded: Expr, ok: bool) {
	name, is_name := e.callee.(^Name_Expr)
	if !is_name {
		return nil, false
	}
	fn, found := find_user_fn(fold.ast, name.name)
	if !found || len(e.args) != len(fn.params) {
		return nil, false
	}
	ret, has_return := single_return_expr(fn.body)
	if !has_return {
		return nil, false
	}
	frame := Setup_Fold{ast = fold.ast, binds = make(map[string]Expr, context.temp_allocator)}
	for param, i in fn.params {
		arg, resolved := fold_expr(fold, e.args[i])
		if !resolved {
			return nil, false
		}
		frame.binds[param.name] = arg
	}
	return fold_expr(&frame, ret)
}

// fold_module_const resolves a module-level `let NAME = expr` to its constant value
// (yard's ACCEL/FOLLOW used inside a setup helper would resolve here, though yard's
// current helpers use none). The RHS reads no local frame, so it folds against an
// empty frame; a name that is not a declared `let` returns found=false.
fold_module_const :: proc(fold: ^Setup_Fold, name: string) -> (value: Expr, found: bool) {
	for decl in fold.ast.lets {
		if decl.name == name {
			empty := Setup_Fold{ast = fold.ast, binds = make(map[string]Expr, context.temp_allocator)}
			return fold_expr(&empty, decl.value)
		}
	}
	return nil, false
}

// fold_field_default constant-folds a field's DEFAULT expression against a module's
// `let` table — the SAME §29 fold the §06 setup batch uses (resolve_setup_spawns) —
// so a default written as a named const (`ground_y: Fixed = GROUND_Y`) or a const
// expression lowers to the closed literal/record/variant value the §6 DEFAULT token
// encodes. Without it a `Name_Expr` default reached encode_literal, which carries no
// const table and returns "", emitting a bare `=` token the runtime's decode_default
// silently drops — so a render-only singleton (Stage) spawned with that column ABSENT
// and its render read nothing. A literal default folds to itself; an
// expression outside the closed fold vocabulary returns UNCHANGED, so the non-foldable
// closed forms encode_field_default already handles (an enum variant, empty list, or
// engine-builder default like `Settings.defaults()`) keep their prior encoding rather
// than faulting.
fold_field_default :: proc(expr: Expr, ast: Ast) -> Expr {
	fold := Setup_Fold{ast = ast, binds = make(map[string]Expr, context.temp_allocator)}
	if folded, ok := fold_expr(&fold, expr); ok {
		return folded
	}
	return expr
}

// fold_field_decls returns a copy of a record's field list with every defaulted
// field's default constant-folded against `ast`'s `let` table. It is the imported-
// decl half of the §6 default fold: collect_imported_decls runs it against the field's
// OWNING module (the seam's lets), so a thing/data/signal imported from a sibling
// module carries folded defaults before it reaches the entrypoint emit, where the
// entry module's lets cannot resolve the sibling's consts. A field with no default,
// or one whose default is already a closed value, is copied unchanged.
fold_field_decls :: proc(fields: []Field_Decl, ast: Ast) -> []Field_Decl {
	out := make([]Field_Decl, len(fields), context.temp_allocator)
	for field, i in fields {
		out[i] = field
		if field.has_default {
			out[i].default = fold_field_default(field.default, ast)
		}
	}
	return out
}

// single_return_expr returns the single `return expr` of a fn body — the setup
// helper shape (`fn wall_body(size) -> Body { return Body{…} }`). A body that is not
// exactly one return statement is outside the foldable shape.
single_return_expr :: proc(body: []Statement) -> (expr: Expr, ok: bool) {
	if len(body) != 1 {
		return nil, false
	}
	ret, is_return := body[0].(Return_Node)
	if !is_return {
		return nil, false
	}
	return ret.value, true
}

// with_engine_defaults fills the §11 §2 Body field defaults the source omits, so the
// emitted §13 row carries the COMPLETE resolved field set the runtime spawns without
// further defaulting. It scans the thing record's fields for a `body: Body(…)`
// composite and, for each §11 §2 defaulted Body field the literal did not name, adds
// the default value — mass=1.0, restitution=0.0, friction=0.5, sensor=false,
// impulse=Vec2{0,0}. A non-Body field is returned unchanged; a thing with no body
// field is unchanged.
with_engine_defaults :: proc(record: ^Record_Expr) -> []Record_Field {
	out := make([]Record_Field, len(record.fields), context.temp_allocator)
	for field, i in record.fields {
		out[i] = field
		body, is_body := field.value.(^Record_Expr)
		if is_body && body.type_name == "Body" {
			out[i] = Record_Field{name = field.name, value = body_with_defaults(body)}
		}
	}
	return out
}

// body_with_defaults returns a Body record with every §11 §2 defaulted field the
// literal omitted filled in. The defaults are appended in the spec's field order
// (mass, restitution, friction, sensor, impulse) after the literal's named fields,
// so a Body always carries its complete column set — the runtime never has to apply
// a Body field default at spawn time. kind/shape/layer/mask are required (no default),
// so a well-typed Body literal always names them.
body_with_defaults :: proc(body: ^Record_Expr) -> Expr {
	fields := make([dynamic]Record_Field, 0, len(body.fields) + 5, context.temp_allocator)
	for field in body.fields {
		append(&fields, field)
	}
	for def in BODY_FIELD_DEFAULTS {
		if record_field_named(fields[:], def.name) {
			continue
		}
		append(&fields, Record_Field{name = def.name, value = def.value()})
	}
	node := new(Record_Expr, context.temp_allocator)
	node^ = Record_Expr{type_name = body.type_name, fields = fields[:]}
	return node
}

// Body_Default is one §11 §2 Body field default: the field name and a thunk that
// builds its default value Expr fresh each use (a fresh node per spawn, so two
// spawns never share a mutable Expr). The set is closed — a new Body field default
// is a deliberate edit mirroring the §11 §2 record (docs/artifact-format.md §6).
Body_Default :: struct {
	name:  string,
	value: proc() -> Expr,
}

@(rodata)
BODY_FIELD_DEFAULTS := []Body_Default{
	{name = "mass", value = fixed_one_expr},
	{name = "restitution", value = fixed_zero_expr},
	{name = "friction", value = fixed_half_expr},
	{name = "sensor", value = false_expr},
	{name = "impulse", value = vec2_zero_expr},
}

fixed_one_expr :: proc() -> Expr {
	return setup_fixed_lit(to_fixed(1))
}

fixed_zero_expr :: proc() -> Expr {
	return setup_fixed_lit(Fixed(0))
}

fixed_half_expr :: proc() -> Expr {
	// 0.5 in Q32.32 is half of the unit bit pattern — exact, no float (the unit is
	// to_fixed(1) = 2^32, so half is its raw i64 bits shifted down one).
	return setup_fixed_lit(Fixed(i64(to_fixed(1)) / 2))
}

false_expr :: proc() -> Expr {
	node := new(Name_Expr, context.temp_allocator)
	node^ = Name_Expr{name = "false", class = .Snake_Case}
	return node
}

vec2_zero_expr :: proc() -> Expr {
	x := Record_Field{name = "x", value = setup_fixed_lit(Fixed(0))}
	y := Record_Field{name = "y", value = setup_fixed_lit(Fixed(0))}
	fields := make([]Record_Field, 2, context.temp_allocator)
	fields[0] = x
	fields[1] = y
	node := new(Record_Expr, context.temp_allocator)
	node^ = Record_Expr{type_name = "Vec2", fields = fields}
	return node
}

// setup_fixed_lit builds a Fixed literal Expr from raw Q32.32 bits — the
// default-value thunks' shared scalar constructor.
setup_fixed_lit :: proc(bits: Fixed) -> Expr {
	node := new(Fixed_Lit_Expr, context.temp_allocator)
	node^ = Fixed_Lit_Expr{bits = bits}
	return node
}

// record_field_named reports whether a folded field set already names `name` — the
// guard that keeps a source-supplied Body field (a friction override, a sensor flag)
// from being overwritten by its §11 §2 default.
record_field_named :: proc(fields: []Record_Field, name: string) -> bool {
	for field in fields {
		if field.name == name {
			return true
		}
	}
	return false
}

// ───────────────────────────────────────────────────────────────────────────
// §13 value encoding — scalar/Vec2 spread (top-level) + composite single-token
// ───────────────────────────────────────────────────────────────────────────

// encode_setup_field_value renders one TOP-LEVEL setup field value (the §13 `set
// FIELD =ENCODED` slot). A Vec2 keeps the §13 three-token spread `vec2 x y`
// (unchanged from the prior emitter, so pong's setup is byte-identical); a composite
// engine record (a Body) and a list use the §6 single-token nested form
// `Type(field=enc,…)` / `[enc,…]`, the space-free spelling a `set` line carries at
// one position (docs/artifact-format.md §6, §13). A scalar/enum routes through
// encode_setup_token.
encode_setup_field_value :: proc(expr: Expr) -> string {
	#partial switch e in expr {
	case ^Record_Expr:
		if e.type_name == "Vec2" {
			x := vec2_component_bits(e, "x")
			y := vec2_component_bits(e, "y")
			return strings.concatenate(
				{"vec2 ", encode_fixed(x, context.temp_allocator), " ", encode_fixed(y, context.temp_allocator)},
				context.temp_allocator,
			)
		}
		// A composite engine record (Body) — the §6 single-token inline form.
		return encode_setup_token(expr)
	}
	return encode_setup_token(expr)
}

// encode_setup_token renders a value as ONE space-free §6 token (docs/artifact-
// format.md §6): a scalar through encode_literal, an enum variant as `Type::Case`, a
// composite record as the inline `Type(field=enc,…)` (a nested Vec2 collapses to the
// single-token `Vec2(x=,y=)` form, NOT the §13 spread, since a token carries no
// interior space), and a list as `[enc,…]`. It is the recursive core the composite
// Body token nests through.
encode_setup_token :: proc(expr: Expr) -> string {
	#partial switch e in expr {
	case ^Variant_Expr:
		if e.has_fields {
			return encode_struct_variant_token(e)
		}
		return strings.concatenate({e.type_name, "::", e.variant}, context.temp_allocator)
	case ^Record_Expr:
		return encode_record_token(e)
	case ^List_Expr:
		return encode_list_token(e)
	}
	return encode_literal(expr)
}

// encode_record_token renders a record literal as the inline `Type(field=enc,…)`
// token: the type name, then a parenthesized comma-joined `field=ENCODED` list with
// no interior spaces, each value a recursive space-free token so the form nests
// (a Body's nested Shape2/Vec2/mask all collapse to space-free tokens).
encode_record_token :: proc(e: ^Record_Expr) -> string {
	b := strings.builder_make(context.temp_allocator)
	strings.write_string(&b, e.type_name)
	strings.write_byte(&b, '(')
	for field, i in e.fields {
		if i > 0 {
			strings.write_byte(&b, ',')
		}
		strings.write_string(&b, field.name)
		strings.write_byte(&b, '=')
		strings.write_string(&b, encode_setup_token(field.value))
	}
	strings.write_byte(&b, ')')
	return strings.to_string(b)
}

// encode_struct_variant_token renders a struct-payload variant (Shape2::Box{size:
// …}) as `Type::Case(field=enc,…)` — the variant tag joined with the §6 record-body
// form, space-free so it nests inside a composite Body token.
encode_struct_variant_token :: proc(e: ^Variant_Expr) -> string {
	b := strings.builder_make(context.temp_allocator)
	strings.write_string(&b, e.type_name)
	strings.write_string(&b, "::")
	strings.write_string(&b, e.variant)
	strings.write_byte(&b, '(')
	for field, i in e.fields {
		if i > 0 {
			strings.write_byte(&b, ',')
		}
		strings.write_string(&b, field.name)
		strings.write_byte(&b, '=')
		strings.write_string(&b, encode_setup_token(field.value))
	}
	strings.write_byte(&b, ')')
	return strings.to_string(b)
}

// encode_list_token renders a list as `[enc,…]` — a bracketed comma-joined run of
// space-free element tokens, the inline form a Body's `mask: [Layer::Wall, …]` takes
// inside a composite token (the §6 default `[]` empty-list form generalized to a
// populated list of enum tokens).
encode_list_token :: proc(e: ^List_Expr) -> string {
	b := strings.builder_make(context.temp_allocator)
	strings.write_byte(&b, '[')
	for element, i in e.elements {
		if i > 0 {
			strings.write_byte(&b, ',')
		}
		strings.write_string(&b, encode_setup_token(element))
	}
	strings.write_byte(&b, ']')
	return strings.to_string(b)
}
