package funpack

import "core:os"
import "core:path/filepath"
import "core:strings"

Baked_Asset :: struct {
	name:             string,
	kind:             Asset_Kind,
	source:           string,
	importer_version: string,
	deps:             []string,
	hash:             string,
	out:              string,
}

Baked_Manifest :: struct {
	assets: []Baked_Asset,
}

Asset_Bake_Error :: enum {
	None,
	Missing_Manifest,
	Malformed_Manifest,
	Missing_Source,
	Malformed_Source,
	Missing_Image,
	Malformed_Image,
	Stale_Manifest,
}

ASSET_MANIFEST_LEAF :: "assets.manifest"

asset_manifest_path :: proc(root: string, allocator := context.allocator) -> string {
	path, _ := filepath.join({root, "assets", ASSET_MANIFEST_LEAF}, allocator)
	return path
}

bake_asset_manifest :: proc(root: string, allocator := context.allocator) -> (baked: Baked_Manifest, err: Asset_Bake_Error, detail: string) {
	manifest_path := asset_manifest_path(root, context.temp_allocator)
	manifest_bytes, read_err := os.read_entire_file_from_path(manifest_path, context.temp_allocator)
	if read_err != nil {
		return Baked_Manifest{}, .Missing_Manifest, manifest_path
	}
	manifest, manifest_err := read_asset_manifest(string(manifest_bytes))
	if manifest_err != .None {
		return Baked_Manifest{}, .Malformed_Manifest, manifest_path
	}

	resolved := make([dynamic]Baked_Asset, 0, len(manifest.entries) + 2, allocator)

	for entry in manifest.entries {
		if entry.kind == .Image {
			image_asset, image_err, image_detail := bake_resolve_image(root, entry.source, allocator)
			if image_err != .None {
				return Baked_Manifest{}, image_err, image_detail
			}
			append(&resolved, baked_image_node(entry.name, entry.source, image_asset.hash, allocator))
			continue
		}

		source_path, _ := filepath.join({root, "assets", entry.source}, context.temp_allocator)
		source_bytes, source_err := os.read_entire_file_from_path(source_path, context.temp_allocator)
		if source_err != nil {
			return Baked_Manifest{}, .Missing_Source, source_path
		}

		switch entry.kind {
		case .Model:
			model, e := import_model(string(source_bytes), context.temp_allocator)
			if e != .None {
				return Baked_Manifest{}, .Malformed_Source, source_path
			}
			append(&resolved, baked_node(entry.name, .Model, entry.source, MODEL_IMPORTER_VERSION, nil, model.hash, allocator))
		case .Audio:
			audio, e := import_audio(source_bytes, context.temp_allocator)
			if e != .None {
				return Baked_Manifest{}, .Malformed_Source, source_path
			}
			append(&resolved, baked_node(entry.name, .Audio, entry.source, AUDIO_IMPORTER_VERSION, nil, audio.hash, allocator))
		case .Atlas:
			atlas_image, image_node, atlas_err, atlas_detail := bake_resolve_atlas(root, entry.name, string(source_bytes), allocator)
			if atlas_err != .None {
				return Baked_Manifest{}, atlas_err, atlas_detail
			}
			bake_append_image_node(&resolved, image_node)
			append(&resolved, baked_node(entry.name, .Atlas, entry.source, ATLAS_IMPORTER_VERSION, []string{atlas_image.image_dep}, atlas_image.hash, allocator))
		case .Tileset:
			tileset_asset, tileset_err, tileset_detail := bake_resolve_tileset(resolved[:], entry.name, string(source_bytes), allocator)
			if tileset_err != .None {
				return Baked_Manifest{}, tileset_err, tileset_detail
			}
			append(&resolved, baked_node(entry.name, .Tileset, entry.source, TILES_IMPORTER_VERSION, tileset_asset.deps, tileset_asset.hash, allocator))
		case .Image:
			unreachable()
		}
	}

	return Baked_Manifest{assets = resolved[:]}, .None, ""
}

bake_resolve_image :: proc(root: string, source: string, allocator := context.allocator) -> (asset: Image_Asset, err: Asset_Bake_Error, detail: string) {
	image_path, _ := filepath.join({root, "assets", source}, context.temp_allocator)
	image_bytes, read_err := os.read_entire_file_from_path(image_path, context.temp_allocator)
	if read_err != nil {
		return Image_Asset{}, .Missing_Image, image_path
	}
	imported, import_err := import_image(image_bytes, allocator)
	if import_err != .None {
		return Image_Asset{}, .Malformed_Image, image_path
	}
	imported.pixels = nil
	return imported, .None, ""
}

bake_resolve_atlas :: proc(root: string, atlas_name: string, src: string, allocator := context.allocator) -> (atlas: Atlas_Asset, image_node: Baked_Asset, err: Asset_Bake_Error, detail: string) {
	p := Atlas_Parser{tokens = lex_atlas(src)}
	parsed, parse_err := atlas_parse(&p)
	if parse_err != .None {
		return Atlas_Asset{}, Baked_Asset{}, .Malformed_Source, atlas_name
	}
	image_source := parsed.image

	image_asset, image_err, image_detail := bake_resolve_image(root, image_source, allocator)
	if image_err != .None {
		return Atlas_Asset{}, Baked_Asset{}, image_err, image_detail
	}

	image_dep := asset_dep_string(image_source, image_asset.hash, allocator)
	imported_atlas, atlas_import_err := import_atlas(src, []string{image_dep}, allocator)
	if atlas_import_err != .None {
		return Atlas_Asset{}, Baked_Asset{}, .Malformed_Source, atlas_name
	}

	node := baked_image_node(image_source, image_source, image_asset.hash, allocator)
	return imported_atlas, node, .None, ""
}

bake_resolve_tileset :: proc(resolved: []Baked_Asset, tileset_name: string, src: string, allocator := context.allocator) -> (out: Baked_Asset, err: Asset_Bake_Error, detail: string) {
	p := Tiles_Parser{tokens = lex_tiles(src)}
	parsed, parse_err := tiles_parse(&p)
	if parse_err != .None {
		return Baked_Asset{}, .Malformed_Source, tileset_name
	}
	atlas_name := parsed.atlas

	atlas_node, found := bake_find_node(resolved, atlas_name)
	if !found || atlas_node.kind != .Atlas {
		return Baked_Asset{}, .Malformed_Source, tileset_name
	}

	atlas_dep := asset_dep_string(atlas_name, atlas_node.hash, allocator)
	imported_tileset, tileset_err := import_tileset(src, []string{atlas_dep}, allocator)
	if tileset_err != .None {
		return Baked_Asset{}, .Malformed_Source, tileset_name
	}

	return baked_node(tileset_name, .Tileset, "", TILES_IMPORTER_VERSION, []string{atlas_dep}, imported_tileset.hash, allocator), .None, ""
}

bake_find_node :: proc(resolved: []Baked_Asset, name: string) -> (node: Baked_Asset, found: bool) {
	for candidate in resolved {
		if candidate.name == name {
			return candidate, true
		}
	}
	return Baked_Asset{}, false
}

bake_append_image_node :: proc(resolved: ^[dynamic]Baked_Asset, node: Baked_Asset) {
	for existing in resolved {
		if existing.name == node.name {
			return
		}
	}
	append(resolved, node)
}

baked_image_node :: proc(name: string, source: string, hash: string, allocator := context.allocator) -> Baked_Asset {
	return baked_node(name, .Image, source, IMAGE_IMPORTER_VERSION, nil, hash, allocator)
}

baked_node :: proc(name: string, kind: Asset_Kind, source: string, importer_version: string, deps: []string, hash: string, allocator := context.allocator) -> Baked_Asset {
	cloned_deps := make([]string, len(deps), allocator)
	for dep, i in deps {
		cloned_deps[i] = strings.clone(dep, allocator)
	}
	return Baked_Asset {
		name             = strings.clone(name, allocator),
		kind             = kind,
		source           = strings.clone(source, allocator),
		importer_version = strings.clone(importer_version, allocator),
		deps             = cloned_deps,
		hash             = strings.clone(hash, allocator),
		out              = asset_out_path(kind, source, hash, allocator),
	}
}

asset_dep_string :: proc(name: string, hash: string, allocator := context.allocator) -> string {
	return strings.concatenate({name, "@", hash}, allocator)
}

asset_out_path :: proc(kind: Asset_Kind, source: string, hash: string, allocator := context.allocator) -> string {
	hex := asset_hash_hex(hash)
	shard := hex
	rest := ""
	if len(hex) >= 2 {
		shard = hex[:2]
		rest = hex[2:]
	}
	leaf := asset_out_leaf(kind, source, allocator)
	path, _ := filepath.join({".cache", shard, rest, leaf}, allocator)
	return path
}

asset_hash_hex :: proc(hash: string) -> string {
	if strings.has_prefix(hash, HASH_PREFIX) {
		return hash[len(HASH_PREFIX):]
	}
	return hash
}

asset_out_leaf :: proc(kind: Asset_Kind, source: string, allocator := context.allocator) -> string {
	stem := source
	if dot := strings.last_index_byte(source, '.'); dot >= 0 {
		stem = source[:dot]
	}
	switch kind {
	case .Model:
		return strings.concatenate({stem, ".mesh"}, allocator)
	case .Audio:
		return strings.concatenate({stem, ".pcm"}, allocator)
	case .Image:
		return strings.concatenate({stem, ".tex"}, allocator)
	case .Atlas:
		return strings.clone(source, allocator)
	case .Tileset:
		return strings.clone(source, allocator)
	}
	return strings.clone(source, allocator)
}

baked_to_manifest :: proc(baked: Baked_Manifest, allocator := context.allocator) -> Asset_Manifest {
	entries := make([]Asset_Entry, len(baked.assets), allocator)
	for asset, i in baked.assets {
		entries[i] = Asset_Entry {
			name             = asset.name,
			kind             = asset.kind,
			source           = asset.source,
			importer_version = asset.importer_version,
			deps             = asset.deps,
			hash             = asset.hash,
			out              = asset.out,
		}
	}
	return Asset_Manifest{entries = entries}
}

bake_tileset_assets :: proc(root: string, baked: Baked_Manifest, allocator := context.allocator) -> (tilesets: []Tileset_Asset, ok: bool) {
	out := make([dynamic]Tileset_Asset, 0, 2, allocator)
	for asset in baked.assets {
		if asset.kind != .Tileset {
			continue
		}
		source_path, _ := filepath.join({root, "assets", asset.source}, context.temp_allocator)
		source_bytes, read_err := os.read_entire_file_from_path(source_path, context.temp_allocator)
		if read_err != nil {
			return nil, false
		}
		tileset, import_err := import_tileset(string(source_bytes), asset.deps, context.temp_allocator)
		if import_err != .None {
			return nil, false
		}
		append(&out, tileset)
	}
	return out[:], true
}

ASSET_MANIFEST_HEADER :: "# assets.manifest — GENERATED by the bake. The committed name -> content-hash -> output index,\n# and the source of truth for handle resolution. Diffable; never hand-edited.\n# hash = H(source bytes + importer version + dependency hashes). Same inputs -> same hash, anywhere.\n"

emit_asset_manifest :: proc(baked: Baked_Manifest, allocator := context.allocator) -> string {
	b := strings.builder_make(allocator)
	strings.write_string(&b, ASSET_MANIFEST_HEADER)
	for asset in baked.assets {
		strings.write_string(&b, "\n")
		emit_manifest_block(&b, asset)
	}
	return strings.to_string(b)
}

emit_manifest_block :: proc(b: ^strings.Builder, asset: Baked_Asset) {
	strings.write_string(b, "[")
	strings.write_string(b, asset.name)
	strings.write_string(b, "]\n")
	emit_manifest_word(b, "kind", asset_kind_word(asset.kind))
	emit_manifest_quoted(b, "source", asset.source)
	emit_manifest_quoted(b, "importer", asset.importer_version)
	emit_manifest_deps(b, asset.deps)
	emit_manifest_quoted(b, "hash", asset.hash)
	emit_manifest_quoted(b, "out", asset.out)
}

MANIFEST_KEY_WIDTH :: 8

emit_manifest_word :: proc(b: ^strings.Builder, key: string, value: string) {
	emit_manifest_key(b, key)
	strings.write_string(b, value)
	strings.write_string(b, "\n")
}

emit_manifest_quoted :: proc(b: ^strings.Builder, key: string, value: string) {
	emit_manifest_key(b, key)
	strings.write_string(b, "\"")
	strings.write_string(b, value)
	strings.write_string(b, "\"\n")
}

emit_manifest_deps :: proc(b: ^strings.Builder, deps: []string) {
	emit_manifest_key(b, "deps")
	if len(deps) == 0 {
		strings.write_string(b, "[]\n")
		return
	}
	strings.write_string(b, "[")
	for dep, i in deps {
		if i > 0 {
			strings.write_string(b, ", ")
		}
		strings.write_string(b, "\"")
		strings.write_string(b, dep)
		strings.write_string(b, "\"")
	}
	strings.write_string(b, "]\n")
}

emit_manifest_key :: proc(b: ^strings.Builder, key: string) {
	strings.write_string(b, key)
	for _ in len(key) ..< MANIFEST_KEY_WIDTH {
		strings.write_string(b, " ")
	}
	strings.write_string(b, " = ")
}

asset_kind_word :: proc(kind: Asset_Kind) -> string {
	switch kind {
	case .Model:
		return "model"
	case .Atlas:
		return "atlas"
	case .Audio:
		return "audio"
	case .Tileset:
		return "tileset"
	case .Image:
		return "image"
	}
	return ""
}

bake_manifest_staleness :: proc(root: string, emitted: string) -> (err: Asset_Bake_Error, detail: string) {
	manifest_path := asset_manifest_path(root, context.temp_allocator)
	committed_bytes, read_err := os.read_entire_file_from_path(manifest_path, context.temp_allocator)
	if read_err != nil {
		return .Missing_Manifest, manifest_path
	}
	if string(committed_bytes) != emitted {
		return .Stale_Manifest, manifest_path
	}
	return .None, ""
}

write_asset_manifest :: proc(root: string, emitted: string) -> bool {
	manifest_path := asset_manifest_path(root, context.temp_allocator)
	return os.write_entire_file(manifest_path, transmute([]u8)emitted) == nil
}

asset_tree_has_manifest :: proc(root: string) -> bool {
	return os.exists(asset_manifest_path(root, context.temp_allocator))
}
