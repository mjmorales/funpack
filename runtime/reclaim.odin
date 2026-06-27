package funpack_runtime

deep_clone_field_value :: proc(
	fv: Field_Value,
	allocator := context.allocator,
) -> (
	owned: Field_Value,
	ok: bool,
) {
	switch v in fv {
	case i64, Fixed, bool, Vec2, Vec3, Ref:
		return fv, true
	case string, String_Value, Record_Value, List_Value, Map_Value, Variant_Value:
		return value_to_field_value(field_value_to_value(fv), allocator)
	}
	return nil, false
}

free_field_value :: proc(fv: Field_Value, allocator := context.allocator) {
	switch v in fv {
	case i64, Fixed, bool, Vec2, Vec3, Ref:
		return
	case string:
		delete(v, allocator)
	case String_Value:
		delete(v.text, allocator)
	case Record_Value:
		free_record_value(v, allocator)
	case List_Value:
		free_list_value(v, allocator)
	case Map_Value:
		free_map_value(v, allocator)
	case Variant_Value:
		free_variant_value(v, allocator)
	}
}

free_record_value :: proc(rec: Record_Value, allocator := context.allocator) {
	for k, v in rec.fields {
		free_column_value(v, allocator)
		delete(k, allocator)
	}
	delete(rec.fields)
	delete(rec.type_name, allocator)
}

free_list_value :: proc(list: List_Value, allocator := context.allocator) {
	for elem in list.elements {
		free_column_value(elem, allocator)
	}
	delete(list.elements, allocator)
}

free_map_value :: proc(m: Map_Value, allocator := context.allocator) {
	for entry in m.entries {
		free_column_value(entry.key, allocator)
		free_column_value(entry.value, allocator)
	}
	delete(m.entries, allocator)
}

free_variant_value :: proc(v: Variant_Value, allocator := context.allocator) {
	delete(v.enum_type, allocator)
	delete(v.case_name, allocator)
	if v.payload != nil {
		free_column_value(v.payload^, allocator)
		free(v.payload, allocator)
	}
}

free_column_value :: proc(v: Value, allocator := context.allocator) {
	switch x in v {
	case Record_Value:
		free_record_value(x, allocator)
	case List_Value:
		free_list_value(x, allocator)
	case Map_Value:
		free_map_value(x, allocator)
	case Variant_Value:
		free_variant_value(x, allocator)
	case i64, Fixed, bool, Vec2, Vec3, Ref, String_Value, Lambda_Value, Tuple_Value, Rng, Transform_Value, Pose_Value, Handle_Value, Nav_Value:
		return
	}
}

free_blackboard :: proc(m: map[string]Field_Value, allocator := context.allocator) {
	m := m
	for _, v in m {
		free_field_value(v, allocator)
	}
	delete(m)
}

free_superseded_maps :: proc(superseded: [dynamic]map[string]Field_Value, allocator := context.allocator) {
	for m in superseded {
		free_blackboard(m, allocator)
	}
}

// Spine only: row.fields blackboards are ALIASED by the survivor version (structural sharing) — freeing them would dangle it.
free_version_structure :: proc(v: World_Version, allocator := context.allocator) {
	for table in v.tables {
		delete(table.rows, allocator)
	}
	delete(v.tables, allocator)
}

// Full free: for a version nothing aliases — frees the row.fields blackboards too, not just the spine.
free_version_fully :: proc(v: World_Version, allocator := context.allocator) {
	for table in v.tables {
		for row in table.rows {
			if row.fields != nil {
				free_blackboard(row.fields, allocator)
			}
		}
		delete(table.rows, allocator)
	}
	delete(v.tables, allocator)
}

free_tick_state :: proc(state: ^Tick_State, allocator := context.allocator) {
	for &table in state.tables {
		delete(table.rows)
	}
	delete(state.tables, allocator)
	free_signal_mailbox(state.mailbox, allocator)
	delete(state.spawns)
	delete(state.despawns)
	delete(state.persist_commands)
	delete(state.terrain_commands)
	delete(state.tile_refusals)
	delete(state.superseded)
}

free_version_tilemaps :: proc(
	dead: World_Version,
	survivor: World_Version,
	program: ^Program,
	allocator := context.allocator,
) {
	if len(dead.tilemaps) == 0 {
		return
	}
	if raw_data(dead.tilemaps) == raw_data(survivor.tilemaps) ||
	   raw_data(dead.tilemaps) == raw_data(program.tilemaps) {
		return
	}
	for layer, i in dead.tilemaps {
		survivor_aliases := i < len(survivor.tilemaps) && raw_data(layer.cells) == raw_data(survivor.tilemaps[i].cells)
		program_owns := i < len(program.tilemaps) && raw_data(layer.cells) == raw_data(program.tilemaps[i].cells)
		if !survivor_aliases && !program_owns {
			delete(layer.cells, allocator)
		}
	}
	delete(dead.tilemaps, allocator)
}

free_signal_mailbox :: proc(mailbox: Signal_Mailbox, allocator := context.allocator) {
	for _, list in mailbox.by_type {
		delete(list, allocator)
	}
	delete(mailbox.by_type)
	for _, inner in mailbox.by_instance {
		inner := inner
		for _, list in inner {
			delete(list, allocator)
		}
		delete(inner)
	}
	delete(mailbox.by_instance)
}
