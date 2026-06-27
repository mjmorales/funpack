package funpack

Fui_Widget_Kind :: enum {
	Panel,
	Row,
	Col,
	Grid,
	Stack,
	Scroll,
	Spacer,
	Text,
	Image,
	Icon,
	Button,
	Field,
	Slider,
	Toggle,
	Select,
}

Fui_Attr_Kind :: enum {
	Plain,
	Bind_In,
	Event,
	Two_Way,
}

Fui_Attr :: struct {
	kind:  Fui_Attr_Kind,
	name:  string,
	value: Fui_Attr_Value,
}

Fui_Attr_Value :: union {
	Fui_Literal,
	Fui_Path,
	Fui_Msg_Ref,
}

Fui_Literal_Kind :: enum {
	String,
	Int,
	Bool,
}

Fui_Literal :: struct {
	kind:       Fui_Literal_Kind,
	text:       string,
	int_value:  i64,
	bool_value: bool,
}

Fui_Path :: struct {
	segments: []string,
}

Fui_Msg_Ref :: struct {
	variant:     string,
	payload:     Fui_Path,
	has_payload: bool,
}

Fui_Node :: union {
	^Fui_Element,
	^Fui_Text,
	^Fui_If,
	^Fui_For,
}

Fui_Element :: struct {
	widget:    Fui_Widget_Kind,
	attrs:     []Fui_Attr,
	children:  []Fui_Node,
	has_block: bool,
}

Fui_Text :: struct {
	text:  string,
	holes: []Fui_Path,
}

Fui_If :: struct {
	cond:     Fui_Path,
	children: []Fui_Node,
}

Fui_For :: struct {
	var:          string,
	list:         Fui_Path,
	row_type:     []Fui_Row_Field,
	has_row_type: bool,
	key:          Fui_Path,
	has_key:      bool,
	children:     []Fui_Node,
}

Fui_Row_Field :: struct {
	name: string,
	type: string,
}

Fui_Screen :: struct {
	name: string,
	body: []Fui_Node,
}

Fui_Parse_Error :: Sub_Parse_Error

Fui_Parser :: Cursor(Fui_Token, Fui_Token_Kind)

parse_fui :: proc(source: string) -> (screen: Fui_Screen, err: Fui_Parse_Error) {
	p := Fui_Parser{tokens = lex_fui(source)}
	screen = parse_fui_screen(&p) or_return
	if !cursor_at_end(&p) {
		return Fui_Screen{}, .Unexpected_Token
	}
	return screen, .None
}

parse_fui_screen :: proc(p: ^Fui_Parser) -> (screen: Fui_Screen, err: Fui_Parse_Error) {
	fui_expect(p, .Screen) or_return
	name := fui_expect_upper(p) or_return
	screen.name = name
	body := parse_fui_block_body(p) or_return
	screen.body = body
	return screen, .None
}

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

parse_fui_plain_attr :: proc(p: ^Fui_Parser) -> (attr: Fui_Attr, err: Fui_Parse_Error) {
	name := fui_expect_lower(p) or_return
	fui_expect(p, .Equals) or_return
	value := parse_fui_attr_value(p) or_return
	return Fui_Attr{kind = .Plain, name = name, value = value}, .None
}

parse_fui_bind_in_attr :: proc(p: ^Fui_Parser) -> (attr: Fui_Attr, err: Fui_Parse_Error) {
	fui_expect(p, .Colon) or_return
	name := fui_expect_lower(p) or_return
	fui_expect(p, .Equals) or_return
	path := parse_fui_path(p) or_return
	return Fui_Attr{kind = .Bind_In, name = name, value = path}, .None
}

parse_fui_two_way_attr :: proc(p: ^Fui_Parser) -> (attr: Fui_Attr, err: Fui_Parse_Error) {
	fui_expect(p, .Bind_Colon) or_return
	name := fui_expect_lower(p) or_return
	fui_expect(p, .Equals) or_return
	path := parse_fui_path(p) or_return
	return Fui_Attr{kind = .Two_Way, name = name, value = path}, .None
}

parse_fui_event_attr :: proc(p: ^Fui_Parser) -> (attr: Fui_Attr, err: Fui_Parse_Error) {
	fui_expect(p, .At_Sign) or_return
	name := fui_expect_lower(p) or_return
	fui_expect(p, .Equals) or_return
	ref := parse_fui_msg_ref(p) or_return
	return Fui_Attr{kind = .Event, name = name, value = ref}, .None
}

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

parse_fui_text :: proc(p: ^Fui_Parser) -> (node: Fui_Node, err: Fui_Parse_Error) {
	tok := cursor_advance(p) or_return
	holes := fui_scan_holes(tok.text) or_return
	t := new(Fui_Text, context.temp_allocator)
	t.text = tok.text
	t.holes = holes
	return t, .None
}

parse_fui_if :: proc(p: ^Fui_Parser) -> (node: Fui_Node, err: Fui_Parse_Error) {
	fui_expect(p, .If) or_return
	cond := parse_fui_path(p) or_return
	children := parse_fui_block_body(p) or_return
	n := new(Fui_If, context.temp_allocator)
	n.cond = cond.(Fui_Path)
	n.children = children
	return n, .None
}

parse_fui_for :: proc(p: ^Fui_Parser) -> (node: Fui_Node, err: Fui_Parse_Error) {
	fui_expect(p, .For) or_return
	loop_var := fui_expect_lower(p) or_return
	fui_expect(p, .In) or_return
	list := parse_fui_path(p) or_return
	n := new(Fui_For, context.temp_allocator)
	n.var = loop_var
	n.list = list.(Fui_Path)
	if cursor_peek_kind(p) == .Colon {
		row_type := parse_fui_row_type(p) or_return
		n.row_type = row_type
		n.has_row_type = true
	}
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

parse_fui_type :: proc(p: ^Fui_Parser) -> (rendered: string, err: Fui_Parse_Error) {
	#partial switch cursor_peek_kind(p) {
	case .L_Bracket:
		p.pos += 1
		inner := parse_fui_type(p) or_return
		fui_expect(p, .R_Bracket) or_return
		return fui_concat("[", inner, "]"), .None
	case .Ident:
		head := fui_expect_upper(p) or_return
		if cursor_peek_kind(p) != .L_Bracket {
			return head, .None
		}
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

fui_scan_holes :: proc(text: string) -> (holes: []Fui_Path, err: Fui_Parse_Error) {
	list := make([dynamic]Fui_Path, 0, 2, context.temp_allocator)
	i := 0
	for i < len(text) {
		if text[i] != '{' {
			i += 1
			continue
		}
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

fui_parse_path_string :: proc(body: string) -> (path: Fui_Path, err: Fui_Parse_Error) {
	segments := make([dynamic]string, 0, 3, context.temp_allocator)
	i := 0
	for {
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

fui_expect :: proc(p: ^Fui_Parser, kind: Fui_Token_Kind) -> (tok: Fui_Token, err: Fui_Parse_Error) {
	return cursor_expect(p, kind)
}

fui_expect_upper :: proc(p: ^Fui_Parser) -> (name: string, err: Fui_Parse_Error) {
	tok := fui_expect(p, .Ident) or_return
	if tok.case_class != .Upper {
		return "", .Wrong_Case
	}
	return tok.text, .None
}

fui_expect_lower :: proc(p: ^Fui_Parser) -> (name: string, err: Fui_Parse_Error) {
	tok := fui_expect(p, .Ident) or_return
	if tok.case_class != .Lower {
		return "", .Wrong_Case
	}
	return tok.text, .None
}

fui_concat :: proc(a, b, c: string) -> string {
	out := make([]u8, len(a)+len(b)+len(c), context.temp_allocator)
	copy(out[:], a)
	copy(out[len(a):], b)
	copy(out[len(a)+len(b):], c)
	return string(out)
}

fui_render_generic :: proc(head: string, args: []string) -> string {
	total := len(head) + 2
	for arg, i in args {
		if i > 0 {
			total += 2
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
