// The terminal render projection (spec §07 §4, §20): a pure, read-only
// self→[Draw] pass that turns a COMMITTED tick into the deterministic
// fixed-point draw-list the determinism comparison and the frame digest assert
// against. Render is NOT part of the per-tick write fold — it never writes a
// blackboard, takes no signals and no Rng, and reads only `self` — so it runs as
// a POST-COMMIT pass over the sealed World_Version (tick.odin's fold skips the
// render stage for exactly this reason). Reading the committed version (with no
// working tick in flight) means a render behavior's `self` is the committed
// blackboard, so the draw-list is the ground truth of the tick as committed, not
// a mid-tick snapshot (§20: the draw-list is the comparison surface).
//
// ORDER (the determinism the assertion rests on): the render stage's behaviors
// run in flattened-pipeline order (§11); within one render behavior, it runs
// ONCE PER INSTANCE of its on-Thing in stable Id order (§08 §2); the per-instance
// [Draw] lists concatenate in that order. So the draw-list is a pure function of
// the committed world — bit-identical run to run. No float (§10): every Vec2
// component is a Fixed off the kernel.
package funpack_runtime

// --- The §20 draw-list (the render projection's first-class result) -------

// Draw_Color is the §20 closed palette a draw command paints in. Pong draws
// everything in White; the enum is the closed taxonomy a Color variant lowers to
// (an unknown token lowers to White so the projection stays total).
Draw_Color :: enum {
	White,
	Black,
	Red,
	Green,
	Blue,
}

// Draw_Rect is the §20 filled rectangle: a fixed-point `at` and `size` in world
// units, painted in one color. `at` is the CENTER of the extent (§20 §1 anchor);
// a corner-origin backend derives the corner at the present boundary. Pong's
// paddles and ball are rects.
Draw_Rect :: struct {
	at:    Vec2,
	size:  Vec2,
	color: Draw_Color,
}

// Draw_Text is the §20 text command: the fully-interpolated string at a
// fixed-point position in one color. Pong's score readout is the only text —
// `{self.left}   {self.right}` rendered from the committed Scoreboard columns.
Draw_Text :: struct {
	at:    Vec2,
	text:  string,
	color: Draw_Color,
}

// Draw_Camera is the §20 camera command (§3: the camera is state, the view is a
// command): the world↔screen transform a `view` render behavior emits each tick.
// `at` is the world point the camera is centered on, `zoom` scales the
// world→pixel projection (1.0 = unscaled), and `rotation` is carried for the §20
// command set but not yet projected (yard emits rotation:0.0). The present
// boundary composes this transform with the letterbox geometry; like every other
// draw field, all three are Fixed off the kernel — no float (§10).
Draw_Camera :: struct {
	at:       Vec2,
	zoom:     Fixed,
	rotation: Fixed,
}

// Draw_Cmd is the closed set of §20 draw commands a render behavior emits. A new
// command kind is a schema-version bump (the closed-enum discipline §04, and the
// frame digest folds the draw-list so a new arm bumps FRAME_DIGEST_SCHEMA_VERSION).
// Pong exercises Rect (paddles, ball) and Text (score); yard adds Camera (the
// world↔screen view); the union is the draw-list's element type.
Draw_Cmd :: union {
	Draw_Rect,
	Draw_Text,
	Draw_Camera,
}

// Draw_List is the §20 draw-list: the ordered draw commands of one committed
// tick, in flattened-pipeline order across render behaviors and stable Id order
// within each. It is the assertion ground truth — two folds of the same program
// from the same inputs produce a bit-identical Draw_List (the determinism thesis,
// §10.5). The commands live in the supplied render allocator.
Draw_List :: struct {
	cmds: []Draw_Cmd,
}

// --- The render pass ------------------------------------------------------

// render_version projects a COMMITTED world version into its §20 draw-list. It
// walks the flattened pipeline (§11), and for each render-stage step runs that
// behavior once per instance of its on-Thing in stable Id order (§08 §2),
// concatenating every instance's emitted [Draw] commands in that order. The
// interpreter reads the committed version with NO tick in flight (interp.tick is
// nil), so each `self` is the committed blackboard — the draw-list is the tick as
// committed. Input/Time bind to the supplied resources, but a render behavior
// reads only `self`, so they are observable-only, never consulted here.
render_version :: proc(
	program: ^Program,
	version: World_Version,
	input: Input,
	time: Record_Value,
	allocator := context.allocator,
) -> Draw_List {
	committed := version
	interp := new_interp(program, &committed, nil, input, time, allocator)

	cmds := make([dynamic]Draw_Cmd, allocator)
	for step in program.pipeline {
		if step.stage != "render" {
			continue
		}
		behavior := program_behavior(program, step.behavior)
		if behavior == nil {
			continue
		}
		render_behavior_over_instances(&interp, behavior, &cmds, allocator)
	}
	return Draw_List{cmds = cmds[:]}
}

// render_behavior_over_instances runs one render behavior once per instance of
// its on-Thing in stable Id order (§08 §2), evaluating the body to its [Draw]
// list and appending each lowered command. The instances come from the committed
// View (interp.tick is nil), so iteration is the committed stable Id order. A
// render behavior binds only `self` (it takes no signals, no Rng, no Views), so
// the env carries the instance blackboard and the body returns a [Draw] list.
render_behavior_over_instances :: proc(
	interp: ^Interp,
	behavior: ^Behavior_Decl,
	cmds: ^[dynamic]Draw_Cmd,
	allocator := context.allocator,
) {
	view := view_of_type(interp.version, behavior.on_thing)
	for i in 0 ..< view_count(view) {
		row, _ := view_at(view, i)
		env := render_behavior_env(interp, behavior, row)
		result, ok := eval_behavior_body(interp, behavior.body, &env)
		if !ok {
			continue
		}
		append_draw_commands(cmds, result)
	}
}

// render_behavior_env binds a render behavior's params for one instance. A render
// behavior reads only `self` — its on-Thing blackboard — so `self` binds to the
// committed row's record and an Input/Time param binds to the resource it
// observes but never writes through. A render behavior declares no signal/View
// params, so this is the whole binding it needs (the slot contract enforces the
// no-blackboard-write, no-signal shape compiler-side; the runtime honors it by
// binding only what render reads).
render_behavior_env :: proc(interp: ^Interp, behavior: ^Behavior_Decl, self_row: Row) -> Env {
	env := Env{names = make(map[string]Value, interp.allocator)}
	for param in behavior.params {
		switch param.type {
		case "Input":
			env.names[param.name] = input_marker(interp)
		case "Time":
			env.names[param.name] = interp.time
		case:
			// `self` (the on-Thing type) and any other thing-typed param read the
			// committed instance blackboard; render's only such param is self.
			env.names[param.name] = row_to_record(interp, self_row)
		}
	}
	return env
}

// append_draw_commands lowers a render behavior's returned [Draw] list into the
// draw-list, appending each command in emitted order. The return is a List_Value
// of Draw::Rect / Draw::Text records (the [Draw] emit shape); a non-list return
// or a record that is not a known draw command is skipped, so a malformed render
// body contributes nothing rather than faulting the projection.
append_draw_commands :: proc(cmds: ^[dynamic]Draw_Cmd, result: Value) {
	list, is_list := result.(List_Value)
	if !is_list {
		return
	}
	for elem in list.elements {
		record, is_record := elem.(Record_Value)
		if !is_record {
			continue
		}
		if cmd, ok := draw_command_from_record(record); ok {
			append(cmds, cmd)
		}
	}
}

// draw_command_from_record lowers one evaluated Draw::* record into a Draw_Cmd by
// its declared type. Draw::Rect reads at/size (Vec2) + color; Draw::Text reads
// at (Vec2) + text (the interpolated String) + color; Draw::Camera reads at (Vec2)
// + zoom/rotation (Fixed) — the world↔screen transform (§3). An unknown draw type
// or a missing required field yields ok=false, so only well-formed §20 commands
// enter the draw-list.
draw_command_from_record :: proc(record: Record_Value) -> (cmd: Draw_Cmd, ok: bool) {
	switch record.type_name {
	case "Draw::Rect":
		at, at_ok := record_vec2(record, "at")
		size, size_ok := record_vec2(record, "size")
		if !at_ok || !size_ok {
			return nil, false
		}
		return Draw_Rect{at = at, size = size, color = record_color(record, "color")}, true
	case "Draw::Text":
		at, at_ok := record_vec2(record, "at")
		text, text_ok := record_text(record, "text")
		if !at_ok || !text_ok {
			return nil, false
		}
		return Draw_Text{at = at, text = text, color = record_color(record, "color")}, true
	case "Draw::Camera":
		// at is required (the camera center); zoom/rotation default to absent-safe
		// values so a partially-built Camera record still lowers — an absent zoom
		// reads 0 (no recenter is observable until the present pass applies it), an
		// absent rotation reads 0 (yard emits rotation:0.0 and rotation is unprojected).
		at, at_ok := record_vec2(record, "at")
		if !at_ok {
			return nil, false
		}
		zoom := record_fixed(record, "zoom")
		rotation := record_fixed(record, "rotation")
		return Draw_Camera{at = at, zoom = zoom, rotation = rotation}, true
	}
	return nil, false
}

// --- draw-record field readers --------------------------------------------

// record_vec2 reads a Vec2 field off a draw-command record — the at/size of a
// Rect, the at of a Text. ok is false when the field is absent or not a Vec2.
record_vec2 :: proc(record: Record_Value, name: string) -> (v: Vec2, ok: bool) {
	field, present := record.fields[name]
	if !present {
		return VEC2_ZERO, false
	}
	vec, is_vec := field.(Vec2)
	return vec, is_vec
}

// record_fixed reads a Fixed field off a draw-command record — the zoom/rotation
// of a Camera. A field that is absent or not a Fixed reads 0, the absent-safe
// default a partially-built Camera record carries (zoom 0 / rotation 0): the
// lowering never faults on a missing scalar, it folds the §20 default in.
record_fixed :: proc(record: Record_Value, name: string) -> Fixed {
	field, present := record.fields[name]
	if !present {
		return Fixed(0)
	}
	value, is_fixed := field.(Fixed)
	if !is_fixed {
		return Fixed(0)
	}
	return value
}

// record_text reads the interpolated String text off a Draw::Text record. ok is
// false when the field is absent or not a String — the render projection's String
// completion lands the field as a String_Value, so a present text is exactly that
// arm.
record_text :: proc(record: Record_Value, name: string) -> (text: string, ok: bool) {
	field, present := record.fields[name]
	if !present {
		return "", false
	}
	str, is_str := field.(String_Value)
	if !is_str {
		return "", false
	}
	return str.text, true
}

// record_color reads a draw command's color into the §20 palette, defaulting to
// White when the field is absent or not an enum value — pong paints everything
// White, so the default is the common case. The Color variant's case name maps to
// the closed palette; an unknown case lowers to White (the projection stays total).
record_color :: proc(record: Record_Value, name: string) -> Draw_Color {
	field, present := record.fields[name]
	if !present {
		return .White
	}
	variant, is_variant := field.(Variant_Value)
	if !is_variant {
		return .White
	}
	switch variant.case_name {
	case "White":
		return .White
	case "Black":
		return .Black
	case "Red":
		return .Red
	case "Green":
		return .Green
	case "Blue":
		return .Blue
	}
	return .White
}
