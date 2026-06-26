// Parser for the §21 UI-template grammar (`.fui`), over the dedicated lexer
// (fui_lexer.odin). It builds a parse-only AST: NO contract inference, NO type
// derivation, NO theme-token check — turning the parsed reads/emits/for-lists
// into the typed view-model `data` and `Msg` enum is the inference story's
// (fui_infer.odin), downstream of this seam, and the .gen.fun emission and
// set-level routing are later stories still. This stage answers one question
// only: does the source match the grammar (grammar/fui.ebnf)?
//
// The grammar is LL(1) (fui.ebnf §0): every Node is selected by one token (a
// widget keyword opens an Element, `if`/`for` open control flow, a String opens a
// TextNode), and every Attr is selected by one token (LOWER_IDENT plain, `:`
// bind-in, `bind:` two-way, `@` event). So the node-dispatch and attr-dispatch
// loops are single-token, no lookahead — unlike `.flvl`, which is explicitly not
// LL(1). The one place a token form is overloaded is `:` (bind-in head AND
// row-type/row-field separator), but the two never compete: `:` opens an Attr only
// inside an Element's attribute run, and opens a RowType only right after a
// ForNode's path, so grammar POSITION resolves it without lookahead.
//
// Widgets and string text retain their CLASS tokens and INTERPOLATION holes
// verbatim — the closed style-token vocabulary check (§21 §1) and the read/emit
// inference (§21 §2) are both downstream consumers of this faithful parse tree.
package funpack

// Fui_Widget_Kind is the closed fourteen-widget set (§21 §1, fui.ebnf Widget):
// layout (panel/row/col/grid/stack/scroll/spacer), content (text/image/icon),
// and input (button/field/slider/toggle/select). The kind is significant to the
// inference downstream — a `bind:value` on a `field` lowers to a String read, on
// a `slider` to an Int read — so the parser records which widget each element is.
Fui_Widget_Kind :: enum {
	// layout
	Panel,
	Row,
	Col,
	Grid,
	Stack,
	Scroll,
	Spacer,
	// content
	Text,
	Image,
	Icon,
	// input
	Button,
	Field,
	Slider,
	Toggle,
	Select,
}

// Fui_Attr_Kind is the closed directive-and-attribute set (§21 §1, fui.ebnf
// Attr): a plain attribute (`class="…"`, `min=0`), the bind-in directive
// (`:class=tone`, value in), the event directive (`@click=Coin`, message out),
// and the two-way directive (`bind:value=volume`, both a read and a Set-message).
// The kind drives the inference: Bind_In contributes a read, Event a Msg variant,
// Two_Way both. Plain attributes (style tokens, placeholders, min/max) contribute
// nothing to the seam — they are layout/theme, checked elsewhere.
Fui_Attr_Kind :: enum {
	Plain,    // LOWER_IDENT '=' AttrValue
	Bind_In,  // ':' LOWER_IDENT '=' Path
	Event,    // '@' LOWER_IDENT '=' MsgRef
	Two_Way,  // 'bind:' LOWER_IDENT '=' Path
}

// Fui_Attr is one parsed attribute or directive on an Element (fui.ebnf Attr).
// name is the attribute/directive name (`class`, `value`, `click`); for an Event
// it is the event name (`click`). value carries the parsed right-hand side per
// kind: a Plain attr's literal/path, a Bind_In/Two_Way directive's path, or an
// Event directive's Msg variant + optional payload path. The four kinds read
// disjoint value shapes, so Fui_Attr_Value is a small union the inference matches.
Fui_Attr :: struct {
	kind:  Fui_Attr_Kind,
	name:  string,
	value: Fui_Attr_Value,
}

// Fui_Attr_Value is the closed set of attribute right-hand sides (fui.ebnf
// AttrValue / Path / MsgRef). A Plain attr is a String/Int/Bool literal or a bare
// path; a Bind_In/Two_Way directive is a Path; an Event directive is a Msg ref (a
// variant name with an optional payload path). The kind that produced it selects
// which arm is populated.
Fui_Attr_Value :: union {
	Fui_Literal,  // a Plain attr's String/Int/Bool literal
	Fui_Path,     // a Plain attr's bare path, or a Bind_In/Two_Way directive's bound path
	Fui_Msg_Ref,  // an Event directive's Msg variant + optional payload path
}

// Fui_Literal_Kind is the closed set of plain-attribute literal forms (fui.ebnf
// AttrValue): a quoted String, a bare Int, or a Bool. Style tokens ride the
// String form; numeric bounds (`min=0`) the Int form.
Fui_Literal_Kind :: enum {
	String,
	Int,
	Bool,
}

// Fui_Literal is a plain-attribute literal value (a `class="…"` string, a `min=0`
// int, a Bool). text holds the String contents; int_value the Int; bool_value the
// Bool — read per kind.
Fui_Literal :: struct {
	kind:       Fui_Literal_Kind,
	text:       string,
	int_value:  i64,
	bool_value: bool,
}

// Fui_Path is a dotted path (fui.ebnf Path): a LOWER_IDENT root and zero or more
// `.LOWER_IDENT` segments (`score`, `p.value`, `item.id`). segments holds the
// names in order; the root is segments[0]. The inference reads the root to decide
// whether a path is a view-model field or a for-loop row binding.
Fui_Path :: struct {
	segments: []string,
}

// Fui_Msg_Ref is an `@event=Msg` directive's target (fui.ebnf MsgRef): a
// UPPER_IDENT variant name and an optional `(Path)` payload. variant is the Msg
// variant (`Coin`, `SetVolume`); payload is the parsed argument path, present per
// has_payload — the path whose inferred type becomes the variant's payload type.
Fui_Msg_Ref :: struct {
	variant:     string,
	payload:     Fui_Path,
	has_payload: bool,
}

// Fui_Node is the closed body-item set (fui.ebnf Node): an Element (a widget with
// its attributes and optional child block), a TextNode (an interpolated string),
// an IfNode (a conditional block over a bare path), or a ForNode (a list
// repetition). A discriminated union of pointer arms, mirroring the `.fun`
// expression union, so a screen body and a block body are both `[]Fui_Node`.
Fui_Node :: union {
	^Fui_Element,
	^Fui_Text,
	^Fui_If,
	^Fui_For,
}

// Fui_Element is one `Widget Attr* Block?` element (fui.ebnf Element): the widget
// kind, its parsed attributes and directives in source order, and an optional
// child block. has_block distinguishes a self-closing input widget (`field … `,
// `slider … `) from a container whose `{ … }` holds child nodes. children is the
// block body when present.
Fui_Element :: struct {
	widget:    Fui_Widget_Kind,
	attrs:     []Fui_Attr,
	children:  []Fui_Node,
	has_block: bool,
}

// Fui_Text is an interpolated text node (fui.ebnf TextNode): the raw string text
// with its `{path}` holes intact, plus the holes parsed out into paths. text is
// the verbatim contents (for faithful re-emission / display); holes are the
// interpolation paths in left-to-right order — the reads the inference lifts into
// view-model fields (a hole on a view-model path) or row bindings (a hole on a
// loop var, `"{p.value}"`).
Fui_Text :: struct {
	text:  string,
	holes: []Fui_Path,
}

// Fui_If is one `if Path Block` conditional (fui.ebnf IfNode): the bare-path
// condition (`game_over`, inferred to a Bool view-model field) and the gated child
// block.
Fui_If :: struct {
	cond:     Fui_Path,
	children: []Fui_Node,
}

// Fui_For is one `for LOWER_IDENT in Path RowType? KeyAttr? Block` repetition
// (fui.ebnf ForNode): the loop var name, the list path (inferred to a
// `[RowType]` view-model field), the optional inline row-payload type ascription,
// the optional `key=path` identity attribute, and the repeated child block. The
// row type is inferred from the loop var's `var.*` uses inside the block unless
// row_type pins it explicitly (§21 §5 payload typing).
Fui_For :: struct {
	var:          string,
	list:         Fui_Path,
	row_type:     []Fui_Row_Field, // explicit inline row type, empty when inferred
	has_row_type: bool,
	key:          Fui_Path,
	has_key:      bool,
	children:     []Fui_Node,
}

// Fui_Row_Field is one `LOWER_IDENT ':' Type` entry of an inline row-payload type
// (fui.ebnf RowField): the field name and its rendered type token (`id`,
// `Ref[Difficulty]`). The explicit-ascription form (§21 §5) the author writes
// when a row payload is a domain type rather than an inferred primitive.
Fui_Row_Field :: struct {
	name: string,
	type: string,
}

// Fui_Screen is one `screen <Name> { Node* }` block (fui.ebnf ScreenDecl) — the
// parse root for a single UI template. name is the UPPER_IDENT screen name; body
// is the top-level node sequence. The leading `Directive*` of UiUnit (the
// `.fun`-style `@directive` head) does not appear in the §21 example screens, so
// this seam parses a bare screen block; a leading directive run is a later
// concern, not surfaced by the examples this story targets.
Fui_Screen :: struct {
	name: string,
	body: []Fui_Node,
}

// Fui_Parse_Error is the shared sub-language verdict set (parser_cursor.odin):
// Unexpected_Token is a token out of grammar position, Unexpected_End is input
// ending mid-production (an unterminated block or string), and Wrong_Case is a
// name whose first-letter case is wrong for its position (a lower-case screen
// name or Msg variant, an upper-case widget or path segment). The downstream
// inference checks (unknown style token, an unconsumed Msg) are NOT parse errors
// — they need the typed seam this stage does not build.
Fui_Parse_Error :: Sub_Parse_Error

// Fui_Parser binds the shared Cursor to the .fui token/kind pair; the cursor
// mechanism (peek/advance/expect) lives in parser_cursor.odin.
Fui_Parser :: Cursor(Fui_Token, Fui_Token_Kind)

// parse_fui is the entry seam: it parses a single `screen … { … }` block from a
// UI source's tokens. Leading and trailing whitespace are already dropped by the
// lexer; the one screen block is parsed and a token after it (a second `screen`,
// stray input) is Unexpected_Token. The leading `Directive*` of fui.ebnf UiUnit
// is not exercised by the §21 example screens, so it is out of this seam's scope.
parse_fui :: proc(source: string) -> (screen: Fui_Screen, err: Fui_Parse_Error) {
	p := Fui_Parser{tokens = lex_fui(source)}
	screen = parse_fui_screen(&p) or_return
	if !cursor_at_end(&p) {
		return Fui_Screen{}, .Unexpected_Token
	}
	return screen, .None
}

// parse_fui_screen parses the `screen <Name> { Node* }` block (fui.ebnf
// ScreenDecl). The name is UPPER_IDENT; the body is a node sequence up to the
// closing `}`. An empty body (a screen with no nodes) is legal grammar — the §21
// edge cases live in the inference, not here.
parse_fui_screen :: proc(p: ^Fui_Parser) -> (screen: Fui_Screen, err: Fui_Parse_Error) {
	fui_expect(p, .Screen) or_return
	name := fui_expect_upper(p) or_return
	screen.name = name
	body := parse_fui_block_body(p) or_return
	screen.body = body
	return screen, .None
}

// parse_fui_block_body parses a `{ Node* }` block: the opening brace, a node
// sequence up to the closing brace, and the closing brace. One body parser drives
// the screen body, an element's child block, an `if` block, and a `for` block,
// since all four are the same `{ Node* }` shape (fui.ebnf Block). Each node is
// dispatched off its single opening token (the grammar is LL(1)).
parse_fui_block_body :: proc(p: ^Fui_Parser) -> (nodes: []Fui_Node, err: Fui_Parse_Error) {
	fui_expect(p, .L_Brace) or_return
	list := make([dynamic]Fui_Node, 0, 8, context.temp_allocator)
	for cursor_peek_kind(p) != .R_Brace {
		node := parse_fui_node(p) or_return
		append(&list, node)
	}
	fui_expect(p, .R_Brace) or_return
	return list[:], .None
}

// parse_fui_node dispatches one body item off its single opening token (fui.ebnf
// Node, LL(1)): `if` opens a conditional, `for` a repetition, a String a text
// node, and any of the fourteen widget keywords an element. An Invalid token is
// Unexpected_End (input ran out mid-block); anything else is Unexpected_Token.
parse_fui_node :: proc(p: ^Fui_Parser) -> (node: Fui_Node, err: Fui_Parse_Error) {
	#partial switch cursor_peek_kind(p) {
	case .If:
		return parse_fui_if(p)
	case .For:
		return parse_fui_for(p)
	case .String_Lit:
		return parse_fui_text(p)
	case .Panel, .Row, .Col, .Grid, .Stack, .Scroll, .Spacer,
	     .Text, .Image, .Icon,
	     .Button, .Field, .Slider, .Toggle, .Select:
		return parse_fui_element(p)
	case .Invalid:
		return nil, .Unexpected_End
	}
	return nil, .Unexpected_Token
}

// parse_fui_element parses one `Widget Attr* Block?` element (fui.ebnf Element):
// the widget keyword, an attribute run, and an optional child block. An input
// widget that ends its attributes with no `{` (a self-closing `field`/`slider`)
// has no block; a container or a labeled button has a `{ … }` body.
parse_fui_element :: proc(p: ^Fui_Parser) -> (node: Fui_Node, err: Fui_Parse_Error) {
	widget := fui_parse_widget(p) or_return
	attrs := parse_fui_attrs(p) or_return
	el := new(Fui_Element, context.temp_allocator)
	el.widget = widget
	el.attrs = attrs
	if cursor_peek_kind(p) == .L_Brace {
		children := parse_fui_block_body(p) or_return
		el.children = children
		el.has_block = true
	}
	return el, .None
}

// fui_parse_widget maps a widget keyword token to its Fui_Widget_Kind (fui.ebnf
// Widget). Only a widget keyword reaches here — the node dispatcher gates on the
// closed widget set — so a non-widget token is Unexpected_Token.
fui_parse_widget :: proc(p: ^Fui_Parser) -> (kind: Fui_Widget_Kind, err: Fui_Parse_Error) {
	tok := cursor_advance(p) or_return
	#partial switch tok.kind {
	case .Panel:  return .Panel, .None
	case .Row:    return .Row, .None
	case .Col:    return .Col, .None
	case .Grid:   return .Grid, .None
	case .Stack:  return .Stack, .None
	case .Scroll: return .Scroll, .None
	case .Spacer: return .Spacer, .None
	case .Text:   return .Text, .None
	case .Image:  return .Image, .None
	case .Icon:   return .Icon, .None
	case .Button: return .Button, .None
	case .Field:  return .Field, .None
	case .Slider: return .Slider, .None
	case .Toggle: return .Toggle, .None
	case .Select: return .Select, .None
	}
	return .Panel, .Unexpected_Token
}

// parse_fui_attrs parses the `Attr*` run after a widget (fui.ebnf Attr), each
// dispatched off its single FIRST token (LL(1)): LOWER_IDENT opens a plain attr,
// `:` a bind-in directive, `bind:` a two-way directive, `@` an event directive.
// The run ends at the element's `{` block or at any node-starting token (the next
// sibling), so the loop stops on anything outside the four attr heads.
parse_fui_attrs :: proc(p: ^Fui_Parser) -> (attrs: []Fui_Attr, err: Fui_Parse_Error) {
	list := make([dynamic]Fui_Attr, 0, 4, context.temp_allocator)
	for {
		#partial switch cursor_peek_kind(p) {
		case .Ident:
			attr := parse_fui_plain_attr(p) or_return
			append(&list, attr)
		case .Colon:
			attr := parse_fui_bind_in_attr(p) or_return
			append(&list, attr)
		case .Bind_Colon:
			attr := parse_fui_two_way_attr(p) or_return
			append(&list, attr)
		case .At_Sign:
			attr := parse_fui_event_attr(p) or_return
			append(&list, attr)
		case:
			return list[:], .None
		}
	}
}

// parse_fui_plain_attr parses `LOWER_IDENT '=' AttrValue` (fui.ebnf PlainAttr): a
// style/layout attribute (`class="…"`, `placeholder="name"`, `min=0`). The name is
// LOWER_IDENT; the value is a String, Int, Bool, or bare Path. Plain attributes
// carry style tokens and bounds — checked by the theme/widget gates, not inferred
// into the seam.
parse_fui_plain_attr :: proc(p: ^Fui_Parser) -> (attr: Fui_Attr, err: Fui_Parse_Error) {
	name := fui_expect_lower(p) or_return
	fui_expect(p, .Equals) or_return
	value := parse_fui_attr_value(p) or_return
	return Fui_Attr{kind = .Plain, name = name, value = value}, .None
}

// parse_fui_bind_in_attr parses `':' LOWER_IDENT '=' Path` (fui.ebnf BindInAttr):
// the value-in directive (`:class=tone`). The bound path is a typed read feeding
// the attribute — a view-model field the inference lifts (String-typed, an
// attribute read).
parse_fui_bind_in_attr :: proc(p: ^Fui_Parser) -> (attr: Fui_Attr, err: Fui_Parse_Error) {
	fui_expect(p, .Colon) or_return
	name := fui_expect_lower(p) or_return
	fui_expect(p, .Equals) or_return
	path := parse_fui_path(p) or_return
	return Fui_Attr{kind = .Bind_In, name = name, value = path}, .None
}

// parse_fui_two_way_attr parses `'bind:' LOWER_IDENT '=' Path` (fui.ebnf
// TwoWayAttr): the two-way directive (`bind:value=volume`). It lowers to BOTH a
// read of the bound path AND a `Set<Field>` Msg variant — the dual edge the
// inference materializes from this one attribute.
parse_fui_two_way_attr :: proc(p: ^Fui_Parser) -> (attr: Fui_Attr, err: Fui_Parse_Error) {
	fui_expect(p, .Bind_Colon) or_return
	name := fui_expect_lower(p) or_return
	fui_expect(p, .Equals) or_return
	path := parse_fui_path(p) or_return
	return Fui_Attr{kind = .Two_Way, name = name, value = path}, .None
}

// parse_fui_event_attr parses `'@' LOWER_IDENT '=' MsgRef` (fui.ebnf EventAttr):
// the message-out directive (`@click=Coin`, `@click=SetVolume(p.value)`). The
// event name is LOWER_IDENT; the MsgRef is an UPPER_IDENT variant with an optional
// `(Path)` payload. The variant becomes a `Msg` enum variant; a payload path's
// inferred type becomes the variant's payload type.
parse_fui_event_attr :: proc(p: ^Fui_Parser) -> (attr: Fui_Attr, err: Fui_Parse_Error) {
	fui_expect(p, .At_Sign) or_return
	name := fui_expect_lower(p) or_return
	fui_expect(p, .Equals) or_return
	ref := parse_fui_msg_ref(p) or_return
	return Fui_Attr{kind = .Event, name = name, value = ref}, .None
}

// parse_fui_msg_ref parses `UPPER_IDENT ('(' Path ')')?` (fui.ebnf MsgRef): the
// Msg variant name and an optional single payload path. The variant is
// UPPER_IDENT; a `(` opens the payload path, closed by `)`. A nullary variant
// (`Coin`, `Back`) has no payload.
parse_fui_msg_ref :: proc(p: ^Fui_Parser) -> (value: Fui_Attr_Value, err: Fui_Parse_Error) {
	variant := fui_expect_upper(p) or_return
	ref := Fui_Msg_Ref{variant = variant}
	if cursor_peek_kind(p) == .L_Paren {
		p.pos += 1
		path := parse_fui_path(p) or_return
		fui_expect(p, .R_Paren) or_return
		ref.payload = path.(Fui_Path)
		ref.has_payload = true
	}
	return ref, .None
}

// parse_fui_attr_value parses a PlainAttr's right-hand side (fui.ebnf AttrValue):
// a quoted String, a bare Int, a Bool, or a bare Path. A String/Int/Bool is a
// literal; a LOWER_IDENT is a bare path (the plain-attr path form). Style tokens
// ride the String form, numeric bounds the Int form.
parse_fui_attr_value :: proc(p: ^Fui_Parser) -> (value: Fui_Attr_Value, err: Fui_Parse_Error) {
	#partial switch cursor_peek_kind(p) {
	case .String_Lit:
		tok := cursor_advance(p) or_return
		return Fui_Literal{kind = .String, text = tok.text}, .None
	case .Int_Lit:
		tok := cursor_advance(p) or_return
		return Fui_Literal{kind = .Int, int_value = tok.int_value}, .None
	case .Bool_Lit:
		tok := cursor_advance(p) or_return
		return Fui_Literal{kind = .Bool, bool_value = tok.bool_value}, .None
	case .Ident:
		path := parse_fui_path(p) or_return
		return path, .None
	case .Invalid:
		return nil, .Unexpected_End
	}
	return nil, .Unexpected_Token
}

// parse_fui_text parses a TextNode (fui.ebnf TextNode): one interpolated string.
// The verbatim contents are kept, and the `{path}` interpolation holes are scanned
// out into paths (fui_scan_holes) — the reads the inference lifts. An empty or
// hole-free string is a legal literal text node (`"Settings"`).
parse_fui_text :: proc(p: ^Fui_Parser) -> (node: Fui_Node, err: Fui_Parse_Error) {
	tok := cursor_advance(p) or_return
	holes := fui_scan_holes(tok.text) or_return
	t := new(Fui_Text, context.temp_allocator)
	t.text = tok.text
	t.holes = holes
	return t, .None
}

// parse_fui_if parses `'if' Path Block` (fui.ebnf IfNode): the bare-path
// condition and the gated block. The condition is a Path (a Bool view-model field
// the inference lifts); the block is the same `{ Node* }` body shape.
parse_fui_if :: proc(p: ^Fui_Parser) -> (node: Fui_Node, err: Fui_Parse_Error) {
	fui_expect(p, .If) or_return
	cond := parse_fui_path(p) or_return
	children := parse_fui_block_body(p) or_return
	n := new(Fui_If, context.temp_allocator)
	n.cond = cond.(Fui_Path)
	n.children = children
	return n, .None
}

// parse_fui_for parses `'for' LOWER_IDENT 'in' Path RowType? KeyAttr? Block`
// (fui.ebnf ForNode): the loop var, the list path, an optional inline row-type
// ascription (`: { id: Ref[Difficulty] }`), an optional `key=path`, and the
// repeated block. The row type is inferred from `var.*` uses in the block when
// the inline ascription is absent (§21 §5).
parse_fui_for :: proc(p: ^Fui_Parser) -> (node: Fui_Node, err: Fui_Parse_Error) {
	fui_expect(p, .For) or_return
	loop_var := fui_expect_lower(p) or_return
	fui_expect(p, .In) or_return
	list := parse_fui_path(p) or_return
	n := new(Fui_For, context.temp_allocator)
	n.var = loop_var
	n.list = list.(Fui_Path)
	// Optional inline row-type ascription: `: { RowField (',' RowField)* }`. The
	// `:` here is the row-type opener, never a bind-in head (that opens an Attr
	// inside an Element, not after a for-path) — grammar position resolves it.
	if cursor_peek_kind(p) == .Colon {
		row_type := parse_fui_row_type(p) or_return
		n.row_type = row_type
		n.has_row_type = true
	}
	// Optional `key = Path` list-identity attribute.
	if cursor_peek_kind(p) == .Key {
		p.pos += 1
		fui_expect(p, .Equals) or_return
		key := parse_fui_path(p) or_return
		n.key = key.(Fui_Path)
		n.has_key = true
	}
	children := parse_fui_block_body(p) or_return
	n.children = children
	return n, .None
}

// parse_fui_row_type parses `':' '{' RowField (',' RowField)* '}'` (fui.ebnf
// RowType): the inline row-payload type ascription. Each RowField is
// `LOWER_IDENT ':' Type` (fui.ebnf RowField); the Type is rendered to a single
// token (`Int`, `Ref[Difficulty]`).
parse_fui_row_type :: proc(p: ^Fui_Parser) -> (fields: []Fui_Row_Field, err: Fui_Parse_Error) {
	fui_expect(p, .Colon) or_return
	fui_expect(p, .L_Brace) or_return
	list := make([dynamic]Fui_Row_Field, 0, 4, context.temp_allocator)
	for {
		name := fui_expect_lower(p) or_return
		fui_expect(p, .Colon) or_return
		type := parse_fui_type(p) or_return
		append(&list, Fui_Row_Field{name = name, type = type})
		if cursor_peek_kind(p) != .Comma {
			break
		}
		p.pos += 1
	}
	fui_expect(p, .R_Brace) or_return
	return list[:], .None
}

// parse_fui_type parses a row-payload Type (fui.ebnf Type): an UPPER_IDENT with an
// optional `[Type (',' Type)*]` generic argument list (`Ref[Difficulty]`), or a
// bracketed list type `[Type]`. It renders the type to its single source token so
// the row field carries the exact written type. The argument types recurse.
parse_fui_type :: proc(p: ^Fui_Parser) -> (rendered: string, err: Fui_Parse_Error) {
	#partial switch cursor_peek_kind(p) {
	case .L_Bracket:
		// A list type `[Type]`.
		p.pos += 1
		inner := parse_fui_type(p) or_return
		fui_expect(p, .R_Bracket) or_return
		return fui_concat("[", inner, "]"), .None
	case .Ident:
		head := fui_expect_upper(p) or_return
		if cursor_peek_kind(p) != .L_Bracket {
			return head, .None
		}
		// A generic application `Head[Arg, …]`.
		p.pos += 1
		args := make([dynamic]string, 0, 2, context.temp_allocator)
		for {
			arg := parse_fui_type(p) or_return
			append(&args, arg)
			if cursor_peek_kind(p) != .Comma {
				break
			}
			p.pos += 1
		}
		fui_expect(p, .R_Bracket) or_return
		return fui_render_generic(head, args[:]), .None
	case .Invalid:
		return "", .Unexpected_End
	}
	return "", .Unexpected_Token
}

// parse_fui_path parses `LOWER_IDENT ('.' LOWER_IDENT)*` (fui.ebnf Path): a dotted
// path with a LOWER_IDENT root and zero or more `.LOWER_IDENT` segments. Returns a
// Fui_Path so a bind/event/if path and a plain-attr path share one node shape.
parse_fui_path :: proc(p: ^Fui_Parser) -> (value: Fui_Attr_Value, err: Fui_Parse_Error) {
	segments := make([dynamic]string, 0, 3, context.temp_allocator)
	head := fui_expect_lower(p) or_return
	append(&segments, head)
	for cursor_peek_kind(p) == .Dot {
		p.pos += 1
		seg := fui_expect_lower(p) or_return
		append(&segments, seg)
	}
	return Fui_Path{segments = segments[:]}, .None
}

// ── Interpolation-hole scanning ─────────────────────────────────────────────

// fui_scan_holes extracts the `{path}` interpolation holes from a text-node
// string in left-to-right order (fui.ebnf Interpolation, §21 §5). The holes are
// PATHS (paths-and-literals-only — no operators or calls), so each `{…}` body is
// re-parsed as a path. A literal `"Settings"` yields no holes; `"Score: {score}"`
// yields one hole `score`; `"{p.value}"` yields one hole `p.value`. An
// unterminated `{` (no closing `}`) is Unexpected_End.
fui_scan_holes :: proc(text: string) -> (holes: []Fui_Path, err: Fui_Parse_Error) {
	list := make([dynamic]Fui_Path, 0, 2, context.temp_allocator)
	i := 0
	for i < len(text) {
		if text[i] != '{' {
			i += 1
			continue
		}
		// Found a hole opener; scan to the closing `}`.
		j := i + 1
		for j < len(text) && text[j] != '}' {
			j += 1
		}
		if j >= len(text) {
			return nil, .Unexpected_End
		}
		path := fui_parse_path_string(text[i+1 : j]) or_return
		append(&list, path)
		i = j + 1
	}
	return list[:], .None
}

// fui_parse_path_string parses a hole body as a path (fui.ebnf Path): a
// `.`-separated run of LOWER_IDENT segments. An empty hole (`{}`) or a malformed
// segment is Unexpected_Token. Reused for the standalone hole-body grammar, which
// the main token stream does not carry (the holes live inside a String_Lit).
fui_parse_path_string :: proc(body: string) -> (path: Fui_Path, err: Fui_Parse_Error) {
	segments := make([dynamic]string, 0, 3, context.temp_allocator)
	i := 0
	for {
		// A segment is a maximal LOWER_IDENT-char run; it must be non-empty and
		// begin with an ident-start char.
		seg_start := i
		for i < len(body) && is_ident_char(body[i]) {
			i += 1
		}
		if i == seg_start || !is_ident_start(body[seg_start]) {
			return Fui_Path{}, .Unexpected_Token
		}
		append(&segments, body[seg_start:i])
		if i >= len(body) {
			break
		}
		if body[i] != '.' {
			return Fui_Path{}, .Unexpected_Token
		}
		i += 1
	}
	return Fui_Path{segments = segments[:]}, .None
}

// ── Cursor facades ──────────────────────────────────────────────────────────
// The token cursor lives in parser_cursor.odin (Cursor / cursor_*). These thin
// facades exist only where a generic call cannot reach: fui_expect's `.Kind`
// argument is an implicit enum selector Odin cannot type through a polymorphic
// proc's parameter, and fui_expect_upper/lower encode the .fui case model (one
// Ident kind plus a case_class field, vs .fpm's two kinds).

fui_expect :: proc(p: ^Fui_Parser, kind: Fui_Token_Kind) -> (tok: Fui_Token, err: Fui_Parse_Error) {
	return cursor_expect(p, kind)
}

// fui_expect_upper consumes an Ident token, demanding UPPER_IDENT case — a screen
// name, Msg variant, or row-payload type (fui.ebnf). A lower-case name there is
// Wrong_Case, not a generic Unexpected_Token.
fui_expect_upper :: proc(p: ^Fui_Parser) -> (name: string, err: Fui_Parse_Error) {
	tok := fui_expect(p, .Ident) or_return
	if tok.case_class != .Upper {
		return "", .Wrong_Case
	}
	return tok.text, .None
}

// fui_expect_lower consumes an Ident token, demanding LOWER_IDENT case — a widget
// name has its own keyword token, so this guards an attribute name, path segment,
// or loop var. An upper-case name there is Wrong_Case.
fui_expect_lower :: proc(p: ^Fui_Parser) -> (name: string, err: Fui_Parse_Error) {
	tok := fui_expect(p, .Ident) or_return
	if tok.case_class != .Lower {
		return "", .Wrong_Case
	}
	return tok.text, .None
}

// fui_concat joins three string parts — the small builder the bracketed list-type
// renderer uses to assemble `[Inner]` without pulling in a strings.Builder for a
// three-part concat.
fui_concat :: proc(a, b, c: string) -> string {
	out := make([]u8, len(a)+len(b)+len(c), context.temp_allocator)
	copy(out[:], a)
	copy(out[len(a):], b)
	copy(out[len(a)+len(b):], c)
	return string(out)
}

// fui_render_generic renders `Head[Arg0, Arg1, …]` — a generic type application's
// canonical single-token form. Args join with ", " inside the brackets, matching
// the rendered-type convention the row-field type carries.
fui_render_generic :: proc(head: string, args: []string) -> string {
	total := len(head) + 2 // head + "[" + "]"
	for arg, i in args {
		if i > 0 {
			total += 2 // ", "
		}
		total += len(arg)
	}
	out := make([]u8, total, context.temp_allocator)
	n := copy(out[:], head)
	n += copy(out[n:], "[")
	for arg, i in args {
		if i > 0 {
			n += copy(out[n:], ", ")
		}
		n += copy(out[n:], arg)
	}
	copy(out[n:], "]")
	return string(out)
}
