// The §19 §3 typed asset-handle seam emitter: the pure manifest → assets.gen.fun
// source-TEXT serializer. It walks the manifest's closed registry in committed
// order and emits one typed handle constant per registered asset — the
// file-leading @doc, one `import <module>.{…}` line per §26 module owning the
// handle types the assets use (engine.assets; engine.tilemap when a tileset is
// registered — modules and members in first-use order), then per asset a
// @doc-headed, @gtag("assets")-tagged `let NAME: KINDHandle = KINDHandle{name:
// "NAME"}` declaration. The byte target is the committed exemplar
// examples/assets/gen/assets.gen.fun.
//
// DOC SOURCING (the manifest-only signature's one wrinkle): the manifest carries
// the registry truth — the closed name set, each asset's kind, and the canonical
// order — but NOT the per-asset prose @doc strings, which are authored content no
// upstream artifact (manifest reader §2, importers §4) produces. So the per-asset
// docs ride alongside the manifest as a parallel []string the baker supplies, one
// entry per manifest entry in the same order, exactly as the .flvl/arena seam
// hand-carries its declaration docs in the Seam model. The manifest stays the
// load-bearing input (it alone fixes which handles exist and their order); the
// docs are the authored layer over it.
//
// DISTINCT FROM gen_emit.odin's emit_gen_fun: that emitter renders the shared
// `data`/`extern fn` Seam shape the .flvl/arena seam uses (no @gtag, no blank
// after the file doc, no `let` handle constants). The asset seam is a different
// canonical byte shape — handle constants with an @gtag tag and a blank line after
// the file doc — so it is its own emitter, reusing only the shared canonical-text
// discipline (the @doc("…") line form, deterministic slice-order walks, a single
// trailing newline), not the Seam_Decl union.
//
// PURITY (spec §09, §29): emission is a pure function of (manifest, docs). Every
// layout decision is mechanical — the import-member list is the kinds in
// first-use order, the per-asset block is fixed, the walks are slice-order — so
// the emitter reads no clock, no path, no host bytes, and two emissions of the
// same inputs are byte-identical.
package funpack

import "core:strings"

// ASSETS_SEAM_MODULE_DOC is the file-leading @doc of every assets.gen.fun: fixed
// boilerplate independent of which assets are registered, naming the seam's
// logical module (`assets`) and the edit-the-source-not-this-file invariant the
// closed registry enforces. Verbatim from the committed exemplar's line 1,
// em-dash and apostrophe included.
ASSETS_SEAM_MODULE_DOC :: "Generated typed asset handles, baked from assets.manifest — edit the source, not this file; a rename propagates as a compile error in every reader. Module name is the seam's logical name, assets."

// ASSETS_SEAM_GTAG is the registered-tag every asset handle carries: the
// @gtag("assets") line is the P7 closed-registry marker — the seam declares each
// handle under the `assets` tag, the same tag the string constructors check
// against, so a name not in this set resolves to nothing and is a compile error.
ASSETS_SEAM_GTAG :: "assets"

// asset_handle_type maps an Asset_Kind onto its typed handle — the type token
// the `let NAME: KINDHandle` declaration and the import list use. The mapping
// is total over the closed kind set: Model → MeshHandle (a model bakes to a
// mesh), Atlas → AtlasHandle, Audio → SoundHandle, Tileset → TilesetHandle,
// Image → TextureHandle (a raw image bakes to a texture, §19 §1 table). A new
// kind is a deliberate addition here in lockstep with the Asset_Kind enum.
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

// asset_handle_module maps an Asset_Kind onto the §26 stdlib module that OWNS
// its handle type — the module path the seam's import line names. The asset
// sink engine.assets owns the mesh/atlas/sound/texture handles (§26 line 78);
// TilesetHandle is owned by engine.tilemap (§26's tilemap row, §18 §2), so a
// manifest registering a tileset adds a second import line rather than
// smuggling a foreign type into the engine.assets member list (one name, one
// owner — the §26 single-exporter rule). Image's TextureHandle is an
// engine.assets type, so an image rides the existing engine.assets line.
asset_handle_module :: proc(kind: Asset_Kind) -> string {
	switch kind {
	case .Model, .Atlas, .Audio, .Image:
		return "engine.assets"
	case .Tileset:
		return "engine.tilemap"
	}
	return ""
}

// emit_assets_gen_fun renders the manifest's closed registry to canonical
// assets.gen.fun source bytes, byte-matching the committed exemplar. `docs` is the
// parallel per-asset @doc prose, one entry per manifest entry in the same order
// (the manifest carries the registry, the baker carries the authored docs). Layout
// mirrors the exemplar exactly: the file-leading @doc, a blank line, the per-module
// import line block, a blank line, then per asset a @doc line, an
// @gtag("assets") line, the `let NAME: KINDHandle = KINDHandle{name: "NAME"}`
// declaration, and a trailing blank line — so the file ends in exactly one
// newline. The returned string is allocated in `allocator`.
//
// `docs` shorter than the manifest emits an empty doc for the unaligned tail
// (never a crash); the byte-match path always supplies a doc per entry.
emit_assets_gen_fun :: proc(manifest: Asset_Manifest, docs: []string, allocator := context.allocator) -> string {
	b := strings.builder_make(allocator)

	// File-leading @doc, then a blank line before the import (the assets seam
	// offsets its module doc from the imports, unlike the .flvl/arena seam).
	emit_seam_doc(&b, ASSETS_SEAM_MODULE_DOC)
	strings.write_string(&b, "\n")

	// One import line per owning module, each carrying exactly the handle
	// types the registered assets use, in first-use order across the manifest
	// — so an assets file with no atlas would not import AtlasHandle, and one
	// with no tileset emits no engine.tilemap line.
	emit_assets_import(&b, manifest)

	// The doc index counts only the EMITTED entries (handle-bearing kinds), not
	// every manifest entry: an image node carries no handle constant (it is sliced
	// THROUGH its atlas, never named by game code — §19 §1: the atlas's seam is the
	// AtlasHandle, the image has no independent seam), so the per-asset docs the
	// caller supplies align to the handle-bearing entries, not to the registry's
	// image nodes interleaved among them.
	emitted := 0
	for entry in manifest.entries {
		if !asset_emits_handle(entry.kind) {
			continue
		}
		// A blank line before every handle block: the same separator the import
		// gets, so the first handle is offset from the import and every adjacent
		// pair is offset from each other.
		strings.write_string(&b, "\n")
		doc := emitted < len(docs) ? docs[emitted] : ""
		emit_asset_handle(&b, entry, doc)
		emitted += 1
	}
	return strings.to_string(b)
}

// asset_emits_handle reports whether an Asset_Kind carries a typed handle
// constant in the generated assets.gen.fun seam. Every kind EXCEPT Image does: a
// model→MeshHandle, atlas→AtlasHandle, audio→SoundHandle, tileset→TilesetHandle
// are all named by game code. An IMAGE is a first-class manifest/DAG node (hashed,
// closed-registry) but carries NO seam handle — it is the atlas's raw-image
// dependency, sliced through the AtlasHandle, never referenced directly (§19 §1:
// the image has no independent seam). Skipping it keeps the seam a pure function of
// the handle-bearing assets, so registering an image does not perturb the seam
// bytes (and never emits a `let dungeon.png:` whose `.`-bearing name is not a valid
// funpack identifier).
asset_emits_handle :: proc(kind: Asset_Kind) -> bool {
	return kind != .Image
}

// emit_assets_import writes one `import <module>.{T0, T1, …}` line per owning
// module the registered assets' handle types live in — modules in first-use
// order, each line's types deduplicated and in first-use order across the
// manifest entries. An all-engine.assets manifest (the committed exemplar)
// emits exactly its single historical line; a manifest registering a tileset
// adds `import engine.tilemap.{TilesetHandle}` after it (or alone, when the
// manifest registers tilesets only).
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

// assets_used_handle_modules returns the §26 modules owning the manifest's
// handle types, deduplicated and in first-use order walking entries by index —
// the deterministic order of the seam's import lines.
assets_used_handle_modules :: proc(manifest: Asset_Manifest, allocator := context.allocator) -> []string {
	modules := make([dynamic]string, 0, 2, allocator)
	for entry in manifest.entries {
		// Image nodes carry no handle (sliced through their atlas, §19 §1), so
		// they contribute no import module — registering an image never adds an
		// import line to the seam.
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

// assets_used_handle_types returns the handle types owned by `module` that the
// manifest's assets use, deduplicated and in first-use order (the order each
// kind first appears walking entries by index). First-use order, not enum
// order, is the byte contract: it is a deterministic function of the committed
// manifest, so the same manifest always yields the same import line.
assets_used_handle_types :: proc(manifest: Asset_Manifest, module: string, allocator := context.allocator) -> []string {
	types := make([dynamic]string, 0, 3, allocator)
	for entry in manifest.entries {
		// Image nodes carry no handle (§19 §1), so they contribute no handle type
		// to any import line.
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

// emit_asset_handle writes one asset's three-line block: the authored @doc, the
// @gtag("assets") closed-registry tag, and the `let NAME: KINDHandle =
// KINDHandle{name: "NAME"}` typed handle constant. The handle's value is keyed on
// the asset's own registered name, so the typed constant (assets.NAME) and the
// string constructor (kind("NAME")) resolve to the same handle.
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

// slice_contains_string reports whether `items` already holds `needle` — the
// dedup probe for the first-use import-type ordering. A linear scan: the handle
// type set is at most the three closed kinds, so order-preserving membership over
// a tiny slice beats a set whose iteration order the import line cannot depend on.
slice_contains_string :: proc(items: []string, needle: string) -> bool {
	for item in items {
		if item == needle {
			return true
		}
	}
	return false
}
