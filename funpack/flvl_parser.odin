package funpack

Flvl_Dim :: enum {
	D2,
	D3,
}

Flvl_Coord :: struct {
	components: []Flvl_Anchor_Expr,
}

Flvl_Item_Kind :: enum {
	Place,
	For,
	Prefab,
	Tilemap,
}

Flvl_Item :: struct {
	kind:  Flvl_Item_Kind,
	index: int,
}

Flvl_Level :: struct {
	name:           string,
	dim:            Flvl_Dim,
	bounds_min:     Flvl_Coord,
	bounds_max:     Flvl_Coord,
	has_bounds:     bool,
	things_module:  string,
	prefabs:        []Flvl_Prefab,
	places:         []Flvl_Place,
	fors:           []Flvl_For,
	tilemaps:       []Flvl_Tilemap,
	items:          []Flvl_Item,
}

Flvl_Tilemap :: struct {
	name:      string,
	cell_size: i64,
	legend:    []Flvl_Legend_Entry,
	rows:      []string,
}

Flvl_Legend_Kind :: enum {
	Tile,
	Spawn,
	Empty,
}

Flvl_Legend_Entry :: struct {
	char:           u8,
	kind:           Flvl_Legend_Kind,
	tile_name:      string,
	spawn_type:     string,
	spawn_name:     string,
	has_spawn_name: bool,
}

Flvl_Place :: struct {
	type_name:     string,
	instance_name: string,
	has_name:      bool,
	params:        []Flvl_Param,
	position:      Flvl_Anchor_Expr,
	facing:        Flvl_Anchor_Expr,
	has_facing:    bool,
}

Flvl_Param :: struct {
	path:  []string,
	value: Flvl_Anchor_Expr,
}

Flvl_Prefab :: struct {
	name:    string,
	places:  []Flvl_Place,
	fors:    []Flvl_For,
	nested:  []Flvl_Prefab,
	items:   []Flvl_Item,
}

Flvl_For :: struct {
	var:    string,
	lo:     Flvl_Anchor_Expr,
	hi:     Flvl_Anchor_Expr,
	places: []Flvl_Place,
	fors:   []Flvl_For,
	nested: []Flvl_Prefab,
	items:  []Flvl_Item,
}

Flvl_Anchor_Expr :: union {
	^Flvl_Int_Expr,
	^Flvl_Fixed_Expr,
	^Flvl_String_Expr,
	^Flvl_Name_Expr,
	^Flvl_Member_Expr,
	^Flvl_Call_Expr,
	^Flvl_Binary_Expr,
	^Flvl_Unary_Expr,
}

Flvl_Int_Expr :: struct {
	value: i64,
}

Flvl_Fixed_Expr :: struct {
	bits: Fixed,
}

Flvl_String_Expr :: struct {
	text: string,
}

Flvl_Name_Expr :: struct {
	name: string,
}

Flvl_Member_Expr :: struct {
	receiver: Flvl_Anchor_Expr,
	member:   string,
}

Flvl_Call_Expr :: struct {
	callee:    Flvl_Anchor_Expr,
	args:      []Flvl_Anchor_Expr,
	arg_names: []string,
}

Flvl_Binary_Expr :: struct {
	op:  Flvl_Token_Kind,
	lhs: Flvl_Anchor_Expr,
	rhs: Flvl_Anchor_Expr,
}

Flvl_Unary_Expr :: struct {
	operand: Flvl_Anchor_Expr,
}

Flvl_Parse_Error :: Sub_Parse_Error

Flvl_Parser :: Cursor(Flvl_Token, Flvl_Token_Kind)

parse_flvl :: proc(source: string) -> (level: Flvl_Level, err: Flvl_Parse_Error) {
	p := Flvl_Parser{tokens = lex_flvl(source)}
	flvl_skip_separators(&p)
	level = parse_flvl_level(&p) or_return
	flvl_skip_separators(&p)
	if !cursor_at_end(&p) {
		return Flvl_Level{}, .Unexpected_Token
	}
	return level, .None
}

parse_flvl_level :: proc(p: ^Flvl_Parser) -> (level: Flvl_Level, err: Flvl_Parse_Error) {
	flvl_expect(p, .Level) or_return
	name := flvl_expect_upper(p) or_return
	level.name = name
	level.dim = flvl_parse_dim(p) or_return
	flvl_expect(p, .L_Brace) or_return

	prefabs := make([dynamic]Flvl_Prefab, 0, 4, context.temp_allocator)
	places := make([dynamic]Flvl_Place, 0, 8, context.temp_allocator)
	fors := make([dynamic]Flvl_For, 0, 4, context.temp_allocator)
	tilemaps := make([dynamic]Flvl_Tilemap, 0, 2, context.temp_allocator)
	items := make([dynamic]Flvl_Item, 0, 16, context.temp_allocator)
	flvl_skip_separators(p)
	for cursor_peek_kind(p) != .R_Brace {
		#partial switch cursor_peek_kind(p) {
		case .Bounds:
			min, max := parse_flvl_bounds(p) or_return
			level.bounds_min = min
			level.bounds_max = max
			level.has_bounds = true
		case .Things:
			level.things_module = parse_flvl_things(p) or_return
		case .Prefab:
			pf := parse_flvl_prefab(p) or_return
			append(&items, Flvl_Item{kind = .Prefab, index = len(prefabs)})
			append(&prefabs, pf)
		case .Place:
			pl := parse_flvl_place(p) or_return
			append(&items, Flvl_Item{kind = .Place, index = len(places)})
			append(&places, pl)
		case .For:
			fr := parse_flvl_for(p) or_return
			append(&items, Flvl_Item{kind = .For, index = len(fors)})
			append(&fors, fr)
		case .Tilemap:
			tm := parse_flvl_tilemap(p) or_return
			append(&items, Flvl_Item{kind = .Tilemap, index = len(tilemaps)})
			append(&tilemaps, tm)
		case .Invalid:
			return Flvl_Level{}, .Unexpected_End
		case:
			return Flvl_Level{}, .Unexpected_Token
		}
		flvl_skip_separators(p)
	}
	flvl_expect(p, .R_Brace) or_return
	level.prefabs = prefabs[:]
	level.places = places[:]
	level.fors = fors[:]
	level.tilemaps = tilemaps[:]
	level.items = items[:]
	return level, .None
}

parse_flvl_tilemap :: proc(p: ^Flvl_Parser) -> (tilemap: Flvl_Tilemap, err: Flvl_Parse_Error) {
	flvl_expect(p, .Tilemap) or_return
	tilemap.name = flvl_expect_lower(p) or_return
	cell_word := flvl_expect(p, .Ident) or_return
	if cell_word.text != "cell" {
		return Flvl_Tilemap{}, .Unexpected_Token
	}
	size_tok := flvl_expect(p, .Int_Lit) or_return
	tilemap.cell_size = size_tok.int_value
	flvl_expect(p, .L_Brace) or_return
	flvl_skip_separators(p)
	tilemap.legend = parse_flvl_legend(p) or_return
	flvl_skip_separators(p)
	flvl_expect(p, .Grid) or_return
	grid_tok := cursor_advance(p) or_return
	if grid_tok.kind == .Invalid {
		return Flvl_Tilemap{}, .Unexpected_End
	}
	if grid_tok.kind != .Triple_String {
		return Flvl_Tilemap{}, .Unexpected_Token
	}
	tilemap.rows = flvl_dedent_grid(grid_tok.text)
	flvl_skip_separators(p)
	flvl_expect(p, .R_Brace) or_return
	return tilemap, .None
}

parse_flvl_legend :: proc(p: ^Flvl_Parser) -> (entries: []Flvl_Legend_Entry, err: Flvl_Parse_Error) {
	flvl_expect(p, .Legend) or_return
	flvl_expect(p, .L_Brace) or_return
	list := make([dynamic]Flvl_Legend_Entry, 0, 8, context.temp_allocator)
	flvl_skip_separators(p)
	for cursor_peek_kind(p) != .R_Brace {
		entry := parse_flvl_legend_entry(p) or_return
		append(&list, entry)
		flvl_skip_separators(p)
	}
	flvl_expect(p, .R_Brace) or_return
	if len(list) == 0 {
		return nil, .Unexpected_Token
	}
	return list[:], .None
}

parse_flvl_legend_entry :: proc(p: ^Flvl_Parser) -> (entry: Flvl_Legend_Entry, err: Flvl_Parse_Error) {
	char_tok := flvl_expect(p, .Char_Lit) or_return
	entry.char = char_tok.char_value
	#partial switch cursor_peek_kind(p) {
	case .Ident:
		entry.kind = .Tile
		entry.tile_name = flvl_expect_lower(p) or_return
	case .Spawn:
		p.pos += 1
		entry.kind = .Spawn
		entry.spawn_type = flvl_expect_upper(p) or_return
		if cursor_peek_kind(p) == .Ident {
			entry.spawn_name = flvl_expect_lower(p) or_return
			entry.has_spawn_name = true
		}
	case .Empty:
		p.pos += 1
		entry.kind = .Empty
	case .Invalid:
		return Flvl_Legend_Entry{}, .Unexpected_End
	case:
		return Flvl_Legend_Entry{}, .Unexpected_Token
	}
	return entry, .None
}

flvl_dedent_grid :: proc(raw: string) -> []string {
	lines := make([dynamic]string, 0, 16, context.temp_allocator)
	start := 0
	for i := 0; i <= len(raw); i += 1 {
		if i == len(raw) || raw[i] == '\n' {
			append(&lines, raw[start:i])
			start = i + 1
		}
	}
	rows := lines[:]
	if len(rows) > 0 && flvl_is_blank_line(rows[0]) {
		rows = rows[1:]
	}
	if len(rows) > 0 && flvl_is_blank_line(rows[len(rows)-1]) {
		rows = rows[:len(rows)-1]
	}
	if len(rows) == 0 {
		return rows
	}
	indent := flvl_leading_whitespace(rows[0])
	for row in rows[1:] {
		indent = flvl_common_prefix(indent, flvl_leading_whitespace(row))
	}
	dedented := make([]string, len(rows), context.temp_allocator)
	for row, i in rows {
		dedented[i] = row[len(indent):]
	}
	return dedented
}

flvl_is_blank_line :: proc(line: string) -> bool {
	for i in 0 ..< len(line) {
		if line[i] != ' ' && line[i] != '\t' && line[i] != '\r' {
			return false
		}
	}
	return true
}

flvl_leading_whitespace :: proc(row: string) -> string {
	i := 0
	for i < len(row) && (row[i] == ' ' || row[i] == '\t') {
		i += 1
	}
	return row[:i]
}

flvl_common_prefix :: proc(a, b: string) -> string {
	limit := min(len(a), len(b))
	i := 0
	for i < limit && a[i] == b[i] {
		i += 1
	}
	return a[:i]
}

flvl_parse_dim :: proc(p: ^Flvl_Parser) -> (dim: Flvl_Dim, err: Flvl_Parse_Error) {
	tok := flvl_expect(p, .Dim) or_return
	switch tok.text {
	case "2d":
		return .D2, .None
	case "3d":
		return .D3, .None
	}
	return .D2, .Unexpected_Token
}

parse_flvl_bounds :: proc(p: ^Flvl_Parser) -> (min: Flvl_Coord, max: Flvl_Coord, err: Flvl_Parse_Error) {
	flvl_expect(p, .Bounds) or_return
	min = parse_flvl_coord(p) or_return
	max = parse_flvl_coord(p) or_return
	return min, max, .None
}

parse_flvl_coord :: proc(p: ^Flvl_Parser) -> (coord: Flvl_Coord, err: Flvl_Parse_Error) {
	flvl_expect(p, .L_Paren) or_return
	components := make([dynamic]Flvl_Anchor_Expr, 0, 3, context.temp_allocator)
	for {
		comp := parse_flvl_unary(p) or_return
		append(&components, comp)
		if cursor_peek_kind(p) != .Comma {
			break
		}
		p.pos += 1
	}
	flvl_expect(p, .R_Paren) or_return
	if len(components) == 0 {
		return Flvl_Coord{}, .Unexpected_Token
	}
	return Flvl_Coord{components = components[:]}, .None
}

parse_flvl_things :: proc(p: ^Flvl_Parser) -> (module: string, err: Flvl_Parse_Error) {
	flvl_expect(p, .Things) or_return
	return flvl_expect_lower(p)
}

parse_flvl_place :: proc(p: ^Flvl_Parser) -> (place: Flvl_Place, err: Flvl_Parse_Error) {
	flvl_expect(p, .Place) or_return
	type_name := flvl_expect_upper(p) or_return
	place.type_name = type_name
	if cursor_peek_kind(p) == .Ident {
		name := flvl_expect_lower(p) or_return
		place.instance_name = name
		place.has_name = true
	}
	if cursor_peek_kind(p) == .L_Brace {
		place.params = parse_flvl_params(p) or_return
	}
	flvl_expect(p, .At) or_return
	place.position = parse_flvl_anchor_expr(p) or_return
	if cursor_peek_kind(p) == .Facing {
		p.pos += 1
		place.facing = parse_flvl_anchor_expr(p) or_return
		place.has_facing = true
	}
	return place, .None
}

parse_flvl_params :: proc(p: ^Flvl_Parser) -> (params: []Flvl_Param, err: Flvl_Parse_Error) {
	flvl_expect(p, .L_Brace) or_return
	list := make([dynamic]Flvl_Param, 0, 4, context.temp_allocator)
	flvl_skip_separators(p)
	for cursor_peek_kind(p) != .R_Brace {
		path := parse_flvl_param_key(p) or_return
		flvl_expect(p, .Colon) or_return
		value := parse_flvl_anchor_expr(p) or_return
		append(&list, Flvl_Param{path = path, value = value})
		flvl_skip_separators(p)
	}
	flvl_expect(p, .R_Brace) or_return
	return list[:], .None
}

parse_flvl_param_key :: proc(p: ^Flvl_Parser) -> (path: []string, err: Flvl_Parse_Error) {
	segments := make([dynamic]string, 0, 3, context.temp_allocator)
	head := flvl_expect_lower(p) or_return
	append(&segments, head)
	for cursor_peek_kind(p) == .Dot {
		p.pos += 1
		seg := flvl_expect_lower(p) or_return
		append(&segments, seg)
	}
	return segments[:], .None
}

parse_flvl_prefab :: proc(p: ^Flvl_Parser) -> (prefab: Flvl_Prefab, err: Flvl_Parse_Error) {
	flvl_expect(p, .Prefab) or_return
	name := flvl_expect_upper(p) or_return
	prefab.name = name
	flvl_expect(p, .L_Brace) or_return
	places, fors, nested, items := parse_flvl_item_body(p) or_return
	flvl_expect(p, .R_Brace) or_return
	prefab.places = places
	prefab.fors = fors
	prefab.nested = nested
	prefab.items = items
	return prefab, .None
}

parse_flvl_for :: proc(p: ^Flvl_Parser) -> (loop: Flvl_For, err: Flvl_Parse_Error) {
	flvl_expect(p, .For) or_return
	loop.var = flvl_expect_lower(p) or_return
	flvl_expect(p, .In) or_return
	loop.lo = parse_flvl_unary(p) or_return
	flvl_expect(p, .Dot_Dot) or_return
	loop.hi = parse_flvl_unary(p) or_return
	flvl_expect(p, .L_Brace) or_return
	places, fors, nested, items := parse_flvl_item_body(p) or_return
	flvl_expect(p, .R_Brace) or_return
	loop.places = places
	loop.fors = fors
	loop.nested = nested
	loop.items = items
	return loop, .None
}

parse_flvl_item_body :: proc(p: ^Flvl_Parser) -> (places: []Flvl_Place, fors: []Flvl_For, nested: []Flvl_Prefab, items: []Flvl_Item, err: Flvl_Parse_Error) {
	place_list := make([dynamic]Flvl_Place, 0, 4, context.temp_allocator)
	for_list := make([dynamic]Flvl_For, 0, 2, context.temp_allocator)
	prefab_list := make([dynamic]Flvl_Prefab, 0, 2, context.temp_allocator)
	item_list := make([dynamic]Flvl_Item, 0, 8, context.temp_allocator)
	flvl_skip_separators(p)
	for cursor_peek_kind(p) != .R_Brace {
		#partial switch cursor_peek_kind(p) {
		case .Place:
			pl := parse_flvl_place(p) or_return
			append(&item_list, Flvl_Item{kind = .Place, index = len(place_list)})
			append(&place_list, pl)
		case .For:
			fr := parse_flvl_for(p) or_return
			append(&item_list, Flvl_Item{kind = .For, index = len(for_list)})
			append(&for_list, fr)
		case .Prefab:
			pf := parse_flvl_prefab(p) or_return
			append(&item_list, Flvl_Item{kind = .Prefab, index = len(prefab_list)})
			append(&prefab_list, pf)
		case .Invalid:
			return nil, nil, nil, nil, .Unexpected_End
		case:
			return nil, nil, nil, nil, .Unexpected_Token
		}
		flvl_skip_separators(p)
	}
	return place_list[:], for_list[:], prefab_list[:], item_list[:], .None
}

parse_flvl_anchor_expr :: proc(p: ^Flvl_Parser) -> (expr: Flvl_Anchor_Expr, err: Flvl_Parse_Error) {
	return parse_flvl_add(p)
}

parse_flvl_add :: proc(p: ^Flvl_Parser) -> (expr: Flvl_Anchor_Expr, err: Flvl_Parse_Error) {
	lhs := parse_flvl_mul(p) or_return
	for cursor_peek_kind(p) == .Plus || cursor_peek_kind(p) == .Minus {
		op := cursor_peek_kind(p)
		p.pos += 1
		rhs := parse_flvl_mul(p) or_return
		node := new(Flvl_Binary_Expr, context.temp_allocator)
		node^ = Flvl_Binary_Expr{op = op, lhs = lhs, rhs = rhs}
		lhs = node
	}
	return lhs, .None
}

parse_flvl_mul :: proc(p: ^Flvl_Parser) -> (expr: Flvl_Anchor_Expr, err: Flvl_Parse_Error) {
	lhs := parse_flvl_unary(p) or_return
	for cursor_peek_kind(p) == .Star || cursor_peek_kind(p) == .Slash {
		op := cursor_peek_kind(p)
		p.pos += 1
		rhs := parse_flvl_unary(p) or_return
		node := new(Flvl_Binary_Expr, context.temp_allocator)
		node^ = Flvl_Binary_Expr{op = op, lhs = lhs, rhs = rhs}
		lhs = node
	}
	return lhs, .None
}

parse_flvl_unary :: proc(p: ^Flvl_Parser) -> (expr: Flvl_Anchor_Expr, err: Flvl_Parse_Error) {
	if cursor_peek_kind(p) == .Minus {
		p.pos += 1
		operand := parse_flvl_unary(p) or_return
		node := new(Flvl_Unary_Expr, context.temp_allocator)
		node^ = Flvl_Unary_Expr{operand = operand}
		return node, .None
	}
	return parse_flvl_postfix(p)
}

parse_flvl_postfix :: proc(p: ^Flvl_Parser) -> (expr: Flvl_Anchor_Expr, err: Flvl_Parse_Error) {
	expr = parse_flvl_atom(p) or_return
	for {
		#partial switch cursor_peek_kind(p) {
		case .Dot:
			p.pos += 1
			member := flvl_expect_lower(p) or_return
			node := new(Flvl_Member_Expr, context.temp_allocator)
			node^ = Flvl_Member_Expr{receiver = expr, member = member}
			expr = node
		case .L_Paren:
			args, names := parse_flvl_call_args(p) or_return
			node := new(Flvl_Call_Expr, context.temp_allocator)
			node^ = Flvl_Call_Expr{callee = expr, args = args, arg_names = names}
			expr = node
		case:
			return expr, .None
		}
	}
}

parse_flvl_call_args :: proc(p: ^Flvl_Parser) -> (args: []Flvl_Anchor_Expr, names: []string, err: Flvl_Parse_Error) {
	flvl_expect(p, .L_Paren) or_return
	arg_list := make([dynamic]Flvl_Anchor_Expr, 0, 4, context.temp_allocator)
	name_list := make([dynamic]string, 0, 4, context.temp_allocator)
	for cursor_peek_kind(p) != .R_Paren {
		name := ""
		if cursor_peek_kind(p) == .Ident && cursor_peek_kind_at(p, 1) == .Colon {
			label := flvl_expect_lower(p) or_return
			flvl_expect(p, .Colon) or_return
			name = label
		}
		arg := parse_flvl_anchor_expr(p) or_return
		append(&arg_list, arg)
		append(&name_list, name)
		if cursor_peek_kind(p) == .Comma {
			p.pos += 1
		} else {
			break
		}
	}
	flvl_expect(p, .R_Paren) or_return
	return arg_list[:], name_list[:], .None
}

parse_flvl_atom :: proc(p: ^Flvl_Parser) -> (expr: Flvl_Anchor_Expr, err: Flvl_Parse_Error) {
	tok := cursor_advance(p) or_return
	#partial switch tok.kind {
	case .Int_Lit:
		node := new(Flvl_Int_Expr, context.temp_allocator)
		node^ = Flvl_Int_Expr{value = tok.int_value}
		return node, .None
	case .Fixed_Lit:
		node := new(Flvl_Fixed_Expr, context.temp_allocator)
		node^ = Flvl_Fixed_Expr{bits = tok.fixed_bits}
		return node, .None
	case .String_Lit:
		node := new(Flvl_String_Expr, context.temp_allocator)
		node^ = Flvl_String_Expr{text = tok.text}
		return node, .None
	case .Ident:
		if tok.case_class != .Lower {
			return nil, .Wrong_Case
		}
		node := new(Flvl_Name_Expr, context.temp_allocator)
		node^ = Flvl_Name_Expr{name = tok.text}
		return node, .None
	case .L_Paren:
		inner := parse_flvl_anchor_expr(p) or_return
		flvl_expect(p, .R_Paren) or_return
		return inner, .None
	}
	if tok.kind == .Invalid {
		return nil, .Unexpected_End
	}
	return nil, .Unexpected_Token
}

flvl_expect :: proc(p: ^Flvl_Parser, kind: Flvl_Token_Kind) -> (tok: Flvl_Token, err: Flvl_Parse_Error) {
	return cursor_expect(p, kind)
}

flvl_expect_upper :: proc(p: ^Flvl_Parser) -> (name: string, err: Flvl_Parse_Error) {
	tok := flvl_expect(p, .Ident) or_return
	if tok.case_class != .Upper {
		return "", .Wrong_Case
	}
	return tok.text, .None
}

flvl_expect_lower :: proc(p: ^Flvl_Parser) -> (name: string, err: Flvl_Parse_Error) {
	tok := flvl_expect(p, .Ident) or_return
	if tok.case_class != .Lower {
		return "", .Wrong_Case
	}
	return tok.text, .None
}

flvl_skip_separators :: proc(p: ^Flvl_Parser) {
	cursor_skip_kinds(p, Flvl_Token_Kind.Newline, Flvl_Token_Kind.Comma)
}
