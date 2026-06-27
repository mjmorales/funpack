package funpack_runtime

SOLVER_ITERATIONS :: 4

SOLVER_BODY_FIELD :: "body"

SOLVER_POS_FIELD :: "pos"
SOLVER_VEL_FIELD :: "vel"

SOLVER_TRIGGER_SIGNAL :: "Trigger"

Body_Kind :: enum {
	Static,
	Dynamic,
	Kinematic,
}

Solver_Shape_Kind :: enum {
	Unknown,
	Box,
	Circle,
}

Solver_Shape :: struct {
	kind:    Solver_Shape_Kind,
	half:    Vec2,
	radius:  Fixed,
}

Solver_Body :: struct {
	table_idx: int,
	row_idx:   int,
	kind:      Body_Kind,
	shape:     Solver_Shape,
	mass:      Fixed,
	friction:  Fixed,
	sensor:    bool,
	layer:     string,
	mask:      []string,
	pos:       Vec2,
	vel:       Vec2,
	impulse:   Vec2,
}

run_solve :: proc(interp: ^Interp, state: ^Tick_State) {
	dt := solver_dt(interp)
	bodies := gather_bodies(state, interp.allocator)

	for &body in bodies {
		integrate_body(&body, dt)
	}

	for iteration in 0 ..< SOLVER_ITERATIONS {
		resolve_contacts(state, bodies, iteration == 0)
	}

	for body in bodies {
		write_body_back(state, body)
	}
}

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

gather_bodies :: proc(state: ^Tick_State, allocator := context.allocator) -> []Solver_Body {
	bodies := make([dynamic]Solver_Body, allocator)
	for table_idx in 0 ..< len(state.tables) {
		table := &state.tables[table_idx]
		for row_idx in 0 ..< len(table.rows) {
			row := table.rows[row_idx]
			body, is_body := parse_body(row, table_idx, row_idx, allocator)
			if !is_body {
				continue
			}
			append(&bodies, body)
		}
	}
	return bodies[:]
}

parse_body :: proc(row: Row, table_idx, row_idx: int, allocator: Runtime_Allocator) -> (body: Solver_Body, is_body: bool) {
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
	body.kind = parse_body_kind(rec, allocator)
	body.shape = parse_body_shape(rec)
	body.mass = body_record_fixed(rec, "mass", to_fixed(1))
	body.friction = body_record_fixed(rec, "friction", fixed_from_decimal(0, "5"))
	body.sensor = body_record_bool(rec, "sensor")
	body.layer = body_record_token(rec, "layer", allocator)
	body.mask = body_record_mask(rec, allocator)
	body.impulse = body_record_vec2(rec, "impulse")
	body.pos = row_vec2(row, SOLVER_POS_FIELD)
	body.vel = row_vec2(row, SOLVER_VEL_FIELD)
	return body, true
}

integrate_body :: proc(body: ^Solver_Body, dt: Fixed) {
	if body.kind != .Dynamic {
		return
	}
	inv_mass := fixed_div(to_fixed(1), body.mass)
	body.vel = vec2_add(body.vel, vec2_scale(body.impulse, inv_mass))
	body.pos = vec2_add(body.pos, vec2_scale(body.vel, dt))
}

resolve_contacts :: proc(state: ^Tick_State, bodies: []Solver_Body, route_triggers: bool) {
	for i in 0 ..< len(bodies) {
		for j in i + 1 ..< len(bodies) {
			a := &bodies[i]
			b := &bodies[j]
			if !layers_collide(a^, b^) {
				continue
			}
			if !bodies_overlap(a^, b^) {
				continue
			}
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

layers_collide :: proc(a, b: Solver_Body) -> bool {
	return mask_contains(a.mask, b.layer) && mask_contains(b.mask, a.layer)
}

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

resolve_solid_pair :: proc(a, b: ^Solver_Body) {
	a_half := shape_half_extents(a.shape)
	b_half := shape_half_extents(b.shape)
	gap := vec2_sub(a.pos, b.pos)

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

correction_share :: proc(a, b: Solver_Body) -> Fixed {
	a_dynamic := a.kind == .Dynamic
	b_dynamic := b.kind == .Dynamic
	if a_dynamic && b_dynamic {
		return fixed_from_decimal(0, "5")
	}
	return to_fixed(1)
}

friction_cancel :: proc(component, friction: Fixed) -> Fixed {
	retained := fixed_sub(to_fixed(1), friction)
	return fixed_mul(component, retained)
}

route_trigger_pair :: proc(state: ^Tick_State, a, b: Solver_Body) {
	if !a.sensor {
		route_one_trigger(state, a)
	}
	if !b.sensor {
		route_one_trigger(state, b)
	}
}

route_one_trigger :: proc(state: ^Tick_State, body: Solver_Body) {
	trigger := Record_Value{type_name = SOLVER_TRIGGER_SIGNAL, fields = make(map[string]Value, state.allocator)}
	target := state.tables[body.table_idx].rows[body.row_idx].id
	route_instance_signal(state, SOLVER_TRIGGER_SIGNAL, target, trigger)
}

write_body_back :: proc(state: ^Tick_State, body: Solver_Body) {
	table := &state.tables[body.table_idx]
	row := &table.rows[body.row_idx]

	commit := state.commit_allocator
	next := make(map[string]Field_Value, len(row.fields), commit)
	for k, v in row.fields {
		next[k] = own_committed_column(v, commit)
	}

	if body.kind == .Dynamic {
		next[SOLVER_POS_FIELD] = body.pos
		next[SOLVER_VEL_FIELD] = body.vel
	}

	if body_col, has_body := row.fields[SOLVER_BODY_FIELD]; has_body {
		if rec, is_record := body_col.(Record_Value); is_record {
			if carried, present := next[SOLVER_BODY_FIELD]; present {
				free_field_value(carried, commit)
			}
			zeroed := clone_record_value(rec, commit)
			if _, has_impulse := zeroed.fields["impulse"]; has_impulse {
				zeroed.fields["impulse"] = VEC2_ZERO
			}
			next[SOLVER_BODY_FIELD] = zeroed
		}
	}

	if row.fields != nil {
		append(&state.superseded, row.fields)
	}
	row.fields = next
}

parse_body_kind :: proc(rec: Record_Value, allocator: Runtime_Allocator) -> Body_Kind {
	token := body_record_token(rec, "kind", allocator)
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
		half := vec2_scale(size, fixed_from_decimal(0, "5"))
		return Solver_Shape{kind = .Box, half = half}
	case "Circle":
		radius := variant_payload_fixed(variant, "radius")
		return Solver_Shape{kind = .Circle, radius = radius}
	}
	return Solver_Shape{kind = .Unknown}
}

body_record_token :: proc(rec: Record_Value, name: string, allocator: Runtime_Allocator) -> string {
	col, present := rec.fields[name]
	if !present {
		return ""
	}
	variant, is_variant := col.(Variant_Value)
	if !is_variant {
		return ""
	}
	return variant_to_token(variant, allocator)
}

body_record_mask :: proc(rec: Record_Value, allocator: Runtime_Allocator) -> []string {
	col, present := rec.fields["mask"]
	if !present {
		return nil
	}
	list, is_list := col.(List_Value)
	if !is_list {
		return nil
	}
	tokens := make([]string, len(list.elements), allocator)
	for elem, i in list.elements {
		tokens[i] = value_to_layer_token(elem, allocator)
	}
	return tokens
}

value_to_layer_token :: proc(v: Value, allocator: Runtime_Allocator) -> string {
	variant, is_variant := v.(Variant_Value)
	if !is_variant {
		return ""
	}
	return variant_to_token(variant, allocator)
}

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

token_case :: proc(token: string) -> string {
	for i in 0 ..< len(token) - 1 {
		if token[i] == ':' && token[i + 1] == ':' {
			return token[i + 2:]
		}
	}
	return token
}
