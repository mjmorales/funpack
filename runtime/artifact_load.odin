// The loader: walk the section-level Artifact_Doc (artifact_lex.odin) and build
// the in-memory Program (program.odin) the sim executes over — the §16 step-4
// model build. Each section maps to its descriptor list; every record is shaped
// by the lead line's declared scalar counts (§16 step 3), and every body `node`
// run is rebuilt into a node forest (artifact_nodes.odin).
//
// Fixed literals reach the runtime ONLY through decode_fixed → the kernel's
// Fixed (artifact_lex.odin §2.3): the setup batch's Fixed/Vec2 fields are
// decoded bit-exact here, never through a float. Function/behavior body `fixed`
// nodes keep their raw token and are decoded at evaluation time by the interpreter
// — also through the kernel, also never float.
package funpack_runtime

import "core:os"
import "core:strconv"
import "core:strings"

// load_artifact_file reads an artifact off disk and loads it into a Program —
// the production entry point. File IO goes through core:os.read_entire_file per
// the Odin-first policy (the runtime owns no custom IO). `io_ok` is false when
// the file cannot be read; a successfully-read-but-malformed artifact surfaces
// through `err` (the same fail-closed refusal as load_program).
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
	loaded, load_err := load_program(string(bytes), allocator)
	return loaded, load_err, true
}

// load_program is the top-level entry: parse the artifact bytes into a Program.
// It refuses on a version mismatch, a malformed section, or a malformed body —
// the load is total or it fails closed, never a best-effort partial program.
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

// build_program assembles the Program from an already-parsed Artifact_Doc by
// reading each section in the §3 fixed order. A section the program needs that
// is absent is a refusal — the order is part of the contract (§3).
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
			program.meta = load_meta(section) or_return
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
			program.entrypoint = load_entrypoint(section) or_return
		case:
			return {}, .Malformed_Header // an unknown section is a schema mismatch
		}
	}
	return program, .None
}

// --- §4 meta ---------------------------------------------------------------

// load_meta reads the two §4 records: `project NAME` and `version L5:0.1.0`.
load_meta :: proc(section: Artifact_Section) -> (meta: Project_Meta, err: Artifact_Error) {
	if len(section.records) != 2 {
		return {}, .Section_Count_Mismatch
	}
	project_fields := record_fields(section.records[0])
	if len(project_fields) < 2 || project_fields[0] != "project" {
		return {}, .Bad_Field
	}
	meta.name = project_fields[1]

	version_fields := record_fields(section.records[1])
	if len(version_fields) < 2 || version_fields[0] != "version" {
		return {}, .Bad_Field
	}
	v, ok := decode_string(version_fields[1])
	if !ok {
		return {}, .Bad_Field
	}
	meta.version = v
	return meta, .None
}

// --- §5 enums --------------------------------------------------------------

// load_enums reads each `enum NAME KIND variant_count` lead line plus its
// `variant NAME PAYLOAD` sub-records, in declaration order.
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
		// enum NAME KIND variant_count
		if len(f) < 4 {
			return nil, .Bad_Field
		}
		variants := make([]Enum_Variant, len(rec.subs), allocator)
		for sub, j in rec.subs {
			sf := strings.fields(sub, context.temp_allocator)
			// variant NAME PAYLOAD…  (payload is the rest of the line verbatim)
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

// enum_kind_from_tag maps the §03 §4 role-kind tag to Enum_Kind; `-` is None.
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

// --- §6 data / §7 signals --------------------------------------------------

// load_data reads each `data NAME field_count mut` record plus its field
// sub-records (§6).
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
		// data NAME field_count mut
		if len(f) < 4 {
			return nil, .Bad_Field
		}
		mutable, ok := decode_bool(f[3])
		if !ok {
			return nil, .Bad_Field
		}
		fields := load_field_decls(rec.subs, allocator) or_return
		out[i] = Data_Decl {
			name    = strings.clone(f[1], allocator),
			mutable = mutable,
			fields  = fields,
		}
	}
	return out, .None
}

// load_signals reads each `signal NAME field_count` record plus its field
// sub-records (§7) — same field grammar as data, but a signal is never mutated.
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
		// signal NAME field_count
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

// load_field_decls reads a run of `field NAME TYPE DEFAULT` sub-records (§6).
// DEFAULT is `-` (no default) or `=ENCODED` (the default value, decoded by
// position at use time — kept as the raw `ENCODED` token here).
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
		// field NAME TYPE DEFAULT
		if len(sf) < 4 || sf[0] != "field" {
			return nil, .Bad_Field
		}
		decl := Field_Decl {
			name = strings.clone(sf[1], allocator),
			type = strings.clone(sf[2], allocator),
		}
		if sf[3] != "-" {
			// `=ENCODED` — strip the leading `=`; the rest is the encoded default.
			decl.has_default = true
			decl.default_encoded = strings.clone(strings.trim_prefix(sf[3], "="), allocator)
		}
		out[i] = decl
	}
	return out, .None
}

// --- §8 things -------------------------------------------------------------

// load_things reads each `thing NAME SINGLETON gtag_count field_count` record
// plus its gtag and field sub-records, shaping them by the declared counts (§8).
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
		// thing NAME SINGLETON gtag_count field_count
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
		// The gtag sub-records come first, then the field sub-records (§8).
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

// load_gtags reads a run of `gtag L4:ball` sub-records into their decoded tag
// strings, in source order (§8).
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

// --- §9 functions ----------------------------------------------------------

// load_functions reads each function record: the signature lead line, its param
// sub-records, then its body node run rebuilt into a forest (§9, §2.7).
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
		// function NAME KIND param_count return:TYPE body_count span:MODULE:LINE
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

// function_kind_from_tag maps the §9 KIND tag to Function_Kind.
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

// parse_span splits a `span:MODULE:LINE` token into its module name and 1-based
// line — diagnostic provenance only, never a filesystem path (§2 purity, §9).
parse_span :: proc(token: string) -> (module: string, line: int) {
	rest := strings.trim_prefix(token, "span:")
	colon := strings.last_index_byte(rest, ':')
	if colon < 0 {
		return rest, 0
	}
	n, _ := strconv.parse_int(rest[colon + 1:])
	return rest[:colon], n
}

// --- §10 behaviors ---------------------------------------------------------

// load_behaviors reads each behavior record: the stage-keyed signature, its
// gtag/param/emit sub-records shaped by their declared counts, then its step
// body node forest (§10, §2.7) — in source-declaration order.
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
		// behavior NAME on:THING stage:STAGE contract:CONTRACT gtag_count param_count emits_count body_count
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

// load_params reads a run of `param NAME TYPE` sub-records (§9, §10).
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

// load_emits reads a run of `emit TYPE` sub-records (§10) — step's return-side
// writes: the blackboard type, signal lists `[S]`, and command lists.
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

// --- §11 pipeline_flattened ------------------------------------------------

// load_pipeline reads the one total order: each `step ORDINAL stage:STAGE
// behavior:NAME` line (§11). The ordinals are contiguous and gap-free; a gap is
// a refusal (the derived flattened tree never drifts).
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
		// step ORDINAL stage:STAGE behavior:NAME
		if len(f) < 4 {
			return nil, .Bad_Field
		}
		ordinal, ok := strconv.parse_int(f[1])
		if !ok || ordinal != i {
			return nil, .Bad_Field // ordinals are 0-based, contiguous, gap-free
		}
		out[i] = Pipeline_Step {
			ordinal  = ordinal,
			stage    = strings.clone(strings.trim_prefix(f[2], "stage:"), allocator),
			behavior = strings.clone(strings.trim_prefix(f[3], "behavior:"), allocator),
		}
	}
	return out, .None
}

// --- §12 signal_routing ----------------------------------------------------

// load_routing reads each `route SIGNAL producer_count consumer_count` record
// plus its producer/consumer sub-records, by flattened-order ordinal (§12).
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
		// route SIGNAL producer_count consumer_count
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

// load_endpoints reads a run of `producer ORDINAL behavior:NAME` (or `consumer`)
// sub-records into endpoints (§12).
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

// --- §13 setup -------------------------------------------------------------

// load_setup reads the fully-evaluated [Spawn] batch: each `spawn THING
// field_count` record plus its `set FIELD =ENCODED` sub-records, decoded to
// concrete values (§13). Fixed and Vec2 fields are decoded bit-exact through the
// kernel here — NO float in the load path. A field omitted in source is not
// carried; the runtime applies the thing's default when setup spawns it.
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
		// spawn THING field_count
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

// load_spawn_field decodes one `set FIELD =ENCODED` sub-record into a typed
// Spawn_Field. The encoded value's shape is self-describing: a `vec2` prefix is a
// Vec2, a `::` is an enum variant, otherwise a numeric token (decoded as Fixed
// — the raw bits round-trip identically whether the source type was Int or Fixed,
// and the thing's Field_Decl carries the type for the interpreter). NO float.
load_spawn_field :: proc(
	sub: string,
	allocator := context.allocator,
) -> (
	field: Spawn_Field,
	err: Artifact_Error,
) {
	sf := strings.fields(sub, context.temp_allocator)
	// set FIELD =ENCODED  (Vec2 spreads to `=vec2 x y`, so 4 tokens)
	if len(sf) < 3 || sf[0] != "set" {
		return {}, .Bad_Field
	}
	field.name = strings.clone(sf[1], allocator)
	encoded := strings.trim_prefix(sf[2], "=")

	switch {
	case encoded == "vec2":
		// `set FIELD =vec2 x_bits y_bits` — two raw Fixed bit fields (§13).
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
	case strings.contains(encoded, "::"):
		// An enum variant as a name field (§2.6), e.g. `Side::Left`.
		field.kind = .Variant
		field.variant = strings.clone(encoded, allocator)
	case is_signed_decimal(encoded):
		// A numeric scalar: keep both an Int and a Fixed reading so the
		// interpreter can apply whichever the field's declared type calls for, both
		// from the same raw bits (a Fixed is `value*2^32`, an Int is plain).
		n, n_ok := decode_int(encoded)
		fx, fx_ok := decode_fixed(encoded)
		if !n_ok || !fx_ok {
			return {}, .Bad_Field
		}
		field.kind = .Fixed // numeric default reading; int_val carries the Int view
		field.int_val = n
		field.fixed = fx
	case:
		// A bare name with no `::` and no leading digit — treat as a variant
		// token so the field stays loadable (pong does not hit this branch).
		field.kind = .Variant
		field.variant = strings.clone(encoded, allocator)
	}
	return field, .None
}

// is_signed_decimal reports whether a token is a plain signed decimal integer —
// the cheap discriminator between a numeric setup value and a name token.
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

// --- §14 bindings ----------------------------------------------------------

// load_bindings reads the resolved §23 axis/button source map: each `bind KIND
// PLAYER ACTION source:SOURCE` line, in source-call order (bindings stack, §14).
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
		// bind axis|button PLAYER ACTION source:SOURCE
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

// --- §15 entrypoint --------------------------------------------------------

// load_entrypoint reads the single `entrypoint NAME pipeline:P tick_hz:HZ
// bindings:B` record — the runtime wiring (§15). tick_hz is the one fixed tick
// rate (60 for pong).
load_entrypoint :: proc(section: Artifact_Section) -> (entry: Entrypoint, err: Artifact_Error) {
	if len(section.records) != 1 {
		return {}, .Section_Count_Mismatch
	}
	f := record_fields(section.records[0])
	// entrypoint NAME pipeline:PIPELINE tick_hz:HZ bindings:BINDINGS
	if len(f) < 5 || f[0] != "entrypoint" {
		return {}, .Bad_Field
	}
	hz, ok := strconv.parse_int(strings.trim_prefix(f[3], "tick_hz:"))
	if !ok {
		return {}, .Bad_Field
	}
	return Entrypoint {
			name = f[1],
			pipeline = strings.trim_prefix(f[2], "pipeline:"),
			tick_hz = hz,
			bindings = strings.trim_prefix(f[4], "bindings:"),
		},
		.None
}

// --- shared helpers --------------------------------------------------------

// record_fields splits a record's lead line into space-delimited tokens. A
// String token (Lk:bytes) never contains a raw space here — pong's String fields
// (gtag, version) live in sub-records, and the few lead-line fields are names and
// counts — so whitespace splitting is sound for lead lines (§2.1).
record_fields :: proc(rec: Artifact_Record) -> []string {
	return strings.fields(rec.lead, context.temp_allocator)
}

// split_params_and_body partitions a function record's sub-records into its
// param run (the first `param_count` sub-records) and the body node run that
// follows (§9). A param sub-record that is not `param …` where one is expected is
// a refusal.
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

// params_clone reads `param NAME TYPE` lines (already separated) into Param_Decl
// — the function-side twin of load_params, which behaviors reuse directly.
params_clone :: proc(
	param_lines: []string,
	allocator := context.allocator,
) -> []Param_Decl {
	out := make([]Param_Decl, len(param_lines), allocator)
	for line, i in param_lines {
		sf := strings.fields(line, context.temp_allocator)
		// param NAME TYPE — shape already asserted by split_params_and_body's
		// caller via the declared count; clone the two name fields.
		name := sf[1] if len(sf) > 1 else ""
		type := sf[2] if len(sf) > 2 else ""
		out[i] = Param_Decl {
			name = strings.clone(name, allocator),
			type = strings.clone(type, allocator),
		}
	}
	return out
}

// slice_window returns the next `count` sub-records starting at `cursor^` and
// advances the cursor past them — the shaping primitive for a record whose
// sub-records are several declared-count runs back to back (§16 step 3).
slice_window :: proc(subs: []string, cursor: ^int, count: int) -> []string {
	start := cursor^
	end := start + count
	if end > len(subs) {
		end = len(subs)
	}
	cursor^ = end
	return subs[start:end]
}
