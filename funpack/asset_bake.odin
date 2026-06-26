// The §19-literal manifest-generating bake: the seam that turns the asset
// SOURCE tree into the GENERATED, never-hand-edited assets.manifest (§19 §3).
// This is the layer the prior bake skipped — it READ the committed manifest as
// the source of truth and TRUSTED its declared dependency hashes (including a
// phantom image hash no PNG was ever read for). The §19-literal path EMITS the
// manifest: it reads the real image bytes off disk, runs import_image over them,
// and resolves every dependency hash from the REAL computed hash, never a
// declared one (§2: hash = H(source bytes ⊕ importer version ⊕ dep hashes)).
//
// THE DAG (§4), walked bottom-up so each node's hash folds its dependencies':
//
//   image  (raw PNG)   — no deps; hash = H(png bytes ⊕ image@1)
//     │ deps-on (real hash)
//   atlas  (.atlas)    — deps-on its image; hash folds the REAL image hash
//     │ deps-on (real hash)
//   tileset (.tiles)   — deps-on its atlas; hash folds the REAL atlas hash
//
//   model  (.fpm)      — no deps; an independent root
//   audio  (raw)       — no deps; an independent root
//
// An image is a FIRST-CLASS manifest asset (the §1 raw-image kind, Asset_Kind
// .Image): the bake DISCOVERS each atlas's image from its `image "X.png"` clause,
// hashes the real file, and emits it as its own `[<name>] kind=image source="X.png"`
// node — the atlas then deps-on that node's real hash. The image is not just a
// dependency STRING; it is a node the manifest registers, so a rename of the PNG
// is a closed-registry compile error like any other asset.
//
// THE NODE SET is authored, the HASHES are computed. The committed manifest
// supplies the closed registry — which assets exist, their kinds, their source
// paths, and the canonical order (§19 §3: the manifest is the source of truth for
// the name set). The bake RECOMPUTES every hash and every dep from real source
// bytes, so an edit to a source (or an importer version bump) moves exactly the
// dirty subgraph's hashes (§2 correct invalidation). The discovered image nodes
// are inserted ahead of the atlas that names them (the bottom-up DAG order), so
// the emitted manifest lists each image immediately before its atlas.
//
// PURITY (§29): the bake reads only source bytes off the §14 tree (the same
// os.read_entire_file_from_path the rest of build.odin uses) and folds them
// through the deterministic hasher — no clock, no network, no machine path in a
// hash. Two bakes of the same tree emit a byte-identical manifest anywhere.
package funpack

import "core:os"
import "core:path/filepath"
import "core:strings"

// Baked_Asset is one fully-resolved manifest node: the same fields the committed
// manifest's `[name]` block carries (name, kind, source, importer, deps, hash,
// out), but with every hash REAL — computed over actual source bytes through the
// §2 hasher, never a declared/phantom value. deps carries the `<name>@<hash>`
// dependency strings the §2 fold ran over, in fold order, so the emitted block
// reproduces exactly the inputs the node's hash covers. out is the §3 baked
// output path derived from the real hash (asset_out_path).
Baked_Asset :: struct {
	name:             string,
	kind:             Asset_Kind,
	source:           string,
	importer_version: string,
	deps:             []string,
	hash:             string,
	out:              string,
}

// Baked_Manifest is the bake's whole output: the resolved nodes in emit order
// (each discovered image immediately ahead of its atlas, the rest in committed
// registry order). It is the in-memory model the emitter serializes and the
// staleness gate compares — the GENERATED manifest before it touches disk.
Baked_Manifest :: struct {
	assets: []Baked_Asset,
}

// Asset_Bake_Error is closed with one arm per way the §19-literal bake refuses
// before it emits a manifest. None is success. Missing_Manifest is the committed
// manifest absent (a tree with assets must carry the generated registry);
// Malformed_Manifest is the registry reader rejecting it; Missing_Source is a
// registered source file unreadable off disk; Malformed_Source is an importer
// rejecting a source's bytes; Missing_Image is an atlas naming an image file that
// is not on disk (the fail-closed image read — a referenced PNG must exist);
// Malformed_Image is import_image rejecting the PNG bytes (a corrupt/non-PNG
// input); Stale_Manifest is the committed manifest not byte-matching the freshly
// emitted one (the §19 §5 seam-staleness model). Each arm names the offending
// asset/file in the returned detail so the build refusal is actionable.
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

// ASSET_MANIFEST_LEAF is the manifest's fixed leaf name under assets/. The
// manifest is a committed-but-GENERATED artifact (§19 §3) — a lockfile-style
// index the bake regenerates and reviews as a diff — so it lives beside the
// asset sources at assets/assets.manifest, the same path read_tree_tilesets and
// the golden harness already read.
ASSET_MANIFEST_LEAF :: "assets.manifest"

// asset_manifest_path is the committed manifest's path under a §14 tree:
// <root>/assets/assets.manifest. The bake reads the registry from here and writes
// the regenerated manifest back here (dev), so the read and the write target one
// canonical location.
asset_manifest_path :: proc(root: string, allocator := context.allocator) -> string {
	path, _ := filepath.join({root, "assets", ASSET_MANIFEST_LEAF}, allocator)
	return path
}

// bake_asset_manifest is the §19-literal bake's pure seam: it reads the §14
// tree's asset SOURCES and produces the GENERATED Baked_Manifest with every hash
// real. The committed manifest supplies the closed node set (names, kinds,
// sources, order — §19 §3); this walk recomputes every hash bottom-up over real
// source bytes, discovering each atlas's image as a first-class node read off
// disk and hashed (never a phantom declared hash). A tree with no assets/ (no
// committed manifest) is Missing_Manifest — a build that bakes assets must carry
// the registry; a tree that legitimately has no assets does not reach this seam
// (the caller checks os.exists first). Any unreadable source, a missing image
// file, or an importer reject refuses the bake (fail-closed), naming the
// offending asset in detail. It writes nothing — the emit/staleness side is the
// caller's — so it is a pure function of the tree: two bakes emit identical
// nodes.
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

	// The hash of each resolved node, keyed by its registered name, so a later
	// node's dep can fold the REAL hash of an earlier one. Walked by index into
	// a parallel slice (never a map whose order the emit could shuffle) — the
	// node set is small and the lookups are by-name over committed order.
	resolved := make([dynamic]Baked_Asset, 0, len(manifest.entries) + 2, allocator)

	for entry in manifest.entries {
		// An image node already declared in the committed manifest is resolved
		// inline like any other source-bearing node; the discover-from-atlas path
		// below also yields image nodes, and the dedupe there keeps a single node
		// per image name regardless of which path first registered it.
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
			// The atlas's image is DISCOVERED from its source — the `image "X.png"`
			// clause — read off disk, hashed real, and registered as a first-class
			// node ahead of the atlas (the bottom-up DAG order). The atlas then
			// deps-on that node's REAL hash.
			atlas_image, image_node, atlas_err, atlas_detail := bake_resolve_atlas(root, entry.name, string(source_bytes), allocator)
			if atlas_err != .None {
				return Baked_Manifest{}, atlas_err, atlas_detail
			}
			bake_append_image_node(&resolved, image_node)
			append(&resolved, baked_node(entry.name, .Atlas, entry.source, ATLAS_IMPORTER_VERSION, []string{atlas_image.image_dep}, atlas_image.hash, allocator))
		case .Tileset:
			// A tileset deps-on its atlas (§19 §5): resolve the REAL hash of the
			// already-baked atlas the tileset's `atlas <name>` clause names, fold
			// it into the tileset's content hash.
			tileset_asset, tileset_err, tileset_detail := bake_resolve_tileset(resolved[:], entry.name, string(source_bytes), allocator)
			if tileset_err != .None {
				return Baked_Manifest{}, tileset_err, tileset_detail
			}
			append(&resolved, baked_node(entry.name, .Tileset, entry.source, TILES_IMPORTER_VERSION, tileset_asset.deps, tileset_asset.hash, allocator))
		case .Image:
			// Handled above — the leading `if entry.kind == .Image` arm — so this
			// case is unreachable; it exists for the exhaustive switch over the
			// closed Asset_Kind set (a new kind without an arm is a compile error).
			unreachable()
		}
	}

	return Baked_Manifest{assets = resolved[:]}, .None, ""
}

// bake_resolve_image reads a raw image source off the §14 tree and content-hashes
// it through import_image (§1: a raw file imports to a decoded buffer; the hash is
// its identity). A missing file is Missing_Image (fail-closed — a referenced PNG
// must exist on disk), a non-decodable input is Malformed_Image. The bake needs only
// the §2 hash at this node (the atlas-slice stage is what reads pixels), so the
// import runs on the caller's `allocator` (temp for the manifest bake) and only the
// hash is kept: import_image puts the hash AND pixels on `allocator`, so the hash
// needs no clone-out, and the pixels are reclaimed with the allocator (nil'd here).
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

// bake_resolve_atlas parses an atlas source, discovers its image from the
// `image "X.png"` clause, reads + hashes that real image, and imports the atlas
// against the image's REAL hash. It returns BOTH the imported atlas (with its
// content hash folding the real image hash and its `<image>@<hash>` dep string)
// AND the discovered image node, so the caller can register the image ahead of
// the atlas. The image node's NAME is the image filename itself (e.g.
// "dungeon.png") — the dep string's left half is `<name>@<hash>`, so the node a
// dep points at is named by the same filename the atlas declares.
bake_resolve_atlas :: proc(root: string, atlas_name: string, src: string, allocator := context.allocator) -> (atlas: Atlas_Asset, image_node: Baked_Asset, err: Asset_Bake_Error, detail: string) {
	// Parse the atlas to read its declared image filename WITHOUT resolving the
	// dependency yet (import_atlas demands the resolved dep hash up front). The
	// parser is the same atlas_parse the importer drives.
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

	// The dep STRING the §2 fold runs over: `<image-name>@<real-hash>` — the
	// image node's name (its filename) joined to its real content hash, the same
	// `<name>@<hash>` shape the committed manifest's deps use and the tileset's
	// atlas dep mirrors.
	image_dep := asset_dep_string(image_source, image_asset.hash, allocator)
	imported_atlas, atlas_import_err := import_atlas(src, []string{image_dep}, allocator)
	if atlas_import_err != .None {
		return Atlas_Asset{}, Baked_Asset{}, .Malformed_Source, atlas_name
	}
	// import_atlas content-hashes onto `allocator`, so imported_atlas.hash already
	// rides the caller's allocator (no clone-out). image_dep is the `<name>@<hash>`
	// string this proc built on `allocator` and handed in, which import_atlas stored
	// by reference — so it too already rides `allocator`. Both outlive the parse
	// scratch without a re-clone.

	node := baked_image_node(image_source, image_source, image_asset.hash, allocator)
	return imported_atlas, node, .None, ""
}

// bake_resolve_tileset imports a tileset against the REAL hash of the atlas it
// deps-on (§19 §5). It parses the tileset to read its `atlas <name>` clause, finds
// that atlas among the already-resolved nodes (the bottom-up walk guarantees the
// atlas is resolved before its tileset), and folds the atlas's real hash into the
// tileset's content hash. An atlas the tileset names but the registry does not
// register is Malformed_Source (a dangling dependency — the bake graph is
// malformed). The dep STRING is `<atlas-name>@<real-hash>`, the committed
// manifest's tileset-deps shape.
bake_resolve_tileset :: proc(resolved: []Baked_Asset, tileset_name: string, src: string, allocator := context.allocator) -> (out: Baked_Asset, err: Asset_Bake_Error, detail: string) {
	p := Tiles_Parser{tokens = lex_tiles(src)}
	parsed, parse_err := tiles_parse(&p)
	if parse_err != .None {
		return Baked_Asset{}, .Malformed_Source, tileset_name
	}
	atlas_name := parsed.atlas

	atlas_node, found := bake_find_node(resolved, atlas_name)
	if !found || atlas_node.kind != .Atlas {
		// The tileset's `atlas <name>` names an asset the registry does not
		// register as an atlas — a dangling dependency edge, a malformed bake
		// graph (never silently tolerated).
		return Baked_Asset{}, .Malformed_Source, tileset_name
	}

	atlas_dep := asset_dep_string(atlas_name, atlas_node.hash, allocator)
	imported_tileset, tileset_err := import_tileset(src, []string{atlas_dep}, allocator)
	if tileset_err != .None {
		return Baked_Asset{}, .Malformed_Source, tileset_name
	}

	// baked_node clones every string (deps + hash) onto `allocator`, so atlas_dep and
	// the tileset hash are handed in raw — no redundant pre-clone before the node clone.
	return baked_node(tileset_name, .Tileset, "", TILES_IMPORTER_VERSION, []string{atlas_dep}, imported_tileset.hash, allocator), .None, ""
}

// bake_find_node resolves a registered name against the already-baked nodes,
// walked by index (the node set is the slice, never a map). found = false is the
// dangling-dependency signal a tileset's atlas lookup turns into Malformed_Source.
bake_find_node :: proc(resolved: []Baked_Asset, name: string) -> (node: Baked_Asset, found: bool) {
	for candidate in resolved {
		if candidate.name == name {
			return candidate, true
		}
	}
	return Baked_Asset{}, false
}

// bake_append_image_node registers a discovered image node ahead of its atlas,
// deduplicating by name: two atlases sharing one image (or an image already
// declared in the committed manifest) register a single image node, so the
// emitted manifest never carries a duplicate image block. The first registration
// wins (its real hash is identical to any later one — the same bytes always hash
// the same — so the dedupe is hash-stable).
bake_append_image_node :: proc(resolved: ^[dynamic]Baked_Asset, node: Baked_Asset) {
	for existing in resolved {
		if existing.name == node.name {
			return
		}
	}
	append(resolved, node)
}

// baked_image_node builds a first-class image node: kind=image, the image@1
// importer version, no deps (a raw image is a DAG root), and an out path derived
// from its real hash. name and source are both the image filename — the node is
// named by the file the atlas declares, so a dep `<name>@<hash>` resolves to it.
baked_image_node :: proc(name: string, source: string, hash: string, allocator := context.allocator) -> Baked_Asset {
	return baked_node(name, .Image, source, IMAGE_IMPORTER_VERSION, nil, hash, allocator)
}

// baked_node assembles one resolved node, cloning every string into the caller's
// allocator (the sources are temp-read) and deriving the §3 out path from the
// real hash. deps is cloned element-wise so the node owns its dependency strings
// independent of the parse scratch they were built in.
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

// asset_dep_string builds one `<name>@<hash>` dependency string — the §2 fold's
// canonical dependency-input shape, the same form the committed manifest's deps
// list and the importers' recorded dep strings carry. The left half is the
// dependency's registered name (an image's filename, an atlas's name); the right
// half is its REAL content hash. The `@` is the single separator; a name carries
// no `@`, so the split back into (name, hash) is unambiguous.
asset_dep_string :: proc(name: string, hash: string, allocator := context.allocator) -> string {
	return strings.concatenate({name, "@", hash}, allocator)
}

// asset_out_path derives a node's §3 baked output path from its REAL hash:
// `.cache/<first2hex>/<rest-of-hex>/<source-leaf-with-baked-ext>`. The hash's
// hex digest (after the `sha256:` prefix) shards the content-addressed store —
// the first two hex chars are the fan-out directory, the remainder the leaf
// directory — and the baked-extension leaf names the product (a model bakes to
// `.mesh`, audio to `.pcm`, an image to `.tex`; the atlas/tileset/source kinds
// keep their source extension). The path is a pure function of (kind, source,
// hash), so the same node always resolves the same out — no machine path leaks.
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

// asset_hash_hex strips the `sha256:` prefix off a canonical hash string, leaving
// the bare hex digest the out-path shard derives from. A hash without the prefix
// (defensive) is returned as-is.
asset_hash_hex :: proc(hash: string) -> string {
	if strings.has_prefix(hash, HASH_PREFIX) {
		return hash[len(HASH_PREFIX):]
	}
	return hash
}

// asset_out_leaf names a node's baked product file: the source's base name with
// the kind's BAKED extension. A model bakes to a mesh, audio decodes to raw PCM,
// an image to a texture; an atlas and a tileset keep their authored extension
// (the baked product is the imported form of the same file). An image declared
// as `X.png` bakes to `X.tex`. The leaf is a pure function of (kind, source).
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

// baked_to_manifest projects a Baked_Manifest back into the Asset_Manifest the
// registry reader produces — so the closed-registry gate (asset_registry.odin),
// the seam emitter (asset_seam_emit.odin), and read_tree_tilesets can consult the
// FRESHLY-BAKED registry with real hashes instead of re-reading the committed
// file. The projection is field-for-field: a baked node IS a manifest entry, with
// the discovered image nodes now part of the registry.
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

// bake_tileset_assets resolves the project's tilesets against the FRESHLY-BAKED
// manifest — the §19-literal replacement for read_tree_tilesets's trust-the-
// committed-deps path. Each tileset imports against the REAL atlas hash the bake
// computed, so the tileset's content hash folds the real (image→atlas→tileset)
// chain. The tile DATA the table aggregates is hash-independent, so this returns
// the same tile defs read_tree_tilesets did; the difference is the resolved
// content hash, now real. ok = false on any unreadable source or importer reject,
// fail-closed like the path it replaces.
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
		// asset.deps already carries the resolved `<atlas>@<real-hash>` string the
		// bake folded — import the tileset against exactly that, so its content
		// hash matches the manifest's emitted hash.
		tileset, import_err := import_tileset(string(source_bytes), asset.deps, context.temp_allocator)
		if import_err != .None {
			return nil, false
		}
		append(&out, tileset)
	}
	return out[:], true
}

// ── Manifest emitter (§19 §3) ───────────────────────────────────────────────
// The GENERATED manifest's byte shape mirrors the committed exemplar exactly
// (examples/dungeon/assets/assets.manifest), with two differences the §19-literal
// path makes: the hashes are REAL full sha256 (not the hand-authored `…` elision)
// and each atlas's image is its own `[name] kind=image` block ahead of it.

// ASSET_MANIFEST_HEADER is the fixed three-line comment header every generated
// manifest leads with — verbatim from the committed exemplars (the GENERATED-by-
// the-bake banner, the diffable-never-hand-edited invariant, the §2 hash rule).
// It is byte-stable, independent of which assets are registered, so two bakes of
// any tree emit the same header.
ASSET_MANIFEST_HEADER :: "# assets.manifest — GENERATED by the bake. The committed name -> content-hash -> output index,\n# and the source of truth for handle resolution. Diffable; never hand-edited.\n# hash = H(source bytes + importer version + dependency hashes). Same inputs -> same hash, anywhere.\n"

// emit_asset_manifest serializes a Baked_Manifest to the committed manifest's
// canonical text — the fixed comment header, then one `[name]` block per node in
// emit order, each carrying kind/source/importer/deps/hash/out. The block shape is
// the exemplar's: a blank line before each block, the six keys in fixed order
// aligned with the exemplar's spacing, deps as a `[ "a", "b" ]` list (`[]` empty),
// and a single trailing newline. The string is allocated in `allocator`. Emission
// is a pure function of the baked manifest, so two emits of the same nodes are
// byte-identical (§29).
emit_asset_manifest :: proc(baked: Baked_Manifest, allocator := context.allocator) -> string {
	b := strings.builder_make(allocator)
	strings.write_string(&b, ASSET_MANIFEST_HEADER)
	for asset in baked.assets {
		strings.write_string(&b, "\n")
		emit_manifest_block(&b, asset)
	}
	return strings.to_string(b)
}

// emit_manifest_block writes one node's `[name]` block: the bracketed name header,
// then the six aligned `key = value` lines in the exemplar's fixed order
// (kind/source/importer/deps/hash/out). kind is a bare word; source/importer/hash/
// out are quoted; deps is the `[ … ]` list. The key column is padded to the
// exemplar's width so the values align, matching the committed byte shape.
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

// MANIFEST_KEY_WIDTH is the key-column width the exemplar pads to — the longest
// key (`importer`, `source`) sets it, so `kind`/`deps`/`hash`/`out` pad to align
// their `=` and values. Verbatim from the committed manifest's column alignment.
MANIFEST_KEY_WIDTH :: 8

// emit_manifest_word writes a `key      = value` line where value is a bare word
// (the kind). The key is left-padded to MANIFEST_KEY_WIDTH so the `=` aligns with
// every other line's, then ` = `, then the bare value.
emit_manifest_word :: proc(b: ^strings.Builder, key: string, value: string) {
	emit_manifest_key(b, key)
	strings.write_string(b, value)
	strings.write_string(b, "\n")
}

// emit_manifest_quoted writes a `key      = "value"` line where value is a quoted
// string (source/importer/hash/out). The key aligns like emit_manifest_word's; the
// value is wrapped in double quotes.
emit_manifest_quoted :: proc(b: ^strings.Builder, key: string, value: string) {
	emit_manifest_key(b, key)
	strings.write_string(b, "\"")
	strings.write_string(b, value)
	strings.write_string(b, "\"\n")
}

// emit_manifest_deps writes the `deps     = [ … ]` line: each dependency a quoted
// `<name>@<hash>` string, comma-and-space separated inside the brackets; an empty
// dep list is `[]` (the model/audio/image roots). The list shape mirrors the
// committed exemplar's deps formatting.
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

// emit_manifest_key writes one padded key plus ` = ` — the shared left side of
// every block line. The key is right-padded with spaces to MANIFEST_KEY_WIDTH so
// the `=` columns align across keys of different lengths (the exemplar's spacing).
emit_manifest_key :: proc(b: ^strings.Builder, key: string) {
	strings.write_string(b, key)
	for _ in len(key) ..< MANIFEST_KEY_WIDTH {
		strings.write_string(b, " ")
	}
	strings.write_string(b, " = ")
}

// asset_kind_word maps an Asset_Kind back to its manifest `kind =` word — the
// inverse of parse_asset_kind. The mapping is total over the closed kind set, so
// every baked node emits a kind word the reader round-trips back to the same kind.
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

// ── Staleness gate (§19 §5) ──────────────────────────────────────────────────

// bake_manifest_staleness compares the FRESHLY-emitted manifest against the
// committed bytes on disk, the §19 §5 seam-staleness model: a committed manifest
// that does not byte-match what the bake emits is a Stale_Manifest build error —
// the manifest is generated, so a divergence means an edited source (or importer
// bump) was not regenerated. ok = false (Stale_Manifest) on a byte mismatch; the
// detail names the manifest path. A regen path (caller-gated) writes the fresh
// bytes instead of comparing — the dev-regenerate side this gate is the release/
// check side of.
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

// write_asset_manifest writes the freshly-emitted manifest back to its committed
// path — the dev-regenerate side of the staleness gate. The bake regenerates the
// manifest on demand (dev) and the operator commits the diff (§19 §3: a committed-
// but-generated artifact); this is the impure write the pure emit/bake seams omit.
// ok = false on a write failure.
write_asset_manifest :: proc(root: string, emitted: string) -> bool {
	manifest_path := asset_manifest_path(root, context.temp_allocator)
	return os.write_entire_file(manifest_path, transmute([]u8)emitted) == nil
}

// asset_tree_has_manifest reports whether a §14 tree carries a committed manifest
// at assets/assets.manifest — the discriminant the build uses to decide whether to
// run the asset bake at all. A tree with no assets/ (no manifest) has no assets to
// bake, so the build skips the manifest seam entirely rather than refusing a
// legitimately asset-free game.
asset_tree_has_manifest :: proc(root: string) -> bool {
	return os.exists(asset_manifest_path(root, context.temp_allocator))
}
