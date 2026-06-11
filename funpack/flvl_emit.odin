// The §17 level-seam projection: it turns a baked level model (flvl_bake.odin's
// Baked_Level) into the shared .gen.fun Seam (gen_emit.odin) the canonical
// emitter renders — the "fresh bake" of levels/<stem>.flvl whose bytes a clean
// tree reproduces against the committed gen/<stem>.gen.fun. It is the level
// analogue of fpm_emit.odin's rig_seam_of_unit: a pure projection from the
// resolved bake to the explicit byte-contract model, with NO emission of its own
// (emit_gen_fun owns the bytes).
//
// The seam shape (exemplar funpack-spec/examples/arena/gen/arena.gen.fun):
//   - import engine.world.{Spawn, Ref}            — the seam's engine surface
//   - import engine.tilemap.{TilemapHandle}       — only when the level carries a
//                                                   §18 §3 tile layer
//   - import <schema>.{<placed thing types>}      — the schema module, members in
//                                                   schema-declaration order, only
//                                                   the thing types the level places
//                                                   (markers included — a marker IS
//                                                   a placement)
//   - let <layer>: TilemapHandle = TilemapHandle{name: "<layer>"}  — one §18 §3
//                                                   layer constant per tilemap, in
//                                                   declaration order
//   - data <Level><PrefabType> { <member>: Ref[T], … }  — one inline record per
//                                                   distinct prefab type a top-level
//                                                   symbol places, members in order
//   - data <Level> { <symbol>: Ref[T] | <Level><PrefabType>, … }  — the symbol
//                                                   table, aligned-multiline, fields
//                                                   in top-level declaration order
//   - extern fn <level>_spawns() -> [Spawn]        — the deterministic spawn list
//   - extern fn <level>() -> <Level>               — the symbol table accessor
//
// DOCS as bake metadata: the file-leading @doc and the per-declaration @doc
// strings are authored bake metadata (a faithful bake passes the committed
// exemplar's docs through — the same contract rig_seam_of_unit uses for the rig
// digest docs), supplied by the caller as Level_Seam_Docs.
//
// PURITY (spec §09, §29): the projection is a pure function of the baked model
// plus the schema's thing-declaration order. It walks ordered slices only (never a
// map), so two projections of the same bake are byte-identical through the
// emitter.
package funpack

import "core:strings"

// Level_Seam_Docs carries the authored @doc strings the projection stamps onto
// the seam — bake metadata a faithful bake passes through from the committed
// exemplar (the level seam's prose is not derivable from the bake alone). file is
// the file-leading @doc; prefab/symbols/spawns/accessor head the four declarations
// in emission order.
Level_Seam_Docs :: struct {
	file:     string, // the file-leading @doc
	prefab:   string, // the `data <Level><PrefabType>` record @doc
	symbols:  string, // the `data <Level>` symbol-table @doc
	spawns:   string, // the `extern fn <level>_spawns` @doc
	accessor: string, // the `extern fn <level>` @doc
	tilemap:  string, // the `let <layer>: TilemapHandle` constant @doc (§18 §3)
}

// level_seam_of_baked projects a baked level onto the shared Seam model. schema is
// the `things` module's parsed Ast (its thing-declaration order is the schema
// import member order); docs are the authored seam @doc strings; allocator backs
// every returned slice so the Seam outlives this call (Odin forbids returning a
// stack-backed compound-literal slice). The projection is deterministic: imports,
// records, and fields all walk ordered slices, so the emitted bytes are stable.
level_seam_of_baked :: proc(baked: Baked_Level, schema: Ast, docs: Level_Seam_Docs, allocator := context.allocator) -> Seam {
	// The engine import block: engine.world always (Spawn/Ref are every level
	// seam's surface); engine.tilemap joins when the level carries a §18 §3
	// tile layer (the TilemapHandle constants' type); the schema import last —
	// engine imports ahead of the schema module, the exemplar order.
	has_layers := len(baked.tile_layers) > 0
	import_count := 3 if has_layers else 2
	imports := make([]Seam_Import, import_count, allocator)
	imports[0] = Seam_Import {
		path    = "engine.world",
		members = slice_lit({"Spawn", "Ref"}, allocator),
	}
	if has_layers {
		imports[1] = Seam_Import {
			path    = "engine.tilemap",
			members = slice_lit({"TilemapHandle"}, allocator),
		}
	}
	imports[import_count-1] = Seam_Import {
		path    = level_schema_module_path(baked, allocator),
		members = level_placed_thing_types(baked, schema, allocator),
	}

	// One `data <Level><PrefabType>` record per distinct prefab type a TOP-LEVEL
	// symbol places, in first-appearance order, ahead of the symbol-table record.
	prefab_records := level_prefab_records(baked, docs.prefab, allocator)

	declarations := make([dynamic]Seam_Decl, 0, len(prefab_records) + len(baked.tile_layers) + 3, allocator)
	// The §18 §3 layer constants lead the declarations (the assets.gen.fun
	// handle-constant position: lets directly after the imports), one per
	// baked layer in declaration order — "the seam gains the layer as a
	// TilemapHandle".
	for layer in baked.tile_layers {
		append(&declarations, Seam_Decl {
			doc  = docs.tilemap,
			kind = Seam_Let {
				name  = strings.clone(layer.name, allocator),
				type  = "TilemapHandle",
				value = tilemap_handle_value(layer.name, allocator),
			},
		})
	}
	for record in prefab_records {
		append(&declarations, record)
	}
	// The `data <Level>` symbol table: aligned-multiline, one field per top-level
	// symbol in declaration order.
	append(&declarations, Seam_Decl {
		doc  = docs.symbols,
		kind = Seam_Data {
			name      = baked.level_name,
			multiline = true,
			fields    = level_symbol_fields(baked, allocator),
		},
	})
	// The two extern-fn accessors: the spawn list and the symbol table.
	append(&declarations, Seam_Decl {
		doc  = docs.spawns,
		kind = Seam_Extern_Fn{name = level_spawns_fn_name(baked, allocator), return_type = "[Spawn]"},
	})
	append(&declarations, Seam_Decl {
		doc  = docs.accessor,
		kind = Seam_Extern_Fn{name = level_accessor_fn_name(baked, allocator), return_type = baked.level_name},
	})

	return Seam {
		doc          = docs.file,
		imports      = imports,
		declarations = declarations[:],
	}
}

// level_schema_module_path is the seam's schema import path — the `things` module
// the bake placed against (`import arena_world.{…}`). The bake recorded the
// resolved `things <module>` name on the Baked_Level, so the projection reads it
// directly, cloned into the seam's allocator.
level_schema_module_path :: proc(baked: Baked_Level, allocator := context.allocator) -> string {
	return strings.clone(baked.schema_module, allocator)
}

// level_placed_thing_types is the schema import's member list: every thing type
// the level PLACES (named or anonymous, named in the spawn list), de-duplicated
// and ordered by the schema's thing-declaration order. A placed type the schema
// does not declare is skipped (the bake already gated unknown types), so the list
// is exactly the schema things the level uses, in schema order — the byte order
// the committed seam carries.
level_placed_thing_types :: proc(baked: Baked_Level, schema: Ast, allocator := context.allocator) -> []string {
	placed := make(map[string]bool, context.temp_allocator)
	for spawn in baked.spawns {
		placed[spawn.thing_type] = true
	}
	members := make([dynamic]string, 0, len(schema.things), allocator)
	for thing in schema.things {
		if placed[thing.name] {
			append(&members, strings.clone(thing.name, allocator))
		}
	}
	return members[:]
}

// level_prefab_records builds one inline `data <Level><PrefabType>` record per
// DISTINCT prefab type a top-level symbol places, in first-appearance order. Its
// fields are the prefab instance's member Refs (`<member>: Ref[<thing_type>]`) in
// member declaration order. Two placements of the same prefab type share one
// record (left_gun and right_gun both `Turret` ⇒ one `ArenaTurret`), so the record
// set is keyed by prefab type and emitted once.
level_prefab_records :: proc(baked: Baked_Level, prefab_doc: string, allocator := context.allocator) -> []Seam_Decl {
	seen := make(map[string]bool, context.temp_allocator)
	records := make([dynamic]Seam_Decl, 0, 2, allocator)
	for symbol in baked.symbols {
		if symbol.kind != .Prefab {
			continue
		}
		prefab := baked.prefabs[symbol.index]
		if seen[prefab.type] {
			continue
		}
		seen[prefab.type] = true
		records = append_prefab_record(records, baked.level_name, prefab, prefab_doc, allocator)
	}
	return records[:]
}

// append_prefab_record appends one `data <Level><PrefabType>` inline record built
// from a prefab instance's member Refs. The record name is the level name prefixed
// onto the PascalCase prefab type (`Arena` + `Turret` ⇒ `ArenaTurret`); each field
// is the member's bare local name typed `Ref[<thing_type>]`, in member order.
append_prefab_record :: proc(records: [dynamic]Seam_Decl, level_name: string, prefab: Baked_Prefab_Instance, prefab_doc: string, allocator := context.allocator) -> [dynamic]Seam_Decl {
	records := records
	fields := make([]Seam_Field, len(prefab.members), allocator)
	for member, i in prefab.members {
		fields[i] = Seam_Field {
			name = strings.clone(member.local_name, allocator),
			type = ref_type_token(member.thing_type, allocator),
		}
	}
	append(&records, Seam_Decl {
		doc  = prefab_doc,
		kind = Seam_Data {
			name      = level_prefab_record_name(level_name, prefab.type, allocator),
			multiline = false,
			fields    = fields,
		},
	})
	return records
}

// level_symbol_fields builds the `data <Level>` symbol-table fields — one per
// top-level symbol in declaration order. A simple Ref symbol is `<name>:
// Ref[<thing_type>]`; a prefab symbol is `<name>: <Level><PrefabType>` (the inline
// prefab record's type). The field order is the level's source order (the bake's
// symbols slice), so the byte layout matches the committed seam.
level_symbol_fields :: proc(baked: Baked_Level, allocator := context.allocator) -> []Seam_Field {
	fields := make([]Seam_Field, len(baked.symbols), allocator)
	for symbol, i in baked.symbols {
		switch symbol.kind {
		case .Ref:
			ref := baked.refs[symbol.index]
			fields[i] = Seam_Field {
				name = strings.clone(symbol.local_name, allocator),
				type = ref_type_token(ref.thing_type, allocator),
			}
		case .Prefab:
			prefab := baked.prefabs[symbol.index]
			fields[i] = Seam_Field {
				name = strings.clone(symbol.local_name, allocator),
				type = level_prefab_record_name(baked.level_name, prefab.type, allocator),
			}
		}
	}
	return fields
}

// tilemap_handle_value renders a layer constant's initializer token —
// `TilemapHandle{name: "<layer>"}`, the §19 handle-constant value shape the
// assets seam fixed (keyed on the layer's authored name, spec §18 §3).
tilemap_handle_value :: proc(layer_name: string, allocator := context.allocator) -> string {
	return strings.concatenate({"TilemapHandle{name: \"", layer_name, "\"}"}, allocator)
}

// ref_type_token renders a `Ref[<thing_type>]` field type token — the typed
// reference a simple symbol and a prefab member both carry (spec §08/§17.2).
ref_type_token :: proc(thing_type: string, allocator := context.allocator) -> string {
	return strings.concatenate({"Ref[", thing_type, "]"}, allocator)
}

// level_prefab_record_name is the inline prefab record's type name: the level name
// prefixed onto the prefab type (`Arena` + `Turret` ⇒ `ArenaTurret`), the §17
// per-level naming that keeps two levels' same-named prefabs distinct.
level_prefab_record_name :: proc(level_name, prefab_type: string, allocator := context.allocator) -> string {
	return strings.concatenate({level_name, prefab_type}, allocator)
}

// level_spawns_fn_name is the deterministic-spawn-list accessor name: the
// lowercase level name with the `_spawns` suffix (`Arena` ⇒ `arena_spawns`).
level_spawns_fn_name :: proc(baked: Baked_Level, allocator := context.allocator) -> string {
	return strings.concatenate({strings.to_lower(baked.level_name, context.temp_allocator), "_spawns"}, allocator)
}

// level_accessor_fn_name is the symbol-table accessor name: the lowercase level
// name (`Arena` ⇒ `arena`), the module-named entry point the behavior code calls.
level_accessor_fn_name :: proc(baked: Baked_Level, allocator := context.allocator) -> string {
	return strings.to_lower(baked.level_name, allocator)
}
