// The §09 §4 / §18 §4 dynamic-tile carry across a schema swap: dynamic tile
// state is COMMITTED WORLD STATE (§18 §4), so a SetTile-rewritten cell must
// SURVIVE the swap that migrates thing schemas. Across a reload/restore swap
// the runtime diffs the LIVE committed layers against the PRIOR artifact's bake
// — exactly the cells SetTile rewrote — and re-applies that delta onto the NEW
// bake, keyed by cell coordinate and tile NAME (the same name-keyed philosophy
// as the schema-diff; palette indices may reshuffle freely). New-bake-wins on
// any unmappable cell (ADR 2026-06-11-dynamic-tiles-carry-across-hot-reload).
//
// ONE kernel, two pure procs, shared by BOTH consumers (§09 §4's "one mechanism
// shared with persistence"): hot-reload threads the prior program's bake +
// committed live layers here (schema_migrate.odin), and the §24 save-stream
// task threads the saved prior bake + saved committed layers through the SAME
// pair — neither proc knows which consumer called it, both are allocator-
// explicit, and neither couples to reload-specific state.
//
// DETERMINISM. The delta scan and the re-apply walk are stable layer-decl order
// + row-major cells, exact string name-match, NO map iteration anywhere — so
// the carried world is a pure function of (old_bake, live, new_bake), bit-
// identical on every machine (§10.5). Hot-reload is incompatible with lockstep
// replay BY CONSTRUCTION (the code changed mid-sim), so nothing on the recorded
// replay/digest path runs this — no golden moves.
package funpack_runtime

// Tile_Carry_Edit is one carried SetTile cell as a name-keyed fact: the layer
// it lives in (matched by name across bakes), the cell coordinate, and the tile
// NAME the live committed layer holds there. Resolving to a NAME (not a palette
// index) is what lets the NEW bake reshuffle its palette freely — an index from
// the old palette is meaningless against the new one, a name is portable.
Tile_Carry_Edit :: struct {
	layer_name: string,
	col:        int,
	row:        int,
	tile_name:  string,
}

// Tile_Carry_Delta is the whole-world carry as a flat slice of edits in
// DETERMINISTIC order (old-bake layer-decl order, then row-major within each
// layer) — never a map, so iteration order is the slice order and the re-apply
// is reproducible. An empty delta (no SetTile ever ran, or live == old_bake) is
// the no-op carry: apply over it yields the new bake unchanged.
Tile_Carry_Delta :: struct {
	edits: []Tile_Carry_Edit,
}

// tile_carry_delta computes the carry: per layer matched BY NAME (old-bake decl
// order), scan cells row-major and emit an edit for every cell where the LIVE
// committed index differs from the OLD BAKE index AND the live cell holds a real
// palette tile. live and old_bake share the same palette (live COW-aliases the
// bake's palette forever — fold_tile_layers only ever fresh-copies `cells`), so
// an index-diff IS a name-diff on the old side; the edit carries the LIVE tile's
// name so the new palette can map it under any reshuffle.
//
// A differing cell that is TILE_CELL_EMPTY in `live` cannot arise from SetTile —
// fold_tile_layers only ever writes a REAL palette index (the Unknown_Tile arm
// refuses an unknown name, never erases to empty), so a live-empty diff would be
// a bake-shape change, not a terrain edit. It is skipped: there is no SetTile to
// carry, and the new bake's own cell wins by default.
tile_carry_delta :: proc(
	old_bake: []Tile_Layer,
	live: []Tile_Layer,
	allocator := context.allocator,
) -> Tile_Carry_Delta {
	edits := make([dynamic]Tile_Carry_Edit, allocator)
	for old_layer in old_bake {
		live_layer := find_tile_layer(live, old_layer.name)
		if live_layer == nil {
			continue // a layer the live world dropped carries no edits (unreachable: live aliases the same bake shape)
		}
		// Grids share dimensions across the same bake (live COW-aliases old_bake's
		// shape), but guard defensively — scan only the common cell range.
		cells := min(len(old_layer.cells), len(live_layer.cells))
		for i in 0 ..< cells {
			if live_layer.cells[i] == old_layer.cells[i] {
				continue
			}
			index := live_layer.cells[i]
			if index < 0 || index >= len(live_layer.palette) {
				continue // TILE_CELL_EMPTY or an out-of-palette index: not a SetTile edit, skip
			}
			append(
				&edits,
				Tile_Carry_Edit {
					layer_name = old_layer.name,
					col = i % live_layer.cols,
					row = i / live_layer.cols,
					tile_name = live_layer.palette[index].name,
				},
			)
		}
	}
	return Tile_Carry_Delta{edits = edits[:]}
}

// tile_carry_apply re-applies the carry delta onto the NEW bake, producing the
// carried committed layers — the value the swap commits as the post-migration
// tile state. COW EXACTLY mirrors fold_tile_layers: an unedited layer SHARES the
// new bake's slice by reference (structural sharing, so the alias-guarded
// reclaim retires nothing it must keep); an edited layer fresh-copies its
// `cells` ONCE on the allocator, while its name/palette ALWAYS alias the new
// bake. A non-empty delta allocates a fresh layers slice (copy of new_bake) so
// the new-bake input is never mutated; an empty delta returns the new bake
// verbatim (the no-op carry — restore's identity case is byte-for-byte the new
// bake).
//
// DROP RULES (new-bake-wins, ADR-pinned): each edit drops silently when its
// layer is ABSENT from the new bake, when (col,row) is OUT OF the new grid, or
// when its tile NAME left the new palette. A mappable edit OVERRIDES the new
// bake's own cell at that coordinate — the delta wins on a collision; the drop
// rules govern only the UNmappable cells.
tile_carry_apply :: proc(
	delta: Tile_Carry_Delta,
	new_bake: []Tile_Layer,
	allocator := context.allocator,
) -> []Tile_Layer {
	if len(delta.edits) == 0 {
		return new_bake // the no-op carry: structural sharing of the new bake
	}
	layers := make([]Tile_Layer, len(new_bake), allocator)
	copy(layers, new_bake)
	// Which layers' cells are already fresh — copy once, then write in place
	// within this slice's own copy (the fold_tile_layers fresh-set discipline).
	fresh := make([]bool, len(layers), allocator)

	for edit in delta.edits {
		index := find_layer_index(layers, edit.layer_name)
		if index < 0 {
			continue // layer absent from the new bake: drop (new-bake-wins)
		}
		layer := &layers[index]
		if edit.col < 0 || edit.col >= layer.cols || edit.row < 0 || edit.row >= layer.rows {
			continue // out of the new grid: drop
		}
		palette := tilemap_palette_index(layer, edit.tile_name)
		if palette < 0 {
			continue // tile name left the new palette: drop
		}
		// Same layer-level COW the live fold uses (cow_layer_cells), pinned to this
		// carry's own allocator: copy `cells` once, then write the carried cell in place.
		cow_cells(layer, index, fresh, allocator)
		layer.cells[edit.row * layer.cols + edit.col] = palette
	}
	return layers
}

// find_tile_layer is the by-name lookup over a layer slice — a linear scan in
// declaration order, the no-map discipline. Returns a pointer into the slice (or
// nil), so the caller reads dimensions/palette without copying.
find_tile_layer :: proc(layers: []Tile_Layer, name: string) -> ^Tile_Layer {
	for &layer in layers {
		if layer.name == name {
			return &layer
		}
	}
	return nil
}
