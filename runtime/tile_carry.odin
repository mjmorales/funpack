package funpack_runtime

Tile_Carry_Edit :: struct {
	layer_name: string,
	col:        int,
	row:        int,
	tile_name:  string,
}

Tile_Carry_Delta :: struct {
	edits: []Tile_Carry_Edit,
}

tile_carry_delta :: proc(
	old_bake: []Tile_Layer,
	live: []Tile_Layer,
	allocator := context.allocator,
) -> Tile_Carry_Delta {
	edits := make([dynamic]Tile_Carry_Edit, allocator)
	for old_layer in old_bake {
		live_layer := find_tile_layer(live, old_layer.name)
		if live_layer == nil {
			continue
		}
		cells := min(len(old_layer.cells), len(live_layer.cells))
		for i in 0 ..< cells {
			if live_layer.cells[i] == old_layer.cells[i] {
				continue
			}
			index := live_layer.cells[i]
			if index < 0 || index >= len(live_layer.palette) {
				continue
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

tile_carry_apply :: proc(
	delta: Tile_Carry_Delta,
	new_bake: []Tile_Layer,
	allocator := context.allocator,
) -> []Tile_Layer {
	if len(delta.edits) == 0 {
		return new_bake
	}
	layers := make([]Tile_Layer, len(new_bake), allocator)
	copy(layers, new_bake)
	fresh := make([]bool, len(layers), allocator)

	for edit in delta.edits {
		index := find_layer_index(layers, edit.layer_name)
		if index < 0 {
			continue
		}
		layer := &layers[index]
		if edit.col < 0 || edit.col >= layer.cols || edit.row < 0 || edit.row >= layer.rows {
			continue
		}
		palette := tilemap_palette_index(layer, edit.tile_name)
		if palette < 0 {
			continue
		}
		cow_cells(layer, index, fresh, allocator)
		layer.cells[edit.row * layer.cols + edit.col] = palette
	}
	return layers
}

find_tile_layer :: proc(layers: []Tile_Layer, name: string) -> ^Tile_Layer {
	for &layer in layers {
		if layer.name == name {
			return &layer
		}
	}
	return nil
}
