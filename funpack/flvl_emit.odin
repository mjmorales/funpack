package funpack

import "core:strings"

Level_Seam_Docs :: struct {
	file:     string,
	prefab:   string,
	symbols:  string,
	spawns:   string,
	accessor: string,
	tilemap:  string,
}

level_seam_of_baked :: proc(baked: Baked_Level, schema: Ast, docs: Level_Seam_Docs, allocator := context.allocator) -> Seam {
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

	prefab_records := level_prefab_records(baked, docs.prefab, allocator)

	declarations := make([dynamic]Seam_Decl, 0, len(prefab_records) + len(baked.tile_layers) + 3, allocator)
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
	append(&declarations, Seam_Decl {
		doc  = docs.symbols,
		kind = Seam_Data {
			name      = baked.level_name,
			multiline = true,
			fields    = level_symbol_fields(baked, allocator),
		},
	})
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

level_schema_module_path :: proc(baked: Baked_Level, allocator := context.allocator) -> string {
	return strings.clone(baked.schema_module, allocator)
}

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

append_prefab_record :: proc(records: [dynamic]Seam_Decl, level_name: string, prefab: Baked_Prefab_Instance, prefab_doc: string, allocator := context.allocator) -> [dynamic]Seam_Decl {
	records := records
	fields := make([]Seam_Field, len(prefab.members), allocator)
	for member, i in prefab.members {
		fields[i] = Seam_Field {
			name = strings.clone(member.local_name, allocator),
			type = flvl_ref_type_token(member.thing_type, allocator),
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

level_symbol_fields :: proc(baked: Baked_Level, allocator := context.allocator) -> []Seam_Field {
	fields := make([]Seam_Field, len(baked.symbols), allocator)
	for symbol, i in baked.symbols {
		switch symbol.kind {
		case .Ref:
			ref := baked.refs[symbol.index]
			fields[i] = Seam_Field {
				name = strings.clone(symbol.local_name, allocator),
				type = flvl_ref_type_token(ref.thing_type, allocator),
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

tilemap_handle_value :: proc(layer_name: string, allocator := context.allocator) -> string {
	return strings.concatenate({"TilemapHandle{name: \"", layer_name, "\"}"}, allocator)
}

flvl_ref_type_token :: proc(thing_type: string, allocator := context.allocator) -> string {
	return strings.concatenate({"Ref[", thing_type, "]"}, allocator)
}

level_prefab_record_name :: proc(level_name, prefab_type: string, allocator := context.allocator) -> string {
	return strings.concatenate({level_name, prefab_type}, allocator)
}

level_spawns_fn_name :: proc(baked: Baked_Level, allocator := context.allocator) -> string {
	return strings.concatenate({strings.to_lower(baked.level_name, context.temp_allocator), "_spawns"}, allocator)
}

level_accessor_fn_name :: proc(baked: Baked_Level, allocator := context.allocator) -> string {
	return strings.to_lower(baked.level_name, allocator)
}
