// The §19 [assets]-section bake: the seam that turns the asset SOURCE tree into
// the Baked_Assets model the v16 [assets] section serializes — the decoded,
// content-addressed image pixels and the atlas slice rects a textured
// `Draw_Sprite{atlas, cell}` resolves against (docs/artifact-format.md §19,
// schema v16).
//
// This is the emit-side twin of bake_asset_manifest (asset_bake.odin): that bake
// resolves every node's HASH for the committed manifest and DROPS the decoded
// pixels (a hash is all the manifest needs); this bake instead PRESERVES the
// pixels and the atlas grid metadata, because the artifact carries them. The two
// run over the same source tree off the same importers, so the image hash an
// [assets] record is keyed by is byte-identical to the manifest's — the same PNG
// bytes always hash the same.
//
// THE DEDUP (§19 §2 content-addressing): two atlases referencing one image hold
// the RGBA blob ONCE, keyed by the image content hash. The walk discovers each
// atlas's image, decodes it, and registers it in a by-hash dedup set; an atlas
// already-seen image contributes no second blob. The atlas record then references
// the image by hash, so (atlas-name, cell-name) → (image pixels, pixel rect) is
// resolvable from the artifact with no pixel duplication.
//
// PURITY (§29): the bake reads only source bytes off the §14 tree and decodes them
// through the deterministic import_image — no clock, no machine path, no float in a
// pixel. Two bakes of the same tree produce byte-identical Baked_Assets, so the
// emitted [assets] section is byte-identical anywhere.
package funpack

import "core:os"
import "core:path/filepath"
import "core:strings"

// bake_tree_assets builds the §19 [assets] emit model from the §14 tree's atlas
// assets: each atlas's image is decoded (pixels preserved, unlike the manifest
// bake) and content-addressed, then sliced into per-cell pixel rects from its grid
// metadata. The committed manifest supplies the closed atlas registry (the same
// source of truth bake_asset_manifest reads); this walk imports each atlas's image
// for its pixels and parses each atlas for its grid + cells. The image set is
// deduped by content hash — two atlases sharing one image hold one Baked_Image —
// so the artifact carries each blob once. ok = false (fail-closed, naming the
// offending asset in detail) on any unreadable source, a missing image, or an
// importer reject — the same floors bake_asset_manifest enforces. A tree with no
// manifest yields an empty Baked_Assets (the `[assets 0]` tail); the caller gates
// on asset_tree_has_manifest, so this is reached only when assets exist.
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
		// Only atlases carry sliced pixel art the [assets] section serializes. A
		// raw `image` manifest entry with no atlas slicing it is not drawn by a
		// `Draw_Sprite{atlas, cell}`, so the [assets] section is atlas-rooted: the
		// images it carries are exactly the ones an atlas references (the dedup set
		// is built from the atlas walk, never from standalone image entries).
		if entry.kind != .Atlas {
			continue
		}
		baked_atlas, atlas_err, atlas_detail := bake_atlas_assets(root, entry.source, &images, allocator)
		if atlas_err != .None {
			return Baked_Assets{}, atlas_err, atlas_detail
		}
		append(&atlases, baked_atlas)
	}

	return Baked_Assets{images = images[:], atlases = atlases[:]}, .None, ""
}

// bake_atlas_assets resolves one atlas into its Baked_Atlas record and registers
// its (deduped) image in the shared image set. It reads the atlas source, parses
// its grid + cells, decodes its `image "X.png"` dependency to RGBA8 pixels through
// import_image, and lowers each cell's grid coordinate to a pixel rect
// (px_x = cell.x*grid_w, px_y = cell.y*grid_h, px_w = grid_w, px_h = grid_h). The
// image is appended to `images` only when its hash is not already registered (the
// §19 §2 content-address dedup), so a second atlas sharing the image adds no blob.
// The atlas record references the image by that hash. fail-closed on an unreadable
// atlas/image source or an importer reject, naming the offending file.
bake_atlas_assets :: proc(root: string, atlas_source: string, images: ^[dynamic]Baked_Image, allocator := context.allocator) -> (atlas: Baked_Atlas, err: Asset_Bake_Error, detail: string) {
	atlas_path, _ := filepath.join({root, "assets", atlas_source}, context.temp_allocator)
	atlas_bytes, read_err := os.read_entire_file_from_path(atlas_path, context.temp_allocator)
	if read_err != nil {
		return Baked_Atlas{}, .Missing_Source, atlas_path
	}

	// Parse the atlas for its grid + cells. The same atlas_parse the importer
	// drives, run here for the slice metadata (grid_w/grid_h, the named cells) the
	// region lowering needs — import_atlas itself records only the dep + hash.
	p := Atlas_Parser{tokens = lex_atlas(string(atlas_bytes))}
	parsed, parse_err := atlas_parse(&p)
	if parse_err != .None {
		return Baked_Atlas{}, .Malformed_Source, atlas_path
	}

	// Decode the atlas's image to RGBA8 — the PIXELS this section carries (the
	// manifest bake drops them; here they are the payload). bake_resolve_image_pixels
	// reads the file off disk and decodes it fail-closed; the hash is the content
	// address the dedup keys on and the atlas record references.
	image, image_err, image_detail := bake_resolve_image_pixels(root, parsed.image, allocator)
	if image_err != .None {
		return Baked_Atlas{}, image_err, image_detail
	}
	bake_dedup_image(images, image)

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
			name = strings.clone(parsed.name, allocator),
			image_hash = image.hash,
			regions = regions,
		},
		.None,
		""
}

// bake_resolve_image_pixels reads a raw image off the §14 tree and decodes it to
// the canonical RGBA8 buffer the [assets] section carries — the pixel-PRESERVING
// twin of bake_resolve_image (asset_bake.odin), which frees the buffer because the
// manifest needs only the hash. A missing file is Missing_Image (fail-closed), a
// non-decodable input Malformed_Image. import_image decodes through the heap
// allocator (it runs png.destroy, which the temp allocator's individual-free gap
// cannot serve); the hash, dims, and pixels are cloned into the caller's allocator
// so the Baked_Image outlives the decode scratch.
bake_resolve_image_pixels :: proc(root: string, source: string, allocator := context.allocator) -> (image: Baked_Image, err: Asset_Bake_Error, detail: string) {
	image_path, _ := filepath.join({root, "assets", source}, context.temp_allocator)
	image_bytes, read_err := os.read_entire_file_from_path(image_path, context.temp_allocator)
	if read_err != nil {
		return Baked_Image{}, .Missing_Image, image_path
	}
	imported, import_err := import_image(image_bytes, context.allocator)
	if import_err != .None {
		return Baked_Image{}, .Malformed_Image, image_path
	}
	// import_image allocated pixels on the heap; clone the buffer + hash into the
	// caller's allocator, then free the decode's heap copy so nothing leaks.
	pixels := make([]byte, len(imported.pixels), allocator)
	copy(pixels, imported.pixels)
	result := Baked_Image {
		hash   = strings.clone(imported.hash, allocator),
		width  = imported.width,
		height = imported.height,
		pixels = pixels,
	}
	delete(imported.pixels)
	return result, .None, ""
}

// bake_dedup_image appends an image to the shared set only when its content hash
// is not already present — the §19 §2 content-address dedup, so two atlases
// sharing one image hold the RGBA blob ONCE. The first registration wins (a later
// one's pixels are byte-identical — the same bytes always decode the same — so the
// dedup is pixel-stable); a hit frees the redundant decode buffer.
bake_dedup_image :: proc(images: ^[dynamic]Baked_Image, image: Baked_Image) {
	for existing in images {
		if existing.hash == image.hash {
			delete(image.pixels)
			return
		}
	}
	append(images, image)
}
