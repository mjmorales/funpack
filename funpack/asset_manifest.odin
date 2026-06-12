// Asset-manifest reader for the §19 bake pipeline: the committed
// assets.manifest is the GENERATED source of truth for handle resolution
// and the closed name registry every later asset seam consults (the
// handle-constant emitter, the @gtag-for-assets closed-registry check, the
// release dead-asset walk). This file owns the manifest's own small config
// grammar — distinct from the §14 .fcfg smaller-config grammar (lex_fcfg):
// it has `#` line comments, `[name]` section headers, and `[…]` string
// lists the .fcfg token set has none of, so it gets its own lexer/parser
// pair, mirroring why .fcfg did not reuse the .fun lexer.
//
// Grammar (an exemplar lives at examples/assets/assets/assets.manifest):
//   - `# …` line comments, anywhere (full-line or trailing)
//   - one `[name]` block per asset, opening a key=value body
//   - `key = value` where value is a bare word (kind: model|atlas|audio|tileset|image),
//     a "quoted string" (source/importer/hash/out), or a `[ "a", "b" ]`
//     list (deps; `[]` is the empty list)
//
// Entries are accumulated in source order and exposed as a []Asset_Entry
// walked by index — never a map. Determinism is the load-bearing invariant
// (§2 same inputs -> same hash, same registry -> same emitted seam), so the
// reader admits no map iteration whose order the runtime could shuffle.
package funpack

// Asset_Kind is the closed set of source kinds the §4 importers cover, one
// arm per importer. A `kind =` value outside this set is a malformed
// manifest, never a silently-tolerated extra kind — the registry is
// closed, so an unknown kind is an error, not an extension point. Tileset
// is the §18 §2 .tiles kind (importer tiles_importer.odin); the committed
// dungeon/warren manifests register one, deps-on its atlas (§19 §5). Image
// is the §1 raw-image kind (importer import_image, asset_importers.odin): a
// Tier-1 binary PNG that imports to a decoded RGBA8 buffer, the §4
// dependency an atlas slices over — a real asset node, not just a
// dependency string.
Asset_Kind :: enum {
	Model,
	Atlas,
	Audio,
	Tileset,
	Image,
}

// Asset_Entry is one [name] block: the asset's registered name (the handle
// the seam emits), its closed source kind, the source path, the importer
// version string (`model@3`) the §2 hash folds in, its dependency hash
// list (raw inputs whose hashes feed this asset's hash — an atlas deps-on
// its raw image), the content hash, and the baked output path. deps travel
// in source order so the §2 canonical concatenation is reproducible.
Asset_Entry :: struct {
	name:             string,
	kind:             Asset_Kind,
	source:           string,
	importer_version: string,
	deps:             []string,
	hash:             string,
	out:              string,
}

// Asset_Manifest is the parsed manifest: the entries in committed-file
// order. The slice is the registry — readers walk it by index to look a
// name up or enumerate the closed set, never iterating a map.
Asset_Manifest :: struct {
	entries: []Asset_Entry,
}

// Asset_Manifest_Error is closed with one arm per way the manifest can
// reject. Malformed_Manifest is any grammar violation (a key=value outside
// a block, a value of the wrong shape, an unterminated string or list, a
// stray glyph); Unknown_Kind is the dedicated closed-set reject — a `kind`
// value that is not model/atlas/audio/tileset/image; Missing_Key is a block missing one
// of the required keys; Duplicate_Name is two blocks registering the same
// name (the registry is single-owner, like §15.6 module identity).
Asset_Manifest_Error :: enum {
	None,
	Malformed_Manifest,
	Unknown_Kind,
	Missing_Key,
	Duplicate_Name,
}

// read_asset_manifest parses the manifest content into the typed in-memory
// index. It walks tokens left to right (the grammar is LL(1)) and
// accumulates entries in source order; a name collision, an unknown kind, a
// missing required key, or any non-grammar construct rejects the whole
// manifest. The five keys — kind, source, importer, deps, out — plus hash
// are all required; the order they appear in a block does not matter
// because each is read by name.
read_asset_manifest :: proc(content: string) -> (manifest: Asset_Manifest, err: Asset_Manifest_Error) {
	p := Manifest_Parser{tokens = lex_manifest(content)}
	entries := make([dynamic]Asset_Entry, 0, 4, context.temp_allocator)
	seen := make(map[string]bool, context.temp_allocator)
	for !manifest_at_end(&p) {
		// The only legal top-level construct is a `[name]` block opener;
		// a key=value outside a block, or any other glyph, is malformed.
		if manifest_peek(&p).kind != .L_Bracket {
			return Asset_Manifest{}, .Malformed_Manifest
		}
		entry := manifest_parse_block(&p) or_return
		if entry.name in seen {
			return Asset_Manifest{}, .Duplicate_Name
		}
		seen[entry.name] = true
		append(&entries, entry)
	}
	return Asset_Manifest{entries = entries[:]}, .None
}

// manifest_parse_block parses one `[name]` header and its key=value body,
// which runs until the next `[` or end of input. Each value is read by its
// key, so key order is free; a missing required key is Missing_Key and an
// unknown key (or a value of the wrong shape) is Malformed_Manifest.
manifest_parse_block :: proc(p: ^Manifest_Parser) -> (entry: Asset_Entry, err: Asset_Manifest_Error) {
	manifest_expect(p, .L_Bracket) or_return
	name_tok := manifest_expect(p, .Word) or_return
	manifest_expect(p, .R_Bracket) or_return
	entry.name = name_tok.text
	saw_kind := false
	saw_source := false
	saw_importer := false
	saw_deps := false
	saw_hash := false
	saw_out := false
	for manifest_peek(p).kind == .Word {
		key := manifest_expect(p, .Word) or_return
		manifest_expect(p, .Eq) or_return
		switch key.text {
		case "kind":
			value := manifest_expect(p, .Word) or_return
			entry.kind = parse_asset_kind(value.text) or_return
			saw_kind = true
		case "source":
			value := manifest_expect(p, .String) or_return
			entry.source = value.text
			saw_source = true
		case "importer":
			value := manifest_expect(p, .String) or_return
			entry.importer_version = value.text
			saw_importer = true
		case "deps":
			entry.deps = manifest_parse_list(p) or_return
			saw_deps = true
		case "hash":
			value := manifest_expect(p, .String) or_return
			entry.hash = value.text
			saw_hash = true
		case "out":
			value := manifest_expect(p, .String) or_return
			entry.out = value.text
			saw_out = true
		case:
			return Asset_Entry{}, .Malformed_Manifest
		}
	}
	if !saw_kind || !saw_source || !saw_importer || !saw_deps || !saw_hash || !saw_out {
		return Asset_Entry{}, .Missing_Key
	}
	return entry, .None
}

// parse_asset_kind maps a `kind =` word onto the closed Asset_Kind set. A
// value outside model/atlas/audio/tileset/image is Unknown_Kind — the
// closed-registry reject, never a tolerated extra kind.
parse_asset_kind :: proc(text: string) -> (kind: Asset_Kind, err: Asset_Manifest_Error) {
	switch text {
	case "model":
		return .Model, .None
	case "atlas":
		return .Atlas, .None
	case "audio":
		return .Audio, .None
	case "tileset":
		return .Tileset, .None
	case "image":
		return .Image, .None
	case:
		return .Model, .Unknown_Kind
	}
}

// manifest_parse_list parses a `[ "a", "b" ]` string list — the deps value.
// `[]` is the empty list (no dependency hashes). The elements are quoted
// strings collected in source order so the §2 canonical concatenation is
// reproducible; a trailing comma before `]` is tolerated. A non-string
// element or an unterminated list is malformed.
manifest_parse_list :: proc(p: ^Manifest_Parser) -> (items: []string, err: Asset_Manifest_Error) {
	manifest_expect(p, .L_Bracket) or_return
	list := make([dynamic]string, 0, 2, context.temp_allocator)
	for manifest_peek(p).kind == .String {
		item := manifest_expect(p, .String) or_return
		append(&list, item.text)
		for manifest_peek(p).kind == .Comma {
			p.pos += 1
		}
	}
	manifest_expect(p, .R_Bracket) or_return
	return list[:], .None
}

// ── Lexer ──────────────────────────────────────────────────────────────
// Manifest_Token_Kind is the closed token set the manifest grammar needs.
// It is deliberately smaller than the .fcfg set and adds the `[`/`]`
// brackets the section headers and lists use; `#` comments and whitespace
// never produce a token.
Manifest_Token_Kind :: enum {
	Invalid, // end of input or an unrecognized glyph
	Word, // a bare identifier: a block name, a key, or a kind value
	String, // a "quoted" value
	Eq,
	L_Bracket,
	R_Bracket,
	Comma,
}

Manifest_Token :: struct {
	kind: Manifest_Token_Kind,
	text: string,
}

Manifest_Parser :: struct {
	tokens: []Manifest_Token,
	pos:    int,
}

manifest_at_end :: proc(p: ^Manifest_Parser) -> bool {
	return p.pos >= len(p.tokens)
}

// manifest_peek reports an Invalid token at end of input so a kind check
// fails closed without a separate end test.
manifest_peek :: proc(p: ^Manifest_Parser) -> Manifest_Token {
	if manifest_at_end(p) {
		return Manifest_Token{kind = .Invalid}
	}
	return p.tokens[p.pos]
}

manifest_expect :: proc(p: ^Manifest_Parser, kind: Manifest_Token_Kind) -> (tok: Manifest_Token, err: Asset_Manifest_Error) {
	tok = manifest_peek(p)
	if tok.kind != kind {
		return Manifest_Token{}, .Malformed_Manifest
	}
	p.pos += 1
	return tok, .None
}

// lex_manifest tokenizes the manifest surface. It is total: an unrecognized
// glyph becomes an Invalid token for the parser to reject. `#` opens a line
// comment consumed to end of line (the manifest is a generated, commented
// index); whitespace and newlines are insignificant.
lex_manifest :: proc(content: string) -> []Manifest_Token {
	tokens := make([dynamic]Manifest_Token, 0, 32, context.temp_allocator)
	i := 0
	for i < len(content) {
		ch := content[i]
		switch {
		case ch == ' ' || ch == '\t' || ch == '\r' || ch == '\n':
			i += 1
		case ch == '#':
			// A line comment runs to the next newline (or end of input).
			for i < len(content) && content[i] != '\n' {
				i += 1
			}
		case ch == '"':
			tok, next := manifest_scan_string(content, i)
			append(&tokens, tok)
			i = next
		case is_manifest_word_char(ch):
			tok, next := manifest_scan_word(content, i)
			append(&tokens, tok)
			i = next
		case:
			append(&tokens, manifest_scan_punct(ch))
			i += 1
		}
	}
	return tokens[:]
}

manifest_scan_string :: proc(content: string, start: int) -> (tok: Manifest_Token, next: int) {
	i := start + 1
	for i < len(content) && content[i] != '"' && content[i] != '\n' {
		i += 1
	}
	if i >= len(content) || content[i] != '"' {
		return Manifest_Token{kind = .Invalid, text = content[start:i]}, i
	}
	return Manifest_Token{kind = .String, text = content[start + 1 : i]}, i + 1
}

manifest_scan_word :: proc(content: string, start: int) -> (tok: Manifest_Token, next: int) {
	i := start
	for i < len(content) && is_manifest_word_char(content[i]) {
		i += 1
	}
	return Manifest_Token{kind = .Word, text = content[start:i]}, i
}

// manifest_scan_punct maps the bracket/comma/eq glyphs the grammar uses;
// every other single character is Invalid, the parser's reject signal.
manifest_scan_punct :: proc(ch: u8) -> Manifest_Token {
	switch ch {
	case '=':
		return Manifest_Token{kind = .Eq, text = "="}
	case '[':
		return Manifest_Token{kind = .L_Bracket, text = "["}
	case ']':
		return Manifest_Token{kind = .R_Bracket, text = "]"}
	case ',':
		return Manifest_Token{kind = .Comma, text = ","}
	case:
		return Manifest_Token{kind = .Invalid}
	}
}

// is_manifest_word_char admits the characters a manifest word can carry: a
// block name or key (`coin`, `coin_sfx`, `importer`) and a kind value
// (`model`). Letters, digits, and underscore — the same class .fun
// identifiers use (is_ident_char already admits `_`), scanned here without
// the casing classes the manifest grammar has no use for.
is_manifest_word_char :: proc(ch: u8) -> bool {
	return is_ident_char(ch)
}
