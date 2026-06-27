package funpack

import "core:os"
import "core:path/filepath"
import "core:strings"

bake_tree_assets :: proc(root: string, allocator := context.allocator) -> (assets: Baked_Assets, err: Asset_Bake_Error, detail: string) {
	manifest_path := asset_manifest_path(root, context.temp_allocator)
	manifest_bytes, read_err := os.read_entire_file_from_path(manifest_path, context.temp_allocator)
	if read_err != nil {
		return Baked_Assets{}, .Missing_Manifest, manifest_path
	}
	manifest, manifest_err := read_asset_manifest(string(manifest_bytes))
	if manifest_err != .None {
		return Baked_Assets{}, .Malformed_Manifest, manifest_path
	}

	images := make([dynamic]Baked_Image, 0, len(manifest.entries), allocator)
	atlases := make([dynamic]Baked_Atlas, 0, len(manifest.entries), allocator)

	for entry in manifest.entries {
		if entry.kind != .Atlas {
			continue
		}
		baked_atlas, atlas_err, atlas_detail := bake_atlas_assets(root, entry.name, entry.source, &images, allocator)
		if atlas_err != .None {
			return Baked_Assets{}, atlas_err, atlas_detail
		}
		append(&atlases, baked_atlas)
	}

	return Baked_Assets{images = images[:], atlases = atlases[:]}, .None, ""
}

bake_atlas_assets :: proc(root: string, handle_name: string, atlas_source: string, images: ^[dynamic]Baked_Image, allocator := context.allocator) -> (atlas: Baked_Atlas, err: Asset_Bake_Error, detail: string) {
	atlas_path, _ := filepath.join({root, "assets", atlas_source}, context.temp_allocator)
	atlas_bytes, read_err := os.read_entire_file_from_path(atlas_path, context.temp_allocator)
	if read_err != nil {
		return Baked_Atlas{}, .Missing_Source, atlas_path
	}

	p := Atlas_Parser{tokens = lex_atlas(string(atlas_bytes))}
	parsed, parse_err := atlas_parse(&p)
	if parse_err != .None {
		return Baked_Atlas{}, .Malformed_Source, atlas_path
	}

	image, image_err, image_detail := bake_resolve_image_pixels(root, parsed.image, allocator)
	if image_err != .None {
		return Baked_Atlas{}, image_err, image_detail
	}
	bake_dedup_image(images, image, allocator)

	regions := make([]Baked_Region, len(parsed.cells), allocator)
	for cell, i in parsed.cells {
		regions[i] = Baked_Region {
			name = strings.clone(cell.name, allocator),
			px_x = int(cell.x * parsed.grid_w),
			px_y = int(cell.y * parsed.grid_h),
			px_w = int(parsed.grid_w),
			px_h = int(parsed.grid_h),
		}
	}

	return Baked_Atlas {
			name = strings.clone(handle_name, allocator),
			image_hash = image.hash,
			regions = regions,
		},
		.None,
		""
}

bake_resolve_image_pixels :: proc(root: string, source: string, allocator := context.allocator) -> (image: Baked_Image, err: Asset_Bake_Error, detail: string) {
	image_path, _ := filepath.join({root, "assets", source}, context.temp_allocator)
	image_bytes, read_err := os.read_entire_file_from_path(image_path, context.temp_allocator)
	if read_err != nil {
		return Baked_Image{}, .Missing_Image, image_path
	}
	imported, import_err := import_image(image_bytes, allocator)
	if import_err != .None {
		return Baked_Image{}, .Malformed_Image, image_path
	}
	result := Baked_Image {
		hash   = imported.hash,
		width  = imported.width,
		height = imported.height,
		pixels = imported.pixels,
	}
	return result, .None, ""
}

bake_dedup_image :: proc(
	images: ^[dynamic]Baked_Image,
	image: Baked_Image,
	allocator := context.allocator,
) {
	for existing in images {
		if existing.hash == image.hash {
			delete(image.pixels, allocator)
			return
		}
	}
	append(images, image)
}
