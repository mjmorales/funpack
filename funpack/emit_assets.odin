// The baked-content serializers of the artifact emitter: [tilemaps] (§17), [nav]
// (§18), and [assets] (§19). These sections carry the baked tile layers, their
// derived nav graphs, and the decoded sprite pixels — content threaded in from
// the tree's bake rather than projected from the AST, which is why they group
// together and why this file alone reaches for base64.
package funpack

import "core:encoding/base64"
import "core:strings"

// ───────────────────────────────────────────────────────────────────────────
// [tilemaps] — the §18 §3 baked tile layers (docs/artifact-format.md §17)
// ───────────────────────────────────────────────────────────────────────────

// emit_tilemaps writes one record per baked tile layer in level declaration
// order (schema v17): the lead line `tilemap NAME CELL_SIZE COLS ROWS
// ANCHOR_X ANCHOR_Y ATLAS PALETTE_COUNT` — the anchor is the world point of the
// grid's top-left corner as two raw Q32.32 Fixed fields (§2.3), the v12
// authoritative grid→world mapping datum (the tilemap-anchor ADR), and ATLAS is
// the layer's tileset atlas HANDLE name (the §19 textured-render link, v17 — the
// same handle name the [assets] atlas record is keyed by, or `-` for a degenerate
// palette-less layer) — then the palette's `tile NAME SOLID CELL_X CELL_Y` lines
// (legend order, each carrying its §18 §2 baked collision verdict and its v17
// atlas-cell coordinate), then ROWS `row` lines of COLS space-separated cells — a
// decimal palette index or `-` for a tile-less cell (an `empty` legend bind or a
// marker cell; markers ride the spawn machinery, never this section). Together the
// per-layer atlas + per-tile cell let the runtime resolve a tile's texture through
// asset_region(atlas, cell), the same lookup a textured Draw_Sprite uses. Every walk
// is slice-order over the baked model, so two emissions are byte-identical.
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
		// The layer atlas handle name (v17); `-` for a degenerate palette-less layer
		// (no tile draws, so there is no atlas), keeping the lead line's field count
		// fixed and the token non-empty (the `-` sentinel the row/marker lines use).
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

// ───────────────────────────────────────────────────────────────────────────
// [nav] — the §12 §1 nav graphs (docs/artifact-format.md §18, schema v13)
// ───────────────────────────────────────────────────────────────────────────

// emit_navs writes one record per derived nav graph in the same slice order as
// [tilemaps] (schema v13): the lead line `nav NAME NODE_COUNT EDGE_COUNT` — NO
// grid metadata, because §12 §5 forbids exposing the Cell index, so the artifact
// leaks no col/row — then NODE_COUNT `navnode FIXED_X FIXED_Y` lines (each a
// walkable cell's world-space CENTER as two raw Q32.32 Fixed, the v12 anchor
// encoding, in ROW-MAJOR order so the line position IS the node index), then
// EDGE_COUNT `navedge A B` lines (the 4-neighbor orthogonal adjacencies, deduped
// to right/down with `A < B` canonical, in ascending (A, B) order). Every walk is
// slice-order over the baked model, so two emissions are byte-identical. A
// level-less game has no graphs, so this writes the constant `[nav 0]` tail.
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

// ───────────────────────────────────────────────────────────────────────────
// [assets] — the §19 baked sprite pixels + atlas slice rects
// (docs/artifact-format.md §19, schema v16)
// ───────────────────────────────────────────────────────────────────────────

// Baked_Assets is the §19 sprite art the [assets] section carries (schema v16):
// the distinct decoded images (content-addressed by hash) and the atlases that
// slice them. images is the dedup set — two atlases sharing one image hold one
// Baked_Image — and atlases reference an image by its hash, so the pixel blob
// appears once. The [assets] top-level record count is len(images) + len(atlases);
// region sub-records ride inside their atlas. The empty value is the asset-less
// default (the constant `[assets 0]` tail).
Baked_Assets :: struct {
	images:  []Baked_Image,
	atlases: []Baked_Atlas,
}

// Baked_Image is one distinct decoded image the [assets] section carries: its §2
// content hash (the dedup key an atlas references), the decoded pixel dimensions,
// and the canonical RGBA8 buffer (width*height*4 bytes, row-major top-to-bottom —
// import_image's `.alpha_add_if_missing` output) the emitter base64-encodes into
// one ASCII token.
Baked_Image :: struct {
	hash:   string,
	width:  int,
	height: int,
	pixels: []byte,
}

// Baked_Atlas is one atlas the [assets] section carries: its registered HANDLE
// name (the manifest [name] block the asset is registered under — the SAME name a
// `Draw_Sprite{atlas: assets.dungeon_atlas, cell}` references through its
// AtlasHandle const, schema v17, NOT the .atlas-file-declared name), the hash of
// the image it slices (the dedup reference into images), and its cell regions in
// source order — the pixel rects (atlas-handle-name, cell-name) → (image pixels,
// rect) resolves through, the same lookup the runtime's asset_region keys on.
Baked_Atlas :: struct {
	name:       string,
	image_hash: string,
	regions:    []Baked_Region,
}

// Baked_Region is one atlas cell's pixel rectangle into its image — the §19
// grid-coord×cell-size lowering (px_x = cell.x*grid_w, px_y = cell.y*grid_h,
// px_w = grid_w, px_h = grid_h). name is the cell name a sprite draw addresses.
Baked_Region :: struct {
	name:  string,
	px_x:  int,
	px_y:  int,
	px_w:  int,
	px_h:  int,
}

// emit_assets writes the [assets] section (schema v16): one `image HASH W H
// b64:RGBA` record per distinct decoded image (content-addressed, so a shared
// image's blob appears once), then one `atlas NAME IMAGE_HASH CELL_COUNT` record
// per atlas with its `region NAME PX_X PX_Y PX_W PX_H` cell rects. The top-level
// record count is len(images) + len(atlases); region lines are sub-records (the
// closed SUB_RECORD_KEYWORDS set), so the lead-line discipline reconciles the
// count. Both walks are slice-order over the baked model and base64 is a pure
// byte→ASCII map, so two emissions are byte-identical (§29). An asset-less game
// writes the constant `[assets 0]` tail.
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
