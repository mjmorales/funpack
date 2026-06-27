package funpack

TILES_IMPORTER_VERSION :: "tiles@1"

Tileset_Asset :: struct {
	name:      string,
	atlas:     string,
	tiles:     []Tileset_Tile,
	atlas_dep: string,
	hash:      string,
}

Tileset_Tile :: struct {
	name:   string,
	cell_x: i64,
	cell_y: i64,
	solid:  bool,
	tags:   []string,
}

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
	for cursor_peek(p).kind != .R_Brace {
		#partial switch cursor_peek(p).kind {
		case .Atlas:
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
		tiles_require_sep_or_close(p) or_return
	}
	tiles_expect(p, .R_Brace) or_return
	if !saw_atlas {
		return Tileset_Asset{}, .Malformed_Source
	}
	tiles_skip_seps(p)
	if !cursor_at_end(p) {
		return Tileset_Asset{}, .Malformed_Source
	}
	asset.tiles = tiles[:]
	return asset, .None
}

tiles_parse_directives :: proc(p: ^Tiles_Parser) -> Importer_Error {
	for cursor_peek(p).kind == .Directive {
		name := cursor_peek(p).text
		switch name {
		case "doc", "gtag", "todo", "index", "spatial", "migrate", "expose", "server", "client":
		case:
			return .Malformed_Source
		}
		p.pos += 1
		if cursor_peek(p).kind == .L_Paren {
			tiles_skip_balanced_parens(p) or_return
		}
		tiles_skip_seps(p)
	}
	return .None
}

tiles_parse_tile :: proc(p: ^Tiles_Parser) -> (tile: Tileset_Tile, err: Importer_Error) {
	tiles_expect(p, .Tile) or_return
	name := tiles_expect_ident(p, .Lower) or_return
	tile.name = name.text
	tiles_expect(p, .L_Brace) or_return
	tiles_skip_seps(p)

	saw_cell := false
	saw_solid := false
	saw_tags := false
	for cursor_peek(p).kind != .R_Brace {
		#partial switch cursor_peek(p).kind {
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

tiles_parse_tags_field :: proc(p: ^Tiles_Parser) -> (tags: []string, err: Importer_Error) {
	tiles_expect(p, .Tags) or_return
	tiles_expect(p, .Colon) or_return
	tiles_expect(p, .L_Bracket) or_return
	list := make([dynamic]string, 0, 2, context.temp_allocator)
	if cursor_peek(p).kind == .String_Lit {
		first := tiles_expect(p, .String_Lit) or_return
		append(&list, first.text)
		for cursor_peek(p).kind == .Comma {
			p.pos += 1
			item := tiles_expect(p, .String_Lit) or_return
			append(&list, item.text)
		}
	}
	tiles_expect(p, .R_Bracket) or_return
	return list[:], .None
}

tiles_skip_balanced_parens :: proc(p: ^Tiles_Parser) -> Importer_Error {
	return import_skip_balanced_parens(p, Tiles_Token_Kind.L_Paren, Tiles_Token_Kind.R_Paren)
}

Tiles_Parser :: Cursor(Tiles_Token, Tiles_Token_Kind)

tiles_expect :: proc(p: ^Tiles_Parser, kind: Tiles_Token_Kind) -> (tok: Tiles_Token, err: Importer_Error) {
	return import_expect(p, kind, Importer_Error.Malformed_Source)
}

tiles_expect_ident :: proc(p: ^Tiles_Parser, case_class: Tiles_Ident_Case) -> (tok: Tiles_Token, err: Importer_Error) {
	tok = cursor_peek(p)
	if tok.kind != .Ident || tok.case_class != case_class {
		return Tiles_Token{}, .Malformed_Source
	}
	p.pos += 1
	return tok, .None
}

tiles_skip_seps :: proc(p: ^Tiles_Parser) {
	cursor_skip_kinds(p, Tiles_Token_Kind.Newline, Tiles_Token_Kind.Comma)
}

tiles_require_sep_or_close :: proc(p: ^Tiles_Parser) -> Importer_Error {
	#partial switch cursor_peek(p).kind {
	case .Newline, .Comma:
		tiles_skip_seps(p)
		return .None
	case .R_Brace:
		return .None
	}
	return .Malformed_Source
}

Tiles_Token_Kind :: enum {
	Invalid,
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
	Directive,
	L_Brace,
	R_Brace,
	L_Paren,
	R_Paren,
	L_Bracket,
	R_Bracket,
	Comma,
	Colon,
	Newline,
}

Tiles_Ident_Case :: enum {
	None,
	Upper,
	Lower,
}

Tiles_Token :: struct {
	kind:       Tiles_Token_Kind,
	text:       string,
	case_class: Tiles_Ident_Case,
	int_value:  i64,
	bool_value: bool,
}

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

tiles_scan_number :: proc(content: string, start: int) -> (tok: Tiles_Token, next: int) {
	i := start
	for i < len(content) && is_digit(content[i]) {
		i += 1
	}
	text := content[start:i]
	return Tiles_Token{kind = .Int_Lit, text = text, int_value = parse_digits(text)}, i
}

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

tiles_classify_case :: proc(text: string) -> Tiles_Ident_Case {
	first := text[0]
	if first >= 'A' && first <= 'Z' {
		return .Upper
	}
	return .Lower
}

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
