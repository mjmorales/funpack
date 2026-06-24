// The §28 §5 capture → test loop — the observe-class self-heal commands that
// emit complete, idiomatic funpack `test "…" { … }` blocks, indistinguishable
// from hand-written tests, ready to land in source as permanent regressions:
//
//   - `capture_test` extracts one behavior instance's (self, resources, inbound
//     signals) at a recorded tick and pins its in-fold pure-step result.
//   - `capture_tick` reads a recorded tick's committed pre-state (version
//     tick-1) and post-state (version tick) of a thing and pins the WHOLE-TICK
//     transition against a hand-rolled twin: `assert twin([pre]) == [post]`.
//     The post-state is the LIVE Id-ordered schedule's committed output, so a
//     twin modeling the tick as a simultaneous map (the false mental model that
//     passes a green suite while diverging from the live fold) fails the assert
//     — the mechanical guard the determinism contract otherwise only warns about.
//
// The exported text is funpack SOURCE, built from the deterministic
// constructors the spec names: record literals `Type{field: value}` in
// declared field order, `View.of([…])` for a View[T] read, the
// `Input.empty().with_*` producer chain rebuilt from the RECORDED snapshot,
// signal lists as plain record lists, Fixed as its exact dyadic decimal
// (Q32.32 is base-2 fractional, so the decimal expansion terminates — no float
// ever touches the render). The export is byte-stable — the same capture
// always renders the same bytes — so the seeded-snake acceptance golden
// (introspect_capture_test.odin) pins the exact exported text.
//
// A read with no deterministic source constructor (a threaded `rng: Rng`, a
// `time: Time` resource) is REFUSED, never approximated: funpack source has no
// literal for a mid-run Rng state, so a capture that would need one is not a
// runnable test. The refusal names the param so the agent captures at a
// constructible boundary instead.
package funpack_runtime

import "core:encoding/json"
import "core:fmt"
import "core:slice"
import "core:strings"

// capture_test_request serves one `capture_test` command: re-fold the recorded
// tick with the observe tap armed (the same bounded re-fold trace runs), select
// the behavior's captured step (args.instance; default the first instance in
// fold order), and render the test block. Observe-class — the canonical chain
// is read, never written.
capture_test_request :: proc(
	s: ^Debug_Session,
	id: i64,
	args: json.Object,
	allocator := context.allocator,
) -> string {
	tick, has_tick := json_int_field(args, "tick")
	behavior_name, has_behavior := json_string_field(args, "behavior")
	if !has_tick || !has_behavior {
		return error_response(id, "capture_test", "missing args.tick or args.behavior", allocator)
	}
	behavior := program_behavior(s.program, behavior_name)
	if behavior == nil {
		return error_response(id, "capture_test", "unknown behavior", allocator)
	}
	obs := new_tick_observe(allocator)
	if _, ok := session_refold_tick(s, int(tick), &obs, allocator); !ok {
		return error_response(id, "capture_test", "tick out of range", allocator)
	}

	instance, instance_given := json_int_field(args, "instance")
	capture: Step_Capture
	found := false
	for step in obs.steps {
		if step.behavior != behavior_name {
			continue
		}
		if instance_given && step.instance.raw != Thing_Id(instance) {
			continue
		}
		capture = step
		found = true
		break
	}
	if !found {
		return error_response(id, "capture_test", "no captured step for that behavior and instance", allocator)
	}
	if !capture.ok {
		return error_response(id, "capture_test", "the captured step produced no result to assert", allocator)
	}

	source, render_err := render_captured_test(s, behavior, capture, int(tick), allocator)
	if render_err != "" {
		return error_response(id, "capture_test", render_err, allocator)
	}

	b := strings.builder_make(allocator)
	ok_response_open(&b, id, "capture_test")
	fmt.sbprintf(&b, "{{\"tick\":%d,\"behavior\":", tick)
	write_json_string(&b, behavior_name)
	fmt.sbprintf(&b, ",\"instance\":%d,\"test\":", capture.instance.raw)
	write_json_string(&b, source)
	strings.write_string(&b, "}}")
	return strings.to_string(b)
}

// render_captured_test renders the funpack test block: a @doc naming the
// provenance, a deterministic test name, and the one assert — the behavior's
// step applied to the captured reads, compared against the in-fold result.
// Returns a non-empty error naming the first unconstructible read or value.
@(private = "file")
render_captured_test :: proc(
	s: ^Debug_Session,
	behavior: ^Behavior_Decl,
	capture: Step_Capture,
	tick: int,
	allocator := context.allocator,
) -> (
	source: string,
	err: string,
) {
	b := strings.builder_make(allocator)
	fmt.sbprintf(
		&b,
		"@doc(\"Captured by capture_test: %s on %s#%d at tick %d of a recorded session.\")\n",
		behavior.name,
		behavior.on_thing,
		capture.instance.raw,
		tick,
	)
	fmt.sbprintf(&b, "test \"captured %s tick %d instance %d\" {{\n", behavior.name, tick, capture.instance.raw)
	fmt.sbprintf(&b, "  assert %s.step(", behavior.name)
	for param, i in behavior.params {
		if i > 0 {
			strings.write_string(&b, ", ")
		}
		if param_err := write_param_fixture(&b, s, behavior, capture, param, tick, allocator); param_err != "" {
			return "", param_err
		}
	}
	strings.write_string(&b, ") == ")
	if result_err := write_source_value(&b, s.program, capture.result, primary_emit(behavior), allocator); result_err != "" {
		return "", result_err
	}
	strings.write_string(&b, "\n}\n")
	return strings.to_string(b), ""
}

// capture_tick_request serves one `capture_tick` command: read the committed
// pre-state (version tick-1; tick 0's pre is the post-startup version) and
// post-state (version tick) of the target thing on the addressed lineage, and
// render a funpack `test` asserting the hand-rolled whole-tick twin reproduces
// the LIVE Id-ordered schedule — `assert twin([pre rows]) == [post rows]`.
// Observe-class — the retained chain is read, never written. The pre/post rows
// render through the same source constructors capture_test uses, so an
// unconstructible column (a Ref, an anim value) is refused, never approximated.
capture_tick_request :: proc(
	s: ^Debug_Session,
	id: i64,
	args: json.Object,
	allocator := context.allocator,
) -> string {
	tick, has_tick := json_int_field(args, "tick")
	thing, has_thing := json_string_field(args, "thing")
	twin_name, has_twin := json_string_field(args, "twin")
	if !has_tick || !has_thing || !has_twin {
		return error_response(id, "capture_tick", "missing args.tick, args.thing, or args.twin", allocator)
	}
	twin := program_function(s.program, twin_name)
	if twin == nil {
		return error_response(id, "capture_tick", "unknown twin function", allocator)
	}
	lineage, lineage_ok := session_read_lineage(s, args)
	if !lineage_ok {
		return error_response(id, "capture_tick", "unknown branch — checkout an existing lineage", allocator)
	}
	pre_version, pre_ok := session_version_on(s, lineage, int(tick) - 1)
	post_version, post_ok := session_version_on(s, lineage, int(tick))
	if !pre_ok || !post_ok {
		return error_response(id, "capture_tick", "tick out of range", allocator)
	}
	pre_mut := pre_version
	post_mut := post_version
	pre_table := version_find_table(&pre_mut, thing)
	post_table := version_find_table(&post_mut, thing)
	if pre_table == nil || post_table == nil {
		return error_response(id, "capture_tick", "unknown thing", allocator)
	}
	// The twin shape is checked against a thing already confirmed present above, so
	// an unknown thing reads as "unknown thing", not as a twin-return-type mismatch.
	takes_view, twin_err := capture_tick_twin_shape(twin, thing, allocator)
	if twin_err != "" {
		return error_response(id, "capture_tick", twin_err, allocator)
	}

	source, render_err := render_captured_tick(
		s.program,
		thing,
		twin_name,
		takes_view,
		pre_table.rows,
		post_table.rows,
		int(tick),
		allocator,
	)
	if render_err != "" {
		return error_response(id, "capture_tick", render_err, allocator)
	}

	b := strings.builder_make(allocator)
	ok_response_open(&b, id, "capture_tick")
	fmt.sbprintf(&b, "{{\"tick\":%d,\"thing\":", tick)
	write_json_string(&b, thing)
	strings.write_string(&b, ",\"twin\":")
	write_json_string(&b, twin_name)
	strings.write_string(&b, ",\"test\":")
	write_json_string(&b, source)
	strings.write_string(&b, "}}")
	return strings.to_string(b)
}

// capture_tick_twin_shape validates the twin is a whole-tick fold over the
// target thing: exactly one param typed `[T]` or `View[T]` (T = thing) and a
// `[T]` return. takes_view is true when the param is `View[T]`, so the rendered
// call wraps the pre rows in `View.of(…)`. A non-empty err names the violation.
@(private = "file")
capture_tick_twin_shape :: proc(
	twin: ^Function_Decl,
	thing: string,
	allocator := context.allocator,
) -> (
	takes_view: bool,
	err: string,
) {
	list_type := fmt.aprintf("[%s]", thing, allocator = allocator)
	if len(twin.params) != 1 {
		return false, fmt.aprintf(
			"twin %s must take exactly one param (%s or View[%s])",
			twin.name,
			list_type,
			thing,
			allocator = allocator,
		)
	}
	if !is_bracket_list(twin.return_type) || signal_type_of(twin.return_type) != thing {
		return false, fmt.aprintf("twin %s must return %s", twin.name, list_type, allocator = allocator)
	}
	param_type := twin.params[0].type
	switch {
	case is_view_type(param_type) && view_thing_of(param_type) == thing:
		return true, ""
	case is_bracket_list(param_type) && signal_type_of(param_type) == thing:
		return false, ""
	}
	return false, fmt.aprintf(
		"twin %s param must be %s or View[%s], not %s",
		twin.name,
		list_type,
		thing,
		param_type,
		allocator = allocator,
	)
}

// render_captured_tick renders the whole-tick twin test block: a @doc naming the
// provenance, a deterministic test name, and the one assert — the twin applied
// to the committed pre rows, compared against the committed post rows (the live
// schedule's Id-ordered output). Returns a non-empty error for the first
// unconstructible column in either row set.
@(private = "file")
render_captured_tick :: proc(
	program: ^Program,
	thing: string,
	twin_name: string,
	takes_view: bool,
	pre_rows: []Row,
	post_rows: []Row,
	tick: int,
	allocator := context.allocator,
) -> (
	source: string,
	err: string,
) {
	b := strings.builder_make(allocator)
	fmt.sbprintf(
		&b,
		"@doc(\"Captured by capture_tick: %s vs the live schedule for %s over tick %d of a recorded session.\")\n",
		twin_name,
		thing,
		tick,
	)
	fmt.sbprintf(&b, "test \"captured tick %d %s twin %s\" {{\n", tick, thing, twin_name)
	fmt.sbprintf(&b, "  assert %s(", twin_name)
	list_hint := fmt.aprintf("[%s]", thing, allocator = allocator)
	if takes_view {
		strings.write_string(&b, "View.of(")
	}
	if pre_err := write_rows_source_list(&b, program, thing, pre_rows, list_hint, allocator); pre_err != "" {
		return "", pre_err
	}
	if takes_view {
		strings.write_string(&b, ")")
	}
	strings.write_string(&b, ") == ")
	if post_err := write_rows_source_list(&b, program, thing, post_rows, list_hint, allocator); post_err != "" {
		return "", post_err
	}
	strings.write_string(&b, "\n}\n")
	return strings.to_string(b), ""
}

// write_rows_source_list renders a committed row slice as a funpack `[T{…}, …]`
// list literal — each row a record of the thing's declared fields, through the
// same constructor renderer capture_test uses (write_source_value over a
// List_Value of Record_Values). Refuses the first column with no source literal.
@(private = "file")
write_rows_source_list :: proc(
	b: ^strings.Builder,
	program: ^Program,
	thing: string,
	rows: []Row,
	list_hint: string,
	allocator := context.allocator,
) -> (
	err: string,
) {
	elements := make([]Value, len(rows), allocator)
	for row, i in rows {
		fields := make(map[string]Value, allocator)
		for k, v in row.fields {
			fields[k] = field_value_to_value(v)
		}
		elements[i] = Record_Value{type_name = thing, fields = fields}
	}
	return write_source_value(b, program, List_Value{elements = elements}, list_hint, allocator)
}

// write_param_fixture renders one declared read as its deterministic source
// constructor: `self` as the captured pre-eval blackboard record, a View[T] as
// `View.of([…])` over the captured rows, a `[Signal]` as the captured inbound
// list, and an Input as the producer chain rebuilt from the recorded snapshot.
// A Rng or Time read has no source literal — refused by name.
@(private = "file")
write_param_fixture :: proc(
	b: ^strings.Builder,
	s: ^Debug_Session,
	behavior: ^Behavior_Decl,
	capture: Step_Capture,
	param: Param_Decl,
	tick: int,
	allocator := context.allocator,
) -> (
	err: string,
) {
	switch {
	case param.type == "Input":
		return write_input_fixture(b, s, tick, allocator)
	case param.type == "Rng" || param.type == "Time":
		return fmt.aprintf(
			"param %s: %s has no deterministic source constructor — capture at a constructible boundary",
			param.name,
			param.type,
			allocator = allocator,
		)
	case is_view_type(param.type):
		strings.write_string(b, "View.of(")
		if list_err := write_source_value(b, s.program, capture.env[param.name], param.type[4:], allocator); list_err != "" {
			return list_err
		}
		strings.write_string(b, ")")
		return ""
	}
	return write_source_value(b, s.program, capture.env[param.name], param.type, allocator)
}

// write_input_fixture rebuilds the recorded snapshot as the §23 §5 producer
// chain — `Input.empty()` plus one `.with_pressed/.with_held/.with_value/
// .with_axis` per recorded entry, in sorted (player, action) order so the
// chain is byte-stable. The producers are total over what a recorded snapshot
// carries except a released-only edge, which no producer mints — refused.
@(private = "file")
write_input_fixture :: proc(
	b: ^strings.Builder,
	s: ^Debug_Session,
	tick: int,
	allocator := context.allocator,
) -> (
	err: string,
) {
	registry := build_action_registry(s.program^, allocator)
	snapshot := s.snapshots[tick]
	strings.write_string(b, "Input.empty()")

	buttons := make([dynamic]Player_Action, 0, len(snapshot.buttons), allocator)
	for key in snapshot.buttons {
		append(&buttons, key)
	}
	sort_player_actions(buttons[:])
	for key in buttons {
		state := snapshot.buttons[key]
		action_name, action_ok := registry_action_name(registry, key.action)
		if !action_ok {
			return "recorded snapshot carries an action outside the program's registry"
		}
		switch {
		case state.pressed:
			fmt.sbprintf(b, ".with_pressed(PlayerId::%v, %s)", key.player, action_name)
		case state.held:
			fmt.sbprintf(b, ".with_held(PlayerId::%v, %s)", key.player, action_name)
		case:
			return "recorded snapshot carries a released-only edge — no producer constructs it"
		}
	}

	axes := make([dynamic]Player_Action, 0, len(snapshot.axes), allocator)
	for key in snapshot.axes {
		append(&axes, key)
	}
	sort_player_actions(axes[:])
	for key in axes {
		vec := snapshot.axes[key]
		action_name, action_ok := registry_action_name(registry, key.action)
		if !action_ok {
			return "recorded snapshot carries an action outside the program's registry"
		}
		if vec.y == 0 {
			fmt.sbprintf(b, ".with_value(PlayerId::%v, %s, ", key.player, action_name)
			write_source_fixed(b, vec.x)
			strings.write_string(b, ")")
		} else {
			fmt.sbprintf(b, ".with_axis(PlayerId::%v, %s, Vec2{{x: ", key.player, action_name)
			write_source_fixed(b, vec.x)
			strings.write_string(b, ", y: ")
			write_source_fixed(b, vec.y)
			strings.write_string(b, "})")
		}
	}
	return ""
}

// sort_player_actions orders snapshot keys by (player, action id) — the
// deterministic producer-chain order (map iteration order is not).
@(private = "file")
sort_player_actions :: proc(keys: []Player_Action) {
	slice.sort_by(keys, proc(a, b: Player_Action) -> bool {
		if a.player != b.player {
			return a.player < b.player
		}
		return a.action < b.action
	})
}

// registry_action_name resolves an ActionId back to its `Enum::Variant` source
// token — the inverse of the binding resolution lookup.
@(private = "file")
registry_action_name :: proc(registry: Action_Registry, action: ActionId) -> (name: string, ok: bool) {
	for def in registry.defs {
		if def.id == action {
			return def.name, true
		}
	}
	return "", false
}

// write_source_value renders one captured Value as funpack source. `type_hint`
// is the DECLARED type at this position (a param/emit/field type), naming an
// anonymous record (a `with` result, a row record) and the element type of a
// `[T]` list; "" means no hint. Returns a non-empty error for a value with no
// source literal (a Ref, a lambda, a tuple, an Rng, an anim value).
@(private = "file")
write_source_value :: proc(
	b: ^strings.Builder,
	program: ^Program,
	value: Value,
	type_hint: string,
	allocator := context.allocator,
) -> (
	err: string,
) {
	switch v in value {
	case i64:
		fmt.sbprintf(b, "%d", v)
		return ""
	case Fixed:
		write_source_fixed(b, v)
		return ""
	case bool:
		strings.write_string(b, v ? "true" : "false")
		return ""
	case Vec2:
		strings.write_string(b, "Vec2{x: ")
		write_source_fixed(b, v.x)
		strings.write_string(b, ", y: ")
		write_source_fixed(b, v.y)
		strings.write_string(b, "}")
		return ""
	case Vec3:
		strings.write_string(b, "Vec3{x: ")
		write_source_fixed(b, v.x)
		strings.write_string(b, ", y: ")
		write_source_fixed(b, v.y)
		strings.write_string(b, ", z: ")
		write_source_fixed(b, v.z)
		strings.write_string(b, "}")
		return ""
	case String_Value:
		write_source_string(b, v.text)
		return ""
	case Record_Value:
		return write_source_record(b, program, v, type_hint, allocator)
	case List_Value:
		strings.write_string(b, "[")
		element_hint := is_bracket_list(type_hint) ? signal_type_of(type_hint) : ""
		for element, i in v.elements {
			if i > 0 {
				strings.write_string(b, ", ")
			}
			if element_err := write_source_value(b, program, element, element_hint, allocator); element_err != "" {
				return element_err
			}
		}
		strings.write_string(b, "]")
		return ""
	case Variant_Value:
		strings.write_string(b, v.enum_type)
		strings.write_string(b, "::")
		strings.write_string(b, v.case_name)
		if v.payload == nil {
			return ""
		}
		if record, is_record := v.payload^.(Record_Value); is_record && record.type_name == "" {
			// A struct-variant payload: the brace literal attaches to the variant
			// token (`Draw::Rect{at: …}`), no constructor name of its own. The enum
			// decl's field order is not modeled here, so sorted names keep the
			// render deterministic.
			return write_source_record_body(b, program, record, allocator)
		}
		strings.write_string(b, "(")
		if payload_err := write_source_value(b, program, v.payload^, "", allocator); payload_err != "" {
			return payload_err
		}
		strings.write_string(b, ")")
		return ""
	case Ref, Lambda_Value, Tuple_Value, Rng, Transform_Value, Pose_Value, Handle_Value, Nav_Value:
		return fmt.aprintf("captured value has no funpack source literal: %v", value, allocator = allocator)
	}
	return "captured value has no funpack source literal: nil"
}

// write_source_record renders `Name{field: value, …}`. The constructor name is
// the value's own type, or the type hint for an anonymous record. Fields walk
// the program's DECLARED order (thing/data/signal lookup) — the idiomatic
// hand-written order — falling back to sorted names for an undeclared shape.
@(private = "file")
write_source_record :: proc(
	b: ^strings.Builder,
	program: ^Program,
	record: Record_Value,
	type_hint: string,
	allocator := context.allocator,
) -> (
	err: string,
) {
	name := record.type_name != "" ? record.type_name : type_hint
	if name == "" {
		return "captured record has no constructor name and no declared type at its position"
	}
	strings.write_string(b, name)
	decl_fields, has_decl := source_decl_fields(program, name)
	if !has_decl {
		return write_source_record_body(b, program, record, allocator)
	}
	strings.write_string(b, "{")
	wrote := 0
	for field in decl_fields {
		value, has_value := record.fields[field.name]
		if !has_value {
			continue
		}
		if wrote > 0 {
			strings.write_string(b, ", ")
		}
		wrote += 1
		strings.write_string(b, field.name)
		strings.write_string(b, ": ")
		if field_err := write_source_value(b, program, value, field.type, allocator); field_err != "" {
			return field_err
		}
	}
	strings.write_string(b, "}")
	return ""
}

// write_source_record_body renders the brace literal of a record with no
// declared field list — a struct-variant payload or an undeclared shape — in
// sorted field-name order (deterministic where no declaration orders it).
@(private = "file")
write_source_record_body :: proc(
	b: ^strings.Builder,
	program: ^Program,
	record: Record_Value,
	allocator := context.allocator,
) -> (
	err: string,
) {
	strings.write_string(b, "{")
	names := make([dynamic]string, 0, len(record.fields), allocator)
	for field_name in record.fields {
		append(&names, field_name)
	}
	slice.sort(names[:])
	for field_name, i in names {
		if i > 0 {
			strings.write_string(b, ", ")
		}
		strings.write_string(b, field_name)
		strings.write_string(b, ": ")
		if field_err := write_source_value(b, program, record.fields[field_name], "", allocator); field_err != "" {
			return field_err
		}
	}
	strings.write_string(b, "}")
	return ""
}

// source_decl_fields resolves a record constructor name onto its declared
// field list — thing, data, or signal, the three record-shaped declarations.
@(private = "file")
source_decl_fields :: proc(program: ^Program, name: string) -> (fields: []Field_Decl, ok: bool) {
	if thing := program_thing(program, name); thing != nil {
		return thing.fields, true
	}
	if data := program_data(program, name); data != nil {
		return data.fields, true
	}
	for &signal in program.signals {
		if signal.name == name {
			return signal.fields, true
		}
	}
	return nil, false
}

// write_source_fixed renders a Q32.32 value as its EXACT decimal literal —
// `2.0`, `-0.5`, `0.00000000023283064365386962890625`. The fraction is dyadic
// (denominator 2^32), so the base-10 expansion terminates within 32 digits;
// the integer long-multiplication by 10 below extracts each digit with no
// float anywhere. A `.` is always present (at least `.0`) — the funpack
// lexeme that separates a Fixed literal from an Int.
//
// Package-visible because it is the ONE float-free Fixed→source-literal renderer the
// runtime owns, shared by two readers: the capture-to-test exporter (here) AND the §28
// debug projection (introspect.odin's observe renderers), so an inspect_draw_list /
// inspect_signals / inspect_state value reads as `96.0`, not the raw Q32.32
// bits. decode_fixed(human=true) is its exact inverse, closing the observe→control
// round-trip. The committed `.artifact` wire format is unaffected — that is the
// compiler's emit.odin, a separate product; this renderer never writes one.
write_source_fixed :: proc(b: ^strings.Builder, value: Fixed) {
	bits := i64(value)
	magnitude: u64
	if bits < 0 {
		strings.write_string(b, "-")
		magnitude = u64(~bits) + 1 // two's-complement negate without i64 overflow at min(i64)
	} else {
		magnitude = u64(bits)
	}
	fmt.sbprintf(b, "%d.", magnitude >> FIXED_FRACTION_BITS)
	fraction := magnitude & 0xFFFFFFFF
	if fraction == 0 {
		strings.write_string(b, "0")
		return
	}
	for fraction != 0 {
		fraction *= 10
		fmt.sbprintf(b, "%d", fraction >> FIXED_FRACTION_BITS)
		fraction &= 0xFFFFFFFF
	}
}

// write_source_string renders a funpack string literal with the escapes the
// lexer reads back (quote, backslash, newline, tab).
@(private = "file")
write_source_string :: proc(b: ^strings.Builder, text: string) {
	strings.write_string(b, "\"")
	for i in 0 ..< len(text) {
		c := text[i]
		switch c {
		case '"':
			strings.write_string(b, "\\\"")
		case '\\':
			strings.write_string(b, "\\\\")
		case '\n':
			strings.write_string(b, "\\n")
		case '\t':
			strings.write_string(b, "\\t")
		case:
			strings.write_byte(b, c)
		}
	}
	strings.write_string(b, "\"")
}
