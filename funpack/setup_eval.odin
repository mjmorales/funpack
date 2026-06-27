// Compile-time constant folding of §6 field DEFAULT expressions and the §06
// single-return level-setup helper shape (docs/artifact-format.md §6, §13). A
// field default and a single-`return` helper are CLOSED forms by language rule —
// a literal, a named `let` const, an enum variant, or an inlined single-return
// fn call — so folding them to a closed value Expr is the right mechanical
// lowering (the §6 DEFAULT token and the v15 level seam carry only evaluated
// values, §29 purity).
//
// The §06 setup() [Spawn] BATCH is NOT folded here. It is EVALUATED through the
// full evaluator (setup_values.odin resolve_setup_values, the same evaluate.odin
// surface `funpack test` runs), so an idiomatic multi-statement (`let`-binding)
// constructor — and every builtin/operator/`if`/`match`/field-access in its call
// tree — bakes its real spawn rather than dropping to an empty [setup]. This file
// is the shared fold core for the closed §6 default forms (fold_field_default);
// the setup-spawn path uses the evaluator, not this fold.
package funpack

// Setup_Fold is the per-fold context: the module's user fns (the inline targets a
// default's helper call resolves against) and a binding frame mapping a fn's
// parameter names to already-folded argument expressions. The frame is replaced
// (not chained) on each fn inline — a folded body reads only its own params and
// module constants, never an outer frame — so a fresh frame per inline keeps
// substitutions isolated.
Setup_Fold :: struct {
	ast:   Ast,
	binds: map[string]Expr,
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
