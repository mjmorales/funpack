// The native fixed-point physics solver — the engine-closed `physics:` stage's
// `solve` battery (spec §11). It is NOT a behavior: a collision writes BOTH
// bodies, which a behavior may never do, so resolution is an engine-closed stage
// (§11 §3) the tick fold invokes directly instead of running a user
// Behavior_Decl. This file is that battery.
//
// DETERMINISM IS THE LOAD-BEARING CONTRACT (§11 §1, runtime Lore #9). The solver
// is a PURE DETERMINISTIC FOLD over the tick's working rows:
//   - fixed-point ONLY — every arithmetic op routes through the fixed_*/vec2_*
//     kernel (fixed.odin / state.odin); no float, no libm ever reaches this path
//     (§10), so the bits are identical on every machine;
//   - a FIXED timestep — the entrypoint `dt` the Time resource carries, never a
//     per-step varying value;
//   - a FIXED solver-iteration count — SOLVER_ITERATIONS, an AX6 engine constant
//     (§11 §1), never a knob exposed to sim code;
//   - a FIXED contact ordering — bodies are gathered in stable (table, Id) order
//     and pairs are visited in stable ascending index order, so a lockstep/replay
//     re-fold resolves the same contacts in the same order, bit-identical.
//
// CONTRACTED, NOT CORRECT (§11 §1). The solver is audited bit-identical exactly
// as `extern fn sin` is; physical CORRECTNESS is proven at the golden leaf (OUT
// of this epic). So the resolution arithmetic here is a minimal deterministic
// scheme — the acceptance bar is determinism + the contract surface (impulse
// consumed and zeroed, sensor overlaps route Triggers and are never resolved,
// layer/mask AND filtering gates contacts), NOT a physically faithful response.
//
// runtime/** never imports funpack/**; the artifact node forest and the kernel
// copy are the only coupling to the compiler product (spec §29, §09).
package funpack_runtime

// SOLVER_ITERATIONS is the AX6 fixed solver-iteration count (§11 §1): the number
// of resolution passes the solver runs over the contact set each step. It is an
// ENGINE CONSTANT, identical on every machine and run, NEVER a knob sim code can
// set — a tunable iteration count would let two runs diverge on the contact-
// resolution boundary, breaking the lockstep/replay warranty. The value is fixed
// here; correctness (how many passes a faithful response needs) is the golden
// leaf's concern, out of this epic.
SOLVER_ITERATIONS :: 4

// SOLVER_BODY_FIELD is the reserved §11 §2 blackboard column a thing carries to
// become a body — `body: Body`. The solver reads every working row carrying this
// column; a row without it is not a physics body and is skipped.
SOLVER_BODY_FIELD :: "body"

// SOLVER_POS_FIELD / SOLVER_VEL_FIELD are the reserved §11 §2 fields the solver
// integrates and writes back: `pos`/`vel`. A Static body carries no `vel` (it
// never integrates), so the vel read is option-shaped.
SOLVER_POS_FIELD :: "pos"
SOLVER_VEL_FIELD :: "vel"

// SOLVER_TRIGGER_SIGNAL is the engine `Trigger{}` signal type (§11 §4) the solver
// routes per overlapping body of a sensor pair. It rides the SAME Signal_Mailbox
// the user-signal route_signals uses, so a `deliver on Crate` reading `[Trigger]`
// consumes it same-tick exactly as it consumes a user signal.
SOLVER_TRIGGER_SIGNAL :: "Trigger"

// Body_Kind is the §11 §2 body kind, parsed from the `kind` enum-token column.
// Static never integrates (infinite mass); Dynamic is fully solved (the solver
// owns its pos/vel); Kinematic is moved by user code, never pushed back (push
// dynamics are OUT of this epic, so Kinematic integrates like Static here — it is
// not solver-driven).
Body_Kind :: enum {
	Static,
	Dynamic,
	Kinematic,
}

// Solver_Shape is the §11 §2 collision shape parsed from the `shape` variant
// column. Only Box and Circle are in scope (yard's bodies); Capsule/Polygon/
// Segment are OUT of this epic, parsed as Unknown and treated as a degenerate
// point so the fold stays total over an out-of-scope shape.
Solver_Shape_Kind :: enum {
	Unknown,
	Box,
	Circle,
}

// Solver_Shape carries the parsed shape geometry: a Box's half-extents (from its
// `size` Vec2, halved) or a Circle's radius. The half-extent form is the overlap
// test's natural operand (an AABB overlaps when the center gap is within the
// summed half-extents on each axis).
Solver_Shape :: struct {
	kind:    Solver_Shape_Kind,
	half:    Vec2, // Box half-extents (size/2); zero for non-Box
	radius:  Fixed, // Circle radius; zero for non-Circle
}

// Solver_Body is one gathered physics body: a back-pointer to its working row (by
// table + row index, so the write-back targets the exact row), plus the parsed
// §11 §2 body fields the solver reads. The pos/vel are the live reserved columns;
// the body fields are read once at gather and the impulse is consumed (zeroed) at
// write-back. Gathered in stable (table, Id) order so the contact-ordering is
// deterministic.
Solver_Body :: struct {
	table_idx: int, // index into Tick_State.tables
	row_idx:   int, // index into that table's working rows (stable Id order)
	kind:      Body_Kind,
	shape:     Solver_Shape,
	mass:      Fixed,
	friction:  Fixed,
	sensor:    bool,
	layer:     string, // the body's collision layer token, e.g. "Layer::Wall"
	mask:      []string, // the layers this body collides with (§11 §5)
	pos:       Vec2, // the reserved `pos` column (the solver integrates/writes it)
	vel:       Vec2, // the reserved `vel` column (zero for a Static body)
	impulse:   Vec2, // accumulated intent the solver CONSUMES and zeroes (§11 §2)
}

// run_solve is the §11 §3 engine `solve` battery the tick fold invokes for the
// `physics:` stage. It is a PURE DETERMINISTIC FOLD over the tick's working rows:
// gather every body in stable order, integrate the dynamic ones over the fixed
// dt, run a fixed number of resolution passes over the stable-ordered contact
// pairs (resolving solid pairs, routing a Trigger per overlapping body of a
// sensor pair), consume and zero each body's impulse, and write pos/vel/body back
// into the working rows. Stage position is the ordering (§11 §3): the control
// stage wrote intent before this runs; reaction stages read the Triggers after.
//
// The dt is the fixed timestep the Time resource carries (interp.time.dt) — the
// entrypoint tick step, identical every tick, never a per-step varying value. A
// missing/non-Fixed dt folds as zero (the integrator advances nothing), so the
// solver never faults on a malformed Time resource.
run_solve :: proc(interp: ^Interp, state: ^Tick_State) {
	dt := solver_dt(interp)
	bodies := gather_bodies(state, interp.allocator)

	// Integrate intent into velocity, then velocity into position, over the fixed
	// dt — Dynamic bodies only (§11 §2: Static never integrates, infinite mass).
	for &body in bodies {
		integrate_body(&body, dt)
	}

	// Resolve contacts over a FIXED iteration count in stable pair order. Each
	// pass visits the same pairs in the same order, so the fold is replay-stable.
	// Triggers are routed once (first pass) so a sensor overlap yields exactly one
	// Trigger per overlapping body, not one per iteration.
	for iteration in 0 ..< SOLVER_ITERATIONS {
		resolve_contacts(state, bodies, iteration == 0)
	}

	// Write the solved pos/vel back and CONSUME the impulse (zero it) — the §11 §2
	// contract: the solver consumes and zeroes the accumulated intent each step.
	for body in bodies {
		write_body_back(state, body, interp.allocator)
	}
}

// solver_dt reads the fixed timestep off the Time resource (`interp.time.dt`) —
// the entrypoint tick step the integrator advances over. A missing or non-Fixed
// dt folds as zero (the integrator advances nothing this step) rather than
// faulting, so the solver stays total over a malformed Time resource.
solver_dt :: proc(interp: ^Interp) -> Fixed {
	dt_value, present := interp.time.fields["dt"]
	if !present {
		return Fixed(0)
	}
	dt, is_fixed := dt_value.(Fixed)
	if !is_fixed {
		return Fixed(0)
	}
	return dt
}

// gather_bodies collects every physics body across the tick's working tables in
// STABLE (table, row) order — the deterministic contact ordering the lockstep/
// replay warranty rests on (§11 §1). Tables are visited in declaration order and
// rows in their stable Id order (the working rows stay Id-ascending through the
// tick), so the gathered order is a pure function of the world, identical every
// run. A row without a Body column is not a body and is skipped.
gather_bodies :: proc(state: ^Tick_State, allocator := context.allocator) -> []Solver_Body {
	bodies := make([dynamic]Solver_Body, allocator)
	for table_idx in 0 ..< len(state.tables) {
		table := &state.tables[table_idx]
		for row_idx in 0 ..< len(table.rows) {
			row := table.rows[row_idx]
			body, is_body := parse_body(row, table_idx, row_idx)
			if !is_body {
				continue
			}
			append(&bodies, body)
		}
	}
	return bodies[:]
}

// parse_body reads one working row into a Solver_Body, or reports is_body=false
// when the row carries no `body: Body` column (it is not a physics body). The
// Body column is a committed Record_Value (the §11 §2 reserved struct); its
// fields parse to the solver's typed reads — the `kind`/`layer` enum tokens, the
// `shape` variant, the `mass`/`friction` Fixed scalars, the `sensor` Bool, the
// `mask` list, and the `impulse` Vec2. The `pos`/`vel` columns are read off the
// ROW (not the body record) — they are the reserved top-level fields the solver
// integrates. A Static body has no `vel` column, so vel defaults to zero.
parse_body :: proc(row: Row, table_idx, row_idx: int) -> (body: Solver_Body, is_body: bool) {
	body_col, has_body := row.fields[SOLVER_BODY_FIELD]
	if !has_body {
		return {}, false
	}
	rec, is_record := body_col.(Record_Value)
	if !is_record {
		return {}, false
	}

	body.table_idx = table_idx
	body.row_idx = row_idx
	body.kind = parse_body_kind(rec)
	body.shape = parse_body_shape(rec)
	body.mass = body_record_fixed(rec, "mass", to_fixed(1)) // §11 §2 default mass 1.0
	body.friction = body_record_fixed(rec, "friction", fixed_from_decimal(0, "5")) // default 0.5
	body.sensor = body_record_bool(rec, "sensor")
	body.layer = body_record_token(rec, "layer")
	body.mask = body_record_mask(rec)
	body.impulse = body_record_vec2(rec, "impulse")
	body.pos = row_vec2(row, SOLVER_POS_FIELD)
	body.vel = row_vec2(row, SOLVER_VEL_FIELD)
	return body, true
}

// integrate_body advances one Dynamic body over the fixed dt: the accumulated
// impulse becomes a velocity change scaled by inverse mass (§11 §2 intent→vel),
// then the velocity advances the position over dt (vel→pos). A Static or
// Kinematic body never integrates here — Static has infinite mass (§11 §2) and
// Kinematic is user-moved (push dynamics are OUT of this epic), so the solver
// leaves their pos/vel untouched. The impulse is still zeroed at write-back for
// every body (§11 §2), whether or not it integrated. All arithmetic is fixed-
// point off the kernel: fixed_div for inverse mass, vec2_scale/vec2_add for the
// vector update.
integrate_body :: proc(body: ^Solver_Body, dt: Fixed) {
	if body.kind != .Dynamic {
		return
	}
	// vel += impulse / mass — the impulse is a momentum change; dividing by mass
	// yields the velocity change (fixed_div saturates a zero mass to the rails per
	// the kernel, never traps, so a degenerate mass stays deterministic).
	inv_mass := fixed_div(to_fixed(1), body.mass)
	body.vel = vec2_add(body.vel, vec2_scale(body.impulse, inv_mass))
	// pos += vel * dt — explicit Euler over the fixed timestep.
	body.pos = vec2_add(body.pos, vec2_scale(body.vel, dt))
}

// resolve_contacts is one resolution pass over the stable-ordered body pairs (i <
// j, ascending). For each pair it applies the §11 §5 symmetric layer/mask AND
// filter; a non-matching pair produces NO contact and is skipped. A matching pair
// is tested for overlap; on overlap a SENSOR pair routes a Trigger to each
// overlapping body and is NEVER resolved (§11 §4), while a solid pair is resolved
// (the minimal deterministic response). `route_triggers` gates the Trigger
// emission to the first pass only, so a sensor overlap yields exactly one Trigger
// per overlapping body across the whole step, not one per iteration.
resolve_contacts :: proc(state: ^Tick_State, bodies: []Solver_Body, route_triggers: bool) {
	for i in 0 ..< len(bodies) {
		for j in i + 1 ..< len(bodies) {
			a := &bodies[i]
			b := &bodies[j]
			// §11 §5: two bodies collide IFF each mask contains the other's layer
			// (symmetric AND). A mismatch is no contact at all — no resolution, no
			// Trigger.
			if !layers_collide(a^, b^) {
				continue
			}
			if !bodies_overlap(a^, b^) {
				continue
			}
			// §11 §4: a sensor is never resolved — an overlap routes a Trigger to each
			// overlapping body. Route on the first pass only (one Trigger per body per
			// step), and skip resolution entirely.
			if a.sensor || b.sensor {
				if route_triggers {
					route_trigger_pair(state, a^, b^)
				}
				continue
			}
			resolve_solid_pair(a, b)
		}
	}
}

// layers_collide is the §11 §5 symmetric AND filter: two bodies collide iff
// EACH body's mask contains the OTHER body's layer. Stated, no hidden matrix —
// the contact is gated by both masks, so a one-sided mask (a's mask names b's
// layer but b's mask omits a's) yields NO contact. This is the test yard relies
// on: the player's mask omits Pad, so the player never triggers the pad even
// though the pad's mask names Crate.
layers_collide :: proc(a, b: Solver_Body) -> bool {
	return mask_contains(a.mask, b.layer) && mask_contains(b.mask, a.layer)
}

// mask_contains reports whether a body's mask list names the given layer token —
// the per-side half of the §11 §5 AND filter. An empty mask names nothing (the
// body collides with no layer), and an empty layer token is never named.
mask_contains :: proc(mask: []string, layer: string) -> bool {
	if layer == "" {
		return false
	}
	for entry in mask {
		if entry == layer {
			return true
		}
	}
	return false
}

// bodies_overlap is the narrow-phase AABB overlap test over the bodies' axis-
// aligned bounds (a Circle uses its radius as a symmetric half-extent, the
// conservative box bound — exact-shape narrow-phase is the golden leaf's
// concern). Two bounds overlap iff the center gap on each axis is within the
// summed half-extents on that axis. All fixed-point: vec2_sub for the gap,
// fixed_add/abs compare on each axis.
bodies_overlap :: proc(a, b: Solver_Body) -> bool {
	a_half := shape_half_extents(a.shape)
	b_half := shape_half_extents(b.shape)
	gap := vec2_sub(a.pos, b.pos)
	if fixed_abs(gap.x) > fixed_add(a_half.x, b_half.x) {
		return false
	}
	if fixed_abs(gap.y) > fixed_add(a_half.y, b_half.y) {
		return false
	}
	return true
}

// shape_half_extents returns a shape's axis-aligned half-extents — the Box's
// half-size directly, a Circle's radius on both axes (the symmetric bound), and
// zero for an out-of-scope shape (treated as a degenerate point so the overlap
// test stays total).
shape_half_extents :: proc(shape: Solver_Shape) -> Vec2 {
	switch shape.kind {
	case .Box:
		return shape.half
	case .Circle:
		return Vec2{shape.radius, shape.radius}
	case .Unknown:
		return VEC2_ZERO
	}
	return VEC2_ZERO
}

// resolve_solid_pair is the minimal deterministic contact response for a solid
// (non-sensor) overlapping pair — a positional separation along the axis of
// least penetration with a friction-damped velocity cancel on that axis. The
// response is symmetric for two Dynamics (each moves half the penetration) and
// one-sided against a Static (the Dynamic takes the whole correction, the Static
// is infinite-mass and never moves). CONTRACTED, NOT CORRECT (§11 §1): this is a
// determinism-stable response, not a physically faithful one — faithful
// resolution is proven at the golden leaf. All arithmetic is fixed-point off the
// kernel.
resolve_solid_pair :: proc(a, b: ^Solver_Body) {
	a_half := shape_half_extents(a.shape)
	b_half := shape_half_extents(b.shape)
	gap := vec2_sub(a.pos, b.pos)

	// Penetration depth on each axis: summed half-extents minus the absolute gap.
	// The axis of LEAST penetration is the separating axis (the shortest push out).
	pen_x := fixed_sub(fixed_add(a_half.x, b_half.x), fixed_abs(gap.x))
	pen_y := fixed_sub(fixed_add(a_half.y, b_half.y), fixed_abs(gap.y))
	if pen_x <= 0 && pen_y <= 0 {
		return
	}

	if pen_x < pen_y {
		separate_axis_x(a, b, gap.x, pen_x)
	} else {
		separate_axis_y(a, b, gap.y, pen_y)
	}
}

// separate_axis_x pushes the pair apart along X by the penetration depth and
// cancels the X velocity with friction damping. The sign of the gap decides the
// push direction (a is to the right of b → a moves +X, b moves −X). The
// correction is split by the movable-body count: two Dynamics each take half, a
// Dynamic-vs-Static pair gives the whole push to the Dynamic.
separate_axis_x :: proc(a, b: ^Solver_Body, gap_x, pen_x: Fixed) {
	dir := gap_x >= 0 ? to_fixed(1) : to_fixed(-1)
	share := correction_share(a^, b^)
	push := fixed_mul(pen_x, share)
	if a.kind == .Dynamic {
		a.pos.x = fixed_add(a.pos.x, fixed_mul(push, dir))
		a.vel.x = friction_cancel(a.vel.x, a.friction)
	}
	if b.kind == .Dynamic {
		b.pos.x = fixed_sub(b.pos.x, fixed_mul(push, dir))
		b.vel.x = friction_cancel(b.vel.x, b.friction)
	}
}

// separate_axis_y is the Y twin of separate_axis_x — the same split-by-share push
// and friction-damped velocity cancel, along the Y axis.
separate_axis_y :: proc(a, b: ^Solver_Body, gap_y, pen_y: Fixed) {
	dir := gap_y >= 0 ? to_fixed(1) : to_fixed(-1)
	share := correction_share(a^, b^)
	push := fixed_mul(pen_y, share)
	if a.kind == .Dynamic {
		a.pos.y = fixed_add(a.pos.y, fixed_mul(push, dir))
		a.vel.y = friction_cancel(a.vel.y, a.friction)
	}
	if b.kind == .Dynamic {
		b.pos.y = fixed_sub(b.pos.y, fixed_mul(push, dir))
		b.vel.y = friction_cancel(b.vel.y, b.friction)
	}
}

// correction_share is the fraction of the penetration each Dynamic body takes:
// half when both are Dynamic (a symmetric separation), the whole when only one is
// Dynamic (the Static is infinite-mass and never moves, so the Dynamic takes the
// full correction). A pair with no Dynamic never reaches here (resolution is
// gated on overlap, and a Static-vs-Static overlap pushes nothing — both branches
// no-op).
correction_share :: proc(a, b: Solver_Body) -> Fixed {
	a_dynamic := a.kind == .Dynamic
	b_dynamic := b.kind == .Dynamic
	if a_dynamic && b_dynamic {
		return fixed_from_decimal(0, "5") // 0.5 each — symmetric split
	}
	return to_fixed(1) // the lone Dynamic takes the whole push
}

// friction_cancel damps a velocity component toward rest by the body's friction
// coefficient: the retained fraction is (1 − friction), so friction 0 keeps the
// component and friction 1 cancels it fully. The solver's friction bleeds off a
// pushed body's velocity so it coasts to rest (yard's crates settle). Fixed-point
// off the kernel: fixed_sub for (1 − f), fixed_mul to scale.
friction_cancel :: proc(component, friction: Fixed) -> Fixed {
	retained := fixed_sub(to_fixed(1), friction)
	return fixed_mul(component, retained)
}

// route_trigger_pair routes an engine `Trigger{}` (§11 §4) to each overlapping
// body of a sensor pair. A sensor is never resolved — the overlap is purely
// detected and reported. The Trigger rides the SAME Signal_Mailbox the user-
// signal route_signals uses (so a `deliver on Crate` reading `[Trigger]` consumes
// it same-tick), and it is routed PER overlapping body: each non-sensor
// participant of the overlap gets one Trigger appended. When BOTH bodies are
// sensors (a degenerate sensor-vs-sensor overlap), neither is resolved and each
// is still reported, matching the per-participant rule.
route_trigger_pair :: proc(state: ^Tick_State, a, b: Solver_Body) {
	// Each NON-sensor body overlapping a sensor receives a Trigger (§11 §4: a
	// sensor pair yields one Trigger to each overlapping body). A sensor body
	// itself is the detector, not a recipient.
	if !a.sensor {
		route_one_trigger(state)
	}
	if !b.sensor {
		route_one_trigger(state)
	}
}

// route_one_trigger appends a single engine `Trigger{}` record to the mailbox via
// the existing route_signals path — the same forward-synchronous routing a user
// signal takes (tick.odin). The Trigger is a unit record (no fields), so a
// consumer's `[Trigger]` param sees one entry per overlapping body it was routed
// to this step.
route_one_trigger :: proc(state: ^Tick_State) {
	trigger := Record_Value{type_name = SOLVER_TRIGGER_SIGNAL, fields = make(map[string]Value, state.allocator)}
	elements := make([]Value, 1, state.allocator)
	elements[0] = trigger
	route_signals(state, SOLVER_TRIGGER_SIGNAL, List_Value{elements = elements})
}

// write_body_back commits a solved body's pos/vel and its CONSUMED impulse back
// into the working row (§11 §2). It builds a FRESH fields map and SWAPS the row's
// `fields` pointer — never an in-place mutation of the existing map. This is the
// same discipline write_blackboard (tick.odin) follows, and it is load-bearing
// for determinism: new_tick_tables shallow-copies each Row (the `fields` map
// header is shared with the prior committed version), so an in-place write would
// corrupt the prior version a re-fold reads — a second fold over the same `base`
// would then diverge. Swapping the whole map leaves the prior version's map
// untouched, so the fold is replay-stable.
//
// The reserved top-level `pos`/`vel` columns take the integrated/resolved vectors
// for a DYNAMIC body (the solver owns its pos/vel); a Static/Kinematic body keeps
// its original columns unchanged (it never integrates and is never pushed, so its
// pos/vel are not the solver's to write — and writing a phantom `vel` onto a
// Static body that declared none would drift the committed shape). Every body's
// `impulse` is zeroed if it carries one — the consume-and-zero — without adding a
// phantom impulse column to a body that never had one. The body record is cloned
// into the tick arena so the committed column owns its data independent of the
// transient gather.
write_body_back :: proc(state: ^Tick_State, body: Solver_Body, allocator := context.allocator) {
	table := &state.tables[body.table_idx]
	row := &table.rows[body.row_idx]

	// Copy the existing columns into a fresh map (keys are stable prior-arena
	// strings, carried by reference exactly as write_blackboard does).
	next := make(map[string]Field_Value, len(row.fields), allocator)
	for k, v in row.fields {
		next[k] = v
	}

	// The solver owns a Dynamic body's pos/vel; a Static/Kinematic body's reserved
	// columns are not the solver's to write (it never integrates them).
	if body.kind == .Dynamic {
		next[SOLVER_POS_FIELD] = body.pos
		next[SOLVER_VEL_FIELD] = body.vel
	}

	// Rebuild the Body record with impulse zeroed — the §11 §2 consume-and-zero. A
	// body with no impulse column is left as-is (no phantom column added).
	if body_col, has_body := row.fields[SOLVER_BODY_FIELD]; has_body {
		if rec, is_record := body_col.(Record_Value); is_record {
			zeroed := clone_record_value(rec, allocator)
			if _, has_impulse := zeroed.fields["impulse"]; has_impulse {
				zeroed.fields["impulse"] = VEC2_ZERO
			}
			next[SOLVER_BODY_FIELD] = zeroed
		}
	}

	row.fields = next
}

// --- Body-column field readers (the §11 §2 Body struct parse) -------------

// parse_body_kind reads the §11 §2 `kind` enum token into the typed Body_Kind. A
// "BodyKind::Static"/"::Dynamic"/"::Kinematic" token maps to its arm; an
// absent/unrecognized kind defaults to Static (the safe inert default — an
// unparsable body never integrates).
parse_body_kind :: proc(rec: Record_Value) -> Body_Kind {
	token := body_record_token(rec, "kind")
	switch token_case(token) {
	case "Dynamic":
		return .Dynamic
	case "Kinematic":
		return .Kinematic
	case "Static":
		return .Static
	}
	return .Static
}

// parse_body_shape reads the §11 §2 `shape` column into a Solver_Shape. The shape
// is a struct-payload variant (`Shape2::Box{size}` / `Shape2::Circle{radius}`) —
// a Box carries a `size` Vec2 payload (halved to the half-extents the overlap
// test uses); a Circle carries a `radius` Fixed payload. An out-of-scope or
// malformed shape parses to Unknown (a degenerate point), so the fold stays total.
parse_body_shape :: proc(rec: Record_Value) -> Solver_Shape {
	shape_col, present := rec.fields["shape"]
	if !present {
		return Solver_Shape{kind = .Unknown}
	}
	variant, is_variant := shape_col.(Variant_Value)
	if !is_variant {
		return Solver_Shape{kind = .Unknown}
	}
	switch variant.case_name {
	case "Box":
		size := variant_payload_vec2(variant, "size")
		// Half-extents are size/2 — the AABB bound centered on pos.
		half := vec2_scale(size, fixed_from_decimal(0, "5"))
		return Solver_Shape{kind = .Box, half = half}
	case "Circle":
		radius := variant_payload_fixed(variant, "radius")
		return Solver_Shape{kind = .Circle, radius = radius}
	}
	return Solver_Shape{kind = .Unknown}
}

// body_record_token reads an enum-token column off the Body record's field map
// (the `kind`/`layer` fields). A Body is a NESTED Record_Value column, so its
// enum fields are carried as Variant_Values (the `Field_Value`→string token
// flattening applies only to a TOP-LEVEL blackboard column, not to a field inside
// a Record_Value column). The Variant renders to its "Enum::Case" token via
// variant_to_token; an absent/non-enum column is "".
body_record_token :: proc(rec: Record_Value, name: string) -> string {
	col, present := rec.fields[name]
	if !present {
		return ""
	}
	variant, is_variant := col.(Variant_Value)
	if !is_variant {
		return ""
	}
	return variant_to_token(variant, context.temp_allocator)
}

// body_record_mask reads the §11 §5 `mask: [Layer]` list column into its layer
// tokens. The mask commits as a List_Value of enum tokens (each "Layer::X"); each
// element renders to its token string (a string column verbatim, a Variant_Value
// via variant_to_token). An absent/non-list mask is an empty mask (the body
// collides with nothing).
body_record_mask :: proc(rec: Record_Value) -> []string {
	col, present := rec.fields["mask"]
	if !present {
		return nil
	}
	list, is_list := col.(List_Value)
	if !is_list {
		return nil
	}
	tokens := make([]string, len(list.elements), context.temp_allocator)
	for elem, i in list.elements {
		tokens[i] = value_to_layer_token(elem)
	}
	return tokens
}

// value_to_layer_token renders one mask element to its "Layer::X" token. A mask
// is a `[Layer]` List_Value whose elements are enum Variant_Values (a nested
// list-of-enum column carries Variants, not flattened string tokens); the Variant
// renders to its token via variant_to_token. A non-enum element is "" (never
// matched by mask_contains, so an off-shape element is inert).
value_to_layer_token :: proc(v: Value) -> string {
	variant, is_variant := v.(Variant_Value)
	if !is_variant {
		return ""
	}
	return variant_to_token(variant, context.temp_allocator)
}

// body_record_fixed reads a Fixed scalar column off the Body record (`mass`/
// `friction`), or the supplied default when the field is absent or not a Fixed —
// the §11 §2 declared defaults (mass 1.0, friction 0.5).
body_record_fixed :: proc(rec: Record_Value, name: string, fallback: Fixed) -> Fixed {
	col, present := rec.fields[name]
	if !present {
		return fallback
	}
	f, is_fixed := col.(Fixed)
	if !is_fixed {
		return fallback
	}
	return f
}

// body_record_bool reads a Bool column off the Body record (`sensor`), defaulting
// false (the §11 §2 default — a body is solid unless declared a sensor).
body_record_bool :: proc(rec: Record_Value, name: string) -> bool {
	col, present := rec.fields[name]
	if !present {
		return false
	}
	b, is_bool := col.(bool)
	if !is_bool {
		return false
	}
	return b
}

// body_record_vec2 reads a Vec2 column off the Body record (`impulse`), defaulting
// VEC2_ZERO (the §11 §2 default — no accumulated intent).
body_record_vec2 :: proc(rec: Record_Value, name: string) -> Vec2 {
	col, present := rec.fields[name]
	if !present {
		return VEC2_ZERO
	}
	v, is_vec := col.(Vec2)
	if !is_vec {
		return VEC2_ZERO
	}
	return v
}

// --- Shape-payload and row readers ----------------------------------------

// variant_payload_vec2 reads a Vec2 field off a struct-payload variant's payload
// record (`Shape2::Box{size}` → its `size` Vec2). The payload is a boxed
// Record_Value; an absent/non-Vec2 field reads VEC2_ZERO.
variant_payload_vec2 :: proc(variant: Variant_Value, name: string) -> Vec2 {
	if variant.payload == nil {
		return VEC2_ZERO
	}
	rec, is_record := variant.payload^.(Record_Value)
	if !is_record {
		return VEC2_ZERO
	}
	return body_record_vec2(rec, name)
}

// variant_payload_fixed reads a Fixed field off a struct-payload variant's payload
// record (`Shape2::Circle{radius}` → its `radius` Fixed). An absent/non-Fixed
// field reads zero (a degenerate point radius).
variant_payload_fixed :: proc(variant: Variant_Value, name: string) -> Fixed {
	if variant.payload == nil {
		return Fixed(0)
	}
	rec, is_record := variant.payload^.(Record_Value)
	if !is_record {
		return Fixed(0)
	}
	return body_record_fixed(rec, name, Fixed(0))
}

// row_vec2 reads a Vec2 column directly off a working ROW (the reserved top-level
// `pos`/`vel` fields, NOT a body-record field), defaulting VEC2_ZERO. A Static
// body has no `vel` column, so its vel reads zero — it never integrates anyway.
row_vec2 :: proc(row: Row, name: string) -> Vec2 {
	col, present := row.fields[name]
	if !present {
		return VEC2_ZERO
	}
	v, is_vec := col.(Vec2)
	if !is_vec {
		return VEC2_ZERO
	}
	return v
}

// token_case strips the "Enum::" prefix from an enum token, yielding the bare
// case name a kind/shape switch matches ("BodyKind::Dynamic" → "Dynamic"). A
// token with no "::" is its own case.
token_case :: proc(token: string) -> string {
	for i in 0 ..< len(token) - 1 {
		if token[i] == ':' && token[i + 1] == ':' {
			return token[i + 2:]
		}
	}
	return token
}

// fixed_abs is the absolute value over the saturating kernel: fixed_neg on a
// negative (which saturates FIXED_MIN to FIXED_MAX), the value itself otherwise.
// No float — the magnitude an overlap/penetration test reads.
fixed_abs :: proc(f: Fixed) -> Fixed {
	if f < 0 {
		return fixed_neg(f)
	}
	return f
}
