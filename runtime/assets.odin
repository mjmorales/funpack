// The §19 baked sprite assets: the decoded, content-addressed atlas/image PIXELS
// a textured `Draw_Sprite{atlas, cell}` (and the textured tile layer) resolve
// against, decoded from the artifact's [assets] section (docs/artifact-format.md
// §19, schema v16) into the Program. The runtime CONSUMES this section; funpack
// DEFINES it (Lore #9) — the format doc is the whole contract, base64 token
// included.
//
// THE MODEL is content-addressed exactly as the wire format is (§19 §2): the
// distinct decoded images live in one by-hash set (Asset_Image keyed by HASH),
// and each atlas references its image by hash, so a blob shared by two atlases is
// held ONCE. `(atlas-name, cell-name) → (image pixels, pixel rect)` resolves
// through asset_region: find the atlas by name, its image by hash, the cell's rect
// by region name — the resolution the textured renderer blits a sprite from.
//
// THE BASE64 SEAM is the load-bearing reconcile: funpack encodes the canonical
// RGBA8 buffer with core:encoding/base64 (ENC_TABLE, std-alphabet RFC-4648); the
// runtime decodes the same token with the SAME core package (DEC_TABLE) — the
// Odin-first policy applied to both sides of the §29 seam, so the decode
// round-trips the encode byte-for-byte. The decoded buffer is GATED against the
// record's declared W·H·4 length: a truncated token, a corrupt alphabet byte, or a
// dimension that disagrees with the pixels is a fail-closed refusal, never a
// best-effort partial image (the §1, §29 exact-match discipline the loader shares).
//
// Determinism: the load is a pure function of the bytes — base64 is a pure
// ASCII→byte map, the image set is slice-order over the section (never map order),
// so two loads of one artifact yield bit-identical Asset_Sets (the tilemap.odin /
// nav.odin invariant).
package funpack_runtime

import "core:encoding/base64"
import "core:strconv"
import "core:strings"

// Asset_Image is one distinct decoded image (§19): its §2 content hash (the dedup
// key an atlas references), the decoded pixel dimensions, and the canonical RGBA8
// buffer (width*height*4 bytes, row-major top-to-bottom — import_image's
// `.alpha_add_if_missing` output the emitter base64-encoded). The runtime owns the
// decoded `pixels` (the loader's allocator); the buffer outlives the artifact
// bytes it was decoded from.
Asset_Image :: struct {
	hash:   string,
	width:  int,
	height: int,
	pixels: []byte, // RGBA8, width*height*4 bytes, row-major top-to-bottom
}

// Asset_Region is one atlas cell's pixel rectangle into its image — the §19
// grid-coord×cell-size lowering (px_x = cell.x*grid_w, px_y = cell.y*grid_h,
// px_w = grid_w, px_h = grid_h). `name` is the cell name a sprite draw addresses;
// the rect is the window the textured renderer blits from the image.
Asset_Region :: struct {
	name:  string,
	px_x:  int,
	px_y:  int,
	px_w:  int,
	px_h:  int,
}

// Asset_Atlas is one registered atlas (§19): its registered name (the token a
// `Draw_Sprite{atlas, cell}` carries), the HASH of the image it slices (the dedup
// reference into Asset_Set.images), and its cell regions in source-declaration
// order — the pixel rects a sprite draw resolves through.
Asset_Atlas :: struct {
	name:       string,
	image_hash: string,
	regions:    []Asset_Region,
}

// Asset_Set is the whole decoded [assets] section (§19): the distinct images
// (content-addressed, so a shared image appears once) and the atlases that slice
// them. An asset-less game decodes to the empty set (the `[assets 0]` tail). The
// [assets] top-level record count is len(images) + len(atlases) — a `region` line
// is a sub-record riding inside its atlas, so the lead-line discipline reconciles
// the count.
Asset_Set :: struct {
	images:  []Asset_Image,
	atlases: []Asset_Atlas,
}

// program_atlas finds a decoded atlas by its registered name, or nil — the
// bare-name lookup a `Draw_Sprite{atlas, cell}` resolves its atlas through
// (mirroring program_tilemap / program_nav / program_function). Assets are
// bake-static, so there is no version_atlas twin: a sprite draw reads the
// Program's pristine decode directly.
program_atlas :: proc(program: ^Program, name: string) -> ^Asset_Atlas {
	for &atlas in program.assets.atlases {
		if atlas.name == name {
			return &atlas
		}
	}
	return nil
}

// program_image finds a decoded image by its content hash, or nil — the
// hash-keyed lookup an atlas resolves its pixels through (the §19 §2
// content-address dedup, so the blob is found once regardless of how many atlases
// reference it).
program_image :: proc(program: ^Program, hash: string) -> ^Asset_Image {
	for &image in program.assets.images {
		if image.hash == hash {
			return &image
		}
	}
	return nil
}

// asset_region resolves `(atlas-name, cell-name) → (image, pixel rect)` — the
// §19 §1 resolution the textured renderer blits a `Draw_Sprite{atlas, cell}` from:
// find the atlas by name, its image by the atlas's image hash, the cell's rect by
// region name. ok=false when the atlas, its image, or the named cell is absent —
// the caller fails closed (an unknown sprite draws nothing), never a guessed rect.
asset_region :: proc(
	program: ^Program,
	atlas_name: string,
	cell_name: string,
) -> (
	image: ^Asset_Image,
	region: Asset_Region,
	ok: bool,
) {
	atlas := program_atlas(program, atlas_name)
	if atlas == nil {
		return nil, {}, false
	}
	img := program_image(program, atlas.image_hash)
	if img == nil {
		return nil, {}, false
	}
	for r in atlas.regions {
		if r.name == cell_name {
			return img, r, true
		}
	}
	return nil, {}, false
}

// atlas_cell_dims derives an atlas's uniform grid cell size (cell_w, cell_h) from
// its regions — the §19 atlas is a uniform grid (px rects are cell_x×cell_w,
// cell_y×cell_h), so every region's px_w/px_h IS the cell dimension. The textured
// TILE resolution needs this: a tile addresses its art by atlas-cell COORDINATE
// (cell_x, cell_y), not by region NAME, so its pixel rect is the coordinate × the
// cell dims — and the cell dims come from any region (they are uniform across the
// grid). ok=false when the atlas has ZERO regions (no region to read the cell dims
// from): a deliberate fail-closed refusal, NEVER a guessed cell size. Every
// TEXTURED atlas the bake emits has regions (a sprite/tile atlas slices a grid), so
// a zero-region atlas reaching here is a degenerate/empty atlas — the textured tile
// pass fails its resolution closed, the same no-texture fallback a missing atlas
// takes.
atlas_cell_dims :: proc(atlas: ^Asset_Atlas) -> (cell_w: int, cell_h: int, ok: bool) {
	if atlas == nil || len(atlas.regions) == 0 {
		return 0, 0, false
	}
	// Any region's px_w/px_h is the uniform grid cell size (the §19 grid lowering:
	// px_w = grid_w, px_h = grid_h for every cell). The first region suffices.
	r := atlas.regions[0]
	return r.px_w, r.px_h, true
}

// tile_cell_rect resolves a TILE's atlas-cell COORDINATE `(cell_x, cell_y)` to its
// pixel rect into the atlas's image — the §17/§19 textured-tile resolution, the
// coordinate twin of asset_region's by-NAME sprite resolution. A tile addresses its
// art by grid coordinate (the §18 §2 tileset cell), so its rect is `(cell_x*cell_w,
// cell_y*cell_h, cell_w, cell_h)` where the cell dims come from atlas_cell_dims (any
// region — the grid is uniform). ok=false when the atlas, its image, or the cell
// dims are absent — the textured tile pass fails closed (no texture), never a
// guessed rect. The image is returned for the present pass's pixel load (the same
// content-addressed dedup a sprite resolves through).
tile_cell_rect :: proc(
	program: ^Program,
	atlas_name: string,
	cell_x: int,
	cell_y: int,
) -> (
	image: ^Asset_Image,
	region: Asset_Region,
	ok: bool,
) {
	atlas := program_atlas(program, atlas_name)
	if atlas == nil {
		return nil, {}, false
	}
	img := program_image(program, atlas.image_hash)
	if img == nil {
		return nil, {}, false
	}
	cell_w, cell_h, dims_ok := atlas_cell_dims(atlas)
	if !dims_ok {
		return nil, {}, false
	}
	return img, Asset_Region {
			px_x = cell_x * cell_w,
			px_y = cell_y * cell_h,
			px_w = cell_w,
			px_h = cell_h,
		}, true
}

// asset_sets_equal compares two decoded sets structurally — the loader
// determinism assertion (same artifact ⇒ same assets). Images compare by hash,
// dims, and pixel bytes; atlases by name, image hash, and region rects, all in
// slice order (the section's emission order, so the order is part of the
// equality).
asset_sets_equal :: proc(a, b: Asset_Set) -> bool {
	if len(a.images) != len(b.images) || len(a.atlases) != len(b.atlases) {
		return false
	}
	for image, i in a.images {
		other := b.images[i]
		if image.hash != other.hash ||
		   image.width != other.width ||
		   image.height != other.height ||
		   len(image.pixels) != len(other.pixels) {
			return false
		}
		for px, j in image.pixels {
			if px != other.pixels[j] {
				return false
			}
		}
	}
	for atlas, i in a.atlases {
		other := b.atlases[i]
		if atlas.name != other.name ||
		   atlas.image_hash != other.image_hash ||
		   len(atlas.regions) != len(other.regions) {
			return false
		}
		for region, j in atlas.regions {
			if region != other.regions[j] {
				return false
			}
		}
	}
	return true
}

// --- The §19 [assets] load (zero funpack imports) --------------------------

// load_assets reads each §19 [assets] record: the two top-level kinds (`image`,
// `atlas`) discriminated by the lead-line keyword, plus the `atlas` record's
// `region` sub-records shaped by its declared CELL_COUNT. An `image` record's
// `b64:RGBA` token is decoded back to the canonical RGBA8 buffer through
// core:encoding/base64 (the same package funpack encoded with) and GATED against
// the declared W·H·4 length — a truncated/corrupt token or a dimension mismatch is
// a fail-closed refusal, never a partial image. An asset-less section ([assets 0])
// yields the empty set. The image set is content-addressed: the wire format dedups
// by hash, so the decoded set holds each blob once (the emitter never repeats a
// shared image).
load_assets :: proc(
	section: Artifact_Section,
	allocator := context.allocator,
) -> (
	assets: Asset_Set,
	err: Artifact_Error,
) {
	images := make([dynamic]Asset_Image, 0, len(section.records), allocator)
	atlases := make([dynamic]Asset_Atlas, 0, len(section.records), allocator)
	for rec in section.records {
		switch line_keyword(rec.lead) {
		case "image":
			image := load_asset_image(rec, allocator) or_return
			append(&images, image)
		case "atlas":
			atlas := load_asset_atlas(rec, allocator) or_return
			append(&atlases, atlas)
		case:
			// An [assets] lead line that is neither `image` nor `atlas` is an
			// unknown record kind — a schema mismatch, refused (never a best-effort
			// skip; the closed two-kind set is the contract, §19).
			return {}, .Bad_Field
		}
	}
	return Asset_Set{images = images[:], atlases = atlases[:]}, .None
}

// load_asset_image decodes one `image HASH W H b64:RGBA` record (§19). The
// dimensions are decimal Int (§2.2); the `b64:RGBA` field is `b64:` immediately
// followed by the base64 token as one space-free ASCII token (record_fields
// splits it whole). The token decodes through base64.decode (DEC_TABLE — the std
// alphabet funpack's ENC_TABLE encode produced), and the recovered buffer must be
// exactly W·H·4 bytes — a corrupt token, a wrong dimension, or a content-address
// drift fails the load closed. An `image` record carries no sub-records.
load_asset_image :: proc(
	rec: Artifact_Record,
	allocator := context.allocator,
) -> (
	image: Asset_Image,
	err: Artifact_Error,
) {
	f := record_fields(rec)
	// image HASH W H b64:RGBA
	if len(f) != 5 || f[0] != "image" {
		return {}, .Bad_Field
	}
	width, w_ok := strconv.parse_int(f[2])
	height, h_ok := strconv.parse_int(f[3])
	if !w_ok || !h_ok || width <= 0 || height <= 0 {
		return {}, .Bad_Field
	}
	if !strings.has_prefix(f[4], "b64:") {
		return {}, .Bad_Field
	}
	encoded := strings.trim_prefix(f[4], "b64:")
	// Decode through the SAME core pkg funpack encoded with (Odin-first, both
	// sides of the §29 seam) — base64 is a pure byte↔ASCII map, so the decode
	// round-trips the encode exactly.
	decoded, decode_err := base64.decode(encoded, base64.DEC_TABLE, allocator)
	if decode_err != nil {
		return {}, .Bad_Field
	}
	// The canonical RGBA8 buffer is W·H·4 bytes (§19) — a decode that does not
	// match the declared dims is a truncated/corrupt token or a tampered record,
	// fail-closed (the exact-match floor, never a partial image the renderer would
	// blit garbage from).
	if len(decoded) != width * height * 4 {
		return {}, .Bad_Field
	}
	return Asset_Image {
			hash = strings.clone(f[1], allocator),
			width = width,
			height = height,
			pixels = decoded,
		},
		.None
}

// load_asset_atlas decodes one `atlas NAME IMAGE_HASH CELL_COUNT` record plus its
// CELL_COUNT `region NAME PX_X PX_Y PX_W PX_H` sub-records (§19). The sub-record
// run must split exactly into CELL_COUNT region lines — an under- or over-shaped
// record is refused (the count-driven discipline the section molds share). Each
// region's rect is decimal Int (§2.2); a malformed region line fails closed.
load_asset_atlas :: proc(
	rec: Artifact_Record,
	allocator := context.allocator,
) -> (
	atlas: Asset_Atlas,
	err: Artifact_Error,
) {
	f := record_fields(rec)
	// atlas NAME IMAGE_HASH CELL_COUNT
	if len(f) != 4 || f[0] != "atlas" {
		return {}, .Bad_Field
	}
	cell_count, cc_ok := strconv.parse_int(f[3])
	if !cc_ok || cell_count < 0 || cell_count != len(rec.subs) {
		return {}, .Bad_Field
	}
	regions := make([]Asset_Region, cell_count, allocator)
	for sub, i in rec.subs {
		region := load_asset_region(sub, allocator) or_return
		regions[i] = region
	}
	return Asset_Atlas {
			name = strings.clone(f[1], allocator),
			image_hash = strings.clone(f[2], allocator),
			regions = regions,
		},
		.None
}

// load_asset_region decodes one `region NAME PX_X PX_Y PX_W PX_H` sub-record
// (§19): the cell name and its four decimal-Int pixel-rect fields. A wrong arity,
// a non-`region` keyword, or a non-integer rect field is a fail-closed refusal.
load_asset_region :: proc(
	sub: string,
	allocator := context.allocator,
) -> (
	region: Asset_Region,
	err: Artifact_Error,
) {
	sf := strings.fields(sub, context.temp_allocator)
	// region NAME PX_X PX_Y PX_W PX_H
	if len(sf) != 6 || sf[0] != "region" {
		return {}, .Bad_Field
	}
	px_x, x_ok := strconv.parse_int(sf[2])
	px_y, y_ok := strconv.parse_int(sf[3])
	px_w, w_ok := strconv.parse_int(sf[4])
	px_h, h_ok := strconv.parse_int(sf[5])
	if !x_ok || !y_ok || !w_ok || !h_ok {
		return {}, .Bad_Field
	}
	return Asset_Region {
			name = strings.clone(sf[1], allocator),
			px_x = px_x,
			px_y = px_y,
			px_w = px_w,
			px_h = px_h,
		},
		.None
}
