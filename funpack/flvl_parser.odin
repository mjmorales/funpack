// Parser for the §17 flat-text level grammar (`.flvl`), over the dedicated
// lexer (flvl_lexer.odin). It builds a parse-only AST: NO name resolution, NO
// schema check, NO Ref typing — turning a bare-name param value or a dotted
// override into a typed Ref[T], expanding prefabs and loops, and the §17.4 bake
// gates are all the bake story's, downstream of this seam. This stage answers
// one question only: does the source match the grammar (grammar/flvl.ebnf)?
//
// The grammar is NOT held to LL(1) (grammar/flvl.ebnf §0) — anchor positions
// carry full offset arithmetic — so positions route through a small Pratt-free
// precedence cascade (parse_anchor_expr: add → mul → unary → postfix → atom),
// paralleling the `.fun` expression ladder but over the level token set. Every
// other production opens on a unique keyword (level/place/prefab/for/bounds/
// things), so the item-dispatch loop is single-token.
//
// Item separators: the grammar separates items by newline OR comma; both are
// tolerated and skipped between items (flvl_skip_separators), so a level body,
// a param block, a prefab body, and a for-loop body all read the same way.
package funpack

// Flvl_Dim is the level's coordinate arity (grammar/flvl.ebnf Dim): a `2d`
// level uses `(x, y)` coordinates and an angle `facing`; a `3d` level uses
// `(x, y, z)` and an orientation. The arity check against a placed thing's
// `pos` is the bake story's; this stage records the header word only.
Flvl_Dim :: enum {
	D2, // `2d`
	D3, // `3d`
}

// Flvl_Coord is a parenthesized coordinate tuple `(n, n[, n])` (the bounds
// corners). Arity is semantic (it must match Dim), validated by the bake; the
// parser records the numbers as written. Each component is a Number atom (Int
// or Fixed), retained as a parsed anchor-expression atom so the coordinate and
// the offset grammars share one number representation.
Flvl_Coord :: struct {
	components: []Flvl_Anchor_Expr,
}

// Flvl_Item_Kind is the closed set of body-item forms a level, prefab, or
// for-loop body holds (grammar/flvl.ebnf LevelItem/PrefabItem): a placement, a
// for-loop, a nested prefab declaration, or — at level depth only — a §18 §3
// tilemap layer. It is the discriminant of an Flvl_Item, which records the
// source ORDER of the body's items across the kinds.
Flvl_Item_Kind :: enum {
	Place,
	For,
	Prefab,
	Tilemap, // a LevelItem only — prefab/for bodies admit no tilemap (grammar/flvl.ebnf PrefabItem)
}

// Flvl_Item records one body item's kind and its index into the matching
// per-kind slice (places/fors/prefabs), in SOURCE ORDER. The parser keeps the
// per-kind slices (each production's natural home) AND this interleaved order
// record, because §17.4 spawn order is DECLARATION order across all item kinds
// (a `for` loop between two `place`s expands between them) — an order the
// per-kind slices alone cannot reconstruct. The bake walks `items` to expand in
// declaration order; a parse-shape consumer that only needs counts reads the
// slices.
Flvl_Item :: struct {
	kind:  Flvl_Item_Kind,
	index: int, // index into places/fors/prefabs for `kind`
}

// Flvl_Level is one `level <Name> 2d|3d { … }` block (grammar/flvl.ebnf
// LevelBlock). It is the parse root for a single level: its name and dimension
// header, the two bounds corners, the schema module the `things` line names,
// and the top-level prefab declarations, placements, and for-loops. The per-kind
// slices group items by production; `items` records their interleaved source
// order (the declaration order §17.4's spawn list requires). things_module is
// the LOWER_IDENT schema module whose thing types this level places; it is ""
// when the (optional in the AST, required by the bake) `things` line is absent so
// the parser does not conflate a missing line with a grammar error here.
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
	items:          []Flvl_Item, // body items in source order (declaration-order spawn list)
}

// Flvl_Tilemap is one `tilemap <name> cell <N> { legend { … } grid """…""" }`
// layer (grammar/flvl.ebnf Tilemap, spec §18 §3): the layer's LOWER_IDENT name,
// the per-cell logical size after the CONTEXTUAL `cell` word, the legend's
// char→bind entries in declaration order, and the grid's DEDENTED rows. The
// rows carry the common-leading-indentation strip the grammar mandates (so a
// grid indented to block depth carries no phantom legend columns); the §18 §5
// rectangularity gate over the dedented rows is the bake's, downstream.
Flvl_Tilemap :: struct {
	name:      string,
	cell_size: i64,
	legend:    []Flvl_Legend_Entry,
	rows:      []string, // dedented grid rows, top-to-bottom (row-major source order)
}

// Flvl_Legend_Kind is the closed LegendBind form set (grammar/flvl.ebnf
// LegendBind): a tile name (static environment, resolved project-globally at
// bake), a spawn marker (an entity), or the explicit empty cell.
Flvl_Legend_Kind :: enum {
	Tile,
	Spawn,
	Empty,
}

// Flvl_Legend_Entry is one `<char> <bind>` legend line (spec §18 §3): the
// single legend char and its bind. tile_name carries a .Tile bind's
// LOWER_IDENT; spawn_type/spawn_name carry a .Spawn bind's UPPER_IDENT thing
// type and its optional LOWER_IDENT marker name (has_spawn_name distinguishes
// the named `'P' spawn Player hero` from the anonymous `'g' spawn Goblin`).
Flvl_Legend_Entry :: struct {
	char:           u8,
	kind:           Flvl_Legend_Kind,
	tile_name:      string, // .Tile: the project-global tile name
	spawn_type:     string, // .Spawn: the marker's thing type (UPPER_IDENT)
	spawn_name:     string, // .Spawn: the optional unique marker name
	has_spawn_name: bool,
}

// Flvl_Place is one `place <Type> [<name>] { params }? at <where> [facing
// <rot>]` placement (grammar/flvl.ebnf Placement). type_name is the placed
// thing or prefab type (UPPER_IDENT); instance_name is the optional stable name
// (LOWER_IDENT) — empty for anonymous one-off scenery, which the seam does not
// expose, distinguished by has_name. params are the inline blackboard-field
// assignments and dotted-path overrides; position is the required `at <where>`
// anchor; facing is the optional `facing <rot>` orientation, present per
// has_facing.
Flvl_Place :: struct {
	type_name:     string,
	instance_name: string,
	has_name:      bool,
	params:        []Flvl_Param,
	position:      Flvl_Anchor_Expr,
	facing:        Flvl_Anchor_Expr,
	has_facing:    bool,
}

// Flvl_Param is one `<key>: <expr>` param entry (grammar/flvl.ebnf ParamEntry).
// key is the dotted ParamKey path: a single LOWER_IDENT field
// (`rate`), or a dotted path into a nested prefab member (`cannon.rate`,
// `right_gun.cannon.rate`). path holds the dotted segments in order, so a flat
// field has one segment and an override has more. value is the param's
// expression: a bare-name (resolving to a Ref[T] at bake) or any anchor
// expression — both parse as an Flvl_Anchor_Expr here.
Flvl_Param :: struct {
	path:  []string,
	value: Flvl_Anchor_Expr,
}

// Flvl_Prefab is one `prefab <Name> { … }` declaration (grammar/flvl.ebnf
// Prefab): a named bundle of placements, nested for-loops, and nested prefabs.
// Prefabs nest to arbitrary depth — a prefab body holds child prefabs — so nested
// holds the inner prefab declarations recursively. The per-kind slices group the
// body by production; `items` records their interleaved source order (the
// declaration order a stamp expands members in).
Flvl_Prefab :: struct {
	name:    string,
	places:  []Flvl_Place,
	fors:    []Flvl_For,
	nested:  []Flvl_Prefab,
	items:   []Flvl_Item, // body items in source order
}

// Flvl_For is one `for <i> in <lo>..<hi> { … }` repetition (grammar/flvl.ebnf
// ForLoop): the loop var name, the inclusive-low/exclusive-high range bounds as
// written, and the body's placements, nested for-loops, and nested prefabs. The
// bounds are Number atoms (Int/Fixed), parsed as anchor-expression atoms; the
// loop var is in scope inside body offsets (`center.offset(x: -48 + i * 24)`),
// resolved at bake. `items` records the body's interleaved source order, walked
// per iteration so a loop body expands in declaration order.
Flvl_For :: struct {
	var:    string,
	lo:     Flvl_Anchor_Expr,
	hi:     Flvl_Anchor_Expr,
	places: []Flvl_Place,
	fors:   []Flvl_For,
	nested: []Flvl_Prefab,
	items:  []Flvl_Item, // body items in source order
}

// Flvl_Anchor_Expr is the position/offset/value expression node
// (grammar/flvl.ebnf AnchorExpr): the kill-raw-coordinates grammar of anchors,
// instance-relative references, sockets, `.offset(…)`, the loop var, number
// literals, and integer arithmetic. A discriminated union of a small closed set
// of forms — the `.fun` expression union's level-grammar parallel — built
// parse-only with no resolution of an anchor name (`center`, `base`) to a
// concrete coordinate.
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

// Flvl_Int_Expr / Flvl_Fixed_Expr are the Number atoms (offset constants,
// coordinate components, range bounds); coordinates are fixed-point at bake, but
// the parser keeps the literal as written (Int or Fixed).
Flvl_Int_Expr :: struct {
	value: i64,
}

Flvl_Fixed_Expr :: struct {
	bits: Fixed,
}

// Flvl_String_Expr is a string atom — the socket-name argument of
// `table.socket("cup")` (grammar/flvl.ebnf AnchorAtom).
Flvl_String_Expr :: struct {
	text: string,
}

// Flvl_Name_Expr is a bare LOWER_IDENT atom: an anchor (`center`,
// `left_edge`), an instance-relative base (`base`), or the loop var (`i`) —
// which one resolves semantically at bake, not here.
Flvl_Name_Expr :: struct {
	name: string,
}

// Flvl_Member_Expr is a `.sub` postfix step (grammar/flvl.ebnf PostfixOp):
// `center.offset`, `base.top`, `right_edge.center`. The dotted sub-path off an
// anchor is built as a chain of Member_Expr over the base atom, so a position's
// `anchor.sub.offset(…)` is a Member/Call chain the bake walks.
Flvl_Member_Expr :: struct {
	receiver: Flvl_Anchor_Expr,
	member:   string,
}

// Flvl_Call_Expr is a call postfix step (grammar/flvl.ebnf PostfixOp/CallArgs):
// `offset(x: 6, y: -4)`, `socket("cup")`, `left_of(door, 2)`, `cell(5, 3)`.
// args carries the positional or named arguments; arg_names carries each arg's
// `name:` label ("" for a positional arg) parallel to args, so the named-arg
// `offset(x:, y:)` form survives the parse.
Flvl_Call_Expr :: struct {
	callee:    Flvl_Anchor_Expr,
	args:      []Flvl_Anchor_Expr,
	arg_names: []string,
}

// Flvl_Binary_Expr is an offset-arithmetic binary op (`+`, `-`, `*`, `/`):
// `-48 + i * 24`. Left-associative, with `* /` binding tighter than `+ -`
// (grammar/flvl.ebnf AddExpr/MulExpr).
Flvl_Binary_Expr :: struct {
	op:  Flvl_Token_Kind, // Plus, Minus, Star, or Slash
	lhs: Flvl_Anchor_Expr,
	rhs: Flvl_Anchor_Expr,
}

// Flvl_Unary_Expr is a unary negation (`-i`, `-48`) — the leading-minus form of
// grammar/flvl.ebnf UnaryExpr.
Flvl_Unary_Expr :: struct {
	operand: Flvl_Anchor_Expr,
}

// Flvl_Parse_Error is the shared sub-language verdict set (parser_cursor.odin):
// Unexpected_Token is a token out of grammar position, Unexpected_End is input
// ending mid-production (an unterminated block), and Wrong_Case is a name whose
// first-letter case is wrong for its position (a lower-case placed type, an
// upper-case instance name). The bake-stage gates (unresolved names, type
// mismatches, out-of-bounds) are NOT parse errors — they need resolution this
// stage does not do.
Flvl_Parse_Error :: Sub_Parse_Error

// Flvl_Parser binds the shared Cursor to the .flvl token/kind pair; the cursor
// mechanism (peek/advance/expect/skip) lives in parser_cursor.odin.
Flvl_Parser :: Cursor(Flvl_Token, Flvl_Token_Kind)

// parse_flvl is the entry seam: it parses a single `level … { … }` block from a
// level source's tokens. Leading separators are skipped, the one level block is
// parsed, and any trailing separators are consumed; a token after the block (a
// second `level`, stray input) is Unexpected_Token. The §17.4 `include` split
// across files is out of this seam's scope — it rides the streaming story.
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

// parse_flvl_level parses the `level <Name> 2d|3d { LevelItem* }` block
// (grammar/flvl.ebnf LevelBlock). The name is UPPER_IDENT; the dimension word
// follows; the body dispatches its items off their unique opening keyword:
// `bounds`, `things`, `prefab`, `place`, `for`, and `tilemap`.
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

// parse_flvl_tilemap parses one `tilemap <name> cell <N> { Sep? Legend Sep Grid
// Sep? }` layer (grammar/flvl.ebnf Tilemap, spec §18 §3). `cell` is the
// CONTEXTUAL keyword: it lexes as an ordinary LOWER_IDENT (it is also the
// `cell(col, row)` anchor callee), so the header matches the Ident's TEXT —
// any other word there is out of grammar position. The body is fixed-order:
// the legend block, then the grid block.
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
		// An unterminated `"""` block lexes Invalid (the input ended inside the
		// grid) — the parse_flvl_atom mold's Invalid→Unexpected_End reading.
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

// parse_flvl_legend parses `legend '{' LegendEntry (Sep LegendEntry)* Sep? '}'`
// (grammar/flvl.ebnf Legend): each entry is a Char literal then its bind — a
// LOWER_IDENT tile name, `spawn <Type> [<name>]`, or `empty`. At least one
// entry is required (the production admits no empty legend); entries keep
// declaration order, the order the §18 §3 resolution and the baked palette
// read.
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

// parse_flvl_legend_entry parses one `Char LegendBind` line (grammar/flvl.ebnf
// LegendEntry): the legend char, then the bind dispatched on its opening
// token — a LOWER_IDENT is a tile, `spawn` opens a marker (UPPER_IDENT type,
// optional LOWER_IDENT unique name), `empty` is the explicit empty cell.
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
		// The optional marker name: a LOWER_IDENT before the entry separator
		// names the marker (`'P' spawn Player hero`); its absence is the
		// anonymous repeat-freely form.
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

// flvl_dedent_grid lowers a grid block's raw triple-string interior to its
// dedented rows (grammar/flvl.ebnf Grid): the normative common-leading-
// indentation strip that runs BEFORE the §18 §5 rectangularity gate, so a grid
// indented to block depth carries no phantom legend columns. The first line
// (the run between the opening fence and its newline) and the last line (the
// closing fence's indentation) are dropped when whitespace-only — they are
// layout, not rows. The common indent is the longest shared leading-whitespace
// PREFIX across the retained rows; a row legitimately opening with a legend
// space narrows the common prefix for every row, so meaningful leading chars
// are never eaten.
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

// flvl_is_blank_line reports whether a grid line is whitespace-only — the
// opening-fence remainder and the closing-fence indentation the dedent drops.
flvl_is_blank_line :: proc(line: string) -> bool {
	for i in 0 ..< len(line) {
		if line[i] != ' ' && line[i] != '\t' && line[i] != '\r' {
			return false
		}
	}
	return true
}

// flvl_leading_whitespace returns a row's leading space/tab run — one side of
// the common-indent fold.
flvl_leading_whitespace :: proc(row: string) -> string {
	i := 0
	for i < len(row) && (row[i] == ' ' || row[i] == '\t') {
		i += 1
	}
	return row[:i]
}

// flvl_common_prefix returns the longest shared prefix of two whitespace runs —
// the fold step that narrows the common indent to what EVERY row carries.
flvl_common_prefix :: proc(a, b: string) -> string {
	limit := min(len(a), len(b))
	i := 0
	for i < limit && a[i] == b[i] {
		i += 1
	}
	return a[:i]
}

// flvl_parse_dim reads the `2d`/`3d` header word (grammar/flvl.ebnf Dim).
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

// parse_flvl_bounds parses `bounds (n, n) (n, n)` — the two corner coordinates
// (grammar/flvl.ebnf Bounds). Coordinate arity is semantic (must match Dim),
// the bake's check; the parser reads each `( … )` tuple as written.
parse_flvl_bounds :: proc(p: ^Flvl_Parser) -> (min: Flvl_Coord, max: Flvl_Coord, err: Flvl_Parse_Error) {
	flvl_expect(p, .Bounds) or_return
	min = parse_flvl_coord(p) or_return
	max = parse_flvl_coord(p) or_return
	return min, max, .None
}

// parse_flvl_coord parses `( n (, n)* )` — a parenthesized coordinate tuple
// (grammar/flvl.ebnf Coord). At least one component is required; an empty `()`
// is malformed. Components are Number atoms parsed through parse_anchor_atom so
// the coordinate and offset grammars share one number representation.
parse_flvl_coord :: proc(p: ^Flvl_Parser) -> (coord: Flvl_Coord, err: Flvl_Parse_Error) {
	flvl_expect(p, .L_Paren) or_return
	components := make([dynamic]Flvl_Anchor_Expr, 0, 3, context.temp_allocator)
	for {
		// A coordinate component is a signed Number; reuse the anchor-expression
		// atom so `-48`-style negatives parse uniformly.
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

// parse_flvl_things parses `things <module>` — the LOWER_IDENT schema module
// this level places (grammar/flvl.ebnf Things).
parse_flvl_things :: proc(p: ^Flvl_Parser) -> (module: string, err: Flvl_Parse_Error) {
	flvl_expect(p, .Things) or_return
	return flvl_expect_lower(p)
}

// parse_flvl_place parses one `place <Type> [<name>] { params }? at <where>
// [facing <rot>]` placement (grammar/flvl.ebnf Placement). The type is
// UPPER_IDENT (required); the instance name is an optional LOWER_IDENT — present
// when a LOWER_IDENT precedes the param block / `at`; an optional `{ … }` param
// block follows; `at <anchor>` is required; an optional `facing <anchor>` ends
// it.
parse_flvl_place :: proc(p: ^Flvl_Parser) -> (place: Flvl_Place, err: Flvl_Parse_Error) {
	flvl_expect(p, .Place) or_return
	type_name := flvl_expect_upper(p) or_return
	place.type_name = type_name
	// The instance name is optional (anonymous scenery omits it). A LOWER_IDENT
	// here is the name; a `{` or `at` next means the placement is anonymous.
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

// parse_flvl_params parses the `{ <key>: <expr> (, <key>: <expr>)* }` param
// block (grammar/flvl.ebnf ParamBlock). Each entry's key is a dotted
// ParamKey (a flat field or a path into a nested member); the value is an
// anchor expression. Entries separate by newline or comma, both tolerated.
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

// parse_flvl_param_key parses a ParamKey: `LOWER_IDENT ('.' LOWER_IDENT)*`
// (grammar/flvl.ebnf ParamKey) — a flat field name (`rate`) or a dotted path
// into a nested prefab member (`cannon.rate`). Every segment is LOWER_IDENT.
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

// parse_flvl_prefab parses `prefab <Name> { PrefabItem* }` (grammar/flvl.ebnf
// Prefab): a UPPER_IDENT name and a body of placements, nested for-loops, and
// nested prefabs (to arbitrary depth) in source order.
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

// parse_flvl_for parses `for <i> in <lo>..<hi> { PrefabItem* }`
// (grammar/flvl.ebnf ForLoop). The loop var is LOWER_IDENT; the range bounds are
// Number atoms split by the `..` operator; the body is the same
// placement/for/prefab item set a prefab body holds.
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

// parse_flvl_item_body parses the shared PrefabItem sequence — a `place`,
// `for`, or nested `prefab` per item (grammar/flvl.ebnf PrefabItem) — up to the
// closing `}` (consumed by the caller). Items separate by newline or comma. One
// body parser drives a prefab body and a for-loop body, since both admit the
// same item set. It returns the per-kind slices AND the interleaved source-order
// `items` record, the declaration order a stamp/iteration expands in.
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

// ── Anchor expressions ─────────────────────────────────────────────────────
// The position/offset grammar (grammar/flvl.ebnf AnchorExpr): a precedence
// cascade add → mul → unary → postfix → atom, left-associative, with `* /`
// binding tighter than `+ -`. The `.fun` Pratt cascade's level-grammar
// parallel, but small and explicit rather than table-driven since the level
// operator set is fixed and tiny.

// parse_flvl_anchor_expr is the single position/offset/param-value seam.
parse_flvl_anchor_expr :: proc(p: ^Flvl_Parser) -> (expr: Flvl_Anchor_Expr, err: Flvl_Parse_Error) {
	return parse_flvl_add(p)
}

// parse_flvl_add parses the additive tier `MulExpr (('+'|'-') MulExpr)*`
// (grammar/flvl.ebnf AddExpr), left-associative.
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

// parse_flvl_mul parses the multiplicative tier `UnaryExpr (('*'|'/')
// UnaryExpr)*` (grammar/flvl.ebnf MulExpr), left-associative and tighter than
// additive.
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

// parse_flvl_unary parses the unary tier `'-' UnaryExpr | PostfixExpr`
// (grammar/flvl.ebnf UnaryExpr) — the leading-minus form of an offset constant
// (`-48`, `-12`) or var (`-i`).
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

// parse_flvl_postfix parses `AnchorAtom PostfixOp*` (grammar/flvl.ebnf
// PostfixExpr): an atom followed by `.member`, `.member(args)`, or a direct
// `(args)` call. The `.sub` chain and the `.offset(…)`/socket calls fold onto
// the atom left-to-right, so `right_edge.center.offset(x: -12)` builds a
// Member→Member→Call chain.
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

// parse_flvl_call_args parses `( (Arg (',' Arg)*)? )` (grammar/flvl.ebnf
// CallArgs/Arg): a comma-separated argument list where each Arg is an optional
// `name:` label followed by an anchor expression. The label is the named-arg
// form `offset(x: 6, y: -4)`; a positional arg (`left_of(door, 2)`,
// `cell(5, 3)`) carries an empty name. args and names travel parallel.
parse_flvl_call_args :: proc(p: ^Flvl_Parser) -> (args: []Flvl_Anchor_Expr, names: []string, err: Flvl_Parse_Error) {
	flvl_expect(p, .L_Paren) or_return
	arg_list := make([dynamic]Flvl_Anchor_Expr, 0, 4, context.temp_allocator)
	name_list := make([dynamic]string, 0, 4, context.temp_allocator)
	for cursor_peek_kind(p) != .R_Paren {
		name := ""
		// A `LOWER_IDENT ':'` lookahead marks a named arg; a lone LOWER_IDENT is
		// a positional anchor name (`door`). Two tokens of lookahead is fine —
		// the level grammar is explicitly not LL(1) (grammar/flvl.ebnf §0).
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

// parse_flvl_atom parses `LOWER_IDENT | Number | String | '(' AnchorExpr ')'`
// (grammar/flvl.ebnf AnchorAtom): a bare name (anchor, base, or loop var), a
// number literal, a socket-name string, or a parenthesized sub-expression that
// unwraps to its inner expr.
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
		// An anchor atom is a LOWER_IDENT (anchor, instance base, or loop var);
		// an upper-case name has no atom position in the anchor grammar.
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

// ── Cursor facades ──────────────────────────────────────────────────────────
// The token cursor lives in parser_cursor.odin (Cursor / cursor_*). These thin
// facades exist only where a generic call cannot reach: flvl_expect's `.Kind`
// argument is an implicit enum selector Odin cannot type through a polymorphic
// proc's parameter, flvl_expect_upper/lower encode the .flvl case model (one
// Ident kind plus a case_class field, vs .fpm's two kinds), and
// flvl_skip_separators binds the .flvl separator set (grammar/flvl.ebnf Sep).

flvl_expect :: proc(p: ^Flvl_Parser, kind: Flvl_Token_Kind) -> (tok: Flvl_Token, err: Flvl_Parse_Error) {
	return cursor_expect(p, kind)
}

// flvl_expect_upper consumes an Ident token, demanding UPPER_IDENT case — a
// placed type or prefab name (grammar/flvl.ebnf). A lower-case name there is
// Wrong_Case, not a generic Unexpected_Token.
flvl_expect_upper :: proc(p: ^Flvl_Parser) -> (name: string, err: Flvl_Parse_Error) {
	tok := flvl_expect(p, .Ident) or_return
	if tok.case_class != .Upper {
		return "", .Wrong_Case
	}
	return tok.text, .None
}

// flvl_expect_lower consumes an Ident token, demanding LOWER_IDENT case — an
// instance name, field, schema module, or loop var. An upper-case name there is
// Wrong_Case.
flvl_expect_lower :: proc(p: ^Flvl_Parser) -> (name: string, err: Flvl_Parse_Error) {
	tok := flvl_expect(p, .Ident) or_return
	if tok.case_class != .Lower {
		return "", .Wrong_Case
	}
	return tok.text, .None
}

// flvl_skip_separators consumes the item-separator run between level items,
// prefab items, param entries, or for-body items: newlines and commas, both
// legal (grammar/flvl.ebnf Sep + the comma the placement grammar uses inside
// param blocks).
flvl_skip_separators :: proc(p: ^Flvl_Parser) {
	cursor_skip_kinds(p, Flvl_Token_Kind.Newline, Flvl_Token_Kind.Comma)
}
