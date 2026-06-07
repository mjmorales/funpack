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

// Draw_Color is the §20 closed palette a draw command paints in — the nine named
// members of the spec's render.fun `Color` enum (White..Gray). It is the closed
// taxonomy a Color variant lowers to; the spec's `Color::Rgb{r,g,b}` escape is NOT
// a member here (the runtime draw-list carries only the named palette — an exact
// Rgb value has no Draw_Color slot, so a Color::Rgb refuses the lowering rather
// than collapsing to a named member). The NAMED members are appended in spec
// order, so the existing five (White=0..Blue=4) keep their ordinals — the frame
// digest folds the color as that raw ordinal (frame_digest.odin write_draw_cmd),
// so a golden whose draw-list paints only the original five is byte-unchanged by
// the four-member extension. A new member is a deliberate schema-version bump
// (§04 closed-enum; FRAME_DIGEST_SCHEMA_VERSION).
Draw_Color :: enum {
	White,
	Black,
	Red,
	Green,
	Blue,
	Yellow,
	Cyan,
	Magenta,
	Gray,
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

// --- The §20 §1 3D draw commands (engine.render3, the Draw3 command set) ----
//
// These are the determinism-path lowering of krognid's [Draw3] render bodies
// (draw_scene/draw_krognid). They are FULL-FIDELITY 3D records — every Vec3, the
// fov, the §16 §7 rig (skeleton/parts/pose), the world position — so the frame
// digest folds the complete 3D draw-list bit-identically (the determinism bet is on
// the LOWERING, not on how the present chooses to draw it). The PRESENT projection
// (session_live.odin) deliberately flattens these to the existing 2D pixel grid
// (the XZ ground plane top-down) — a render-boundary-only choice that never
// re-enters the sim (the render-is-a-post-commit-projection ADR). A new Draw3 arm
// is a deliberate schema-version bump (§04 closed-enum; FRAME_DIGEST_SCHEMA_VERSION),
// and its Cmd_Tag ordinal is APPENDED after the 2D ordinals so the existing
// pong/snake/hunt/yard digests are byte-unmoved.

// Draw3_Camera is the §20 §1 3D camera: a world-space eye point, a look-at target,
// and a field of view in Fixed degrees. The 3D twin of Draw_Camera (which carries a
// 2D at/zoom/rotation) — render3 owns its own camera. All three positions are Fixed
// off the kernel; no float (§10).
Draw3_Camera :: struct {
	eye: Vec3,
	at:  Vec3,
	fov: Fixed,
}

// Draw3_Light is the §20 §1 directional light: a world-space direction and a
// palette color. The direction is a Vec3 off the kernel; the color is the closed
// §20 palette (Color::White, …) the named draw-list carries.
Draw3_Light :: struct {
	dir:   Vec3,
	color: Draw_Color,
}

// Draw3_Plane is the §20 §1 flat ground plane: a world center (Vec3), an XZ extent
// (Vec2), and a palette color. krognid's draw_scene paints the board's Gray ground
// plane. Every component is Fixed off the kernel.
Draw3_Plane :: struct {
	at:    Vec3,
	size:  Vec2,
	color: Draw_Color,
}

// Draw3_Rigged is the §20 §1 / §16 §7 posed rigged mesh: the opaque Skeleton and
// PartSet handles, the composed Pose, and the world position (Vec3). It is the
// render seam krognid's draw_krognid emits — the blended pose of the walking
// creature. The skeleton/parts are opaque Handle_Values (composed through builders,
// never read by field); the pose is the sparse Bone→Transform map (pose.odin); `at`
// is the creature's world position. The digest folds the handles' op logs, the
// pose's per-bone transforms, and the position — the whole rig state bit-exactly.
Draw3_Rigged :: struct {
	skeleton: Handle_Value,
	parts:    Handle_Value,
	pose:     Pose_Value,
	at:       Vec3,
}

// Draw_Cmd is the closed set of §20 draw commands a render behavior emits. A new
// command kind is a schema-version bump (the closed-enum discipline §04, and the
// frame digest folds the draw-list so a new arm bumps FRAME_DIGEST_SCHEMA_VERSION).
// Pong exercises Rect (paddles, ball) and Text (score); yard adds Camera (the 2D
// world↔screen view); krognid adds the four §20 §1 3D commands
// (Draw3_Camera/Light/Plane/Rigged). The 3D arms are APPENDED after the 2D arms;
// the union is the draw-list's element type, mixing 2D and 3D commands in one
// flattened draw-list (an artifact emits one OR the other in practice, but the
// union admits both).
Draw_Cmd :: union {
	Draw_Rect,
	Draw_Text,
	Draw_Camera,
	Draw3_Camera,
	Draw3_Light,
	Draw3_Plane,
	Draw3_Rigged,
}

// Draw_List is the §20 draw-list: the ordered draw commands of one committed
// tick, in flattened-pipeline order across render behaviors and stable Id order
// within each. It is the assertion ground truth — two folds of the same program
// from the same inputs produce a bit-identical Draw_List (the determinism thesis,
// §10.5). The commands live in the supplied render allocator.
Draw_List :: struct {
	cmds: []Draw_Cmd,
}

// draw_cmd_equal compares two §20 draw commands structurally — the bit-identical
// equality the determinism assertion reads. The 2D arms (Rect/Text/Camera) and the
// Draw3_Camera/Light/Plane arms are simply comparable (Fixed by raw bits, text/color
// by value), but Draw3_Rigged carries SLICE-bearing values (the Handle_Value op-logs
// and the Pose_Value driven-bone slice), so the whole Draw_Cmd union is no longer
// simply comparable — `==` is undefined on it. This proc dispatches each arm to its
// structural comparison (handles_equal / poses_equal for the rig, raw-bit equality
// for the rest); a kind mismatch is unequal. It is the one comparison the draw-list
// equality the §20 ground truth folds through.
draw_cmd_equal :: proc(a, b: Draw_Cmd) -> bool {
	switch x in a {
	case Draw_Rect:
		y, ok := b.(Draw_Rect)
		return ok && x == y
	case Draw_Text:
		y, ok := b.(Draw_Text)
		return ok && x == y
	case Draw_Camera:
		y, ok := b.(Draw_Camera)
		return ok && x == y
	case Draw3_Camera:
		y, ok := b.(Draw3_Camera)
		return ok && x == y
	case Draw3_Light:
		y, ok := b.(Draw3_Light)
		return ok && x == y
	case Draw3_Plane:
		y, ok := b.(Draw3_Plane)
		return ok && x == y
	case Draw3_Rigged:
		y, ok := b.(Draw3_Rigged)
		if !ok {
			return false
		}
		return(
			handles_equal(x.skeleton, y.skeleton) &&
			handles_equal(x.parts, y.parts) &&
			poses_equal(x.pose, y.pose) &&
			x.at == y.at \
		)
	}
	// Both nil (an empty union) compares equal; a nil-vs-set mismatch is unequal.
	return a == nil && b == nil
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
// + zoom/rotation (Fixed) — the world↔screen transform (§3). An unknown draw type,
// a missing required field, OR a color naming a member outside the closed §20
// palette (record_color refuses with ok=false) yields ok=false, so only well-formed
// §20 commands enter the draw-list — an out-of-palette color drops the command
// rather than silently mispainting it White.
draw_command_from_record :: proc(record: Record_Value) -> (cmd: Draw_Cmd, ok: bool) {
	switch record.type_name {
	case "Draw::Rect":
		at, at_ok := record_vec2(record, "at")
		size, size_ok := record_vec2(record, "size")
		color, color_ok := record_color(record, "color")
		if !at_ok || !size_ok || !color_ok {
			return nil, false
		}
		return Draw_Rect{at = at, size = size, color = color}, true
	case "Draw::Text":
		at, at_ok := record_vec2(record, "at")
		text, text_ok := record_text(record, "text")
		color, color_ok := record_color(record, "color")
		if !at_ok || !text_ok || !color_ok {
			return nil, false
		}
		return Draw_Text{at = at, text = text, color = color}, true
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
	case "Draw3::Camera":
		// the §20 §1 3D camera: eye/at world points (Vec3) + fov (Fixed degrees).
		eye, eye_ok := record_vec3(record, "eye")
		at, at_ok := record_vec3(record, "at")
		if !eye_ok || !at_ok {
			return nil, false
		}
		fov := record_fixed(record, "fov")
		return Draw3_Camera{eye = eye, at = at, fov = fov}, true
	case "Draw3::Light":
		// the §20 §1 directional light: dir (Vec3) + a closed-palette color. An
		// out-of-palette color refuses the lowering (record_color ok=false).
		dir, dir_ok := record_vec3(record, "dir")
		color, color_ok := record_color(record, "color")
		if !dir_ok || !color_ok {
			return nil, false
		}
		return Draw3_Light{dir = dir, color = color}, true
	case "Draw3::Plane":
		// the §20 §1 ground plane: at (Vec3 world center) + size (Vec2 XZ extent) +
		// a closed-palette color (krognid's Gray ground plane).
		at, at_ok := record_vec3(record, "at")
		size, size_ok := record_vec2(record, "size")
		color, color_ok := record_color(record, "color")
		if !at_ok || !size_ok || !color_ok {
			return nil, false
		}
		return Draw3_Plane{at = at, size = size, color = color}, true
	case "Draw3::Rigged":
		// the §20 §1 / §16 §7 posed rigged mesh: opaque Skeleton/PartSet handles +
		// the composed Pose + the world position (Vec3). The handles/pose ride
		// through verbatim — the digest folds their op logs / per-bone transforms.
		skeleton, sk_ok := record_handle(record, "skeleton")
		parts, pt_ok := record_handle(record, "parts")
		pose, pose_ok := record_pose(record, "pose")
		at, at_ok := record_vec3(record, "at")
		if !sk_ok || !pt_ok || !pose_ok || !at_ok {
			return nil, false
		}
		return Draw3_Rigged{skeleton = skeleton, parts = parts, pose = pose, at = at}, true
	}
	return nil, false
}

// --- draw-record field readers --------------------------------------------

// record_vec2 reads a Vec2 field off a draw-command record — the at/size of a
// Rect, the at of a Text, the XZ size of a Draw3::Plane. ok is false when the field
// is absent or not a Vec2.
record_vec2 :: proc(record: Record_Value, name: string) -> (v: Vec2, ok: bool) {
	field, present := record.fields[name]
	if !present {
		return VEC2_ZERO, false
	}
	vec, is_vec := field.(Vec2)
	return vec, is_vec
}

// record_vec3 reads a Vec3 field off a Draw3 command record — the eye/at of a
// Draw3::Camera, the dir of a Draw3::Light, the at of a Draw3::Plane / Draw3::Rigged.
// It accepts BOTH shapes a Vec3 reaches the lowering as: the Vec3 union value
// (eval_record collapses a `Vec3{x,y,z}` literal to it, and a hand-built fixture
// passes it directly) AND, defensively, a Record_Value{type_name="Vec3"} with x/y/z
// Fixed fields (the pre-collapse shape any path that bypasses eval_record's Vec3 arm
// would carry) — so the reader is robust to either producer. ok is false when the
// field is absent or is neither shape.
record_vec3 :: proc(record: Record_Value, name: string) -> (v: Vec3, ok: bool) {
	field, present := record.fields[name]
	if !present {
		return Vec3{}, false
	}
	#partial switch f in field {
	case Vec3:
		return f, true
	case Record_Value:
		if f.type_name != "Vec3" {
			return Vec3{}, false
		}
		x, x_ok := record_value_fixed(f, "x")
		y, y_ok := record_value_fixed(f, "y")
		z, z_ok := record_value_fixed(f, "z")
		if !x_ok || !y_ok || !z_ok {
			return Vec3{}, false
		}
		return Vec3{x = x, y = y, z = z}, true
	}
	return Vec3{}, false
}

// record_value_fixed reads a Fixed-valued field off a record's field map — the x/y/z
// of a pre-collapse Vec3 Record_Value. ok is false when the field is absent or not a
// Fixed (a Vec3 component must be a kernel Fixed; never lifted from an Int here, as a
// Vec3 literal's components are §10 Fixed).
record_value_fixed :: proc(record: Record_Value, name: string) -> (v: Fixed, ok: bool) {
	field, present := record.fields[name]
	if !present {
		return Fixed(0), false
	}
	value, is_fixed := field.(Fixed)
	return value, is_fixed
}

// record_handle reads an opaque anim Handle_Value field off a Draw3::Rigged record —
// the skeleton/parts handles draw_krognid binds. ok is false when the field is
// absent or not a Handle_Value (the handle composes only through its builders, so a
// well-formed Rigged carries exactly this arm).
record_handle :: proc(record: Record_Value, name: string) -> (h: Handle_Value, ok: bool) {
	field, present := record.fields[name]
	if !present {
		return Handle_Value{}, false
	}
	handle, is_handle := field.(Handle_Value)
	return handle, is_handle
}

// record_pose reads the composed Pose_Value field off a Draw3::Rigged record — the
// blended pose draw_krognid drives the rig with. ok is false when the field is
// absent or not a Pose_Value.
record_pose :: proc(record: Record_Value, name: string) -> (p: Pose_Value, ok: bool) {
	field, present := record.fields[name]
	if !present {
		return Pose_Value{}, false
	}
	pose, is_pose := field.(Pose_Value)
	return pose, is_pose
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

// record_color reads a draw command's color into the §20 palette. An ABSENT color
// field defaults to White — pong paints everything White, so the default is the
// common case and a missing field is the well-formed "no color stated" shape. A
// PRESENT field that names a color must name one of the nine closed-palette members
// (the spec render.fun `Color` enum, White..Gray): a recognized name lowers to its
// member with ok=true; an unrecognized case_name (a typo, a future palette member,
// or the spec's `Color::Rgb{...}` escape the named draw-list has no slot for)
// REFUSES with ok=false — never guessed, the same fail-closed discipline
// node_kind_from_tag applies to an unknown node tag. The caller drops the malformed
// command rather than silently mispainting it White (a silent White fallback
// renders e.g. a Gray ground plane White — the closed-palette violation this
// refusal exists to prevent). A present-but-not-a-variant field also refuses.
record_color :: proc(record: Record_Value, name: string) -> (color: Draw_Color, ok: bool) {
	field, present := record.fields[name]
	if !present {
		return .White, true
	}
	variant, is_variant := field.(Variant_Value)
	if !is_variant {
		return .White, false
	}
	switch variant.case_name {
	case "White":
		return .White, true
	case "Black":
		return .Black, true
	case "Red":
		return .Red, true
	case "Green":
		return .Green, true
	case "Blue":
		return .Blue, true
	case "Yellow":
		return .Yellow, true
	case "Cyan":
		return .Cyan, true
	case "Magenta":
		return .Magenta, true
	case "Gray":
		return .Gray, true
	}
	return .White, false
}
