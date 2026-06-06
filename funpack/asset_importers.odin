// Per-format asset importers for the §19 bake pipeline: one engine-closed,
// deterministic, pure source -> content-hashed-asset function per source kind
// (§4). These are the functions the §2 hasher (asset_hash.odin) hashes OVER —
// distinct from the manifest reader (asset_manifest.odin), which is the
// registry the importer OUTPUTS index into. The three kinds the closed
// Asset_Kind set covers:
//
//   - .fpm model   -> import_model:  a mesh+collider record from the modeling
//     DSL (§16) — `model <Name> { param … ; emit … ; material … }`
//   - .atlas sheet -> import_atlas:  regions + named cells + named clips from
//     the image+slice spec, RECORDING the raw image as a dependency (§4:
//     editing the PNG re-bakes only this atlas and whatever references it)
//   - raw audio    -> import_audio:  content-hashing the raw binary directly
//     (no DSL — a Tier-1 binary input hashed as-is)
//
// Each importer carries its own importer-version string (model@3, atlas@2,
// audio@1, matching the committed assets.manifest), folded into the content
// hash so a version bump invalidates EXACTLY that importer's outputs and their
// dependents — never more (§2 correct invalidation).
//
// Purity boundary (§29): an importer reads ONLY its source bytes (and, for the
// atlas, the dependency hashes the caller resolved for it). No clock, no host
// nondeterminism, no map iteration whose order the runtime could shuffle — so
// the same source yields the same asset, and the same asset yields the same
// content hash, anywhere. The importers are the parallelizable DAG nodes of §4:
// the atlas node deps-on its raw image hash, the model and audio nodes have no
// dependencies, so a bake walks them in any order.
package funpack

// ── Importer version strings ─────────────────────────────────────────────
// Each importer-version constant is folded into the §2 content hash. Bumping
// one changes the hash of everything that importer produced — a kernel fix
// rebuilds exactly its outputs (§2 correct invalidation). They match the
// committed assets.manifest `importer =` values exactly so a hash this battery
// computes is comparable against the manifest's pinned hash.
MODEL_IMPORTER_VERSION :: "model@3"
ATLAS_IMPORTER_VERSION :: "atlas@2"
AUDIO_IMPORTER_VERSION :: "audio@1"

// Importer_Error is closed with one arm per way an importer can reject. None
// is success. Malformed_Source is any grammar violation in a DSL source (the
// .fpm or .atlas surface): a stray glyph, a value of the wrong shape, an
// unterminated string, a missing required clause, a clip naming an undeclared
// cell. The set is uniform across importers so a caller branches on one enum
// regardless of which kind it imported.
Importer_Error :: enum {
	None,
	Malformed_Source,
}

// ── Model importer (.fpm) ────────────────────────────────────────────────
// Model_Asset is the imported coin.fpm: the model name, its disc params
// (radius/thickness — the tunable Length knobs §16 turns into params-`data`
// fields), the emitted geometry primitive, the named material, and the §2
// content hash that is this asset's identity. The params are the proof
// surface: import_model on coin.fpm yields radius/thickness. Geometry is held
// as the primitive name + its positional arguments (parse+produce, no CSG
// evaluation — that is the bake's mesh stage, not this importer's concern).
Model_Asset :: struct {
	name:      string,
	params:    []Model_Param,
	emit_prim: string, // the `emit` geometry primitive (`cyl`)
	emit_args: []string, // the primitive's positional arguments, as written (`radius`, `thickness`)
	material:  string, // the named `material` slot (`body`)
	hash:      string,
}

// Model_Param is one `param <name>: <type> = <default>` knob (§16: a tunable
// knob + default that becomes a params-`data` field). The default is held as a
// Fixed — Length is a §10 fixed-point dimension — parsed from the literal so
// the disc dimensions (radius 4, thickness 1) are recoverable numerically.
Model_Param :: struct {
	name:    string,
	type:    string, // the declared dimension type (`Length`)
	default: Fixed, // the parsed default value
}

// import_model parses a .fpm modeling source into a content-hashed Model_Asset.
// It reads the §16 `model <Name> { … }` vocabulary this battery covers — param,
// emit, material — left to right (the grammar is LL(1)); a missing model
// header, a malformed clause, or a stray glyph rejects the whole source. The
// content hash folds the raw source bytes, the model importer version, and (for
// a model) an empty dependency list — a model has no input assets (§4), so its
// hash depends only on its own source and the importer version.
import_model :: proc(src: string) -> (asset: Model_Asset, err: Importer_Error) {
	p := Fpm_Parser{tokens = lex_fpm(src)}
	asset = fpm_parse_model(&p) or_return
	asset.hash = asset_content_hash(transmute([]byte)src, MODEL_IMPORTER_VERSION, nil)
	return asset, .None
}

// fpm_parse_model parses one `model <Name> { … }` block: the header, then the
// param/emit/material clauses in any order until the closing brace. emit and
// material are single-slot (§16: a model declares one `emit`); a duplicate or a
// missing model header is malformed. params accumulate in source order.
fpm_parse_model :: proc(p: ^Fpm_Parser) -> (asset: Model_Asset, err: Importer_Error) {
	fpm_expect(p, .Model) or_return
	name := fpm_expect(p, .Ident) or_return
	asset.name = name.text
	fpm_expect(p, .L_Brace) or_return

	params := make([dynamic]Model_Param, 0, 4, context.temp_allocator)
	saw_emit := false
	for fpm_peek(p).kind != .R_Brace {
		switch fpm_peek(p).kind {
		case .Param:
			append(&params, fpm_parse_param(p) or_return)
		case .Emit:
			if saw_emit {
				return Model_Asset{}, .Malformed_Source
			}
			asset.emit_prim, asset.emit_args = fpm_parse_emit(p) or_return
			saw_emit = true
		case .Material:
			asset.material = fpm_parse_material(p) or_return
		case .Invalid, .Model, .Ident, .Number, .L_Brace, .R_Brace, .L_Paren, .R_Paren, .Colon, .Comma, .Eq:
			return Model_Asset{}, .Malformed_Source
		}
	}
	fpm_expect(p, .R_Brace) or_return
	asset.params = params[:]
	return asset, .None
}

// fpm_parse_param parses `param <name>: <Type> = <default>`. The default is a
// number literal (Int or decimal), folded into a Fixed because Length is a
// §10 fixed-point dimension.
fpm_parse_param :: proc(p: ^Fpm_Parser) -> (param: Model_Param, err: Importer_Error) {
	fpm_expect(p, .Param) or_return
	name := fpm_expect(p, .Ident) or_return
	fpm_expect(p, .Colon) or_return
	type := fpm_expect(p, .Ident) or_return
	fpm_expect(p, .Eq) or_return
	value := fpm_expect(p, .Number) or_return
	param.name = name.text
	param.type = type.text
	param.default = value.fixed_value
	return param, .None
}

// fpm_parse_emit parses `emit <prim>(<arg>, …)` — the render geometry. The
// primitive is the geometry-algebra name (§16: box/sphere/cyl/capsule, unions);
// arguments are the as-written param references, captured by text for the
// content surface without evaluating the CSG (the bake's mesh stage owns that).
fpm_parse_emit :: proc(p: ^Fpm_Parser) -> (prim: string, args: []string, err: Importer_Error) {
	fpm_expect(p, .Emit) or_return
	prim_tok := fpm_expect(p, .Ident) or_return
	fpm_expect(p, .L_Paren) or_return
	arg_list := make([dynamic]string, 0, 2, context.temp_allocator)
	for fpm_peek(p).kind == .Ident {
		arg := fpm_expect(p, .Ident) or_return
		append(&arg_list, arg.text)
		for fpm_peek(p).kind == .Comma {
			p.pos += 1
		}
	}
	fpm_expect(p, .R_Paren) or_return
	return prim_tok.text, arg_list[:], .None
}

// fpm_parse_material parses `material <name> = <appearance>` and records the
// named slot. The appearance expression (`pbr(color: gold, rough: 0.3)`) is the
// bake's material-binding concern (§16); this importer records the slot name
// the seam exposes and consumes the appearance to the clause's end.
fpm_parse_material :: proc(p: ^Fpm_Parser) -> (name: string, err: Importer_Error) {
	fpm_expect(p, .Material) or_return
	name_tok := fpm_expect(p, .Ident) or_return
	fpm_expect(p, .Eq) or_return
	fpm_expect(p, .Ident) or_return // the appearance constructor (`pbr`)
	fpm_skip_balanced_parens(p) or_return
	return name_tok.text, .None
}

// fpm_skip_balanced_parens consumes a balanced `( … )` group (the material
// appearance constructor's argument list, whose interior — named args, decimal
// literals — is the bake's concern, not this importer's). A missing opener or
// an unbalanced group is malformed.
fpm_skip_balanced_parens :: proc(p: ^Fpm_Parser) -> Importer_Error {
	fpm_expect(p, .L_Paren) or_return
	depth := 1
	for depth > 0 {
		tok := fpm_peek(p)
		#partial switch tok.kind {
		case .L_Paren:
			depth += 1
		case .R_Paren:
			depth -= 1
		case .Invalid:
			return .Malformed_Source
		}
		p.pos += 1
	}
	return .None
}

// ── Atlas importer (.atlas) ──────────────────────────────────────────────
// Atlas_Asset is the imported pickups.atlas: the atlas name, the raw image its
// cells slice (the §4 DEPENDENCY — its hash feeds this atlas's content hash, so
// editing the PNG re-bakes only this atlas), the grid cell dimensions, the
// named cells (regions in the sheet), the named clips (animation sequences over
// cells), and the §2 content hash. The cells and clips are the proof surface:
// import_atlas on pickups.atlas yields coin/gem/key + the spin clip.
Atlas_Asset :: struct {
	name:        string,
	image:       string, // the raw image this atlas slices — the §4 dependency
	grid_w:      i64, // cell width in the sheet
	grid_h:      i64, // cell height in the sheet
	cells:       []Atlas_Cell,
	clips:       []Atlas_Clip,
	image_dep:   string, // the dependency entry recorded for the image (image@hash)
	hash:        string,
}

// Atlas_Cell is one `cell <name> at (<x>, <y>)` region — a named sub-rectangle
// of the sheet at the given grid coordinate. Cells accumulate in source order
// (the clip frame indices below reference them by name, resolved at parse).
Atlas_Cell :: struct {
	name: string,
	x:    i64,
	y:    i64,
}

// Atlas_Clip is one `clip <name> cells [<cell>, …] fps <n>` animation — a named
// sequence of cell references played at a frame rate. The proof surface's spin
// clip is 4 frames at fps 8. The frame names must each name a declared cell;
// referencing an undeclared cell is malformed (the closed-name discipline the
// manifest registry mirrors at the asset level).
Atlas_Clip :: struct {
	name:   string,
	frames: []string, // the cell names this clip cycles, in order
	fps:    i64,
}

// import_atlas parses an .atlas image+slice source into a content-hashed
// Atlas_Asset, recording the raw image as a §4 dependency. dep_hashes are the
// content hashes the caller resolved for this atlas's inputs (the raw image
// hash) — folded into this atlas's own hash so a PNG edit invalidates it. The
// atlas is the DAG node that deps-on its image: pass the image's resolved hash
// here, and import_atlas threads it into both the recorded dependency and the
// content hash. The image filename declared in the source must be the single
// dependency the caller resolved; an empty dep list with a declared image, or a
// mismatch in count, is malformed.
import_atlas :: proc(src: string, dep_hashes: []string) -> (asset: Atlas_Asset, err: Importer_Error) {
	p := Atlas_Parser{tokens = lex_atlas(src)}
	asset = atlas_parse(&p) or_return
	// An atlas declares exactly one image, so it carries exactly one resolved
	// dependency hash. A count mismatch means the caller resolved the wrong
	// inputs for this source — a malformed bake graph, not a tolerated state.
	if len(dep_hashes) != 1 {
		return Atlas_Asset{}, .Malformed_Source
	}
	asset.image_dep = dep_hashes[0]
	asset.hash = asset_content_hash(transmute([]byte)src, ATLAS_IMPORTER_VERSION, dep_hashes)
	return asset, .None
}

// atlas_parse parses one `atlas <Name> { … }` block: the header, then the
// image/grid/cell/clip clauses in source order. image and grid are single-slot;
// cells and clips accumulate. A clip frame naming an undeclared cell, a missing
// required clause, or a stray glyph rejects the whole source.
atlas_parse :: proc(p: ^Atlas_Parser) -> (asset: Atlas_Asset, err: Importer_Error) {
	atlas_expect(p, .Atlas) or_return
	name := atlas_expect(p, .Ident) or_return
	asset.name = name.text
	atlas_expect(p, .L_Brace) or_return

	cells := make([dynamic]Atlas_Cell, 0, 4, context.temp_allocator)
	clips := make([dynamic]Atlas_Clip, 0, 2, context.temp_allocator)
	declared := make(map[string]bool, context.temp_allocator)
	saw_image := false
	saw_grid := false
	for atlas_peek(p).kind != .R_Brace {
		switch atlas_peek(p).kind {
		case .Image:
			atlas_expect(p, .Image) or_return
			img := atlas_expect(p, .String) or_return
			asset.image = img.text
			saw_image = true
		case .Grid:
			atlas_expect(p, .Grid) or_return
			w := atlas_expect(p, .Number) or_return
			h := atlas_expect(p, .Number) or_return
			asset.grid_w = w.int_value
			asset.grid_h = h.int_value
			saw_grid = true
		case .Cell:
			cell := atlas_parse_cell(p) or_return
			declared[cell.name] = true
			append(&cells, cell)
		case .Clip:
			clip := atlas_parse_clip(p, declared) or_return
			append(&clips, clip)
		case .Invalid, .Atlas, .Ident, .Number, .String, .At, .Fps, .Cells, .L_Brace, .R_Brace, .L_Paren, .R_Paren, .L_Bracket, .R_Bracket, .Comma:
			return Atlas_Asset{}, .Malformed_Source
		}
	}
	atlas_expect(p, .R_Brace) or_return
	if !saw_image || !saw_grid {
		return Atlas_Asset{}, .Malformed_Source
	}
	asset.cells = cells[:]
	asset.clips = clips[:]
	return asset, .None
}

// atlas_parse_cell parses `cell <name> at (<x>, <y>)` — a named region at a grid
// coordinate. The coordinates are integer cell indices into the sheet.
atlas_parse_cell :: proc(p: ^Atlas_Parser) -> (cell: Atlas_Cell, err: Importer_Error) {
	atlas_expect(p, .Cell) or_return
	name := atlas_expect(p, .Ident) or_return
	atlas_expect(p, .At) or_return
	atlas_expect(p, .L_Paren) or_return
	x := atlas_expect(p, .Number) or_return
	atlas_expect(p, .Comma) or_return
	y := atlas_expect(p, .Number) or_return
	atlas_expect(p, .R_Paren) or_return
	cell.name = name.text
	cell.x = x.int_value
	cell.y = y.int_value
	return cell, .None
}

// atlas_parse_clip parses `clip <name> cells [<cell>, …] fps <n>`. Each frame is
// a quoted cell name that must reference a cell declared earlier in this atlas
// (declared) — a clip over an undeclared cell is malformed, the closed-name
// discipline at the asset level. Frames retain source order (the animation
// sequence); the spin clip's four frames cycle coin/gem/key/gem.
atlas_parse_clip :: proc(p: ^Atlas_Parser, declared: map[string]bool) -> (clip: Atlas_Clip, err: Importer_Error) {
	atlas_expect(p, .Clip) or_return
	name := atlas_expect(p, .Ident) or_return
	atlas_expect(p, .Cells) or_return
	atlas_expect(p, .L_Bracket) or_return
	frames := make([dynamic]string, 0, 4, context.temp_allocator)
	for atlas_peek(p).kind == .String {
		frame := atlas_expect(p, .String) or_return
		if !(frame.text in declared) {
			return Atlas_Clip{}, .Malformed_Source
		}
		append(&frames, frame.text)
		for atlas_peek(p).kind == .Comma {
			p.pos += 1
		}
	}
	atlas_expect(p, .R_Bracket) or_return
	atlas_expect(p, .Fps) or_return
	fps := atlas_expect(p, .Number) or_return
	clip.name = name.text
	clip.frames = frames[:]
	clip.fps = fps.int_value
	return clip, .None
}

// ── Closed dispatch keyed on Asset_Kind ──────────────────────────────────
// Imported_Asset is the closed union over the three importer outputs, tagged
// by the same Asset_Kind the manifest registry uses. The bake walks the
// manifest, dispatches each entry's kind to its importer, and folds the result
// into this union — so a kind that has no importer arm is a compile error in
// the dispatch below, never a silently-skipped asset (the registry is closed,
// §3).
Imported_Asset :: union {
	Model_Asset,
	Atlas_Asset,
	Audio_Asset,
}

// import_asset is the closed dispatch keyed on Asset_Kind: one arm per kind,
// each routing to its format importer over the same source bytes the manifest
// names. The model and audio importers take no dependency hashes (their §4 DAG
// nodes have no inputs); the atlas takes the resolved hash of its raw image.
// Passing audio's DSL-less source as bytes is the binary path; the model and
// atlas paths parse the bytes as their DSL text. Because Asset_Kind is closed,
// adding a kind without an arm here fails the build — the dispatch can never
// silently drop an asset.
import_asset :: proc(kind: Asset_Kind, src: []byte, dep_hashes: []string) -> (asset: Imported_Asset, err: Importer_Error) {
	switch kind {
	case .Model:
		model := import_model(string(src)) or_return
		return model, .None
	case .Atlas:
		atlas := import_atlas(string(src), dep_hashes) or_return
		return atlas, .None
	case .Audio:
		audio := import_audio(src) or_return
		return audio, .None
	}
	return nil, .Malformed_Source
}

// ── Audio importer (raw binary) ──────────────────────────────────────────
// Audio_Asset is an imported raw audio input: just the §2 content hash of its
// bytes. Audio is a Tier-1 binary input (§4) with no authoring DSL — the
// importer content-hashes the raw binary directly, no parse. The hash is the
// proof surface: import_audio on the same bytes is deterministic.
Audio_Asset :: struct {
	hash: string,
}

// import_audio content-hashes a raw audio binary directly (§4: a raw external
// file hashed through a binary importer). No DSL, no dependencies — the hash
// folds the raw bytes and the audio importer version. Always succeeds (raw
// bytes have no grammar to violate), so the error arm exists only for the
// uniform Importer signature.
import_audio :: proc(bytes: []byte) -> (asset: Audio_Asset, err: Importer_Error) {
	asset.hash = asset_content_hash(bytes, AUDIO_IMPORTER_VERSION, nil)
	return asset, .None
}

// ── .fpm lexer ───────────────────────────────────────────────────────────
// Fpm_Token_Kind is the closed token set the §16 model surface this battery
// reads needs. The model/param/emit/material keywords open the productions;
// Ident/Number are the atoms; the bracket/colon/comma/eq glyphs drive the
// clause structure. The .fpm grammar is far larger than this (fn/let/for, full
// CSG expressions) — this token set is exactly the parse+produce surface the
// importer needs, no more.
Fpm_Token_Kind :: enum {
	Invalid, // end of input or an unrecognized glyph
	Model,
	Param,
	Emit,
	Material,
	Ident,
	Number,
	L_Brace,
	R_Brace,
	L_Paren,
	R_Paren,
	Colon,
	Comma,
	Eq,
}

Fpm_Token :: struct {
	kind:        Fpm_Token_Kind,
	text:        string,
	fixed_value: Fixed, // Number value, as a §10 Fixed
}

Fpm_Parser :: struct {
	tokens: []Fpm_Token,
	pos:    int,
}

fpm_at_end :: proc(p: ^Fpm_Parser) -> bool {
	return p.pos >= len(p.tokens)
}

// fpm_peek reports an Invalid token at end of input so a kind check fails
// closed without a separate end test.
fpm_peek :: proc(p: ^Fpm_Parser) -> Fpm_Token {
	if fpm_at_end(p) {
		return Fpm_Token{kind = .Invalid}
	}
	return p.tokens[p.pos]
}

fpm_expect :: proc(p: ^Fpm_Parser, kind: Fpm_Token_Kind) -> (tok: Fpm_Token, err: Importer_Error) {
	tok = fpm_peek(p)
	if tok.kind != kind {
		return Fpm_Token{}, .Malformed_Source
	}
	p.pos += 1
	return tok, .None
}

// lex_fpm tokenizes the model surface this battery reads. It is total: an
// unrecognized glyph becomes an Invalid token for the parser to reject. `//`
// opens a line comment consumed to end-of-line (§16: .fpm allows `//`);
// whitespace and newlines are insignificant.
lex_fpm :: proc(content: string) -> []Fpm_Token {
	tokens := make([dynamic]Fpm_Token, 0, 32, context.temp_allocator)
	i := 0
	for i < len(content) {
		ch := content[i]
		switch {
		case ch == ' ' || ch == '\t' || ch == '\r' || ch == '\n':
			i += 1
		case ch == '/' && i+1 < len(content) && content[i+1] == '/':
			for i < len(content) && content[i] != '\n' {
				i += 1
			}
		case is_digit(ch):
			tok, next := fpm_scan_number(content, i)
			append(&tokens, tok)
			i = next
		case is_ident_start(ch):
			tok, next := fpm_scan_ident(content, i)
			append(&tokens, tok)
			i = next
		case:
			append(&tokens, fpm_scan_punct(ch))
			i += 1
		}
	}
	return tokens[:]
}

// fpm_scan_number scans a number literal — an integer run with an optional
// `.` fractional part — and folds it to a §10 Fixed, mirroring the .fun and
// .flvl number scanners. A `.` is consumed into the literal only when a digit
// follows it (no member-access concern in this surface, but the rule keeps the
// scan total and identical to the family).
fpm_scan_number :: proc(content: string, start: int) -> (tok: Fpm_Token, next: int) {
	i := start
	for i < len(content) && is_digit(content[i]) {
		i += 1
	}
	if i+1 < len(content) && content[i] == '.' && is_digit(content[i+1]) {
		frac_start := i + 1
		j := frac_start
		for j < len(content) && is_digit(content[j]) {
			j += 1
		}
		bits := fixed_from_decimal(parse_digits(content[start:i]), content[frac_start:j])
		return Fpm_Token{kind = .Number, text = content[start:j], fixed_value = bits}, j
	}
	text := content[start:i]
	return Fpm_Token{kind = .Number, text = text, fixed_value = to_fixed(parse_digits(text))}, i
}

// fpm_scan_ident scans an identifier run and maps the model keywords. A
// non-keyword run is an Ident.
fpm_scan_ident :: proc(content: string, start: int) -> (tok: Fpm_Token, next: int) {
	i := start
	for i < len(content) && is_ident_char(content[i]) {
		i += 1
	}
	text := content[start:i]
	switch text {
	case "model":
		return Fpm_Token{kind = .Model, text = text}, i
	case "param":
		return Fpm_Token{kind = .Param, text = text}, i
	case "emit":
		return Fpm_Token{kind = .Emit, text = text}, i
	case "material":
		return Fpm_Token{kind = .Material, text = text}, i
	}
	return Fpm_Token{kind = .Ident, text = text}, i
}

// fpm_scan_punct maps the structural glyphs the model surface uses; every other
// single character is Invalid, the parser's reject signal.
fpm_scan_punct :: proc(ch: u8) -> Fpm_Token {
	switch ch {
	case '{':
		return Fpm_Token{kind = .L_Brace, text = "{"}
	case '}':
		return Fpm_Token{kind = .R_Brace, text = "}"}
	case '(':
		return Fpm_Token{kind = .L_Paren, text = "("}
	case ')':
		return Fpm_Token{kind = .R_Paren, text = ")"}
	case ':':
		return Fpm_Token{kind = .Colon, text = ":"}
	case ',':
		return Fpm_Token{kind = .Comma, text = ","}
	case '=':
		return Fpm_Token{kind = .Eq, text = "="}
	case:
		return Fpm_Token{kind = .Invalid}
	}
}

// ── .atlas lexer ─────────────────────────────────────────────────────────
// Atlas_Token_Kind is the closed token set the .atlas image+slice surface
// needs. The atlas/image/grid/cell/clip keywords open the productions; the
// at/cells/fps keywords mark the cell coordinate and clip fields; Ident/Number/
// String are the atoms; the bracket/comma glyphs drive the coordinate tuple and
// the frame list.
Atlas_Token_Kind :: enum {
	Invalid, // end of input or an unrecognized glyph
	Atlas,
	Image,
	Grid,
	Cell,
	Clip,
	At,
	Cells,
	Fps,
	Ident,
	Number,
	String,
	L_Brace,
	R_Brace,
	L_Paren,
	R_Paren,
	L_Bracket,
	R_Bracket,
	Comma,
}

Atlas_Token :: struct {
	kind:      Atlas_Token_Kind,
	text:      string,
	int_value: i64, // Number value (cell coordinate, grid dim, fps)
}

Atlas_Parser :: struct {
	tokens: []Atlas_Token,
	pos:    int,
}

atlas_at_end :: proc(p: ^Atlas_Parser) -> bool {
	return p.pos >= len(p.tokens)
}

// atlas_peek reports an Invalid token at end of input so a kind check fails
// closed without a separate end test.
atlas_peek :: proc(p: ^Atlas_Parser) -> Atlas_Token {
	if atlas_at_end(p) {
		return Atlas_Token{kind = .Invalid}
	}
	return p.tokens[p.pos]
}

atlas_expect :: proc(p: ^Atlas_Parser, kind: Atlas_Token_Kind) -> (tok: Atlas_Token, err: Importer_Error) {
	tok = atlas_peek(p)
	if tok.kind != kind {
		return Atlas_Token{}, .Malformed_Source
	}
	p.pos += 1
	return tok, .None
}

// lex_atlas tokenizes the atlas surface. It is total: an unrecognized glyph
// becomes an Invalid token for the parser to reject. `//` opens a line comment
// consumed to end-of-line; whitespace and newlines are insignificant.
lex_atlas :: proc(content: string) -> []Atlas_Token {
	tokens := make([dynamic]Atlas_Token, 0, 32, context.temp_allocator)
	i := 0
	for i < len(content) {
		ch := content[i]
		switch {
		case ch == ' ' || ch == '\t' || ch == '\r' || ch == '\n':
			i += 1
		case ch == '/' && i+1 < len(content) && content[i+1] == '/':
			for i < len(content) && content[i] != '\n' {
				i += 1
			}
		case ch == '"':
			tok, next := atlas_scan_string(content, i)
			append(&tokens, tok)
			i = next
		case is_digit(ch):
			tok, next := atlas_scan_number(content, i)
			append(&tokens, tok)
			i = next
		case is_ident_start(ch):
			tok, next := atlas_scan_ident(content, i)
			append(&tokens, tok)
			i = next
		case:
			append(&tokens, atlas_scan_punct(ch))
			i += 1
		}
	}
	return tokens[:]
}

// atlas_scan_string returns the contents between the quotes (the image filename,
// a clip frame's cell name). An unterminated string is Invalid, the parser's
// reject signal.
atlas_scan_string :: proc(content: string, start: int) -> (tok: Atlas_Token, next: int) {
	i := start + 1
	for i < len(content) && content[i] != '"' && content[i] != '\n' {
		i += 1
	}
	if i >= len(content) || content[i] != '"' {
		return Atlas_Token{kind = .Invalid, text = content[start:i]}, i
	}
	return Atlas_Token{kind = .String, text = content[start + 1 : i]}, i + 1
}

// atlas_scan_number scans an integer literal — cell coordinates, grid
// dimensions, and fps are all whole-number indices, so the atlas surface has no
// fractional literal.
atlas_scan_number :: proc(content: string, start: int) -> (tok: Atlas_Token, next: int) {
	i := start
	for i < len(content) && is_digit(content[i]) {
		i += 1
	}
	text := content[start:i]
	return Atlas_Token{kind = .Number, text = text, int_value = parse_digits(text)}, i
}

// atlas_scan_ident scans an identifier run and maps the atlas keywords. A
// non-keyword run is an Ident.
atlas_scan_ident :: proc(content: string, start: int) -> (tok: Atlas_Token, next: int) {
	i := start
	for i < len(content) && is_ident_char(content[i]) {
		i += 1
	}
	text := content[start:i]
	switch text {
	case "atlas":
		return Atlas_Token{kind = .Atlas, text = text}, i
	case "image":
		return Atlas_Token{kind = .Image, text = text}, i
	case "grid":
		return Atlas_Token{kind = .Grid, text = text}, i
	case "cell":
		return Atlas_Token{kind = .Cell, text = text}, i
	case "clip":
		return Atlas_Token{kind = .Clip, text = text}, i
	case "at":
		return Atlas_Token{kind = .At, text = text}, i
	case "cells":
		return Atlas_Token{kind = .Cells, text = text}, i
	case "fps":
		return Atlas_Token{kind = .Fps, text = text}, i
	}
	return Atlas_Token{kind = .Ident, text = text}, i
}

// atlas_scan_punct maps the structural glyphs the atlas surface uses; every
// other single character is Invalid, the parser's reject signal.
atlas_scan_punct :: proc(ch: u8) -> Atlas_Token {
	switch ch {
	case '{':
		return Atlas_Token{kind = .L_Brace, text = "{"}
	case '}':
		return Atlas_Token{kind = .R_Brace, text = "}"}
	case '(':
		return Atlas_Token{kind = .L_Paren, text = "("}
	case ')':
		return Atlas_Token{kind = .R_Paren, text = ")"}
	case '[':
		return Atlas_Token{kind = .L_Bracket, text = "["}
	case ']':
		return Atlas_Token{kind = .R_Bracket, text = "]"}
	case ',':
		return Atlas_Token{kind = .Comma, text = ","}
	case:
		return Atlas_Token{kind = .Invalid}
	}
}
