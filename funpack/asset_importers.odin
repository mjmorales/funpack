package funpack

import "core:bytes"
import png "core:image/png"

MODEL_IMPORTER_VERSION :: "model@3"
ATLAS_IMPORTER_VERSION :: "atlas@2"
AUDIO_IMPORTER_VERSION :: "audio@1"
IMAGE_IMPORTER_VERSION :: "image@1"

Importer_Error :: enum {
	None,
	Malformed_Source,
	Missing_Tile_Cell,
	Missing_Tile_Solid,
	Duplicate_Tile_Name,
	Malformed_Image,
}

Model_Asset :: struct {
	name:      string,
	params:    []Model_Param,
	emit_prim: string,
	emit_args: []string,
	material:  string,
	hash:      string,
}

Model_Param :: struct {
	name:    string,
	type:    string,
	default: Fixed,
}

import_model :: proc(src: string, allocator := context.temp_allocator) -> (asset: Model_Asset, err: Importer_Error) {
	p := Fpm_Parser{tokens = fpm_lex(src)}
	asset = fpm_import_model_block(&p) or_return
	asset.hash = asset_content_hash(transmute([]byte)src, MODEL_IMPORTER_VERSION, nil, allocator)
	return asset, .None
}

fpm_import_model_block :: proc(p: ^Fpm_Parser) -> (asset: Model_Asset, err: Importer_Error) {
	if _, e := fpm_expect(p, .Model); e != .None {
		return Model_Asset{}, .Malformed_Source
	}
	name, ne := cursor_advance(p)
	if ne != .None || (name.kind != .Lower_Ident && name.kind != .Upper_Ident) {
		return Model_Asset{}, .Malformed_Source
	}
	asset.name = name.text
	if _, e := fpm_expect(p, .L_Brace); e != .None {
		return Model_Asset{}, .Malformed_Source
	}

	params := make([dynamic]Model_Param, 0, 4, context.temp_allocator)
	saw_emit := false
	fpm_skip_seps(p)
	for cursor_peek_kind(p) != .R_Brace {
		#partial switch cursor_peek_kind(p) {
		case .Param:
			param := fpm_import_param(p) or_return
			append(&params, param)
		case .Emit:
			if saw_emit {
				return Model_Asset{}, .Malformed_Source
			}
			asset.emit_prim, asset.emit_args = fpm_import_emit(p) or_return
			saw_emit = true
		case .Material:
			asset.material = fpm_import_material(p) or_return
		case:
			return Model_Asset{}, .Malformed_Source
		}
		fpm_skip_seps(p)
	}
	if _, e := fpm_expect(p, .R_Brace); e != .None {
		return Model_Asset{}, .Malformed_Source
	}
	asset.params = params[:]
	return asset, .None
}

fpm_import_param :: proc(p: ^Fpm_Parser) -> (param: Model_Param, err: Importer_Error) {
	if _, e := fpm_expect(p, .Param); e != .None {
		return Model_Param{}, .Malformed_Source
	}
	name, ne := cursor_advance(p)
	if ne != .None || (name.kind != .Lower_Ident && name.kind != .Upper_Ident) {
		return Model_Param{}, .Malformed_Source
	}
	if _, e := fpm_expect(p, .Colon); e != .None {
		return Model_Param{}, .Malformed_Source
	}
	type, te := cursor_advance(p)
	if te != .None || (type.kind != .Lower_Ident && type.kind != .Upper_Ident) {
		return Model_Param{}, .Malformed_Source
	}
	if _, e := fpm_expect(p, .Eq); e != .None {
		return Model_Param{}, .Malformed_Source
	}
	value, ve := cursor_advance(p)
	if ve != .None || (value.kind != .Int_Lit && value.kind != .Float_Lit) {
		return Model_Param{}, .Malformed_Source
	}
	param.name = name.text
	param.type = type.text
	param.default = fpm_token_fixed(value)
	return param, .None
}

fpm_import_emit :: proc(p: ^Fpm_Parser) -> (prim: string, args: []string, err: Importer_Error) {
	if _, e := fpm_expect(p, .Emit); e != .None {
		return "", nil, .Malformed_Source
	}
	prim_tok, pe := cursor_advance(p)
	if pe != .None || (prim_tok.kind != .Lower_Ident && prim_tok.kind != .Upper_Ident) {
		return "", nil, .Malformed_Source
	}
	if _, e := fpm_expect(p, .L_Paren); e != .None {
		return "", nil, .Malformed_Source
	}
	arg_list := make([dynamic]string, 0, 2, context.temp_allocator)
	for cursor_peek_kind(p) == .Lower_Ident || cursor_peek_kind(p) == .Upper_Ident {
		arg, _ := cursor_advance(p)
		append(&arg_list, arg.text)
		for cursor_peek_kind(p) == .Comma {
			p.pos += 1
		}
	}
	if _, e := fpm_expect(p, .R_Paren); e != .None {
		return "", nil, .Malformed_Source
	}
	return prim_tok.text, arg_list[:], .None
}

fpm_import_material :: proc(p: ^Fpm_Parser) -> (name: string, err: Importer_Error) {
	if _, e := fpm_expect(p, .Material); e != .None {
		return "", .Malformed_Source
	}
	name_tok, ne := cursor_advance(p)
	if ne != .None || (name_tok.kind != .Lower_Ident && name_tok.kind != .Upper_Ident) {
		return "", .Malformed_Source
	}
	if _, e := fpm_expect(p, .Eq); e != .None {
		return "", .Malformed_Source
	}
	ctor, ce := cursor_advance(p)
	if ce != .None || (ctor.kind != .Lower_Ident && ctor.kind != .Upper_Ident) {
		return "", .Malformed_Source
	}
	fpm_import_skip_balanced_parens(p) or_return
	return name_tok.text, .None
}

fpm_import_skip_balanced_parens :: proc(p: ^Fpm_Parser) -> Importer_Error {
	return import_skip_balanced_parens(p, Fpm_Token_Kind.L_Paren, Fpm_Token_Kind.R_Paren)
}

fpm_token_fixed :: proc(tok: Fpm_Token) -> Fixed {
	if tok.kind == .Int_Lit {
		return to_fixed(tok.int_value)
	}
	text := tok.text
	if len(text) > 0 && text[len(text) - 1] == 'f' {
		text = text[:len(text) - 1]
	}
	for i in 0 ..< len(text) {
		if text[i] == '.' {
			return fixed_from_decimal(parse_digits(text[:i]), text[i + 1:])
		}
	}
	return to_fixed(parse_digits(text))
}

Atlas_Asset :: struct {
	name:        string,
	image:       string,
	grid_w:      i64,
	grid_h:      i64,
	cells:       []Atlas_Cell,
	clips:       []Atlas_Clip,
	image_dep:   string,
	hash:        string,
}

Atlas_Cell :: struct {
	name: string,
	x:    i64,
	y:    i64,
}

Atlas_Clip :: struct {
	name:   string,
	frames: []string,
	fps:    i64,
}

import_atlas :: proc(src: string, dep_hashes: []string, allocator := context.temp_allocator) -> (asset: Atlas_Asset, err: Importer_Error) {
	p := Atlas_Parser{tokens = lex_atlas(src)}
	asset = atlas_parse(&p) or_return
	if len(dep_hashes) != 1 {
		return Atlas_Asset{}, .Malformed_Source
	}
	asset.image_dep = dep_hashes[0]
	asset.hash = asset_content_hash(transmute([]byte)src, ATLAS_IMPORTER_VERSION, dep_hashes, allocator)
	return asset, .None
}

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
	for cursor_peek(p).kind != .R_Brace {
		switch cursor_peek(p).kind {
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

atlas_parse_clip :: proc(p: ^Atlas_Parser, declared: map[string]bool) -> (clip: Atlas_Clip, err: Importer_Error) {
	atlas_expect(p, .Clip) or_return
	name := atlas_expect(p, .Ident) or_return
	atlas_expect(p, .Cells) or_return
	atlas_expect(p, .L_Bracket) or_return
	frames := make([dynamic]string, 0, 4, context.temp_allocator)
	for cursor_peek(p).kind == .String {
		frame := atlas_expect(p, .String) or_return
		if !(frame.text in declared) {
			return Atlas_Clip{}, .Malformed_Source
		}
		append(&frames, frame.text)
		for cursor_peek(p).kind == .Comma {
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

Imported_Asset :: union {
	Model_Asset,
	Atlas_Asset,
	Audio_Asset,
	Tileset_Asset,
	Image_Asset,
}

import_asset :: proc(kind: Asset_Kind, src: []byte, dep_hashes: []string, allocator := context.temp_allocator) -> (asset: Imported_Asset, err: Importer_Error) {
	switch kind {
	case .Model:
		model := import_model(string(src), allocator) or_return
		return model, .None
	case .Atlas:
		atlas := import_atlas(string(src), dep_hashes, allocator) or_return
		return atlas, .None
	case .Audio:
		audio := import_audio(src, allocator) or_return
		return audio, .None
	case .Tileset:
		tileset := import_tileset(string(src), dep_hashes, allocator) or_return
		return tileset, .None
	case .Image:
		image := import_image(src, allocator) or_return
		return image, .None
	}
	return nil, .Malformed_Source
}

Audio_Asset :: struct {
	hash: string,
}

import_audio :: proc(bytes: []byte, allocator := context.temp_allocator) -> (asset: Audio_Asset, err: Importer_Error) {
	asset.hash = asset_content_hash(bytes, AUDIO_IMPORTER_VERSION, nil, allocator)
	return asset, .None
}

Image_Asset :: struct {
	width:  int,
	height: int,
	pixels: []byte,
	hash:   string,
}

import_image :: proc(bytes_in: []byte, allocator := context.temp_allocator) -> (asset: Image_Asset, err: Importer_Error) {
	asset.hash = asset_content_hash(bytes_in, IMAGE_IMPORTER_VERSION, nil, allocator)
	img, decode_err := png.load_from_bytes(bytes_in, png.Options{.alpha_add_if_missing}, context.allocator)
	defer png.destroy(img)
	if decode_err != nil {
		return Image_Asset{}, .Malformed_Image
	}
	asset.width = img.width
	asset.height = img.height
	decoded := bytes.buffer_to_bytes(&img.pixels)
	pixels := make([]byte, len(decoded), allocator)
	copy(pixels, decoded)
	asset.pixels = pixels
	return asset, .None
}

Atlas_Token_Kind :: enum {
	Invalid,
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
	int_value: i64,
}

Atlas_Parser :: Cursor(Atlas_Token, Atlas_Token_Kind)

atlas_expect :: proc(p: ^Atlas_Parser, kind: Atlas_Token_Kind) -> (tok: Atlas_Token, err: Importer_Error) {
	return import_expect(p, kind, Importer_Error.Malformed_Source)
}

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

atlas_scan_number :: proc(content: string, start: int) -> (tok: Atlas_Token, next: int) {
	i := start
	for i < len(content) && is_digit(content[i]) {
		i += 1
	}
	text := content[start:i]
	return Atlas_Token{kind = .Number, text = text, int_value = parse_digits(text)}, i
}

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
