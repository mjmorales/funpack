// Generational version reclamation for the unbounded live session loop. The
// live driver (session_live.odin) commits one World_Version per tick on
// context.allocator and never ends, so without reclamation the heap grows
// without bound. The bounded test/re-fold paths (replay.odin, *_test.odin) free
// everything wholesale at the END; the live loop has no end, so it must retire
// each tick's now-dead prior version IN the loop.
//
// THE STRUCTURAL-SHARING INVARIANT THIS FILE PRESERVES (load-bearing). The
// version model (state.odin) shares across versions at TWO granularities:
//   - TABLE level (commit_version): an unchanged table is shared by reference.
//     But commit_tick_tables supplies EVERY table as changed, so in the live
//     loop a committed version's `tables` slice and each table's `rows` SLICE
//     are FRESHLY allocated each tick — never shared. These are reclaimable.
//   - ROW level (new_tick_tables): the working table seeds each row by copying
//     the prior Row STRUCT, and Row.fields is an Odin map (a reference). So an
//     UNWRITTEN row's `fields` map (and the Record/List/String/Variant payloads
//     inside it) is ALIASED prior→committed: version N and version N+1 point at
//     the SAME map backing. write_blackboard (tick.odin) installs a FRESH map
//     only on a row the tick actually wrote; a despawn drops a row entirely.
//
// THEREFORE, once N+1 commits, N is dead EXCEPT the `fields` maps N+1 still
// aliases (its unwritten rows). The reclaim set for N is:
//   (1) N's `tables` slice + each table's `rows` SLICE — the []Row backing,
//       NOT the maps inside (free_version_structure), AND
//   (2) the maps of the rows N+1 REWROTE or DESPAWNED — collected O(delta)
//       during the tick into Tick_State.superseded as exactly the prior-N (and
//       intermediate working) maps no longer reachable from N+1, freed once
//       N+1 commits (free_superseded_maps).
// Keeping the unwritten rows' maps is what makes this O(delta), not O(state):
// no copy-forward, no clone-each-tick, no refcount box on Row/Version_Table.
//
// DETERMINISM FLOOR (sacred). Reclamation frees memory; it changes no committed
// value, no frame digest, and no replay log. world_versions_equal between a
// reclaimed run and a temp-allocator reference run at the same tick MUST hold
// (the AC test asserts it). Nothing here runs on the read/fold path — these
// procs are called only by the live driver after a tick has fully committed and
// its draw/audio have been consumed.
package funpack_runtime

// deep_clone_field_value produces a fully-OWNED copy of a blackboard column on
// `allocator` — every leaf string an allocation head, every map/slice/boxed
// payload freshly allocated. It is the round-trip clone value_to_field_value
// already performs, routed through field_value_to_value so the column re-owns even
// the strings the read path BORROWS (a stored enum token lifts to a Variant_Value
// whose tag strings are sub-slices of the token; the lift-then-lower re-clones them
// as owned allocations). It exists so the startup spawn path (build_spawn_blackboard
// / decode_*) commits columns with the SAME uniform ownership a tick write's clone
// produces — which is what makes the generational free procs SOUND: a committed
// column is always a freeable owned tree, never a borrowed slice into artifact
// bytes. The clone is value-identical (same bits, same strings), so the determinism
// floor is untouched. ok mirrors value_to_field_value (a non-column value yields
// false; no startup column produces one).
deep_clone_field_value :: proc(
	fv: Field_Value,
	allocator := context.allocator,
) -> (
	owned: Field_Value,
	ok: bool,
) {
	// The scalar arms own no heap — copy by value, no round-trip needed.
	switch v in fv {
	case i64, Fixed, bool, Vec2, Vec3, Ref:
		return fv, true
	case string, String_Value, Record_Value, List_Value, Variant_Value:
		// The string/structural arms: lift to a Value then lower with a fresh clone, so
		// every owned-by-clone allocation (incl. re-owned enum tags) lands on `allocator`.
		return value_to_field_value(field_value_to_value(fv), allocator)
	}
	return nil, false
}

// free_field_value frees the allocations OWNED BY one blackboard column value —
// the recursive inverse of value_to_field_value / clone_record_value /
// clone_list_value / clone_variant_value (interp.odin). The scalar arms
// (i64/Fixed/bool/Vec2/Vec3/Ref) own nothing and are no-ops. The structural arms
// own heap:
//   - string  : a UNIT enum token cloned by variant_to_token — free the bytes.
//   - String_Value : a §03 String column cloned into the commit allocator.
//   - Record_Value / List_Value / Variant_Value : the cloned structural tree
//     (delegated to free_column_value, the inverse of clone_column_value).
// This frees the VALUE's owned allocations; the caller frees the map/slice that
// holds it. It must run ONLY against a column the surviving version no longer
// aliases (a superseded/rewritten/despawned map's contents) — never an unwritten
// row's column, which the survivor still reads.
free_field_value :: proc(fv: Field_Value, allocator := context.allocator) {
	switch v in fv {
	case i64, Fixed, bool, Vec2, Vec3, Ref:
		// Scalar columns own no heap — copied by value at commit (value_to_field_value).
		return
	case string:
		// A unit-variant token is a string clone (variant_to_token) — free its bytes.
		delete(v, allocator)
	case String_Value:
		// A String column's text was cloned into the commit allocator (strings.clone).
		delete(v.text, allocator)
	case Record_Value:
		free_record_value(v, allocator)
	case List_Value:
		free_list_value(v, allocator)
	case Variant_Value:
		free_variant_value(v, allocator)
	}
}

// free_record_value frees a committed Record_Value column's owned tree — the
// inverse of clone_record_value: each cloned field key string, each field value
// (recursively, via free_column_value), the type_name clone, then the fields map
// itself. Mirrors the clone exactly so no allocation the commit made is leaked or
// double-freed.
free_record_value :: proc(rec: Record_Value, allocator := context.allocator) {
	for k, v in rec.fields {
		free_column_value(v, allocator)
		delete(k, allocator)
	}
	delete(rec.fields)
	delete(rec.type_name, allocator)
}

// free_list_value frees a committed List_Value column's owned slice — the inverse
// of clone_list_value: each element recursively, then the elements slice backing.
free_list_value :: proc(list: List_Value, allocator := context.allocator) {
	for elem in list.elements {
		free_column_value(elem, allocator)
	}
	delete(list.elements, allocator)
}

// free_variant_value frees a committed Variant_Value column's owned bytes — the
// inverse of clone_variant_value: the two tag-string clones and, when present, the
// heap-boxed payload (the `new(Value)` allocation plus the value tree inside it).
free_variant_value :: proc(v: Variant_Value, allocator := context.allocator) {
	delete(v.enum_type, allocator)
	delete(v.case_name, allocator)
	if v.payload != nil {
		free_column_value(v.payload^, allocator)
		free(v.payload, allocator)
	}
}

// free_column_value frees one structural-column Value's owned allocations — the
// inverse of clone_column_value. The scalar/handle/transient arms copy by value at
// clone time (they own nothing in the commit allocator), so they are no-ops here;
// the Record/List/Variant arms recurse into their cloned trees. The
// Pose_Value/Handle_Value/Lambda_Value arms are render-time/transient and never
// reach a committed column (value_to_field_value rejects them), so a committed
// tree never carries them — they no-op defensively to keep the switch total.
free_column_value :: proc(v: Value, allocator := context.allocator) {
	switch x in v {
	case Record_Value:
		free_record_value(x, allocator)
	case List_Value:
		free_list_value(x, allocator)
	case Variant_Value:
		free_variant_value(x, allocator)
	case i64, Fixed, bool, Vec2, Vec3, Ref, String_Value, Lambda_Value, Tuple_Value, Rng, Transform_Value, Pose_Value, Handle_Value:
		// Copied by value at clone time (clone_column_value's by-value arm) — owns no
		// allocation in the commit allocator, so nothing to free.
		return
	}
}

// free_blackboard frees a row's whole blackboard map: each column value's owned
// allocations (free_field_value) then the map backing. Used to retire a SUPERSEDED
// map — a prior-version or intermediate-working map the surviving version no
// longer aliases (a rewritten or despawned row's map collected in
// Tick_State.superseded). It MUST NOT be called on a map the surviving version
// still reads (an unwritten row's map), which free_version_structure deliberately
// leaves alone.
free_blackboard :: proc(m: map[string]Field_Value, allocator := context.allocator) {
	m := m
	for _, v in m {
		free_field_value(v, allocator)
	}
	delete(m)
}

// free_superseded_maps retires every map collected on a tick's superseded list —
// exactly the prior-version maps (and same-tick intermediate working maps) that
// the committed next version no longer aliases, because the tick REWROTE or
// DESPAWNED their rows. Each is freed whole (contents + backing). This is the
// O(delta) half of reclamation: it touches only the maps the tick actually
// replaced, never the unwritten majority the survivor still shares.
free_superseded_maps :: proc(superseded: [dynamic]map[string]Field_Value, allocator := context.allocator) {
	for m in superseded {
		free_blackboard(m, allocator)
	}
}

// free_version_structure retires a now-dead version's STRUCTURE: each table's
// `rows` SLICE (the []Row backing commit_tick_tables freshly allocated) and the
// `tables` SLICE itself. It deliberately does NOT free the `fields` maps inside
// the rows — those may be ALIASED by the surviving version (its unwritten rows
// share the prior version's maps by reference), so freeing them here is a
// use-after-free. The aliased maps that the survivor ABANDONED (rewritten/
// despawned rows) are reclaimed separately via free_superseded_maps; the maps the
// survivor KEPT are now solely owned through the survivor and travel forward with
// it. Call this on a version ONLY after its successor has committed and any draw/
// audio projection of it has been consumed.
free_version_structure :: proc(v: World_Version, allocator := context.allocator) {
	for table in v.tables {
		// Free the row-struct backing only — NOT row.fields (the survivor may alias it).
		delete(table.rows, allocator)
	}
	delete(v.tables, allocator)
}

// free_version_fully retires a version that has NO surviving aliases — every one
// of its rows' `fields` maps AND its structure are freed. The only live case is
// the RESTORE bypass: when a tick folds from a deserialized swap instead of the
// immediate prior, that bypassed prior is referenced by nothing afterward (the
// next version aliases the SWAP's maps, never the prior's), so the prior is wholly
// dead. This is the ONLY situation it is safe to free a version's maps in bulk —
// the normal retirement path (free_version_structure + free_superseded_maps) must
// be used for a version whose successor folded FROM it, because then the
// successor still aliases its unwritten rows' maps.
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

// free_tick_state retires a committed tick's working scratch — everything
// Tick_State allocated that the committed version does NOT own:
//   - each working table's [dynamic]Row backing (delete frees the Row STRUCTS,
//     NOT their maps; the committed version's rows are a separate slice from
//     commit_tick_tables' copy, and the live maps are reachable through either
//     N+1 or the superseded list, so this drops only the working row-struct
//     array, never a live map);
//   - the tables slice itself;
//   - the signal mailbox (both routing maps and their accumulated lists);
//   - the spawns / despawns / persist_commands dynamic arrays;
//   - the `superseded` collection backing (its MAPS are freed by
//     free_superseded_maps FIRST; this frees only the [dynamic] array holding
//     them).
// The transient `changed` map commit_tick_tables built is freed AT its own call
// site (it is not reachable from Tick_State), so it is not retired here. The
// per-tick eval scratch the interpreter built during the fold (env maps,
// intermediate records/lists, the action registry, mailbox slice churn) is NOT
// freed here — the live driver runs the eval on a per-tick scratch ARENA and
// frees it wholesale (free_all) after the tick, which is what bounds the dominant
// transient allocation.
// free_tick_state MUST run AFTER free_superseded_maps (which consumes the maps)
// and does NOT free anything the committed version owns (the committed rows slice,
// the committed maps).
free_tick_state :: proc(state: ^Tick_State, allocator := context.allocator) {
	for &table in state.tables {
		delete(table.rows) // frees the Row-struct backing; maps live on via N+1 / superseded
	}
	delete(state.tables, allocator)
	free_signal_mailbox(state.mailbox, allocator)
	delete(state.spawns)
	delete(state.despawns)
	delete(state.persist_commands)
	delete(state.settile_commands)
	delete(state.settile_refusals)
	delete(state.superseded)
}

// free_version_tilemaps retires a now-dead version's §18 §4 tile-layer state —
// the layers slice and each layer's cells backing — SKIPPING every slice the
// SURVIVING version still aliases (COW: a SetTile-less tick shares the whole
// slice; a SetTile tick copies only the touched layers' cells) and every slice
// the PROGRAM owns (version -1 aliases the pristine decoded bake, which is
// never reclaimed — it is the loader's). Alias detection is the same
// pointer-identity discipline world_versions_same_identity uses: layer order
// is fixed by artifact declaration, so index-wise comparison is exact. Names
// and palettes always alias the program's decode and are never freed here.
// Call it where free_version_structure is called — after the successor commits.
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
		// The survivor (or the bake) still reads this exact slice — nothing is dead.
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

// free_signal_mailbox frees the per-tick signal mailbox's routing structure: the
// per-type broadcast lists, the per-instance inner maps, and the two outer maps.
// The signal RECORD values inside the lists live in the tick's evaluation
// allocator (the same context.allocator the working tables use) and are not
// individually owned here — the mailbox holds Value views built during the fold,
// reset each tick; freeing the list/map backing reclaims the routing tables the
// mailbox itself allocated (new_signal_mailbox + route_signals' combined slices).
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
