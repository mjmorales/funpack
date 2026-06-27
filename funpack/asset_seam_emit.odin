package funpack

import "core:strings"

ASSETS_SEAM_MODULE_DOC :: "Generated typed asset handles, baked from assets.manifest — edit the source, not this file; a rename propagates as a compile error in every reader. Module name is the seam's logical name, assets."

ASSETS_SEAM_GTAG :: "assets"

asset_handle_type :: proc(kind: Asset_Kind) -> string {
	switch kind {
	case .Model:
		return "MeshHandle"
	case .Atlas:
		return "AtlasHandle"
	case .Audio:
		return "SoundHandle"
	case .Tileset:
		return "TilesetHandle"
	case .Image:
		return "TextureHandle"
	}
	return ""
}

asset_handle_module :: proc(kind: Asset_Kind) -> string {
	switch kind {
	case .Model, .Atlas, .Audio, .Image:
		return "engine.assets"
	case .Tileset:
		return "engine.tilemap"
	}
	return ""
}

emit_assets_gen_fun :: proc(manifest: Asset_Manifest, docs: []string, allocator := context.allocator) -> string {
	b := strings.builder_make(allocator)

	emit_seam_doc(&b, ASSETS_SEAM_MODULE_DOC)
	strings.write_string(&b, "\n")

	emit_assets_import(&b, manifest)

	emitted := 0
	for entry in manifest.entries {
		if !asset_emits_handle(entry.kind) {
			continue
		}
		strings.write_string(&b, "\n")
		doc := emitted < len(docs) ? docs[emitted] : ""
		emit_asset_handle(&b, entry, doc)
		emitted += 1
	}
	return strings.to_string(b)
}

asset_emits_handle :: proc(kind: Asset_Kind) -> bool {
	return kind != .Image
}

emit_assets_import :: proc(b: ^strings.Builder, manifest: Asset_Manifest) {
	modules := assets_used_handle_modules(manifest, context.temp_allocator)
	for module in modules {
		types := assets_used_handle_types(manifest, module, context.temp_allocator)
		strings.write_string(b, "import ")
		strings.write_string(b, module)
		strings.write_string(b, ".{")
		for type, i in types {
			if i > 0 {
				strings.write_string(b, ", ")
			}
			strings.write_string(b, type)
		}
		strings.write_string(b, "}\n")
	}
}

assets_used_handle_modules :: proc(manifest: Asset_Manifest, allocator := context.allocator) -> []string {
	modules := make([dynamic]string, 0, 2, allocator)
	for entry in manifest.entries {
		if !asset_emits_handle(entry.kind) {
			continue
		}
		module := asset_handle_module(entry.kind)
		if !slice_contains_string(modules[:], module) {
			append(&modules, module)
		}
	}
	return modules[:]
}

assets_used_handle_types :: proc(manifest: Asset_Manifest, module: string, allocator := context.allocator) -> []string {
	types := make([dynamic]string, 0, 3, allocator)
	for entry in manifest.entries {
		if !asset_emits_handle(entry.kind) {
			continue
		}
		if asset_handle_module(entry.kind) != module {
			continue
		}
		type := asset_handle_type(entry.kind)
		if !slice_contains_string(types[:], type) {
			append(&types, type)
		}
	}
	return types[:]
}

emit_asset_handle :: proc(b: ^strings.Builder, entry: Asset_Entry, doc: string) {
	emit_seam_doc(b, doc)
	strings.write_string(b, "@gtag(\"")
	strings.write_string(b, ASSETS_SEAM_GTAG)
	strings.write_string(b, "\")\n")

	type := asset_handle_type(entry.kind)
	strings.write_string(b, "let ")
	strings.write_string(b, entry.name)
	strings.write_string(b, ": ")
	strings.write_string(b, type)
	strings.write_string(b, " = ")
	strings.write_string(b, type)
	strings.write_string(b, "{name: \"")
	strings.write_string(b, entry.name)
	strings.write_string(b, "\"}\n")
}

slice_contains_string :: proc(items: []string, needle: string) -> bool {
	for item in items {
		if item == needle {
			return true
		}
	}
	return false
}
