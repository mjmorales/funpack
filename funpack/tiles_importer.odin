// The .tiles tileset importer for the §19 bake battery: the fourth importer
// kind beside model/atlas/audio (asset_importers.odin), parsing the §18 §2
// tileset DSL — the tile types a tilemap draws from, each naming its atlas
// cell and carrying its sim-side collision — into a content-hashed
// Tileset_Asset the §19 manifest path bakes to a TilesetHandle.
//
// Grammar (grammar/tiles.ebnf, confirmed against the dungeon/warren corpus):
//   TilesUnit    ::= Directive* TilesetBlock
//   TilesetBlock ::= 'tileset' UPPER_IDENT '{' TilesMember (Sep TilesMember)* Sep? '}'
//   TilesMember  ::= 'atlas' LOWER_IDENT
//                 |  'tile'  LOWER_IDENT '{' TileField (Sep TileField)* Sep? '}'
//   TileField    ::= 'cell' ':' '(' INT ',' INT ')'
//                 |  'solid' ':' BOOL
//                 |  'tags' ':' '[' (String (',' String)*)? ']'
// Comments are `//` (the config-family flavour); Sep is (NEWLINE | ',')+ per
// lexical-core §8, so the lexer emits Newline tokens (the flvl mold) and the
// parser tolerates either separator between members and fields — including
// around a block's braces, the same leading/trailing-separator reading the
// .flvl and .fcfg parsers apply to their brace bodies over this Sep rule.
//
// Error discipline: any GRAMMAR violation — a stray glyph, a wrong-case name,
// a missing required clause, a duplicate single-slot member or field — is the
// battery's uniform Malformed_Source. The SEMANTIC required-ness of a tile's
// cell and solid fields (the grammar admits a tile carrying only tags) is
// fail-closed with its own named arm — Missing_Tile_Cell / Missing_Tile_Solid
// — because a tile without an atlas cell cannot draw and one without a solid
// verdict cannot collide (§18 §2: collision is baked, never defaulted). A
// repeated tile name within the tileset is Duplicate_Tile_Name (the §18 §3
// one-name-one-tile discipline applied inside one file; the cross-tileset
// project-global check is the tilemap layer story's).
//
// Purity boundary (§29): the importer reads ONLY its source bytes and the
// atlas dependency hash the caller resolved (the manifest's `deps` edge — a
// tileset deps-on its atlas, §19 §5). Tiles accumulate in source order and
// every walk is slice-order, so the same source yields the same asset and the
// same content hash, anywhere.
package funpack

// TILES_IMPORTER_VERSION is folded into the §2 content hash (asset_hash.odin);
// it matches the committed dungeon/warren assets.manifest `importer =` values
// exactly so a hash this importer computes is comparable against the pinned
// manifest hash. Bumping it invalidates exactly the tileset outputs (§2).
TILES_IMPORTER_VERSION :: "tiles@1"

// Tileset_Asset is the imported dungeon.tiles: the tileset name, the atlas its
// tiles slice cells from (the §4 DEPENDENCY — its hash feeds this tileset's
// content hash, so re-baking the atlas re-bakes the tileset), the tile types in
// source order, and the §2 content hash that is this asset's identity. The
// tiles are the proof surface: import_tileset on dungeon.tiles yields
// floor/wall/water/rubble with their cells, collision, and tags.
Tileset_Asset :: struct {
	name:      string, // the tileset's UPPER_IDENT name (`Dungeon`)
	atlas:     string, // the LOWER_IDENT atlas the tiles draw from — the §4 dependency
	tiles:     []Tileset_Tile,
	atlas_dep: string, // the dependency entry recorded for the atlas (atlas@hash)
	hash:      string,
}

// Tileset_Tile is one `tile <name> { … }` type: its atlas cell coordinate, its
// sim-side collision verdict (§18 §2: fixed-point grid collision, baked into
// the tile layer), and its optional tags (`["liquid"]`, `["diggable"]`). cell
// and solid are REQUIRED (the named Missing_Tile_* rejects); tags default to
// the empty list.
Tileset_Tile :: struct {
	name:   string,
	cell_x: i64,
	cell_y: i64,
	solid:  bool,
	tags:   []string,
}

// import_tileset parses a .tiles tileset source into a content-hashed
// Tileset_Asset, recording its atlas as the §4 dependency. dep_hashes is the
// resolved content hash of this tileset's one input (the atlas the manifest's
// `deps` edge names, §19 §5) — folded into this tileset's own hash so an atlas
// re-bake invalidates it. A tileset declares exactly one atlas, so it carries
// exactly one resolved dependency hash; a count mismatch means the caller
// resolved the wrong inputs for this source — a malformed bake graph, not a
// tolerated state (the import_atlas discipline).
import_tileset :: proc(src: string, dep_hashes: []string, allocator := context.temp_allocator) -> (asset: Tileset_Asset, err: Importer_Error) {
	p := Tiles_Parser{tokens = lex_tiles(src)}
	asset = tiles_parse(&p) or_return
	if len(dep_hashes) != 1 {
		return Tileset_Asset{}, .Malformed_Source
	}
	asset.atlas_dep = dep_hashes[0]
	asset.hash = asset_content_hash(transmute([]byte)src, TILES_IMPORTER_VERSION, dep_hashes, allocator)
	return asset, .None
}

// tiles_parse parses one TilesUnit: leading directives, then the single
// tileset block, then end of input — a token after the block (a second
// tileset, stray input) rejects the source. The atlas member is single-slot
// and required (a tileset whose tiles can name no atlas cells is a missing
// required clause); tiles accumulate in source order.
tiles_parse :: proc(p: ^Tiles_Parser) -> (asset: Tileset_Asset, err: Importer_Error) {
	tiles_skip_seps(p)
	tiles_parse_directives(p) or_return
	tiles_expect(p, .Tileset) or_return
	name := tiles_expect_ident(p, .Upper) or_return
	asset.name = name.text
	tiles_expect(p, .L_Brace) or_return
	tiles_skip_seps(p)

	tiles := make([dynamic]Tileset_Tile, 0, 4, context.temp_allocator)
	declared := make(map[string]bool, context.temp_allocator)
	saw_atlas := false
	for tiles_peek(p).kind != .R_Brace {
		#partial switch tiles_peek(p).kind {
		case .Atlas:
			// Single-slot: a second `atlas` member is a duplicate clause.
			if saw_atlas {
				return Tileset_Asset{}, .Malformed_Source
			}
			tiles_expect(p, .Atlas) or_return
			atlas := tiles_expect_ident(p, .Lower) or_return
			asset.atlas = atlas.text
			saw_atlas = true
		case .Tile:
			tile := tiles_parse_tile(p) or_return
			if tile.name in declared {
				return Tileset_Asset{}, .Duplicate_Tile_Name
			}
			declared[tile.name] = true
			append(&tiles, tile)
		case:
			return Tileset_Asset{}, .Malformed_Source
		}
		// Members are Sep-separated: after one, the next token is a separator
		// or the closing brace — two members butted together on one line with
		// no separator violate the grammar.
		tiles_require_sep_or_close(p) or_return
	}
	tiles_expect(p, .R_Brace) or_return
	if !saw_atlas {
		return Tileset_Asset{}, .Malformed_Source
	}
	tiles_skip_seps(p)
	if !tiles_at_end(p) {
		return Tileset_Asset{}, .Malformed_Source
	}
	asset.tiles = tiles[:]
	return asset, .None
}

// tiles_parse_directives consumes the leading Directive* run (lexical-core §5:
// the closed metadata set — @doc/@gtag/…). The directives are metadata this
// importer does not lift (the narrowed-read discipline the .fpm importer
// applies to rig members), so each is validated against the closed name set,
// its optional parenthesized arguments are consumed balanced, and parsing
// moves on. A directive name outside the closed set is malformed — the set is
// not user-extensible.
tiles_parse_directives :: proc(p: ^Tiles_Parser) -> Importer_Error {
	for tiles_peek(p).kind == .Directive {
		name := tiles_peek(p).text
		switch name {
		case "doc", "gtag", "todo", "index", "spatial", "migrate", "expose", "server", "client":
			// the lexical-core §5 closed metadata set
		case:
			return .Malformed_Source
		}
		p.pos += 1
		if tiles_peek(p).kind == .L_Paren {
			tiles_skip_balanced_parens(p) or_return
		}
		tiles_skip_seps(p)
	}
	return .None
}

// tiles_parse_tile parses one `tile <name> { TileField (Sep TileField)* Sep? }`
// block. Fields are read by their opening keyword in any order, each at most
// once (a duplicate field is a duplicate single-slot clause); a block with no
// field at all violates the grammar's TileField+ requirement. The semantic
// floor is fail-closed and NAMED: a tile missing its cell cannot draw and one
// missing its solid verdict cannot collide, so each absence is its own arm
// rather than a defaulted value (§18 §2 collision is baked, never assumed).
tiles_parse_tile :: proc(p: ^Tiles_Parser) -> (tile: Tileset_Tile, err: Importer_Error) {
	tiles_expect(p, .Tile) or_return
	name := tiles_expect_ident(p, .Lower) or_return
	tile.name = name.text
	tiles_expect(p, .L_Brace) or_return
	tiles_skip_seps(p)

	saw_cell := false
	saw_solid := false
	saw_tags := false
	for tiles_peek(p).kind != .R_Brace {
		#partial switch tiles_peek(p).kind {
		case .Cell:
			if saw_cell {
				return Tileset_Tile{}, .Malformed_Source
			}
			tile.cell_x, tile.cell_y = tiles_parse_cell_field(p) or_return
			saw_cell = true
		case .Solid:
			if saw_solid {
				return Tileset_Tile{}, .Malformed_Source
			}
			tiles_expect(p, .Solid) or_return
			tiles_expect(p, .Colon) or_return
			value := tiles_expect(p, .Bool_Lit) or_return
			tile.solid = value.bool_value
			saw_solid = true
		case .Tags:
			if saw_tags {
				return Tileset_Tile{}, .Malformed_Source
			}
			tile.tags = tiles_parse_tags_field(p) or_return
			saw_tags = true
		case:
			return Tileset_Tile{}, .Malformed_Source
		}
		tiles_require_sep_or_close(p) or_return
	}
	tiles_expect(p, .R_Brace) or_return
	// Grammar floor first (TileField+ admits no empty block), then the named
	// semantic floor for each required field.
	if !saw_cell && !saw_solid && !saw_tags {
		return Tileset_Tile{}, .Malformed_Source
	}
	if !saw_cell {
		return Tileset_Tile{}, .Missing_Tile_Cell
	}
	if !saw_solid {
		return Tileset_Tile{}, .Missing_Tile_Solid
	}
	return tile, .None
}

// tiles_parse_cell_field parses `cell : ( INT , INT )` — the tile's atlas grid
// coordinate. The tuple's comma is the literal grammar terminal (never a Sep),
// so the coordinate reads exactly as written.
tiles_parse_cell_field :: proc(p: ^Tiles_Parser) -> (x: i64, y: i64, err: Importer_Error) {
	tiles_expect(p, .Cell) or_return
	tiles_expect(p, .Colon) or_return
	tiles_expect(p, .L_Paren) or_return
	x_tok := tiles_expect(p, .Int_Lit) or_return
	tiles_expect(p, .Comma) or_return
	y_tok := tiles_expect(p, .Int_Lit) or_return
	tiles_expect(p, .R_Paren) or_return
	return x_tok.int_value, y_tok.int_value, .None
}

// tiles_parse_tags_field parses `tags : [ (String (',' String)*)? ]` — the
// optional tag list. `[]` is the empty list; elements are comma-separated with
// no trailing comma (the grammar's literal comma, not a Sep), collected in
// source order.
tiles_parse_tags_field :: proc(p: ^Tiles_Parser) -> (tags: []string, err: Importer_Error) {
	tiles_expect(p, .Tags) or_return
	tiles_expect(p, .Colon) or_return
	tiles_expect(p, .L_Bracket) or_return
	list := make([dynamic]string, 0, 2, context.temp_allocator)
	if tiles_peek(p).kind == .String_Lit {
		first := tiles_expect(p, .String_Lit) or_return
		append(&list, first.text)
		for tiles_peek(p).kind == .Comma {
			p.pos += 1
			item := tiles_expect(p, .String_Lit) or_return
			append(&list, item.text)
		}
	}
	tiles_expect(p, .R_Bracket) or_return
	return list[:], .None
}

// tiles_skip_balanced_parens consumes a balanced `( … )` group — a directive's
// argument list, whose interior is metadata this importer does not lift. A
// missing opener, an unbalanced group, or an Invalid token inside is malformed
// (the fpm_import_skip_balanced_parens mold).
tiles_skip_balanced_parens :: proc(p: ^Tiles_Parser) -> Importer_Error {
	if _, e := tiles_expect(p, .L_Paren); e != .None {
		return .Malformed_Source
	}
	depth := 1
	for depth > 0 {
		if tiles_at_end(p) {
			return .Malformed_Source
		}
		#partial switch tiles_peek(p).kind {
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

// ── Parser plumbing ──────────────────────────────────────────────────────

Tiles_Parser :: struct {
	tokens: []Tiles_Token,
	pos:    int,
}

tiles_at_end :: proc(p: ^Tiles_Parser) -> bool {
	return p.pos >= len(p.tokens)
}

// tiles_peek reports an Invalid token at end of input so a kind check fails
// closed without a separate end test.
tiles_peek :: proc(p: ^Tiles_Parser) -> Tiles_Token {
	if tiles_at_end(p) {
		return Tiles_Token{kind = .Invalid}
	}
	return p.tokens[p.pos]
}

tiles_expect :: proc(p: ^Tiles_Parser, kind: Tiles_Token_Kind) -> (tok: Tiles_Token, err: Importer_Error) {
	tok = tiles_peek(p)
	if tok.kind != kind {
		return Tiles_Token{}, .Malformed_Source
	}
	p.pos += 1
	return tok, .None
}

// tiles_expect_ident expects an identifier of the given case class — the
// lexical-core §2 upper/lower split the grammar makes load-bearing (a
// lower-case tileset name or an upper-case tile name is out of grammar
// position, so a wrong case is the same grammar reject as a wrong token).
tiles_expect_ident :: proc(p: ^Tiles_Parser, case_class: Tiles_Ident_Case) -> (tok: Tiles_Token, err: Importer_Error) {
	tok = tiles_peek(p)
	if tok.kind != .Ident || tok.case_class != case_class {
		return Tiles_Token{}, .Malformed_Source
	}
	p.pos += 1
	return tok, .None
}

// tiles_skip_seps consumes a (NEWLINE | ',')* run — the lexical-core §8 Sep
// the grammar separates members and fields with, leading/trailing separators
// tolerated around brace bodies (the flvl/fcfg reading).
tiles_skip_seps :: proc(p: ^Tiles_Parser) {
	for tiles_peek(p).kind == .Newline || tiles_peek(p).kind == .Comma {
		p.pos += 1
	}
}

// tiles_require_sep_or_close enforces the Sep BETWEEN items: after a member or
// field, the next token must be a separator (then any run of them is skipped)
// or the body's closing brace — two items butted together with no separator
// violate the `(Sep Item)*` production.
tiles_require_sep_or_close :: proc(p: ^Tiles_Parser) -> Importer_Error {
	#partial switch tiles_peek(p).kind {
	case .Newline, .Comma:
		tiles_skip_seps(p)
		return .None
	case .R_Brace:
		return .None
	}
	return .Malformed_Source
}

// ── .tiles lexer ─────────────────────────────────────────────────────────
// Tiles_Token_Kind is the closed token set the .tiles surface needs. The
// tileset/atlas/tile keywords open the productions; cell/solid/tags open the
// tile fields; Ident carries its lexical-core case class; Int_Lit/Bool_Lit/
// String_Lit are the atoms; Directive is an `@name` metadata opener; Newline
// is the Sep half the parser tolerates alongside Comma.
Tiles_Token_Kind :: enum {
	Invalid, // end of input or an unrecognized glyph
	Tileset,
	Atlas,
	Tile,
	Cell,
	Solid,
	Tags,
	Ident,
	Int_Lit,
	Bool_Lit,
	String_Lit,
	Directive, // `@` + a directive name run (text carries the name, no `@`)
	L_Brace,
	R_Brace,
	L_Paren,
	R_Paren,
	L_Bracket,
	R_Bracket,
	Comma,
	Colon,
	Newline, // item separator (the grammar also accepts `,`; the parser tolerates either)
}

// Tiles_Ident_Case is the upper/lower split the tiles grammar reads
// (UPPER_IDENT for the tileset name, LOWER_IDENT for atlas and tile names).
// The lexer decides the class by first letter alone (lexical-core §2), so the
// parser only ever asks "upper or lower" of a name's grammar position.
Tiles_Ident_Case :: enum {
	None,  // non-identifier tokens
	Upper, // the tileset name (UPPER_IDENT)
	Lower, // an atlas or tile name (LOWER_IDENT)
}

Tiles_Token :: struct {
	kind:       Tiles_Token_Kind,
	text:       string,
	case_class: Tiles_Ident_Case, // Ident first-letter case
	int_value:  i64,              // Int_Lit value (a cell coordinate)
	bool_value: bool,             // Bool_Lit value (the solid verdict)
}

// lex_tiles tokenizes the .tiles surface. It is total: an unrecognized glyph
// becomes an Invalid token for the parser to reject. `//` opens a line comment
// consumed to end-of-line (the config-family flavour); spaces and tabs are
// insignificant; a newline emits a Newline token — the Sep half the grammar
// separates members with (the flvl lexing mold, minus the line counter the
// positionless battery rejects do not consume).
lex_tiles :: proc(content: string) -> []Tiles_Token {
	tokens := make([dynamic]Tiles_Token, 0, 32, context.temp_allocator)
	i := 0
	for i < len(content) {
		ch := content[i]
		switch {
		case ch == '\n':
			append(&tokens, Tiles_Token{kind = .Newline, text = "\n"})
			i += 1
		case ch == ' ' || ch == '\t' || ch == '\r':
			i += 1
		case ch == '/' && i+1 < len(content) && content[i+1] == '/':
			// A `//` line comment runs to end-of-line; the trailing newline is
			// scanned on the next iteration so it still separates the items.
			for i < len(content) && content[i] != '\n' {
				i += 1
			}
		case ch == '"':
			tok, next := tiles_scan_string(content, i)
			append(&tokens, tok)
			i = next
		case ch == '@':
			tok, next := tiles_scan_directive(content, i)
			append(&tokens, tok)
			i = next
		case is_digit(ch):
			tok, next := tiles_scan_number(content, i)
			append(&tokens, tok)
			i = next
		case is_ident_start(ch):
			tok, next := tiles_scan_ident(content, i)
			append(&tokens, tok)
			i = next
		case:
			append(&tokens, tiles_scan_punct(ch))
			i += 1
		}
	}
	return tokens[:]
}

// tiles_scan_string returns the contents between the quotes (a tag, a
// directive's prose argument). An unterminated string (end of input or a
// newline before the closing quote) is Invalid, the parser's reject signal.
tiles_scan_string :: proc(content: string, start: int) -> (tok: Tiles_Token, next: int) {
	i := start + 1
	for i < len(content) && content[i] != '"' && content[i] != '\n' {
		i += 1
	}
	if i >= len(content) || content[i] != '"' {
		return Tiles_Token{kind = .Invalid, text = content[start:i]}, i
	}
	return Tiles_Token{kind = .String_Lit, text = content[start + 1 : i]}, i + 1
}

// tiles_scan_directive scans `@` plus its name run into one Directive token
// whose text is the bare name (`doc`, `gtag`). A lone `@` with no name run is
// Invalid, the parser's reject signal.
tiles_scan_directive :: proc(content: string, start: int) -> (tok: Tiles_Token, next: int) {
	i := start + 1
	for i < len(content) && is_ident_char(content[i]) {
		i += 1
	}
	if i == start + 1 {
		return Tiles_Token{kind = .Invalid, text = content[start:i]}, i
	}
	return Tiles_Token{kind = .Directive, text = content[start + 1 : i]}, i
}

// tiles_scan_number scans an integer literal — cell coordinates are whole-
// number grid indices, so the tiles surface has no fractional literal.
tiles_scan_number :: proc(content: string, start: int) -> (tok: Tiles_Token, next: int) {
	i := start
	for i < len(content) && is_digit(content[i]) {
		i += 1
	}
	text := content[start:i]
	return Tiles_Token{kind = .Int_Lit, text = text, int_value = parse_digits(text)}, i
}

// tiles_scan_ident scans an identifier run, mapping the tiles keywords and the
// lexical-core BOOL literals. A non-keyword run is an Ident carrying its
// first-letter case class.
tiles_scan_ident :: proc(content: string, start: int) -> (tok: Tiles_Token, next: int) {
	i := start
	for i < len(content) && is_ident_char(content[i]) {
		i += 1
	}
	text := content[start:i]
	switch text {
	case "tileset":
		return Tiles_Token{kind = .Tileset, text = text}, i
	case "atlas":
		return Tiles_Token{kind = .Atlas, text = text}, i
	case "tile":
		return Tiles_Token{kind = .Tile, text = text}, i
	case "cell":
		return Tiles_Token{kind = .Cell, text = text}, i
	case "solid":
		return Tiles_Token{kind = .Solid, text = text}, i
	case "tags":
		return Tiles_Token{kind = .Tags, text = text}, i
	case "true":
		return Tiles_Token{kind = .Bool_Lit, text = text, bool_value = true}, i
	case "false":
		return Tiles_Token{kind = .Bool_Lit, text = text, bool_value = false}, i
	}
	return Tiles_Token{kind = .Ident, text = text, case_class = tiles_classify_case(text)}, i
}

// tiles_classify_case decides a name's grammar case from its first letter only
// (the lexical-core §2 upper/lower split). An underscore-led name is Lower —
// lower_start admits `_` — so the parser rejects by position, not the lexer.
tiles_classify_case :: proc(text: string) -> Tiles_Ident_Case {
	first := text[0]
	if first >= 'A' && first <= 'Z' {
		return .Upper
	}
	return .Lower
}

// tiles_scan_punct maps the structural glyphs the tiles surface uses; every
// other single character is Invalid, the parser's reject signal.
tiles_scan_punct :: proc(ch: u8) -> Tiles_Token {
	switch ch {
	case '{':
		return Tiles_Token{kind = .L_Brace, text = "{"}
	case '}':
		return Tiles_Token{kind = .R_Brace, text = "}"}
	case '(':
		return Tiles_Token{kind = .L_Paren, text = "("}
	case ')':
		return Tiles_Token{kind = .R_Paren, text = ")"}
	case '[':
		return Tiles_Token{kind = .L_Bracket, text = "["}
	case ']':
		return Tiles_Token{kind = .R_Bracket, text = "]"}
	case ',':
		return Tiles_Token{kind = .Comma, text = ","}
	case ':':
		return Tiles_Token{kind = .Colon, text = ":"}
	case:
		return Tiles_Token{kind = .Invalid}
	}
}
