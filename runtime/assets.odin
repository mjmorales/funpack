package funpack_runtime

import "core:encoding/base64"
import "core:slice"
import "core:strconv"
import "core:strings"

Asset_Image :: struct {
	hash:   string,
	width:  int,
	height: int,
	pixels: []byte,
}

Asset_Region :: struct {
	name:  string,
	px_x:  int,
	px_y:  int,
	px_w:  int,
	px_h:  int,
}

Asset_Atlas :: struct {
	name:       string,
	image_hash: string,
	regions:    []Asset_Region,
}

Asset_Set :: struct {
	images:  []Asset_Image,
	atlases: []Asset_Atlas,
}

program_atlas :: proc(program: ^Program, name: string) -> ^Asset_Atlas {
	for &atlas in program.assets.atlases {
		if atlas.name == name {
			return &atlas
		}
	}
	return nil
}

program_image :: proc(program: ^Program, hash: string) -> ^Asset_Image {
	for &image in program.assets.images {
		if image.hash == hash {
			return &image
		}
	}
	return nil
}

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

atlas_cell_dims :: proc(atlas: ^Asset_Atlas) -> (cell_w: int, cell_h: int, ok: bool) {
	if atlas == nil || len(atlas.regions) == 0 {
		return 0, 0, false
	}
	r := atlas.regions[0]
	return r.px_w, r.px_h, true
}

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
		if !slice.equal(image.pixels, other.pixels) {
			return false
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
			return {}, .Bad_Field
		}
	}
	return Asset_Set{images = images[:], atlases = atlases[:]}, .None
}

load_asset_image :: proc(
	rec: Artifact_Record,
	allocator := context.allocator,
) -> (
	image: Asset_Image,
	err: Artifact_Error,
) {
	f := record_fields(rec)
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
	decoded, decode_err := base64.decode(encoded, base64.DEC_TABLE, allocator)
	if decode_err != nil {
		return {}, .Bad_Field
	}
	if len(decoded) != width * height * 4 {
		delete(decoded, allocator)
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

load_asset_atlas :: proc(
	rec: Artifact_Record,
	allocator := context.allocator,
) -> (
	atlas: Asset_Atlas,
	err: Artifact_Error,
) {
	f := record_fields(rec)
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

load_asset_region :: proc(
	sub: string,
	allocator := context.allocator,
) -> (
	region: Asset_Region,
	err: Artifact_Error,
) {
	sf := strings.fields(sub, context.temp_allocator)
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
