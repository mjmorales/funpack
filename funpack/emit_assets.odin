package funpack

import "core:encoding/base64"
import "core:strings"

emit_tilemaps :: proc(b: ^strings.Builder, layers: []Baked_Tile_Layer) {
	emit_header(b, "tilemaps", len(layers))
	for layer in layers {
		strings.write_string(b, "tilemap ")
		strings.write_string(b, layer.name)
		strings.write_byte(b, ' ')
		strings.write_int(b, int(layer.cell_size))
		strings.write_byte(b, ' ')
		strings.write_int(b, layer.cols)
		strings.write_byte(b, ' ')
		strings.write_int(b, layer.rows)
		strings.write_byte(b, ' ')
		strings.write_string(b, encode_fixed(layer.anchor_x, context.temp_allocator))
		strings.write_byte(b, ' ')
		strings.write_string(b, encode_fixed(layer.anchor_y, context.temp_allocator))
		strings.write_byte(b, ' ')
		strings.write_string(b, layer.atlas == "" ? "-" : layer.atlas)
		strings.write_byte(b, ' ')
		strings.write_int(b, len(layer.palette))
		emit_line(b, "")
		for tile in layer.palette {
			strings.write_string(b, "tile ")
			strings.write_string(b, tile.name)
			strings.write_byte(b, ' ')
			strings.write_string(b, encode_bool(tile.solid))
			strings.write_byte(b, ' ')
			strings.write_int(b, int(tile.cell_x))
			strings.write_byte(b, ' ')
			strings.write_int(b, int(tile.cell_y))
			emit_line(b, "")
		}
		for r in 0 ..< layer.rows {
			strings.write_string(b, "row")
			for c in 0 ..< layer.cols {
				strings.write_byte(b, ' ')
				cell := layer.cells[r * layer.cols + c]
				if cell == TILE_LAYER_EMPTY_CELL {
					strings.write_byte(b, '-')
				} else {
					strings.write_int(b, cell)
				}
			}
			emit_line(b, "")
		}
	}
}

emit_navs :: proc(b: ^strings.Builder, graphs: []Baked_Nav_Graph) {
	emit_header(b, "nav", len(graphs))
	for graph in graphs {
		strings.write_string(b, "nav ")
		strings.write_string(b, graph.name)
		strings.write_byte(b, ' ')
		strings.write_int(b, len(graph.nodes))
		strings.write_byte(b, ' ')
		strings.write_int(b, len(graph.edges))
		emit_line(b, "")
		for node in graph.nodes {
			emit_line(b, "navnode ", encode_fixed(node.x, context.temp_allocator), " ", encode_fixed(node.y, context.temp_allocator))
		}
		for edge in graph.edges {
			strings.write_string(b, "navedge ")
			strings.write_int(b, edge.a)
			strings.write_byte(b, ' ')
			strings.write_int(b, edge.b)
			emit_line(b, "")
		}
	}
}

Baked_Assets :: struct {
	images:  []Baked_Image,
	atlases: []Baked_Atlas,
}

Baked_Image :: struct {
	hash:   string,
	width:  int,
	height: int,
	pixels: []byte,
}

Baked_Atlas :: struct {
	name:       string,
	image_hash: string,
	regions:    []Baked_Region,
}

Baked_Region :: struct {
	name:  string,
	px_x:  int,
	px_y:  int,
	px_w:  int,
	px_h:  int,
}

emit_assets :: proc(b: ^strings.Builder, assets: Baked_Assets) {
	emit_header(b, "assets", len(assets.images) + len(assets.atlases))
	for image in assets.images {
		strings.write_string(b, "image ")
		strings.write_string(b, image.hash)
		strings.write_byte(b, ' ')
		strings.write_int(b, image.width)
		strings.write_byte(b, ' ')
		strings.write_int(b, image.height)
		strings.write_string(b, " b64:")
		encoded, _ := base64.encode(image.pixels, base64.ENC_TABLE, context.temp_allocator)
		strings.write_string(b, encoded)
		emit_line(b, "")
	}
	for atlas in assets.atlases {
		strings.write_string(b, "atlas ")
		strings.write_string(b, atlas.name)
		strings.write_byte(b, ' ')
		strings.write_string(b, atlas.image_hash)
		strings.write_byte(b, ' ')
		strings.write_int(b, len(atlas.regions))
		emit_line(b, "")
		for region in atlas.regions {
			strings.write_string(b, "region ")
			strings.write_string(b, region.name)
			strings.write_byte(b, ' ')
			strings.write_int(b, region.px_x)
			strings.write_byte(b, ' ')
			strings.write_int(b, region.px_y)
			strings.write_byte(b, ' ')
			strings.write_int(b, region.px_w)
			strings.write_byte(b, ' ')
			strings.write_int(b, region.px_h)
			emit_line(b, "")
		}
	}
}
