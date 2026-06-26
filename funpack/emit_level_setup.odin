// The v15 LEVEL-BACKED [setup] fold: the emitter side that honors the §13
// contract — "the setup program carries no expressions" — for a game whose
// setup() loads a baked level. dungeon/warren's `setup()` body is `return
// dungeon_spawns()`: a call to the level seam's body-less spawns extern, which
// the prior emitter could neither inline (no body) nor encode (a call is an
// expression), leaving `[setup 0]` and an empty initial world. The spawn data
// already exists at build time — the §17 bake's deterministic Baked_Spawn list
// — so the emitter constant-folds the extern AT EMIT TIME: a setup body that is
// a lone call to a baked level's `<level>_spawns` name emits one §13 `spawn
// THING field_count` row per baked spawn, in bake order (markers row-major
// where their layer is declared, then explicit places, declaration order), each
// field a primitive-encoded value.
//
// FIELD ENCODING. `pos` is the §13 Vec2 spread (`vec2 x_bits y_bits`) from the
// bake's cell-center/anchor fold; `facing` (when authored) is its raw Q32.32
// bits; a non-reserved param encodes by its DECLARED schema field type — the
// bake folds every scalar to Fixed, so the emitter re-reads the placed thing's
// field decl (the v15 declaration carry makes it available) to write an `Int`
// as its truncated decimal and a `Bool` as its bare token, never a raw-bits
// leak. A field the level omits is not emitted — the runtime applies the §6
// default off the carried [things] schema (the §13 omission rule). A Ref-valued
// param has no ratified §13 encoding yet: its consumer is the deferred
// level-accessor surface (the `dungeon() -> Dungeon` extern), so the fold skips
// it; carrying Ref ids is that story's schema bump, not this one's.
//
// PURITY (spec §09, §29): the fold is a pure function of the checked AST and
// the baked spawn list — both pure functions of source — so two emissions are
// byte-identical.
package funpack

import "core:strings"

// Level_Spawn_Batch is one baked level's deterministic spawn list keyed by its
// seam extern name (`dungeon_spawns` for level Dungeon — level_spawns_fn_name).
// The build verb threads one batch per baked level into Emit_Input; the [setup]
// emitter folds the batch whose fn_name the setup() body calls.
Level_Spawn_Batch :: struct {
	fn_name: string,
	spawns:  []Baked_Spawn,
}

// level_setup_batch reports whether the module's setup() body is a lone call to
// a threaded level-spawns extern — `return <level>_spawns()` — and returns that
// batch. Any other setup shape (a literal [Spawn] list, a helper-fn batch, no
// setup at all) returns found = false, so the caller falls through to the
// resolve_setup_spawns constant-fold and a level-less game's bytes are
// unchanged.
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

// emit_level_setup writes the §13 batch from a baked level's spawn list: one
// `spawn THING field_count` per Baked_Spawn in bake order, then its `set` rows
// in the fixed field order pos → facing → params (params in their resolved
// source order). field_count counts exactly the emitted `set` rows, so a reader
// shapes the record without lookahead. things is the placed-type schema lookup
// (the entrypoint module's own things plus the v15 imported carry) the param
// encoding reads declared field types from.
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

// emittable_params filters a spawn's resolved params to the ones the v15 §13
// fold encodes: every scalar param. A Ref-valued param is skipped — its §13
// encoding rides the deferred level-accessor schema bump (this file's header) —
// so the emitted field_count counts exactly the rows that follow.
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

// encode_level_param renders one scalar param value in the placed thing's
// DECLARED field type encoding. The bake folds every scalar to Fixed
// (resolve_param_value), so the declared type — read off the thing's schema in
// the artifact's own carry — chooses the §2 primitive form: an `Int` field
// writes the truncated decimal (`gems: 5` → `5`), a `Bool` field writes the
// bare token (`0`/non-zero → `false`/`true`), and a `Fixed` field (or a thing/
// field the lookup cannot resolve — a placed type outside the import closure,
// whose decode the runtime refuses anyway) writes the raw Q32.32 bits, the
// bake's native representation.
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

// level_param_field resolves a placed thing's field decl by name against the
// entrypoint module's own things first, then the v15 imported carry — both
// index walks, never a map — so the param encoding reads the same schema the
// artifact's [things] section carries.
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
