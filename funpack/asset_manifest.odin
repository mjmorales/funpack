package funpack

Asset_Kind :: enum {
	Model,
	Atlas,
	Audio,
	Tileset,
	Image,
}

Asset_Entry :: struct {
	name:             string,
	kind:             Asset_Kind,
	source:           string,
	importer_version: string,
	deps:             []string,
	hash:             string,
	out:              string,
}

Asset_Manifest :: struct {
	entries: []Asset_Entry,
}

Asset_Manifest_Error :: enum {
	None,
	Malformed_Manifest,
	Unknown_Kind,
	Missing_Key,
	Duplicate_Name,
}

read_asset_manifest :: proc(content: string) -> (manifest: Asset_Manifest, err: Asset_Manifest_Error) {
	p := Manifest_Parser{tokens = lex_manifest(content)}
	entries := make([dynamic]Asset_Entry, 0, 4, context.temp_allocator)
	seen := make(map[string]bool, context.temp_allocator)
	for !cursor_at_end(&p) {
		if cursor_peek(&p).kind != .L_Bracket {
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
	for cursor_peek(p).kind == .Word {
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

manifest_parse_list :: proc(p: ^Manifest_Parser) -> (items: []string, err: Asset_Manifest_Error) {
	manifest_expect(p, .L_Bracket) or_return
	list := make([dynamic]string, 0, 2, context.temp_allocator)
	for cursor_peek(p).kind == .String {
		item := manifest_expect(p, .String) or_return
		append(&list, item.text)
		for cursor_peek(p).kind == .Comma {
			p.pos += 1
		}
	}
	manifest_expect(p, .R_Bracket) or_return
	return list[:], .None
}

Manifest_Token_Kind :: enum {
	Invalid,
	Word,
	String,
	Eq,
	L_Bracket,
	R_Bracket,
	Comma,
}

Manifest_Token :: struct {
	kind: Manifest_Token_Kind,
	text: string,
}

Manifest_Parser :: Cursor(Manifest_Token, Manifest_Token_Kind)

manifest_expect :: proc(p: ^Manifest_Parser, kind: Manifest_Token_Kind) -> (tok: Manifest_Token, err: Asset_Manifest_Error) {
	return import_expect(p, kind, Asset_Manifest_Error.Malformed_Manifest)
}

lex_manifest :: proc(content: string) -> []Manifest_Token {
	tokens := make([dynamic]Manifest_Token, 0, 32, context.temp_allocator)
	i := 0
	for i < len(content) {
		ch := content[i]
		switch {
		case ch == ' ' || ch == '\t' || ch == '\r' || ch == '\n':
			i += 1
		case ch == '#':
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

is_manifest_word_char :: proc(ch: u8) -> bool {
	return is_ident_char(ch) || ch == '.'
}
