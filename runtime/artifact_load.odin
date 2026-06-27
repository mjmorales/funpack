package funpack_runtime

import "core:os"
import "core:strconv"
import "core:strings"

load_artifact_file :: proc(
	path: string,
	allocator := context.allocator,
) -> (
	program: Program,
	err: Artifact_Error,
	io_ok: bool,
) {
	bytes, read_err := os.read_entire_file_from_path(path, allocator)
	if read_err != nil {
		return {}, .None, false
	}
	defer delete(bytes, allocator)
	loaded, load_err := load_program(string(bytes), allocator)
	return loaded, load_err, true
}

load_program :: proc(
	content: string,
	allocator := context.allocator,
) -> (
	program: Program,
	err: Artifact_Error,
) {
	doc, parse_err := parse_artifact(content, allocator)
	if parse_err != .None {
		return {}, parse_err
	}
	return build_program(doc, allocator)
}

build_program :: proc(
	doc: Artifact_Doc,
	allocator := context.allocator,
) -> (
	program: Program,
	err: Artifact_Error,
) {
	program.schema_version = doc.schema_version

	for section in doc.sections {
		switch section.name {
		case "meta":
			program.meta = load_meta(section, allocator) or_return
		case "enums":
			program.enums = load_enums(section, allocator) or_return
		case "data":
			program.data = load_data(section, allocator) or_return
		case "signals":
			program.signals = load_signals(section, allocator) or_return
		case "things":
			program.things = load_things(section, allocator) or_return
		case "functions":
			program.functions = load_functions(section, allocator) or_return
		case "behaviors":
			program.behaviors = load_behaviors(section, allocator) or_return
		case "pipeline_flattened":
			program.pipeline = load_pipeline(section, allocator) or_return
		case "signal_routing":
			program.routing = load_routing(section, allocator) or_return
		case "setup":
			program.setup = load_setup(section, allocator) or_return
		case "bindings":
			program.bindings = load_bindings(section, allocator) or_return
		case "entrypoint":
			program.entrypoint = load_entrypoint(section, allocator) or_return
		case "queries":
			program.queries = load_queries(section, allocator) or_return
		case "tilemaps":
			program.tilemaps = load_tilemaps(section, allocator) or_return
		case "nav":
			program.navs = load_navs(section, allocator) or_return
		case "assets":
			program.assets = load_assets(section, allocator) or_return
		case "probes":
			program.probes = load_probes(section, allocator) or_return
		case:
			return {}, .Malformed_Header
		}
	}
	program.registry = build_action_registry(program, allocator)
	return program, .None
}

load_meta :: proc(
	section: Artifact_Section,
	allocator := context.allocator,
) -> (
	meta: Project_Meta,
	err: Artifact_Error,
) {
	if len(section.records) != 2 {
		return {}, .Section_Count_Mismatch
	}
	project_fields := record_fields(section.records[0])
	if len(project_fields) < 2 || project_fields[0] != "project" {
		return {}, .Bad_Field
	}
	meta.name = strings.clone(project_fields[1], allocator)

	version_fields := record_fields(section.records[1])
	if len(version_fields) < 2 || version_fields[0] != "version" {
		return {}, .Bad_Field
	}
	v, ok := decode_string(version_fields[1])
	if !ok {
		return {}, .Bad_Field
	}
	meta.version = strings.clone(v, allocator)
	return meta, .None
}

load_enums :: proc(
	section: Artifact_Section,
	allocator := context.allocator,
) -> (
	enums: []Enum_Decl,
	err: Artifact_Error,
) {
	out := make([]Enum_Decl, len(section.records), allocator)
	for rec, i in section.records {
		f := record_fields(rec)
		if len(f) < 4 {
			return nil, .Bad_Field
		}
		variants := make([]Enum_Variant, len(rec.subs), allocator)
		for sub, j in rec.subs {
			sf := strings.fields(sub, context.temp_allocator)
			if len(sf) < 3 || sf[0] != "variant" {
				return nil, .Bad_Field
			}
			variants[j] = Enum_Variant {
				name    = strings.clone(sf[1], allocator),
				payload = strings.clone(strings.join(sf[2:], " ", allocator), allocator),
			}
		}
		out[i] = Enum_Decl {
			name     = strings.clone(f[1], allocator),
			kind     = enum_kind_from_tag(f[2]),
			variants = variants,
		}
	}
	return out, .None
}

enum_kind_from_tag :: proc(tag: string) -> Enum_Kind {
	switch tag {
	case "Axis":
		return .Axis
	case "Button":
		return .Button
	case "CollisionLayer":
		return .Collision_Layer
	case "Num":
		return .Num
	}
	return .None
}

load_data :: proc(
	section: Artifact_Section,
	allocator := context.allocator,
) -> (
	data: []Data_Decl,
	err: Artifact_Error,
) {
	out := make([]Data_Decl, len(section.records), allocator)
	for rec, i in section.records {
		f := record_fields(rec)
		if len(f) < 4 {
			return nil, .Bad_Field
		}
		mutable, ok := decode_bool(f[3])
		if !ok {
			return nil, .Bad_Field
		}
		decl := Data_Decl {
			name    = strings.clone(f[1], allocator),
			mutable = mutable,
		}
		subs := rec.subs
		if len(subs) > 0 && line_keyword(subs[0]) == "migrate" {
			from, with, mig_ok := parse_migrate_line(subs[0])
			if !mig_ok || with != "" || from == "" {
				return nil, .Bad_Field
			}
			decl.prior_name = strings.clone(from, allocator)
			decl.has_prior = true
			subs = subs[1:]
		}
		decl.fields = load_data_field_decls(subs, allocator) or_return
		out[i] = decl
	}
	return out, .None
}

parse_migrate_line :: proc(line: string) -> (from: string, with: string, ok: bool) {
	sf := strings.fields(line, context.temp_allocator)
	if len(sf) != 3 || sf[0] != "migrate" {
		return "", "", false
	}
	from = sf[1] == "-" ? "" : sf[1]
	with = sf[2] == "-" ? "" : sf[2]
	if from == "" && with == "" {
		return "", "", false
	}
	return from, with, true
}

load_data_field_decls :: proc(
	subs: []string,
	allocator := context.allocator,
) -> (
	fields: []Field_Decl,
	err: Artifact_Error,
) {
	out := make([dynamic]Field_Decl, 0, len(subs), allocator)
	for sub in subs {
		if line_keyword(sub) == "migrate" {
			if len(out) == 0 {
				return nil, .Bad_Field
			}
			from, with, ok := parse_migrate_line(sub)
			if !ok {
				return nil, .Bad_Field
			}
			decl := &out[len(out) - 1]
			if from != "" {
				decl.migrate_from = strings.clone(from, allocator)
				decl.has_from = true
			}
			if with != "" {
				decl.migrate_with = strings.clone(with, allocator)
				decl.has_with = true
			}
			continue
		}
		one := [1]string{sub}
		decoded := load_field_decls(one[:], allocator) or_return
		append(&out, decoded[0])
	}
	return out[:], .None
}

load_signals :: proc(
	section: Artifact_Section,
	allocator := context.allocator,
) -> (
	signals: []Signal_Decl,
	err: Artifact_Error,
) {
	out := make([]Signal_Decl, len(section.records), allocator)
	for rec, i in section.records {
		f := record_fields(rec)
		if len(f) < 3 {
			return nil, .Bad_Field
		}
		fields := load_field_decls(rec.subs, allocator) or_return
		out[i] = Signal_Decl {
			name   = strings.clone(f[1], allocator),
			fields = fields,
		}
	}
	return out, .None
}

load_field_decls :: proc(
	subs: []string,
	allocator := context.allocator,
) -> (
	fields: []Field_Decl,
	err: Artifact_Error,
) {
	out := make([]Field_Decl, len(subs), allocator)
	for sub, i in subs {
		sf := strings.fields(sub, context.temp_allocator)
		if len(sf) < 4 || sf[0] != "field" {
			return nil, .Bad_Field
		}
		decl := Field_Decl {
			name = strings.clone(sf[1], allocator),
			type = strings.clone(sf[2], allocator),
		}
		if sf[3] != "-" {
			decl.has_default = true
			decl.default_encoded = strings.clone(strings.trim_prefix(sf[3], "="), allocator)
		}
		out[i] = decl
	}
	return out, .None
}

load_things :: proc(
	section: Artifact_Section,
	allocator := context.allocator,
) -> (
	things: []Thing_Decl,
	err: Artifact_Error,
) {
	out := make([]Thing_Decl, len(section.records), allocator)
	for rec, i in section.records {
		f := record_fields(rec)
		if len(f) < 5 {
			return nil, .Bad_Field
		}
		singleton, ok := decode_bool(f[2])
		if !ok {
			return nil, .Bad_Field
		}
		gtag_count, gc_ok := strconv.parse_int(f[3])
		if !gc_ok {
			return nil, .Bad_Field
		}
		if gtag_count > len(rec.subs) {
			return nil, .Bad_Field
		}
		gtags := load_gtags(rec.subs[:gtag_count], allocator) or_return
		fields := load_field_decls(rec.subs[gtag_count:], allocator) or_return
		out[i] = Thing_Decl {
			name      = strings.clone(f[1], allocator),
			singleton = singleton,
			gtags     = gtags,
			fields    = fields,
		}
	}
	return out, .None
}

load_gtags :: proc(
	subs: []string,
	allocator := context.allocator,
) -> (
	gtags: []string,
	err: Artifact_Error,
) {
	out := make([]string, len(subs), allocator)
	for sub, i in subs {
		sf := strings.fields(sub, context.temp_allocator)
		if len(sf) < 2 || sf[0] != "gtag" {
			return nil, .Bad_Field
		}
		tag, ok := decode_string(sf[1])
		if !ok {
			return nil, .Bad_Field
		}
		out[i] = strings.clone(tag, allocator)
	}
	return out, .None
}

load_functions :: proc(
	section: Artifact_Section,
	allocator := context.allocator,
) -> (
	functions: []Function_Decl,
	err: Artifact_Error,
) {
	out := make([]Function_Decl, len(section.records), allocator)
	for rec, i in section.records {
		f := record_fields(rec)
		if len(f) < 7 {
			return nil, .Bad_Field
		}
		param_count, pc_ok := strconv.parse_int(f[3])
		body_count, bc_ok := strconv.parse_int(f[5])
		if !pc_ok || !bc_ok {
			return nil, .Bad_Field
		}
		span_module, span_line := parse_span(f[6])
		params, body_lines := split_params_and_body(rec.subs, param_count) or_return
		body := parse_node_forest(body_lines, body_count, allocator) or_return
		out[i] = Function_Decl {
			name        = strings.clone(f[1], allocator),
			kind        = function_kind_from_tag(f[2]),
			params      = params_clone(params, allocator),
			return_type = strings.clone(strings.trim_prefix(f[4], "return:"), allocator),
			span_module = strings.clone(span_module, allocator),
			span_line   = span_line,
			body        = body,
		}
	}
	return out, .None
}

load_probes :: proc(
	section: Artifact_Section,
	allocator := context.allocator,
) -> (
	probes: []Probe_Decl,
	err: Artifact_Error,
) {
	out := make([]Probe_Decl, len(section.records), allocator)
	for rec, i in section.records {
		f := record_fields(rec)
		if len(f) != 4 || f[0] != "probe" {
			return nil, .Bad_Field
		}
		kind, kind_ok := probe_kind_from_tag(f[1])
		if !kind_ok {
			return nil, .Bad_Field
		}
		body_count, bc_ok := strconv.parse_int(f[3])
		if !bc_ok || body_count < 0 {
			return nil, .Bad_Field
		}
		body := parse_node_forest(rec.subs, body_count, allocator) or_return
		out[i] = Probe_Decl {
			kind   = kind,
			target = strings.clone(f[2], allocator),
			body   = body,
		}
	}
	return out, .None
}

probe_kind_from_tag :: proc(tag: string) -> (kind: Probe_Kind, ok: bool) {
	switch tag {
	case "break":
		return .Break, true
	case "log":
		return .Log, true
	case "watch":
		return .Watch, true
	case "trace":
		return .Trace, true
	}
	return .Break, false
}

load_queries :: proc(
	section: Artifact_Section,
	allocator := context.allocator,
) -> (
	queries: []Query_Decl,
	err: Artifact_Error,
) {
	out := make([]Query_Decl, len(section.records), allocator)
	for rec, i in section.records {
		f := record_fields(rec)
		if len(f) < 7 {
			return nil, .Bad_Field
		}
		param_count, pc_ok := strconv.parse_int(f[2])
		index_count, ic_ok := strconv.parse_int(f[4])
		body_count, bc_ok := strconv.parse_int(f[5])
		if !pc_ok || !ic_ok || !bc_ok {
			return nil, .Bad_Field
		}
		span_module, span_line := parse_span(f[6])

		cursor := 0
		params := load_params(slice_window(rec.subs, &cursor, param_count), allocator) or_return
		indexes := load_index_reqs(slice_window(rec.subs, &cursor, index_count), allocator) or_return
		body := parse_node_forest(rec.subs[cursor:], body_count, allocator) or_return

		out[i] = Query_Decl {
			name        = strings.clone(f[1], allocator),
			params      = params,
			return_type = strings.clone(strings.trim_prefix(f[3], "return:"), allocator),
			indexes     = indexes,
			span_module = strings.clone(span_module, allocator),
			span_line   = span_line,
			body        = body,
		}
	}
	return out, .None
}

load_index_reqs :: proc(
	subs: []string,
	allocator := context.allocator,
) -> (
	reqs: []Index_Req,
	err: Artifact_Error,
) {
	out := make([]Index_Req, len(subs), allocator)
	for sub, i in subs {
		sf := strings.fields(sub, context.temp_allocator)
		if len(sf) < 4 || sf[0] != "index" {
			return nil, .Bad_Field
		}
		kind: Query_Index_Kind
		switch sf[1] {
		case "index":
			kind = .Index
		case "spatial":
			kind = .Spatial
		case:
			return nil, .Bad_Field
		}
		out[i] = Index_Req {
			kind  = kind,
			thing = strings.clone(sf[2], allocator),
			field = strings.clone(sf[3], allocator),
		}
	}
	return out, .None
}

load_tilemaps :: proc(
	section: Artifact_Section,
	allocator := context.allocator,
) -> (
	tilemaps: []Tile_Layer,
	err: Artifact_Error,
) {
	out := make([]Tile_Layer, len(section.records), allocator)
	for rec, i in section.records {
		f := record_fields(rec)
		if len(f) != 9 || f[0] != "tilemap" {
			return nil, .Bad_Field
		}
		cell_size, cs_ok := strconv.parse_i64(f[2])
		cols, c_ok := strconv.parse_int(f[3])
		rows, r_ok := strconv.parse_int(f[4])
		anchor_x, ax_ok := strconv.parse_i64(f[5])
		anchor_y, ay_ok := strconv.parse_i64(f[6])
		atlas := f[7] == "-" ? "" : strings.clone(f[7], allocator)
		palette_count, p_ok := strconv.parse_int(f[8])
		if !cs_ok || !c_ok || !r_ok || !ax_ok || !ay_ok || !p_ok {
			return nil, .Bad_Field
		}
		if cell_size <= 0 || cols <= 0 || rows <= 0 || palette_count < 0 {
			return nil, .Bad_Field
		}
		if len(rec.subs) != palette_count + rows {
			return nil, .Bad_Field
		}
		palette := load_tile_palette(rec.subs[:palette_count], allocator) or_return
		cells := load_tile_rows(rec.subs[palette_count:], cols, palette_count, allocator) or_return
		out[i] = Tile_Layer {
			name      = strings.clone(f[1], allocator),
			cell_size = cell_size,
			cols      = cols,
			rows      = rows,
			top_left  = Vec2{x = Fixed(anchor_x), y = Fixed(anchor_y)},
			atlas     = atlas,
			palette   = palette,
			cells     = cells,
		}
	}
	return out, .None
}

load_tile_palette :: proc(
	subs: []string,
	allocator := context.allocator,
) -> (
	palette: []Tile_Def,
	err: Artifact_Error,
) {
	out := make([]Tile_Def, len(subs), allocator)
	for sub, i in subs {
		sf := strings.fields(sub, context.temp_allocator)
		if len(sf) != 5 || sf[0] != "tile" {
			return nil, .Bad_Field
		}
		solid, ok := decode_bool(sf[2])
		cell_x, cx_ok := strconv.parse_int(sf[3])
		cell_y, cy_ok := strconv.parse_int(sf[4])
		if !ok || !cx_ok || !cy_ok || cell_x < 0 || cell_y < 0 {
			return nil, .Bad_Field
		}
		out[i] = Tile_Def {
			name   = strings.clone(sf[1], allocator),
			solid  = solid,
			cell_x = cell_x,
			cell_y = cell_y,
		}
	}
	return out, .None
}

load_tile_rows :: proc(
	subs: []string,
	cols: int,
	palette_count: int,
	allocator := context.allocator,
) -> (
	cells: []int,
	err: Artifact_Error,
) {
	out := make([]int, len(subs) * cols, allocator)
	for sub, r in subs {
		sf := strings.fields(sub, context.temp_allocator)
		if len(sf) != cols + 1 || sf[0] != "row" {
			return nil, .Bad_Field
		}
		for c in 0 ..< cols {
			token := sf[c + 1]
			if token == "-" {
				out[r * cols + c] = TILE_CELL_EMPTY
				continue
			}
			index, ok := strconv.parse_int(token)
			if !ok || index < 0 || index >= palette_count {
				return nil, .Bad_Field
			}
			out[r * cols + c] = index
		}
	}
	return out, .None
}

function_kind_from_tag :: proc(tag: string) -> Function_Kind {
	switch tag {
	case "const":
		return .Const
	case "bindings":
		return .Bindings
	case "startup":
		return .Startup
	}
	return .Fn
}

parse_span :: proc(token: string) -> (module: string, line: int) {
	rest := strings.trim_prefix(token, "span:")
	colon := strings.last_index_byte(rest, ':')
	if colon < 0 {
		return rest, 0
	}
	n, _ := strconv.parse_int(rest[colon + 1:])
	return rest[:colon], n
}

load_behaviors :: proc(
	section: Artifact_Section,
	allocator := context.allocator,
) -> (
	behaviors: []Behavior_Decl,
	err: Artifact_Error,
) {
	out := make([]Behavior_Decl, len(section.records), allocator)
	for rec, i in section.records {
		f := record_fields(rec)
		if len(f) < 9 {
			return nil, .Bad_Field
		}
		gtag_count, gc_ok := strconv.parse_int(f[5])
		param_count, pc_ok := strconv.parse_int(f[6])
		emits_count, ec_ok := strconv.parse_int(f[7])
		body_count, bc_ok := strconv.parse_int(f[8])
		if !gc_ok || !pc_ok || !ec_ok || !bc_ok {
			return nil, .Bad_Field
		}

		cursor := 0
		gtags := load_gtags(slice_window(rec.subs, &cursor, gtag_count), allocator) or_return
		params := load_params(slice_window(rec.subs, &cursor, param_count), allocator) or_return
		emits := load_emits(slice_window(rec.subs, &cursor, emits_count), allocator) or_return
		body := parse_node_forest(rec.subs[cursor:], body_count, allocator) or_return

		out[i] = Behavior_Decl {
			name     = strings.clone(f[1], allocator),
			on_thing = strings.clone(strings.trim_prefix(f[2], "on:"), allocator),
			stage    = strings.clone(strings.trim_prefix(f[3], "stage:"), allocator),
			contract = strings.clone(strings.trim_prefix(f[4], "contract:"), allocator),
			gtags    = gtags,
			params   = params,
			emits    = emits,
			body     = body,
		}
	}
	return out, .None
}

load_params :: proc(
	subs: []string,
	allocator := context.allocator,
) -> (
	params: []Param_Decl,
	err: Artifact_Error,
) {
	out := make([]Param_Decl, len(subs), allocator)
	for sub, i in subs {
		sf := strings.fields(sub, context.temp_allocator)
		if len(sf) < 3 || sf[0] != "param" {
			return nil, .Bad_Field
		}
		out[i] = Param_Decl {
			name = strings.clone(sf[1], allocator),
			type = strings.clone(sf[2], allocator),
		}
	}
	return out, .None
}

load_emits :: proc(
	subs: []string,
	allocator := context.allocator,
) -> (
	emits: []string,
	err: Artifact_Error,
) {
	out := make([]string, len(subs), allocator)
	for sub, i in subs {
		sf := strings.fields(sub, context.temp_allocator)
		if len(sf) < 2 || sf[0] != "emit" {
			return nil, .Bad_Field
		}
		out[i] = strings.clone(sf[1], allocator)
	}
	return out, .None
}

load_pipeline :: proc(
	section: Artifact_Section,
	allocator := context.allocator,
) -> (
	pipeline: []Pipeline_Step,
	err: Artifact_Error,
) {
	out := make([]Pipeline_Step, len(section.records), allocator)
	for rec, i in section.records {
		f := record_fields(rec)
		if len(f) < 4 {
			return nil, .Bad_Field
		}
		ordinal, ok := strconv.parse_int(f[1])
		if !ok || ordinal != i {
			return nil, .Bad_Field
		}
		out[i] = Pipeline_Step {
			ordinal  = ordinal,
			stage    = strings.clone(strings.trim_prefix(f[2], "stage:"), allocator),
			behavior = strings.clone(strings.trim_prefix(f[3], "behavior:"), allocator),
		}
	}
	return out, .None
}

load_routing :: proc(
	section: Artifact_Section,
	allocator := context.allocator,
) -> (
	routing: []Signal_Route,
	err: Artifact_Error,
) {
	out := make([]Signal_Route, len(section.records), allocator)
	for rec, i in section.records {
		f := record_fields(rec)
		if len(f) < 4 {
			return nil, .Bad_Field
		}
		producer_count, pc_ok := strconv.parse_int(f[2])
		consumer_count, cc_ok := strconv.parse_int(f[3])
		if !pc_ok || !cc_ok {
			return nil, .Bad_Field
		}
		cursor := 0
		producers := load_endpoints(
			slice_window(rec.subs, &cursor, producer_count),
			"producer",
			allocator,
		) or_return
		consumers := load_endpoints(
			slice_window(rec.subs, &cursor, consumer_count),
			"consumer",
			allocator,
		) or_return
		out[i] = Signal_Route {
			signal    = strings.clone(f[1], allocator),
			producers = producers,
			consumers = consumers,
		}
	}
	return out, .None
}

load_endpoints :: proc(
	subs: []string,
	keyword: string,
	allocator := context.allocator,
) -> (
	endpoints: []Signal_Endpoint,
	err: Artifact_Error,
) {
	out := make([]Signal_Endpoint, len(subs), allocator)
	for sub, i in subs {
		sf := strings.fields(sub, context.temp_allocator)
		if len(sf) < 3 || sf[0] != keyword {
			return nil, .Bad_Field
		}
		ordinal, ok := strconv.parse_int(sf[1])
		if !ok {
			return nil, .Bad_Field
		}
		out[i] = Signal_Endpoint {
			ordinal  = ordinal,
			behavior = strings.clone(strings.trim_prefix(sf[2], "behavior:"), allocator),
		}
	}
	return out, .None
}

load_setup :: proc(
	section: Artifact_Section,
	allocator := context.allocator,
) -> (
	setup: []Spawn_Command,
	err: Artifact_Error,
) {
	out := make([]Spawn_Command, len(section.records), allocator)
	for rec, i in section.records {
		f := record_fields(rec)
		if len(f) < 3 {
			return nil, .Bad_Field
		}
		fields := make([]Spawn_Field, len(rec.subs), allocator)
		for sub, j in rec.subs {
			field := load_spawn_field(sub, allocator) or_return
			fields[j] = field
		}
		out[i] = Spawn_Command {
			thing  = strings.clone(f[1], allocator),
			fields = fields,
		}
	}
	return out, .None
}

load_spawn_field :: proc(
	sub: string,
	allocator := context.allocator,
) -> (
	field: Spawn_Field,
	err: Artifact_Error,
) {
	sf := strings.fields(sub, context.temp_allocator)
	if len(sf) < 3 || sf[0] != "set" {
		return {}, .Bad_Field
	}
	field.name = strings.clone(sf[1], allocator)
	encoded := strings.trim_prefix(sf[2], "=")

	switch {
	case encoded == "vec2":
		if len(sf) < 5 {
			return {}, .Bad_Field
		}
		x, x_ok := decode_fixed(sf[3])
		y, y_ok := decode_fixed(sf[4])
		if !x_ok || !y_ok {
			return {}, .Bad_Field
		}
		field.kind = .Vec2
		field.vec2_x = x
		field.vec2_y = y
	case strings.has_prefix(encoded, "["):
		field.kind = .List
		field.encoded = strings.clone(encoded, allocator)
	case is_composite_record_token(encoded):
		field.kind = .Record
		field.encoded = strings.clone(encoded, allocator)
	case strings.contains(encoded, "::"):
		field.kind = .Variant
		field.variant = strings.clone(encoded, allocator)
	case is_signed_decimal(encoded):
		n, n_ok := decode_int(encoded)
		fx, fx_ok := decode_fixed(encoded)
		if !n_ok || !fx_ok {
			return {}, .Bad_Field
		}
		field.kind = .Fixed
		field.int_val = n
		field.fixed = fx
	case:
		field.kind = .Variant
		field.variant = strings.clone(encoded, allocator)
	}
	return field, .None
}

is_composite_record_token :: proc(token: string) -> bool {
	open := strings.index_byte(token, '(')
	return open > 0 && strings.has_suffix(token, ")")
}

is_signed_decimal :: proc(token: string) -> bool {
	if len(token) == 0 {
		return false
	}
	start := 0
	if token[0] == '-' {
		if len(token) == 1 {
			return false
		}
		start = 1
	}
	for ch in token[start:] {
		if ch < '0' || ch > '9' {
			return false
		}
	}
	return true
}

load_bindings :: proc(
	section: Artifact_Section,
	allocator := context.allocator,
) -> (
	bindings: []Binding,
	err: Artifact_Error,
) {
	out := make([]Binding, len(section.records), allocator)
	for rec, i in section.records {
		f := record_fields(rec)
		if len(f) < 5 || f[0] != "bind" {
			return nil, .Bad_Field
		}
		out[i] = Binding {
			kind   = strings.clone(f[1], allocator),
			player = strings.clone(f[2], allocator),
			action = strings.clone(f[3], allocator),
			source = strings.clone(strings.trim_prefix(f[4], "source:"), allocator),
		}
	}
	return out, .None
}

load_entrypoint :: proc(
	section: Artifact_Section,
	allocator := context.allocator,
) -> (
	entry: Entrypoint,
	err: Artifact_Error,
) {
	if len(section.records) != 1 {
		return {}, .Section_Count_Mismatch
	}
	f := record_fields(section.records[0])
	if len(f) < 6 || f[0] != "entrypoint" {
		return {}, .Bad_Field
	}
	hz, ok := strconv.parse_int(strings.trim_prefix(f[3], "tick_hz:"))
	if !ok {
		return {}, .Bad_Field
	}
	logical_w, logical_h, logical_ok := parse_logical_field(strings.trim_prefix(f[4], "logical:"))
	if !logical_ok {
		return {}, .Bad_Field
	}
	has_seed := false
	seed := i64(0)
	if len(f) >= 7 {
		if !strings.has_prefix(f[6], "seed:") {
			return {}, .Bad_Field
		}
		parsed_seed, seed_ok := strconv.parse_i64(strings.trim_prefix(f[6], "seed:"))
		if !seed_ok {
			return {}, .Bad_Field
		}
		has_seed = true
		seed = parsed_seed
	}
	return Entrypoint {
			name = strings.clone(f[1], allocator),
			pipeline = strings.clone(strings.trim_prefix(f[2], "pipeline:"), allocator),
			tick_hz = hz,
			logical_w = logical_w,
			logical_h = logical_h,
			bindings = strings.clone(strings.trim_prefix(f[5], "bindings:"), allocator),
			has_seed = has_seed,
			seed = seed,
		},
		.None
}

parse_logical_field :: proc(text: string) -> (w: int, h: int, ok: bool) {
	sep := strings.index_byte(text, 'x')
	if sep <= 0 || sep >= len(text) - 1 {
		return 0, 0, false
	}
	parsed_w, w_ok := strconv.parse_int(text[:sep])
	parsed_h, h_ok := strconv.parse_int(text[sep + 1:])
	if !w_ok || !h_ok || parsed_w <= 0 || parsed_h <= 0 {
		return 0, 0, false
	}
	return parsed_w, parsed_h, true
}

record_fields :: proc(rec: Artifact_Record) -> []string {
	return strings.fields(rec.lead, context.temp_allocator)
}

split_params_and_body :: proc(
	subs: []string,
	param_count: int,
) -> (
	params: []string,
	body: []string,
	err: Artifact_Error,
) {
	if param_count > len(subs) {
		return nil, nil, .Bad_Field
	}
	return subs[:param_count], subs[param_count:], .None
}

params_clone :: proc(
	param_lines: []string,
	allocator := context.allocator,
) -> []Param_Decl {
	out := make([]Param_Decl, len(param_lines), allocator)
	for line, i in param_lines {
		sf := strings.fields(line, context.temp_allocator)
		name := sf[1] if len(sf) > 1 else ""
		type := sf[2] if len(sf) > 2 else ""
		out[i] = Param_Decl {
			name = strings.clone(name, allocator),
			type = strings.clone(type, allocator),
		}
	}
	return out
}

slice_window :: proc(subs: []string, cursor: ^int, count: int) -> []string {
	start := cursor^
	end := start + count
	if end > len(subs) {
		end = len(subs)
	}
	cursor^ = end
	return subs[start:end]
}
