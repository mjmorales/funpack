// The edge-wiring serializers of the artifact emitter: [bindings] (§14),
// [entrypoint] (§15), and [queries] (§16). These sections carry the device-aware
// input map, the runtime entrypoint config, and the state-query declarations —
// the program's wiring to the host, grouped apart from the type schema and the
// run schedule.
package funpack

import "core:strings"

// ───────────────────────────────────────────────────────────────────────────
// [bindings] — the §23 axis/button source map (docs/artifact-format.md §14)
// ───────────────────────────────────────────────────────────────────────────

// emit_bindings writes the resolved binding table (docs/artifact-format.md §14):
// one `bind` record per `.axis(…)`/`.button(…)` call in source-call order, the
// only device-aware data in the artifact. Each carries the analog/digital kind,
// the PlayerId, the targeted enum variant, and the device source as the builder
// call that produced it.
emit_bindings :: proc(b: ^strings.Builder, ast: Ast) {
	binds := binding_calls(ast)
	emit_header(b, "bindings", len(binds))
	for bind in binds {
		strings.write_string(b, "bind ")
		strings.write_string(b, bind.kind)
		strings.write_byte(b, ' ')
		strings.write_string(b, bind.player)
		strings.write_byte(b, ' ')
		strings.write_string(b, bind.action)
		emit_line(b, " source:", bind.source)
	}
}

// Binding_Record is one resolved binding (docs/artifact-format.md §14): the
// analog/digital kind (`axis`/`button`), the PlayerId case (`P1`), the targeted
// action variant (`Steer::Move`), and the device source rendered as its builder
// call (`keys_axis(Key::W,Key::S)`).
Binding_Record :: struct {
	kind:   string,
	player: string,
	action: string,
	source: string,
}

// binding_calls walks the bindings() body's builder chain and lifts each
// `.axis(player, action, source)` / `.button(…)` call into a record, in
// source-call order. The body is `Bindings.empty().axis(…).axis(…)…`, a
// left-nested call/member chain, so the outermost call is the last binding; the
// walk recurses to the base first, then records this call, recovering source
// order (bindings stack, §23 §3).
binding_calls :: proc(ast: Ast) -> []Binding_Record {
	for fn in ast.fns {
		if fn.name != "bindings" {
			continue
		}
		if len(fn.body) != 1 {
			return nil
		}
		ret, is_return := fn.body[0].(Return_Node)
		if !is_return {
			return nil
		}
		binds := make([dynamic]Binding_Record, 0, 4, context.temp_allocator)
		collect_binding_calls(ret.value, &binds)
		return binds[:]
	}
	return nil
}

// collect_binding_calls walks a binding builder chain inner-to-outer, appending
// one record per `.axis(…)`/`.button(…)` call so the output is in source-call
// order (docs/artifact-format.md §14). It recurses into the call's receiver
// (the prior link) before recording the current call, so `.empty()` and any
// non-binding link contribute nothing and the binding calls land in order. A
// key-LIST button source (`[Key::W, Key::Up]`) SPREADS into one record per
// listed key — stacking is §23 §3 semantics, so each key is its own bind — and
// a builder-call source lowers through lower_source_call into the closed §14
// source-form set (schema v3).
collect_binding_calls :: proc(expr: Expr, binds: ^[dynamic]Binding_Record) {
	call, is_call := expr.(^Call_Expr)
	if !is_call {
		return
	}
	member, is_member := call.callee.(^Member_Expr)
	if !is_member {
		return
	}
	collect_binding_calls(member.receiver, binds)
	kind := binding_kind(member.member)
	if kind == "" {
		return
	}
	if len(call.args) != 3 {
		return
	}
	player := variant_case(call.args[0])
	action := variant_path(call.args[1])
	if list, is_list := call.args[2].(^List_Expr); is_list {
		// One stacked bind per listed device code: `[Key::W, Key::Up]` becomes
		// `source:key(Key::W)` + `source:key(Key::Up)` (§23 §3 stacking). An
		// element whose enum is not a device set contributes nothing — the
		// checker owns refusing it; the emitter never emits an empty source.
		for element in list.elements {
			source := device_code_source(element)
			if source == "" {
				continue
			}
			append(binds, Binding_Record{kind = kind, player = player, action = action, source = source})
		}
		return
	}
	append(binds, Binding_Record{
		kind   = kind,
		player = player,
		action = action,
		source = lower_source_call(call.args[2]),
	})
}

// device_code_source renders one spread key-list element as its single-code
// §14 source form: `Key::W` → `key(Key::W)`, `PadButton::A` → `pad(PadButton::A)`.
// The helper name comes from the device enum, so the artifact records the same
// builder-call spelling an explicit `key(…)` source would produce. A non-device
// element returns "" and is skipped by the caller.
device_code_source :: proc(expr: Expr) -> string {
	variant, is_variant := expr.(^Variant_Expr)
	if !is_variant {
		return ""
	}
	helper := ""
	switch variant.type_name {
	case "Key":
		helper = "key"
	case "PadButton":
		helper = "pad"
	case:
		return ""
	}
	return strings.concatenate({helper, "(", variant.type_name, "::", variant.variant, ")"}, context.temp_allocator)
}

// lower_source_call lowers a §23 §3 builder-call source into its ratified §14
// source form (schema v3): `wasd()` lowers to the 2D digital quad
// `keys_quad(Key::A,Key::D,Key::W,Key::S)` and `arrows()` to its arrow-key twin
// `keys_quad(Key::Left,Key::Right,Key::Up,Key::Down)` — argument order (neg_x,
// pos_x, neg_y, pos_y), up = neg_y in the y-down draw space, matching SDL stick
// polarity — and every already-canonical helper (key/pad/mouse/keys_axis/stick/
// stick_x/stick_y) renders verbatim through builder_call_string. `dpad()` lowers
// to the d-pad 2D quad `pad_quad(PadButton::DpadLeft,DpadRight,DpadUp,DpadDown)`
// — the same (neg_x, pos_x, neg_y, pos_y) order and up = neg_y polarity as the
// keys_quad forms, over the four d-pad direction codes; the runtime folds it
// through the new Pad_Quad source (parsed-but-unemitted on the v18 open window
// until a committed artifact binds dpad()). `stick(Stick)`
// is deliberately NOT spread into stick_x/stick_y: those are 1D forms feeding
// the action's single 1D value slot, while `stick` is a first-class 2D source
// the runtime folds as both components (ADR
// 2026-06-06-binding-source-lowering-2d-quad-and-stick). `arrows()` lowers to a
// keys_quad the runtime already resolves, so it needs no new source-form
// vocabulary (ADR 2026-06-15-engine-input-source-helpers-split).
lower_source_call :: proc(expr: Expr) -> string {
	call, is_call := expr.(^Call_Expr)
	if !is_call {
		return ""
	}
	if name, is_name := call.callee.(^Name_Expr); is_name {
		if name.name == "wasd" && len(call.args) == 0 {
			return "keys_quad(Key::A,Key::D,Key::W,Key::S)"
		}
		if name.name == "arrows" && len(call.args) == 0 {
			return "keys_quad(Key::Left,Key::Right,Key::Up,Key::Down)"
		}
		if name.name == "dpad" && len(call.args) == 0 {
			return "pad_quad(PadButton::DpadLeft,PadButton::DpadRight,PadButton::DpadUp,PadButton::DpadDown)"
		}
	}
	return builder_call_string(expr)
}

// binding_kind maps the builder method to the artifact bind kind
// (docs/artifact-format.md §14): `.axis` → `axis`, `.button` → `button`; any
// other member (`.empty`) is not a binding and returns "".
binding_kind :: proc(member: string) -> string {
	switch member {
	case "axis":
		return "axis"
	case "button":
		return "button"
	}
	return ""
}

// variant_case renders just the variant case of a `Type::Case` expression — the
// PLAYER field is the PlayerId case alone (`PlayerId::P1` → `P1`,
// docs/artifact-format.md §14).
variant_case :: proc(expr: Expr) -> string {
	if variant, ok := expr.(^Variant_Expr); ok {
		return variant.variant
	}
	return ""
}

// variant_path renders the full `Type::Case` of a variant expression — the
// ACTION field keeps its enum prefix (`Steer::Move`, docs/artifact-format.md
// §14).
variant_path :: proc(expr: Expr) -> string {
	if variant, ok := expr.(^Variant_Expr); ok {
		return strings.concatenate({variant.type_name, "::", variant.variant}, context.temp_allocator)
	}
	return ""
}

// builder_call_string renders a device-source builder call as compact text
// (docs/artifact-format.md §14): `keys_axis(Key::W,Key::S)`,
// `stick_y(Stick::Left)` — the callee name, then the parenthesized variant
// arguments with no interior spaces. The device names appear only here, never
// in sim logic (§23 §3).
builder_call_string :: proc(expr: Expr) -> string {
	call, is_call := expr.(^Call_Expr)
	if !is_call {
		return ""
	}
	name, is_name := call.callee.(^Name_Expr)
	if !is_name {
		return ""
	}
	b := strings.builder_make(context.temp_allocator)
	strings.write_string(&b, name.name)
	strings.write_byte(&b, '(')
	for arg, i in call.args {
		if i > 0 {
			strings.write_byte(&b, ',')
		}
		strings.write_string(&b, variant_path(arg))
	}
	strings.write_byte(&b, ')')
	return strings.to_string(b)
}

// ───────────────────────────────────────────────────────────────────────────
// [entrypoint] — the runtime wiring (docs/artifact-format.md §15)
// ───────────────────────────────────────────────────────────────────────────

// emit_entrypoint writes the single entrypoint record (docs/artifact-format.md
// §15): the pipeline ↔ tick ↔ logical ↔ bindings wiring lifted from
// funpack_configs/entrypoints.fcfg (§14 §4), which a pipeline carries no
// configuration for. tick_hz is the integer Hz of the `60hz` tick; logical is
// the `WxH` draw-space extent in integer world units (§20 §3). The trailing
// `seed:N` field is emitted ONLY when the entrypoint baked a `seed = N` config seed
// (§25 §60); a no-config-seed build emits the bare 6-field record, which the runtime
// loads as has_seed=false.
emit_entrypoint :: proc(b: ^strings.Builder, entrypoint: Entrypoint_Config) {
	emit_header(b, "entrypoint", 1)
	strings.write_string(b, "entrypoint ")
	strings.write_string(b, entrypoint.name)
	strings.write_string(b, " pipeline:")
	strings.write_string(b, entrypoint.pipeline)
	strings.write_string(b, " tick_hz:")
	strings.write_int(b, entrypoint.tick_hz)
	strings.write_string(b, " logical:")
	strings.write_int(b, entrypoint.logical_w)
	strings.write_byte(b, 'x')
	strings.write_int(b, entrypoint.logical_h)
	strings.write_string(b, " bindings:")
	strings.write_string(b, entrypoint.bindings)
	if entrypoint.has_seed {
		strings.write_string(b, " seed:")
		strings.write_i64(b, entrypoint.seed)
	}
	strings.write_byte(b, '\n')
}

// ───────────────────────────────────────────────────────────────────────────
// [queries] — §08 §3 state-query declarations with their index requirements
// (docs/artifact-format.md §16, schema v9)
// ───────────────────────────────────────────────────────────────────────────

// emit_queries writes one record per entrypoint-module `query` declaration in
// source order — the [functions] record mold extended with the declared §05 §3
// @index/@spatial requirement lines, so the runtime can both MAINTAIN the
// declared engine indices over the world database and evaluate a query call
// from the artifact alone. A query body is a Block by grammar (fun.ebnf §7:
// QueryDecl admits no body-position hole), so the body run is the plain §2.7
// statement forest. Cross-module query carry is deliberately absent: a §17
// seam carries FNS only, and no spec example imports a query — widening the
// carry would be its own schema bump.
emit_queries :: proc(b: ^strings.Builder, ast: Ast, module: string) {
	emit_header(b, "queries", len(ast.queries))
	for query in ast.queries {
		strings.write_string(b, "query ")
		strings.write_string(b, query.name)
		strings.write_byte(b, ' ')
		strings.write_int(b, len(query.params))
		strings.write_string(b, " return:")
		strings.write_string(b, type_ref_string(query.return_type))
		strings.write_byte(b, ' ')
		strings.write_int(b, len(query.indexes))
		strings.write_byte(b, ' ')
		strings.write_int(b, len(query.body))
		strings.write_string(b, " span:")
		strings.write_string(b, module)
		strings.write_byte(b, ':')
		strings.write_int(b, query.line)
		emit_line(b, "")
		for param in query.params {
			emit_line(b, "param ", param.name, " ", type_ref_string(param.type))
		}
		for directive in query.indexes {
			emit_line(b, "index ", index_directive_tag(directive.kind), " ", directive.thing, " ", directive.field)
		}
		emit_body(b, query.body)
	}
}

// index_directive_tag renders an Index_Directive_Kind as its artifact KIND
// token (docs/artifact-format.md §16): the closed two-value set the §05 §3
// directive vocabulary admits.
index_directive_tag :: proc(kind: Index_Directive_Kind) -> string {
	switch kind {
	case .Index:
		return "index"
	case .Spatial:
		return "spatial"
	}
	return "index"
}
