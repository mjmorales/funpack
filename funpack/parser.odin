package funpack

Assert_Node :: struct {
	expr: Expr,
}

Let_Node :: struct {
	name:     string,
	names:    []string,
	is_tuple: bool,
	value:    Expr,
}

Return_Node :: struct {
	value: Expr,
}

If_Node :: struct {
	cond: Expr,
	body: []Statement,
}

Statement :: union {
	Assert_Node,
	Let_Node,
	Return_Node,
	If_Node,
}

Import_Node :: struct {
	segments: []string,
	members:  []string,
	line:     int,
	col:      int,
}

Test_Node :: struct {
	name: string,
	doc:  string,
	body: []Statement,
	line: int,
	probes: []Debug_Probe,
}

Type_Ref :: struct {
	name: string,
	args: []Type_Ref,
}

TYPE_REF_LIST_HEAD :: "[]"
TYPE_REF_TUPLE_HEAD :: "()"
TYPE_REF_FN_HEAD :: "fn"

Field_Decl :: struct {
	name:        string,
	type:        Type_Ref,
	default:     Expr,
	has_default: bool,
	migrate:     Migrate_Node,
	has_migrate: bool,
	probes:      []Debug_Probe,
}

Variant_Payload :: enum {
	Plain,
	Tuple,
	Struct,
}

Variant_Decl :: struct {
	name:    string,
	payload: Variant_Payload,
	tuple:   []Type_Ref,
	fields:  []Field_Decl,
	doc:     string,
}

Param_Decl :: struct {
	name: string,
	type: Type_Ref,
}

Let_Decl_Node :: struct {
	name:    string,
	type:    Type_Ref,
	value:   Expr,
	doc:     string,
	gtags:   []string,
	probes:  []Debug_Probe,
	todos:   []Todo_Node,
	exposed: bool,
	line:    int,
}

Data_Node :: struct {
	name:   string,
	kind:   string,
	type_params: []string,
	fields: []Field_Decl,
	doc:    string,
	gtags:  []string,
	probes: []Debug_Probe,
	todos:  []Todo_Node,
	migrate:     Migrate_Node,
	has_migrate: bool,
	exposed:     bool,
	line:        int,
}

Enum_Node :: struct {
	name:     string,
	kind:     string,
	type_params: []string,
	variants: []Variant_Decl,
	doc:      string,
	gtags:    []string,
	probes:   []Debug_Probe,
	todos:    []Todo_Node,
	exposed:  bool,
	line:     int,
}

Thing_Node :: struct {
	name:         string,
	is_singleton: bool,
	fields:       []Field_Decl,
	doc:          string,
	gtags:        []string,
	probes:       []Debug_Probe,
	todos:        []Todo_Node,
	exposed:      bool,
	line:         int,
}

Signal_Node :: struct {
	name:    string,
	fields:  []Field_Decl,
	doc:     string,
	gtags:   []string,
	probes:  []Debug_Probe,
	todos:   []Todo_Node,
	exposed: bool,
	line:    int,
}

Fn_Node :: struct {
	name:         string,
	params:       []Param_Decl,
	return_type:  Type_Ref,
	body:         []Statement,
	doc:          string,
	gtags:        []string,
	probes:       []Debug_Probe,
	todos:        []Todo_Node,
	exposed:      bool,
	line:         int,
	is_extern:    bool,
	holed:        bool,
	hole_type:    Type_Ref,
	fallback:     Expr,
	has_fallback: bool,
}

Extern_Type_Node :: struct {
	name:    string,
	type_params: []string,
	doc:     string,
	gtags:   []string,
	probes:  []Debug_Probe,
	todos:   []Todo_Node,
	exposed: bool,
	line:    int,
}

Index_Directive_Kind :: enum {
	Index,
	Spatial,
}

Index_Directive :: struct {
	kind:  Index_Directive_Kind,
	thing: string,
	field: string,
	line:  int,
}

Query_Node :: struct {
	name:        string,
	params:      []Param_Decl,
	return_type: Type_Ref,
	body:        []Statement,
	doc:         string,
	gtags:       []string,
	probes:      []Debug_Probe,
	todos:       []Todo_Node,
	indexes:     []Index_Directive,
	exposed:     bool,
	line:        int,
}

Behavior_Node :: struct {
	name:    string,
	target:  string,
	step:    Fn_Node,
	doc:     string,
	gtags:   []string,
	probes:  []Debug_Probe,
	todos:   []Todo_Node,
	exposed: bool,
	line:    int,
}

Pipeline_Stage :: struct {
	name:       string,
	behaviors:  []string,
	battery:    string,
	is_battery: bool,
	probes:     []Debug_Probe,
}

Pipeline_Node :: struct {
	name:    string,
	stages:  []Pipeline_Stage,
	doc:     string,
	gtags:   []string,
	probes:  []Debug_Probe,
	todos:   []Todo_Node,
	exposed: bool,
	line:    int,
}

Debug_Probe_Kind :: enum {
	Break,
	Log,
	Watch,
	Trace,
}

Debug_Probe :: struct {
	kind: Debug_Probe_Kind,
	arg:  Expr,
	line: int,
}

Todo_Window_Form :: enum {
	Duration,
	Date,
	Build_Count,
	Task_Ref,
}

Todo_Window :: struct {
	form:   Todo_Window_Form,
	amount: i64,
	unit:   string,
	year:   i64,
	month:  i64,
	day:    i64,
	task:   string,
}

Migrate_Node :: struct {
	from:     string,
	with:     string,
	has_from: bool,
	has_with: bool,
	line:     int,
}

Todo_Node :: struct {
	message: string,
	window:  Todo_Window,
	line:    int,
}

Directives :: struct {
	doc:         string,
	exposed:     bool,
	gtags:       [dynamic]string,
	probes:      [dynamic]Debug_Probe,
	todos:       [dynamic]Todo_Node,
	indexes:     [dynamic]Index_Directive,
	migrate:     Migrate_Node,
	has_migrate: bool,
}

Parse_Error :: enum {
	None,
	Unexpected_Token,
	Unexpected_End,
	Wrong_Case,
	Missing_Else,
	Probe_Missing_Arg,
	Probe_Unexpected_Arg,
	Probe_Wrong_Target,
	Malformed_Todo_Window,
	Malformed_Migrate,
	Migrate_Wrong_Target,
	Malformed_Index_Path,
	Index_Wrong_Target,
	Expose_Unexpected_Arg,
	Malformed_Extern,
	Malformed_Type_Params,
	Malformed_Fn_Type,
	Malformed_String_Escape,
	Variant_Directive_Wrong_Target,
	Bool_Pattern_Unsupported,
	Newline_Before_Binary_Op,
	Lambda_Body_Multi_Statement,
	Statement_In_Value_Block,
}

Parser :: struct {
	tokens: []Token,
	pos:    int,
	no_record_brace: bool,
	err_line: int,
	err_col:  int,
}

reject :: proc(p: ^Parser, tok: Token, err: Parse_Error) -> Parse_Error {
	if p.err_line == 0 {
		p.err_line = tok.line
		p.err_col = tok.col
	}
	return err
}

Parse_Verdict :: struct {
	err:  Parse_Error,
	line: int,
	col:  int,
}

stage_parse_located :: proc(tokens: []Token) -> (ast: Ast, verdict: Parse_Verdict) {
	p := Parser{tokens = tokens}
	parsed, err := parse_module(&p)
	if err == .None {
		return parsed, Parse_Verdict{}
	}
	line, col := p.err_line, p.err_col
	if line == 0 {
		line, col = parser_stop_span(&p)
	}
	return parsed, Parse_Verdict{err = err, line = line, col = col}
}

parser_stop_span :: proc(p: ^Parser) -> (line: int, col: int) {
	if len(p.tokens) == 0 {
		return 0, 0
	}
	idx := p.pos
	if idx >= len(p.tokens) {
		idx = len(p.tokens) - 1
	}
	tok := p.tokens[idx]
	return tok.line, tok.col
}

stage_parse :: proc(tokens: []Token) -> (ast: Ast, err: Parse_Error) {
	p := Parser{tokens = tokens}
	return parse_module(&p)
}

parse_module :: proc(p: ^Parser) -> (ast: Ast, err: Parse_Error) {
	out := Decl_Sink {
		imports   = make([dynamic]Import_Node, 0, 8, context.temp_allocator),
		decls     = make([dynamic]Decl_Ref, 0, 32, context.temp_allocator),
		lets      = make([dynamic]Let_Decl_Node, 0, 4, context.temp_allocator),
		datas     = make([dynamic]Data_Node, 0, 4, context.temp_allocator),
		enums     = make([dynamic]Enum_Node, 0, 4, context.temp_allocator),
		things    = make([dynamic]Thing_Node, 0, 8, context.temp_allocator),
		signals   = make([dynamic]Signal_Node, 0, 4, context.temp_allocator),
		fns       = make([dynamic]Fn_Node, 0, 16, context.temp_allocator),
		queries   = make([dynamic]Query_Node, 0, 4, context.temp_allocator),
		behaviors = make([dynamic]Behavior_Node, 0, 16, context.temp_allocator),
		pipelines = make([dynamic]Pipeline_Node, 0, 2, context.temp_allocator),
		tests     = make([dynamic]Test_Node, 0, 8, context.temp_allocator),
		extern_types = make([dynamic]Extern_Type_Node, 0, 4, context.temp_allocator),
	}
	module_doc := ""
	seen_decl := false
	pending := empty_directives()
	skip_newlines(p)
	for !at_end(p) {
		if peek_kind(p) == .At {
			parse_directive(p, &module_doc, &pending, seen_decl) or_return
			skip_newlines(p)
			continue
		}
		parse_declaration(p, &out, &pending) or_return
		seen_decl = true
		pending = empty_directives()
		skip_newlines(p)
	}
	return Ast {
			module_doc = module_doc,
			imports = out.imports[:],
			decls = out.decls[:],
			lets = out.lets[:],
			datas = out.datas[:],
			enums = out.enums[:],
			things = out.things[:],
			signals = out.signals[:],
			fns = out.fns[:],
			queries = out.queries[:],
			behaviors = out.behaviors[:],
			pipelines = out.pipelines[:],
			tests = out.tests[:],
			extern_types = out.extern_types[:],
		},
		.None
}

empty_directives :: proc() -> Directives {
	return Directives {
		gtags = make([dynamic]string, 0, 4, context.temp_allocator),
		probes = make([dynamic]Debug_Probe, 0, 4, context.temp_allocator),
		todos = make([dynamic]Todo_Node, 0, 4, context.temp_allocator),
		indexes = make([dynamic]Index_Directive, 0, 2, context.temp_allocator),
	}
}

Decl_Sink :: struct {
	imports:   [dynamic]Import_Node,
	decls:     [dynamic]Decl_Ref,
	lets:      [dynamic]Let_Decl_Node,
	datas:     [dynamic]Data_Node,
	enums:     [dynamic]Enum_Node,
	things:    [dynamic]Thing_Node,
	signals:   [dynamic]Signal_Node,
	fns:       [dynamic]Fn_Node,
	queries:   [dynamic]Query_Node,
	behaviors: [dynamic]Behavior_Node,
	pipelines: [dynamic]Pipeline_Node,
	tests:     [dynamic]Test_Node,
	extern_types: [dynamic]Extern_Type_Node,
}

sink_mark :: proc(out: ^Decl_Sink, kind: Ast_Decl_Kind) {
	index := 0
	switch kind {
	case .Let:
		index = len(out.lets) - 1
	case .Data:
		index = len(out.datas) - 1
	case .Enum:
		index = len(out.enums) - 1
	case .Thing:
		index = len(out.things) - 1
	case .Signal:
		index = len(out.signals) - 1
	case .Fn:
		index = len(out.fns) - 1
	case .Query:
		index = len(out.queries) - 1
	case .Behavior:
		index = len(out.behaviors) - 1
	case .Pipeline:
		index = len(out.pipelines) - 1
	case .Test:
		index = len(out.tests) - 1
	case .Extern_Type:
		index = len(out.extern_types) - 1
	}
	append(&out.decls, Decl_Ref{kind = kind, index = index})
}

parse_declaration :: proc(p: ^Parser, out: ^Decl_Sink, pending: ^Directives) -> Parse_Error {
	if pending.has_migrate {
		if peek_kind(p) != .Ident || p.tokens[p.pos].text != "data" {
			return .Migrate_Wrong_Target
		}
		if pending.migrate.has_with {
			return .Migrate_Wrong_Target
		}
	}
	if len(pending.indexes) > 0 {
		if peek_kind(p) != .Ident || p.tokens[p.pos].text != "query" {
			return .Index_Wrong_Target
		}
	}
	#partial switch peek_kind(p) {
	case .Import:
		node := parse_import(p) or_return
		append(&out.imports, node)
	case .Let:
		node := parse_let_decl(p) or_return
		node.doc = pending.doc
		node.gtags = pending.gtags[:]
		node.probes = pending.probes[:]
		node.todos = pending.todos[:]
		node.exposed = pending.exposed
		append(&out.lets, node)
		sink_mark(out, .Let)
	case .Ident:
		return parse_contextual_declaration(p, out, pending)
	case .Signal:
		node := parse_signal(p) or_return
		node.doc = pending.doc
		node.gtags = pending.gtags[:]
		node.probes = pending.probes[:]
		node.todos = pending.todos[:]
		node.exposed = pending.exposed
		append(&out.signals, node)
		sink_mark(out, .Signal)
	case .Fn:
		node := parse_fn_decl(p) or_return
		node.doc = pending.doc
		node.gtags = pending.gtags[:]
		node.probes = pending.probes[:]
		node.todos = pending.todos[:]
		node.exposed = pending.exposed
		append(&out.fns, node)
		sink_mark(out, .Fn)
	case .Extern:
		return parse_extern_declaration(p, out, pending)
	case .Behavior:
		node := parse_behavior(p) or_return
		node.doc = pending.doc
		node.gtags = pending.gtags[:]
		node.probes = pending.probes[:]
		node.todos = pending.todos[:]
		node.exposed = pending.exposed
		append(&out.behaviors, node)
		sink_mark(out, .Behavior)
	case .Pipeline:
		node := parse_pipeline(p) or_return
		node.doc = pending.doc
		node.gtags = pending.gtags[:]
		node.probes = pending.probes[:]
		node.todos = pending.todos[:]
		node.exposed = pending.exposed
		append(&out.pipelines, node)
		sink_mark(out, .Pipeline)
	case .Test:
		node := parse_test(p) or_return
		node.doc = pending.doc
		node.probes = pending.probes[:]
		append(&out.tests, node)
		sink_mark(out, .Test)
	case:
		return .Unexpected_Token
	}
	return .None
}

parse_contextual_declaration :: proc(p: ^Parser, out: ^Decl_Sink, pending: ^Directives) -> Parse_Error {
	switch p.tokens[p.pos].text {
	case "data":
		node := parse_data(p) or_return
		node.doc = pending.doc
		node.gtags = pending.gtags[:]
		node.probes = pending.probes[:]
		node.todos = pending.todos[:]
		node.migrate = pending.migrate
		node.has_migrate = pending.has_migrate
		node.exposed = pending.exposed
		append(&out.datas, node)
		sink_mark(out, .Data)
	case "enum":
		node := parse_enum(p) or_return
		node.doc = pending.doc
		node.gtags = pending.gtags[:]
		node.probes = pending.probes[:]
		node.todos = pending.todos[:]
		node.exposed = pending.exposed
		append(&out.enums, node)
		sink_mark(out, .Enum)
	case "thing", "singleton":
		node := parse_thing(p) or_return
		node.doc = pending.doc
		node.gtags = pending.gtags[:]
		node.probes = pending.probes[:]
		node.todos = pending.todos[:]
		node.exposed = pending.exposed
		append(&out.things, node)
		sink_mark(out, .Thing)
	case "query":
		node := parse_query(p) or_return
		node.doc = pending.doc
		node.gtags = pending.gtags[:]
		node.probes = pending.probes[:]
		node.todos = pending.todos[:]
		node.exposed = pending.exposed
		node.indexes = pending.indexes[:]
		append(&out.queries, node)
		sink_mark(out, .Query)
	case:
		return .Unexpected_Token
	}
	return .None
}

parse_directive :: proc(p: ^Parser, module_doc: ^string, pending: ^Directives, seen_decl: bool) -> Parse_Error {
	at_tok := expect(p, .At) or_return
	name := expect(p, .Ident) or_return
	switch name.text {
	case "doc":
		expect(p, .L_Paren) or_return
		str := expect(p, .String_Lit) or_return
		expect(p, .R_Paren) or_return
		terminate_statement(p) or_return
		skip_newlines(p)
		if !seen_decl && module_doc^ == "" && peek_kind(p) == .Import {
			module_doc^ = str.text
		} else {
			pending.doc = str.text
		}
	case "gtag":
		expect(p, .L_Paren) or_return
		for peek_kind(p) == .String_Lit {
			tag := advance(p) or_return
			append(&pending.gtags, tag.text)
			if peek_kind(p) == .Comma {
				p.pos += 1
			} else {
				break
			}
		}
		expect(p, .R_Paren) or_return
		terminate_statement(p) or_return
	case "todo":
		expect(p, .L_Paren) or_return
		msg := expect(p, .String_Lit) or_return
		if peek_kind(p) != .Comma {
			return reject(p, at_tok, .Malformed_Todo_Window)
		}
		p.pos += 1
		window := parse_todo_window(p) or_return
		expect(p, .R_Paren) or_return
		terminate_statement(p) or_return
		append(&pending.todos, Todo_Node{message = msg.text, window = window, line = at_tok.line})
	case "break", "log", "watch":
		if peek_kind(p) != .L_Paren {
			return reject(p, at_tok, .Probe_Missing_Arg)
		}
		p.pos += 1
		if peek_kind(p) == .R_Paren {
			return reject(p, at_tok, .Probe_Missing_Arg)
		}
		arg := parse_expression(p) or_return
		expect(p, .R_Paren) or_return
		terminate_statement(p) or_return
		kind: Debug_Probe_Kind
		switch name.text {
		case "break":
			kind = .Break
		case "log":
			kind = .Log
		case "watch":
			kind = .Watch
		}
		append(&pending.probes, Debug_Probe{kind = kind, arg = arg, line = at_tok.line})
	case "migrate":
		if pending.has_migrate {
			return reject(p, at_tok, .Malformed_Migrate)
		}
		node := parse_migrate_args(p, at_tok.line) or_return
		terminate_statement(p) or_return
		pending.migrate = node
		pending.has_migrate = true
	case "trace":
		if peek_kind(p) == .L_Paren {
			return reject(p, at_tok, .Probe_Unexpected_Arg)
		}
		terminate_statement(p) or_return
		append(&pending.probes, Debug_Probe{kind = .Trace, line = at_tok.line})
	case "expose":
		if peek_kind(p) == .L_Paren {
			return reject(p, at_tok, .Expose_Unexpected_Arg)
		}
		terminate_statement(p) or_return
		pending.exposed = true
	case "index", "spatial":
		kind := Index_Directive_Kind.Index if name.text == "index" else Index_Directive_Kind.Spatial
		node := parse_index_path(p, kind, at_tok.line) or_return
		terminate_statement(p) or_return
		append(&pending.indexes, node)
	case:
		return reject(p, name, .Unexpected_Token)
	}
	return .None
}

parse_todo_window :: proc(p: ^Parser) -> (window: Todo_Window, err: Parse_Error) {
	#partial switch peek_kind(p) {
	case .Int_Lit:
		lead := advance(p) or_return
		if peek_kind(p) == .Minus {
			return parse_todo_date(p, lead)
		}
		if peek_kind(p) != .Ident {
			return window, reject(p, lead, .Malformed_Todo_Window)
		}
		unit := advance(p) or_return
		switch unit.text {
		case "h", "d", "w", "mo", "q", "y":
			return Todo_Window{form = .Duration, amount = lead.int_value, unit = unit.text}, .None
		case "builds":
			return Todo_Window{form = .Build_Count, amount = lead.int_value}, .None
		case:
			return window, reject(p, lead, .Malformed_Todo_Window)
		}
	case .Ident:
		lead := advance(p) or_return
		if lead.text != "T" || peek_kind(p) != .Minus {
			return window, reject(p, lead, .Malformed_Todo_Window)
		}
		p.pos += 1
		if peek_kind(p) != .Int_Lit {
			return window, reject(p, lead, .Malformed_Todo_Window)
		}
		digits := advance(p) or_return
		return Todo_Window{form = .Task_Ref, task = digits.text}, .None
	case:
		return window, .Malformed_Todo_Window
	}
}

parse_todo_date :: proc(p: ^Parser, year_tok: Token) -> (window: Todo_Window, err: Parse_Error) {
	if len(year_tok.text) != 4 {
		return window, reject(p, year_tok, .Malformed_Todo_Window)
	}
	p.pos += 1
	if peek_kind(p) != .Int_Lit {
		return window, reject(p, year_tok, .Malformed_Todo_Window)
	}
	month_tok := advance(p) or_return
	if len(month_tok.text) != 2 || month_tok.int_value < 1 || month_tok.int_value > 12 {
		return window, reject(p, year_tok, .Malformed_Todo_Window)
	}
	if peek_kind(p) != .Minus {
		return window, reject(p, year_tok, .Malformed_Todo_Window)
	}
	p.pos += 1
	if peek_kind(p) != .Int_Lit {
		return window, reject(p, year_tok, .Malformed_Todo_Window)
	}
	day_tok := advance(p) or_return
	if len(day_tok.text) != 2 || day_tok.int_value < 1 || day_tok.int_value > 31 {
		return window, reject(p, year_tok, .Malformed_Todo_Window)
	}
	return Todo_Window {
			form = .Date,
			year = year_tok.int_value,
			month = month_tok.int_value,
			day = day_tok.int_value,
		},
		.None
}

parse_migrate_args :: proc(p: ^Parser, line: int) -> (node: Migrate_Node, err: Parse_Error) {
	node.line = line
	if peek_kind(p) != .L_Paren {
		return node, .Malformed_Migrate
	}
	p.pos += 1
	if peek_kind(p) == .Ident && p.tokens[p.pos].text == "from" {
		p.pos += 1
		if peek_kind(p) != .Colon {
			return node, .Malformed_Migrate
		}
		p.pos += 1
		if peek_kind(p) != .String_Lit {
			return node, .Malformed_Migrate
		}
		from := advance(p) or_return
		if from.text == "" {
			return node, reject(p, from, .Malformed_Migrate)
		}
		node.from = from.text
		node.has_from = true
		if peek_kind(p) == .Comma {
			p.pos += 1
			if peek_kind(p) != .With {
				return node, .Malformed_Migrate
			}
			parse_migrate_with(p, &node) or_return
		}
	} else if peek_kind(p) == .With {
		parse_migrate_with(p, &node) or_return
	} else {
		return node, .Malformed_Migrate
	}
	if peek_kind(p) != .R_Paren {
		return node, .Malformed_Migrate
	}
	p.pos += 1
	return node, .None
}

parse_migrate_with :: proc(p: ^Parser, node: ^Migrate_Node) -> Parse_Error {
	p.pos += 1
	if peek_kind(p) != .Colon {
		return .Malformed_Migrate
	}
	p.pos += 1
	if peek_kind(p) != .Ident {
		return .Malformed_Migrate
	}
	convert := advance(p) or_return
	if convert.class != .Snake_Case {
		return reject(p, convert, .Wrong_Case)
	}
	node.with = convert.text
	node.has_with = true
	return .None
}

parse_index_path :: proc(p: ^Parser, kind: Index_Directive_Kind, line: int) -> (node: Index_Directive, err: Parse_Error) {
	node.kind = kind
	node.line = line
	if peek_kind(p) != .L_Paren {
		return node, .Malformed_Index_Path
	}
	p.pos += 1
	if peek_kind(p) != .Ident {
		return node, .Malformed_Index_Path
	}
	thing := advance(p) or_return
	if !is_upper_ident(thing.class) {
		return node, reject(p, thing, .Wrong_Case)
	}
	if peek_kind(p) != .Dot {
		return node, .Malformed_Index_Path
	}
	p.pos += 1
	if peek_kind(p) != .Ident {
		return node, .Malformed_Index_Path
	}
	field := advance(p) or_return
	if field.class != .Snake_Case {
		return node, reject(p, field, .Wrong_Case)
	}
	if peek_kind(p) != .R_Paren {
		return node, .Malformed_Index_Path
	}
	p.pos += 1
	node.thing = thing.text
	node.field = field.text
	return node, .None
}

parse_import :: proc(p: ^Parser) -> (node: Import_Node, err: Parse_Error) {
	import_tok := expect(p, .Import) or_return
	segments := make([dynamic]string, 0, 4, context.temp_allocator)
	members: []string
	for {
		tok := expect(p, .Ident) or_return
		if peek_kind(p) == .Dot {
			if tok.class != .Snake_Case {
				return node, reject(p, tok, .Wrong_Case)
			}
			append(&segments, tok.text)
			p.pos += 1
			if peek_kind(p) == .L_Brace {
				members = parse_import_group(p) or_return
				break
			}
			continue
		}
		if tok.class == .Mixed {
			return node, reject(p, tok, .Wrong_Case)
		}
		append(&segments, tok.text)
		break
	}
	terminate_statement(p) or_return
	return Import_Node {
			segments = segments[:],
			members = members,
			line = import_tok.line,
			col = import_tok.col,
		},
		.None
}

parse_import_group :: proc(p: ^Parser) -> (members: []string, err: Parse_Error) {
	expect(p, .L_Brace) or_return
	list := make([dynamic]string, 0, 8, context.temp_allocator)
	skip_newlines(p)
	for peek_kind(p) == .Ident {
		tok := advance(p) or_return
		if tok.class == .Mixed {
			return nil, reject(p, tok, .Wrong_Case)
		}
		append(&list, tok.text)
		for peek_kind(p) == .Comma || peek_kind(p) == .Newline {
			p.pos += 1
		}
	}
	expect(p, .R_Brace) or_return
	return list[:], .None
}

parse_test :: proc(p: ^Parser) -> (test: Test_Node, err: Parse_Error) {
	test_tok := expect(p, .Test) or_return
	name_tok := expect(p, .String_Lit) or_return
	expect(p, .L_Brace) or_return
	skip_newlines(p)
	body := make([dynamic]Statement, 0, 4, context.temp_allocator)
	body_loop: for {
		#partial switch peek_kind(p) {
		case .Assert:
			node := parse_assert(p) or_return
			append(&body, node)
		case .Let:
			node := parse_let(p) or_return
			append(&body, node)
		case:
			break body_loop
		}
		skip_newlines(p)
	}
	expect(p, .R_Brace) or_return
	return Test_Node{name = name_tok.text, body = body[:], line = test_tok.line}, .None
}

parse_assert :: proc(p: ^Parser) -> (node: Assert_Node, err: Parse_Error) {
	expect(p, .Assert) or_return
	expr := parse_expression(p) or_return
	terminate_statement(p) or_return
	return Assert_Node{expr = expr}, .None
}

parse_let :: proc(p: ^Parser) -> (node: Let_Node, err: Parse_Error) {
	expect(p, .Let) or_return
	if peek_kind(p) == .L_Paren {
		return parse_let_tuple(p)
	}
	name := expect(p, .Ident) or_return
	if name.class != .Snake_Case && name.class != .Upper_Snake {
		return node, reject(p, name, .Wrong_Case)
	}
	expect(p, .Eq) or_return
	value := parse_expression(p) or_return
	terminate_statement(p) or_return
	return Let_Node{name = name.text, value = value}, .None
}

parse_let_tuple :: proc(p: ^Parser) -> (node: Let_Node, err: Parse_Error) {
	expect(p, .L_Paren) or_return
	names := make([dynamic]string, 0, 2, context.temp_allocator)
	for {
		name := expect(p, .Ident) or_return
		if name.class != .Snake_Case {
			return node, reject(p, name, .Wrong_Case)
		}
		append(&names, name.text)
		if peek_kind(p) != .Comma {
			break
		}
		p.pos += 1
	}
	expect(p, .R_Paren) or_return
	expect(p, .Eq) or_return
	value := parse_expression(p) or_return
	terminate_statement(p) or_return
	return Let_Node{names = names[:], is_tuple = true, value = value}, .None
}

parse_let_decl :: proc(p: ^Parser) -> (node: Let_Decl_Node, err: Parse_Error) {
	let_tok := expect(p, .Let) or_return
	name := expect(p, .Ident) or_return
	if name.class != .Snake_Case && name.class != .Upper_Snake {
		return node, reject(p, name, .Wrong_Case)
	}
	expect(p, .Colon) or_return
	type := parse_type_ref(p) or_return
	expect(p, .Eq) or_return
	value := parse_expression(p) or_return
	terminate_statement(p) or_return
	return Let_Decl_Node{name = name.text, type = type, value = value, line = let_tok.line}, .None
}

parse_data :: proc(p: ^Parser) -> (node: Data_Node, err: Parse_Error) {
	data_tok := expect(p, .Ident) or_return
	name := expect_type_name(p) or_return
	type_params := parse_type_params(p) or_return
	kind := parse_optional_kind(p) or_return
	fields := parse_field_list(p, is_data_body = true) or_return
	return Data_Node{name = name, kind = kind, type_params = type_params, fields = fields, line = data_tok.line}, .None
}

parse_thing :: proc(p: ^Parser) -> (node: Thing_Node, err: Parse_Error) {
	is_singleton := p.tokens[p.pos].text == "singleton"
	thing_tok := expect(p, .Ident) or_return
	name := expect_type_name(p) or_return
	fields := parse_field_list(p) or_return
	return Thing_Node{name = name, is_singleton = is_singleton, fields = fields, line = thing_tok.line}, .None
}

parse_signal :: proc(p: ^Parser) -> (node: Signal_Node, err: Parse_Error) {
	signal_tok := expect(p, .Signal) or_return
	name := expect_type_name(p) or_return
	fields := parse_field_list(p) or_return
	return Signal_Node{name = name, fields = fields, line = signal_tok.line}, .None
}

parse_type_params :: proc(p: ^Parser) -> (params: []string, err: Parse_Error) {
	if peek_kind(p) != .L_Bracket {
		return nil, .None
	}
	p.pos += 1
	list := make([dynamic]string, 0, 2, context.temp_allocator)
	for {
		if peek_kind(p) != .Ident {
			return nil, .Malformed_Type_Params
		}
		tok := advance(p) or_return
		if !is_upper_ident(tok.class) {
			return nil, reject(p, tok, .Wrong_Case)
		}
		append(&list, tok.text)
		if peek_kind(p) == .Comma {
			p.pos += 1
			continue
		}
		break
	}
	if peek_kind(p) != .R_Bracket {
		return nil, .Malformed_Type_Params
	}
	p.pos += 1
	return list[:], .None
}

parse_optional_kind :: proc(p: ^Parser) -> (kind: string, err: Parse_Error) {
	if peek_kind(p) != .Colon {
		return "", .None
	}
	p.pos += 1
	kind_tok := expect_type_name(p) or_return
	return kind_tok, .None
}

parse_field_list :: proc(p: ^Parser, is_data_body := false) -> (fields: []Field_Decl, err: Parse_Error) {
	expect(p, .L_Brace) or_return
	skip_field_separators(p)
	list := make([dynamic]Field_Decl, 0, 8, context.temp_allocator)
	pending_migrate := Migrate_Node{}
	has_pending_migrate := false
	pending_probes := make([dynamic]Debug_Probe, 0, 2, context.temp_allocator)
	for {
		if peek_kind(p) == .At {
			at_tok := advance(p) or_return
			directive := expect(p, .Ident) or_return
			switch directive.text {
			case "migrate":
				if !is_data_body {
					return nil, reject(p, at_tok, .Migrate_Wrong_Target)
				}
				if has_pending_migrate {
					return nil, reject(p, at_tok, .Malformed_Migrate)
				}
				pending_migrate = parse_migrate_args(p, at_tok.line) or_return
				has_pending_migrate = true
			case "watch":
				if !is_data_body {
					return nil, reject(p, at_tok, .Probe_Wrong_Target)
				}
				if peek_kind(p) != .L_Paren {
					return nil, reject(p, at_tok, .Probe_Missing_Arg)
				}
				p.pos += 1
				if peek_kind(p) == .R_Paren {
					return nil, reject(p, at_tok, .Probe_Missing_Arg)
				}
				arg := parse_expression(p) or_return
				expect(p, .R_Paren) or_return
				append(&pending_probes, Debug_Probe{kind = .Watch, arg = arg, line = at_tok.line})
			case "break", "log", "trace":
				return nil, reject(p, at_tok, .Probe_Wrong_Target)
			case:
				return nil, reject(p, at_tok, .Unexpected_Token)
			}
			skip_newlines(p)
			continue
		}
		if peek_kind(p) != .Ident {
			break
		}
		fname := advance(p) or_return
		if fname.class != .Snake_Case {
			return nil, reject(p, fname, .Wrong_Case)
		}
		expect(p, .Colon) or_return
		type := parse_type_ref(p) or_return
		field := Field_Decl{name = fname.text, type = type}
		if peek_kind(p) == .Eq {
			p.pos += 1
			field.default = parse_expression(p) or_return
			field.has_default = true
		}
		field.migrate = pending_migrate
		field.has_migrate = has_pending_migrate
		if len(pending_probes) > 0 {
			field.probes = pending_probes[:]
		}
		pending_migrate = Migrate_Node{}
		has_pending_migrate = false
		pending_probes = make([dynamic]Debug_Probe, 0, 2, context.temp_allocator)
		append(&list, field)
		skip_field_separators(p)
	}
	if has_pending_migrate {
		return nil, .Migrate_Wrong_Target
	}
	if len(pending_probes) > 0 {
		return nil, .Probe_Wrong_Target
	}
	expect(p, .R_Brace) or_return
	return list[:], .None
}

parse_enum :: proc(p: ^Parser) -> (node: Enum_Node, err: Parse_Error) {
	enum_tok := expect(p, .Ident) or_return
	name := expect_type_name(p) or_return
	type_params := parse_type_params(p) or_return
	kind := parse_optional_kind(p) or_return
	expect(p, .L_Brace) or_return
	skip_field_separators(p)
	variants := make([dynamic]Variant_Decl, 0, 8, context.temp_allocator)
	pending_doc := ""
	has_pending_doc := false
	for {
		if peek_kind(p) == .At {
			p.pos += 1
			directive := expect(p, .Ident) or_return
			switch directive.text {
			case "doc":
				expect(p, .L_Paren) or_return
				str := expect(p, .String_Lit) or_return
				expect(p, .R_Paren) or_return
				pending_doc = str.text
				has_pending_doc = true
				skip_newlines(p)
			case "migrate":
				return node, reject(p, directive, .Migrate_Wrong_Target)
			case "index", "spatial":
				return node, reject(p, directive, .Index_Wrong_Target)
			case "gtag", "todo", "expose", "break", "log", "watch", "trace":
				return node, reject(p, directive, .Variant_Directive_Wrong_Target)
			case:
				return node, reject(p, directive, .Unexpected_Token)
			}
			continue
		}
		if peek_kind(p) != .Ident {
			break
		}
		variant := parse_variant(p) or_return
		variant.doc = pending_doc
		pending_doc = ""
		has_pending_doc = false
		append(&variants, variant)
		skip_field_separators(p)
	}
	if has_pending_doc {
		return node, .Variant_Directive_Wrong_Target
	}
	expect(p, .R_Brace) or_return
	return Enum_Node{name = name, kind = kind, type_params = type_params, variants = variants[:], line = enum_tok.line}, .None
}

parse_variant :: proc(p: ^Parser) -> (variant: Variant_Decl, err: Parse_Error) {
	name := expect(p, .Ident) or_return
	if !is_upper_ident(name.class) {
		return variant, reject(p, name, .Wrong_Case)
	}
	variant.name = name.text
	#partial switch peek_kind(p) {
	case .L_Paren:
		p.pos += 1
		types := make([dynamic]Type_Ref, 0, 4, context.temp_allocator)
		for peek_kind(p) != .R_Paren {
			type := parse_type_ref(p) or_return
			append(&types, type)
			if peek_kind(p) == .Comma {
				p.pos += 1
			} else {
				break
			}
		}
		expect(p, .R_Paren) or_return
		variant.payload = .Tuple
		variant.tuple = types[:]
	case .L_Brace:
		fields := parse_field_list(p) or_return
		variant.payload = .Struct
		variant.fields = fields
	case:
		variant.payload = .Plain
	}
	return variant, .None
}

parse_fn_decl :: proc(p: ^Parser) -> (node: Fn_Node, err: Parse_Error) {
	fn_tok := expect(p, .Fn) or_return
	name := expect(p, .Ident) or_return
	if name.class != .Snake_Case {
		return node, reject(p, name, .Wrong_Case)
	}
	fn := parse_fn_rest(p) or_return
	fn.name = name.text
	fn.line = fn_tok.line
	return fn, .None
}

parse_extern_declaration :: proc(p: ^Parser, out: ^Decl_Sink, pending: ^Directives) -> Parse_Error {
	extern_tok := expect(p, .Extern) or_return
	#partial switch peek_kind(p) {
	case .Fn:
		node := parse_extern_fn_decl(p, extern_tok.line) or_return
		node.doc = pending.doc
		node.gtags = pending.gtags[:]
		node.probes = pending.probes[:]
		node.todos = pending.todos[:]
		node.exposed = pending.exposed
		append(&out.fns, node)
		sink_mark(out, .Fn)
	case .Type:
		node := parse_extern_type_decl(p, extern_tok.line) or_return
		node.doc = pending.doc
		node.gtags = pending.gtags[:]
		node.probes = pending.probes[:]
		node.todos = pending.todos[:]
		node.exposed = pending.exposed
		append(&out.extern_types, node)
		sink_mark(out, .Extern_Type)
	case:
		return reject(p, peek_tok(p), .Malformed_Extern)
	}
	return .None
}

parse_extern_fn_decl :: proc(p: ^Parser, extern_line: int) -> (node: Fn_Node, err: Parse_Error) {
	expect(p, .Fn) or_return
	name := expect(p, .Ident) or_return
	if name.class != .Snake_Case {
		return node, reject(p, name, .Wrong_Case)
	}
	params := parse_param_list(p) or_return
	expect(p, .Arrow) or_return
	return_type := parse_type_ref(p) or_return
	terminate_statement(p) or_return
	return Fn_Node {
			name = name.text,
			params = params,
			return_type = return_type,
			line = extern_line,
			is_extern = true,
		},
		.None
}

parse_extern_type_decl :: proc(p: ^Parser, extern_line: int) -> (node: Extern_Type_Node, err: Parse_Error) {
	expect(p, .Type) or_return
	name := expect_type_name(p) or_return
	type_params := parse_type_params(p) or_return
	terminate_statement(p) or_return
	return Extern_Type_Node{name = name, type_params = type_params, line = extern_line}, .None
}

parse_query :: proc(p: ^Parser) -> (node: Query_Node, err: Parse_Error) {
	query_tok := expect(p, .Ident) or_return
	name := expect(p, .Ident) or_return
	if name.class != .Snake_Case {
		return node, reject(p, name, .Wrong_Case)
	}
	params := parse_param_list(p) or_return
	expect(p, .Arrow) or_return
	return_type := parse_type_ref(p) or_return
	body := parse_fn_body(p) or_return
	return Query_Node {
			name = name.text,
			params = params,
			return_type = return_type,
			body = body,
			line = query_tok.line,
		},
		.None
}

parse_fn_rest :: proc(p: ^Parser) -> (node: Fn_Node, err: Parse_Error) {
	params := parse_param_list(p) or_return
	expect(p, .Arrow) or_return
	return_type := parse_type_ref(p) or_return
	if peek_kind(p) == .At {
		node = parse_stub_body(p) or_return
		node.params = params
		node.return_type = return_type
		return node, .None
	}
	body := parse_fn_body(p) or_return
	return Fn_Node{params = params, return_type = return_type, body = body}, .None
}

parse_param_list :: proc(p: ^Parser) -> (params: []Param_Decl, err: Parse_Error) {
	expect(p, .L_Paren) or_return
	list := make([dynamic]Param_Decl, 0, 4, context.temp_allocator)
	for peek_kind(p) == .Ident {
		pname := advance(p) or_return
		if pname.class != .Snake_Case {
			return nil, .Wrong_Case
		}
		expect(p, .Colon) or_return
		type := parse_type_ref(p) or_return
		append(&list, Param_Decl{name = pname.text, type = type})
		if peek_kind(p) == .Comma {
			p.pos += 1
		} else {
			break
		}
	}
	expect(p, .R_Paren) or_return
	return list[:], .None
}

parse_fn_body :: proc(p: ^Parser) -> (body: []Statement, err: Parse_Error) {
	expect(p, .L_Brace) or_return
	skip_newlines(p)
	stmts := make([dynamic]Statement, 0, 4, context.temp_allocator)
	body_loop: for {
		#partial switch peek_kind(p) {
		case .Let:
			node := parse_let(p) or_return
			append(&stmts, node)
		case .Return:
			node := parse_return(p) or_return
			append(&stmts, node)
		case .If:
			node := parse_if_stmt(p) or_return
			append(&stmts, node)
		case:
			if !at_end(p) && leading_binary_op(p.tokens[p.pos]) {
				return nil, reject(p, p.tokens[p.pos], .Newline_Before_Binary_Op)
			}
			break body_loop
		}
		skip_newlines(p)
	}
	expect(p, .R_Brace) or_return
	return stmts[:], .None
}

parse_stub_body :: proc(p: ^Parser) -> (node: Fn_Node, err: Parse_Error) {
	expect(p, .At) or_return
	node.hole_type, node.fallback, node.has_fallback = parse_stub_parts(p) or_return
	node.holed = true
	terminate_statement(p) or_return
	return node, .None
}

parse_stub_parts :: proc(p: ^Parser) -> (hole_type: Type_Ref, fallback: Expr, has_fallback: bool, err: Parse_Error) {
	name := expect(p, .Ident) or_return
	if name.text != "stub" {
		return hole_type, nil, false, reject(p, name, .Unexpected_Token)
	}
	expect(p, .L_Paren) or_return
	saved := p.no_record_brace
	p.no_record_brace = false
	defer p.no_record_brace = saved
	hole_type = parse_type_ref(p) or_return
	if peek_kind(p) == .Comma {
		p.pos += 1
		fallback = parse_expression(p) or_return
		has_fallback = true
	}
	expect(p, .R_Paren) or_return
	return hole_type, fallback, has_fallback, .None
}

parse_return :: proc(p: ^Parser) -> (node: Return_Node, err: Parse_Error) {
	expect(p, .Return) or_return
	value := parse_expression(p) or_return
	terminate_statement(p) or_return
	return Return_Node{value = value}, .None
}

parse_if_stmt :: proc(p: ^Parser) -> (node: If_Node, err: Parse_Error) {
	expect(p, .If) or_return
	saved := p.no_record_brace
	p.no_record_brace = true
	cond := parse_expression(p) or_return
	p.no_record_brace = saved
	body := parse_fn_body(p) or_return
	return If_Node{cond = cond, body = body}, .None
}

parse_behavior :: proc(p: ^Parser) -> (node: Behavior_Node, err: Parse_Error) {
	behavior_tok := expect(p, .Behavior) or_return
	name := expect(p, .Ident) or_return
	if name.class != .Snake_Case {
		return node, reject(p, name, .Wrong_Case)
	}
	on_tok := expect(p, .Ident) or_return
	if on_tok.text != "on" {
		return node, reject(p, on_tok, .Unexpected_Token)
	}
	target := expect_type_name(p) or_return
	expect(p, .L_Brace) or_return
	skip_newlines(p)
	expect(p, .Fn) or_return
	step_name := expect(p, .Ident) or_return
	if step_name.text != "step" {
		return node, reject(p, step_name, .Unexpected_Token)
	}
	step := parse_fn_rest(p) or_return
	step.name = "step"
	skip_newlines(p)
	expect(p, .R_Brace) or_return
	return Behavior_Node{name = name.text, target = target, step = step, line = behavior_tok.line}, .None
}

parse_pipeline :: proc(p: ^Parser) -> (node: Pipeline_Node, err: Parse_Error) {
	pipeline_tok := expect(p, .Pipeline) or_return
	name := expect_type_name(p) or_return
	expect(p, .L_Brace) or_return
	skip_field_separators(p)
	stages := make([dynamic]Pipeline_Stage, 0, 8, context.temp_allocator)
	pending_probes := make([dynamic]Debug_Probe, 0, 2, context.temp_allocator)
	for {
		if peek_kind(p) == .At {
			at_tok := advance(p) or_return
			directive := expect(p, .Ident) or_return
			switch directive.text {
			case "trace":
				if peek_kind(p) == .L_Paren {
					return node, reject(p, directive, .Probe_Unexpected_Arg)
				}
				append(&pending_probes, Debug_Probe{kind = .Trace, line = at_tok.line})
			case "break", "log", "watch":
				return node, reject(p, directive, .Probe_Wrong_Target)
			case:
				return node, reject(p, directive, .Unexpected_Token)
			}
			skip_newlines(p)
			continue
		}
		if peek_kind(p) != .Ident {
			break
		}
		sname := advance(p) or_return
		if sname.class != .Snake_Case {
			return node, reject(p, sname, .Wrong_Case)
		}
		expect(p, .Colon) or_return
		stage := parse_pipeline_stage(p, sname.text) or_return
		if len(pending_probes) > 0 {
			stage.probes = pending_probes[:]
		}
		pending_probes = make([dynamic]Debug_Probe, 0, 2, context.temp_allocator)
		append(&stages, stage)
		skip_field_separators(p)
	}
	if len(pending_probes) > 0 {
		return node, .Probe_Wrong_Target
	}
	expect(p, .R_Brace) or_return
	return Pipeline_Node{name = name, stages = stages[:], line = pipeline_tok.line}, .None
}

parse_pipeline_stage :: proc(p: ^Parser, name: string) -> (stage: Pipeline_Stage, err: Parse_Error) {
	if peek_kind(p) == .L_Bracket {
		behaviors := parse_behavior_list(p) or_return
		return Pipeline_Stage{name = name, behaviors = behaviors}, .None
	}
	battery := expect(p, .Ident) or_return
	if battery.class != .Snake_Case {
		return stage, reject(p, battery, .Wrong_Case)
	}
	return Pipeline_Stage{name = name, battery = battery.text, is_battery = true}, .None
}

parse_behavior_list :: proc(p: ^Parser) -> (names: []string, err: Parse_Error) {
	expect(p, .L_Bracket) or_return
	list := make([dynamic]string, 0, 4, context.temp_allocator)
	for peek_kind(p) == .Ident {
		bname := advance(p) or_return
		if bname.class != .Snake_Case {
			return nil, reject(p, bname, .Wrong_Case)
		}
		append(&list, bname.text)
		for peek_kind(p) == .Comma || peek_kind(p) == .Newline {
			p.pos += 1
		}
	}
	expect(p, .R_Bracket) or_return
	return list[:], .None
}

parse_type_ref :: proc(p: ^Parser) -> (type: Type_Ref, err: Parse_Error) {
	if peek_kind(p) == .L_Bracket {
		p.pos += 1
		elem := parse_type_ref(p) or_return
		expect(p, .R_Bracket) or_return
		args := make([]Type_Ref, 1, context.temp_allocator)
		args[0] = elem
		return Type_Ref{name = TYPE_REF_LIST_HEAD, args = args}, .None
	}
	if peek_kind(p) == .L_Paren {
		return parse_tuple_type_ref(p)
	}
	if peek_kind(p) == .Fn {
		return parse_fn_type_ref(p)
	}
	name := expect(p, .Ident) or_return
	if !is_upper_ident(name.class) {
		return type, reject(p, name, .Wrong_Case)
	}
	type.name = name.text
	if peek_kind(p) == .L_Bracket {
		p.pos += 1
		args := make([dynamic]Type_Ref, 0, 4, context.temp_allocator)
		for peek_kind(p) != .R_Bracket {
			arg := parse_type_ref(p) or_return
			append(&args, arg)
			if peek_kind(p) == .Comma {
				p.pos += 1
			} else {
				break
			}
		}
		expect(p, .R_Bracket) or_return
		type.args = args[:]
	}
	return type, .None
}

parse_tuple_type_ref :: proc(p: ^Parser) -> (type: Type_Ref, err: Parse_Error) {
	expect(p, .L_Paren) or_return
	args := make([dynamic]Type_Ref, 0, 4, context.temp_allocator)
	for peek_kind(p) != .R_Paren {
		arg := parse_type_ref(p) or_return
		append(&args, arg)
		if peek_kind(p) == .Comma {
			p.pos += 1
		} else {
			break
		}
	}
	expect(p, .R_Paren) or_return
	return Type_Ref{name = TYPE_REF_TUPLE_HEAD, args = args[:]}, .None
}

parse_fn_type_ref :: proc(p: ^Parser) -> (type: Type_Ref, err: Parse_Error) {
	expect(p, .Fn) or_return
	if peek_kind(p) != .L_Paren {
		return type, .Malformed_Fn_Type
	}
	p.pos += 1
	args := make([dynamic]Type_Ref, 0, 4, context.temp_allocator)
	if peek_kind(p) != .R_Paren {
		for {
			if !type_ref_ahead(p) {
				return type, .Malformed_Fn_Type
			}
			arg := parse_type_ref(p) or_return
			append(&args, arg)
			if peek_kind(p) == .Comma {
				p.pos += 1
				continue
			}
			break
		}
	}
	if peek_kind(p) != .R_Paren {
		return type, .Malformed_Fn_Type
	}
	p.pos += 1
	if peek_kind(p) != .Arrow {
		return type, .Malformed_Fn_Type
	}
	p.pos += 1
	result := parse_type_ref(p) or_return
	append(&args, result)
	return Type_Ref{name = TYPE_REF_FN_HEAD, args = args[:]}, .None
}

type_ref_ahead :: proc(p: ^Parser) -> bool {
	#partial switch peek_kind(p) {
	case .Ident, .L_Bracket, .L_Paren, .Fn:
		return true
	}
	return false
}

expect_type_name :: proc(p: ^Parser) -> (name: string, err: Parse_Error) {
	tok := expect(p, .Ident) or_return
	if !is_upper_ident(tok.class) {
		return "", reject(p, tok, .Wrong_Case)
	}
	return tok.text, .None
}

skip_field_separators :: proc(p: ^Parser) {
	for peek_kind(p) == .Newline || peek_kind(p) == .Comma {
		p.pos += 1
	}
}

check_ident_case :: proc(p: ^Parser, tok: Token, following: Token_Kind) -> Parse_Error {
	if tok.class == .Mixed {
		return reject(p, tok, .Wrong_Case)
	}
	#partial switch following {
	case .L_Brace, .Colon_Colon:
		if !is_upper_ident(tok.class) {
			return reject(p, tok, .Wrong_Case)
		}
	case .Dot, .L_Paren:
	case:
		if tok.class != .Snake_Case && tok.class != .Upper_Snake {
			return reject(p, tok, .Wrong_Case)
		}
	}
	return .None
}

terminate_statement :: proc(p: ^Parser) -> Parse_Error {
	if peek_kind(p) == .Newline {
		p.pos += 1
		return .None
	}
	if at_end(p) || peek_kind(p) == .R_Brace {
		return .None
	}
	return .Unexpected_Token
}

at_end :: proc(p: ^Parser) -> bool {
	return p.pos >= len(p.tokens)
}

peek_kind :: proc(p: ^Parser) -> Token_Kind {
	if at_end(p) {
		return .Invalid
	}
	return p.tokens[p.pos].kind
}

peek_tok :: proc(p: ^Parser) -> Token {
	if at_end(p) {
		return Token{}
	}
	return p.tokens[p.pos]
}

advance :: proc(p: ^Parser) -> (tok: Token, err: Parse_Error) {
	if at_end(p) {
		return Token{}, .Unexpected_End
	}
	tok = p.tokens[p.pos]
	p.pos += 1
	if tok.kind == .Malformed_Escape {
		return Token{}, .Malformed_String_Escape
	}
	return tok, .None
}

expect :: proc(p: ^Parser, kind: Token_Kind) -> (tok: Token, err: Parse_Error) {
	tok = advance(p) or_return
	if tok.kind != kind {
		return Token{}, .Unexpected_Token
	}
	return tok, .None
}

skip_newlines :: proc(p: ^Parser) {
	for peek_kind(p) == .Newline {
		p.pos += 1
	}
}
