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

// Draw_Palette is the §20 closed NAMED palette a draw command paints in — the
// nine named members of the spec's render.fun `Color` enum (White..Gray). The
// members are appended in spec order, so the existing five (White=0..Blue=4) keep
// their ordinals — the frame digest folds a named color as that raw ordinal
// (frame_digest.odin write_color), so a golden whose draw-list paints only the
// original five is byte-unchanged by the four-member extension. A new named member
// is a deliberate schema-version bump (§04 closed-enum; FRAME_DIGEST_SCHEMA_VERSION).
// It is `u8`-backed so the digest fold writes one ordinal byte (the closed set
// fits a byte; the Rgb sentinel byte 255 in write_color is reserved and can never
// be a named ordinal).
Draw_Palette :: enum u8 {
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

// Draw_Color_Kind discriminates the two §20 §1 Color forms a draw command can
// carry: a Named palette member or an exact Rgb channel triple (Color::Rgb).
Draw_Color_Kind :: enum u8 {
	Named,
	Rgb,
}

// Draw_Color is the §20 §1 color a draw command paints in — EITHER a named palette
// member OR the spec's `Color::Rgb{r,g,b}` exact-value escape (render.fun:14,
// 0..1 Fixed channels). Before the surface-parity restore the runtime draw-list
// carried only the named palette and a Color::Rgb REFUSED the lowering; the Rgb variant now has
// a first-class slot here so an arbitrary color reaches the frame digest and the
// present pass deterministically. The fields are all simply-comparable (the kind
// enum, the palette enum, three Fixed channels), so every Draw_* command carrying
// a Draw_Color stays `==`-comparable (draw_cmd_equal's Rect/Sprite/Light/Plane
// arms). DETERMINISM: the Rgb channels are raw Q32.32 Fixed off the kernel — no
// float (§10) — and the digest folds them under a reserved sentinel tag, so an
// Rgb color is inside the §20 comparison surface bit-exactly. Extending the color
// taxonomy from a bare enum to this discriminated form is a deliberate
// schema-version bump (§04 closed-enum; FRAME_DIGEST_SCHEMA_VERSION 9→10).
Draw_Color :: struct {
	kind:    Draw_Color_Kind,
	palette: Draw_Palette, // the named member, valid when kind == .Named
	r:       Fixed, // the Rgb red channel (0..1 Fixed), valid when kind == .Rgb
	g:       Fixed, // the Rgb green channel
	b:       Fixed, // the Rgb blue channel
}

// named_color builds a Draw_Color from a closed-palette member — the common case
// every Draw_* color field carried before the Rgb escape existed. r/g/b sit at the
// Fixed zero value (unread when kind == .Named).
named_color :: proc(palette: Draw_Palette) -> Draw_Color {
	return Draw_Color{kind = .Named, palette = palette}
}

// rgb_color builds a Draw_Color from an exact §20 §1 Color::Rgb channel triple
// (0..1 Fixed each). The palette member sits at its zero value (.White, unread when
// kind == .Rgb).
rgb_color :: proc(r, g, b: Fixed) -> Draw_Color {
	return Draw_Color{kind = .Rgb, r = r, g = g, b = b}
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

// Draw_Tilemap is the §18 §3 BATCHED tile-layer command: ONE draw command per
// baked layer carrying the whole committed layer — never per-tile Draw::Sprite
// rows (§18 §3's normative batching). It is ENGINE-EMITTED, not behavior-
// emitted: render_version prepends one Draw_Tilemap per layer of the rendered
// VERSION's tile state (declaration order, beneath every behavior draw) before
// the render behaviors run — the §18 §4 "render updates from the same data"
// clause: a SetTile committed this tick is in this tick's draw-list. The
// carried Tile_Layer's slices alias the version's COW tables (the version
// outlives its projection), so the command is a view, not a copy; the digest
// folds the layer's full content (name, geometry, anchor, palette, cells) so
// the drawn terrain is inside the comparison surface bit-exactly.
//
// `palette_textures` is the v17 RESOLVED tile art: one Tile_Texture per palette
// entry (parallel to layer.palette), bound by resolve_tilemap_textures AFTER the
// engine emits the command — each palette tile's atlas-cell coordinate resolves
// through tile_cell_rect against the layer's atlas to its image hash + pixel rect,
// the same §19 [assets] art a sprite resolves through (the by-coordinate twin of
// the by-name sprite resolution). The render present pass blits a cell's pixels by
// indexing this slice with the cell's palette index; the digest folds it (v9 §19),
// so the resolved terrain art is inside the comparison surface, the same proof the
// sprite seam carries. A nil/empty slice is the pre-resolution shape (the engine
// emits names + coords, the pass binds pixels); an unresolved tile (no atlas, or a
// zero-region atlas) carries resolved=false — the no-texture fallback.
Draw_Tilemap :: struct {
	layer:            Tile_Layer,
	palette_textures: []Tile_Texture, // one resolved §19 texture per palette entry (v17), parallel to layer.palette
}

// Tile_Texture is one palette tile's RESOLVED §19 texture reference — the
// content-addressed image hash and the cell's pixel rect, the `(atlas, cell coord)
// → (image, rect)` resolve_tilemap_textures folds through tile_cell_rect. It is the
// tile twin of Sprite_Texture: `resolved` discriminates a hit (the layer's atlas
// registered, with regions to read the cell dims from) from the fail-closed miss (a
// palette-less layer's empty atlas, or a zero-region atlas) — an unresolved tile
// carries resolved=false with a zero hash/rect, the no-texture fallback the present
// pass paints untextured, never a crash and never a guessed rect. The resolution is
// on the determinism path: the digest folds it (frame digest v9), so a tile
// resolving to a different cell moves the digest — the proof the terrain resolved to
// the correct atlas pixels deterministically.
Tile_Texture :: struct {
	resolved:   bool, // true when the tile's (atlas, cell coord) resolved to a registered grid cell
	image_hash: string, // the §19 §2 content hash of the resolved image (the dedup key)
	px_x:       int, // the cell's pixel rect into the image — the present pass's UV window
	px_y:       int,
	px_w:       int,
	px_h:       int,
}

// Draw_Sprite is the §20 §1 / §18 §1 atlas sprite: a named atlas region drawn as a
// quad at a fixed-point center. It is the per-entity draw command the dungeon's
// draw_hero/draw_slime/draw_chest behaviors emit — distinct from the engine-emitted
// batched Draw_Tilemap (§18 §3 forbids per-tile sprite rows for terrain; a moving
// entity sprite is a behavior-emitted Draw::Sprite). The lowered fields:
//   - `atlas` is the atlas handle's NAME (a string): the digest carries the name and
//     the PRESENT pass resolves the atlas to a texture later (the §19 atlas asset is
//     the assets epic's; the determinism lowering never resolves it, it carries the
//     name as the stable identity);
//   - `cell` is the §18 §1 region key (a String — `"hero"`, `"slime"`, the chest's
//     state cell): the named region the present pass slices from the atlas;
//   - `at` is the CENTER of the sprite extent (§20 §1 anchor) and `size` reaches
//     size/2 out on each axis — both Vec2 off the kernel;
//   - `tint` is the closed §20 palette color (a Draw_Color); `flip` is the §18 §1
//     flip token (a Flip:: variant case name carried verbatim — None/Horizontal/…);
//   - `layer` is the §18 §1 draw-order layer (an Int).
// Every field is folded raw into the digest — the determinism bet is on the lowering;
// the present resolution (atlas → texture, cell → uv, flip → quad orientation) is
// render-boundary-only and never re-enters the sim. A new arm is a deliberate
// schema-version bump (§04 closed-enum; FRAME_DIGEST_SCHEMA_VERSION).
Draw_Sprite :: struct {
	atlas:   string, // the atlas handle NAME — resolved against §19 [assets] by the resolution pass
	cell:    string, // the §18 §1 named region key
	at:      Vec2, // the CENTER of the extent (§20 §1 anchor)
	size:    Vec2, // the extent, reaching size/2 out on each axis
	tint:    Draw_Color, // the closed §20 palette tint
	flip:    string, // the §18 §1 flip token (a Flip:: case name)
	layer:   i64, // the §18 §1 draw-order layer
	texture: Sprite_Texture, // the resolved §19 image hash + pixel rect (resolved=false when unresolved)
}

// Sprite_Texture is a `Draw_Sprite`'s RESOLVED §19 texture reference: the
// content-addressed image hash (the dedup key the present pass loads pixels by) and
// the cell's pixel rect into that image — the `(atlas, cell) → (image, rect)` the
// resolution pass folds through asset_region. `resolved` discriminates a hit from
// the fail-closed miss: an unresolved sprite (the [assets] section registers no
// atlas under the handle name, or no such cell) carries `resolved=false` with a
// zero hash/rect — a deliberate NO-TEXTURE fallback the present pass paints as the
// untextured stand-in, NEVER a crash and never a guessed rect. The resolution is on
// the determinism path: the digest folds this reference (Cmd_Tag.Sprite, frame
// digest v9), so two folds of the same committed sprite resolve to the SAME texture
// bit-identically and a sprite that resolves to a different region (a moved chest
// flipping closed→open) moves the digest. Carrying the resolution into the digest is
// what PROVES the sprite resolved to the correct atlas pixels deterministically,
// rather than deferring the resolution to the impure present boundary.
Sprite_Texture :: struct {
	resolved:   bool, // true when (atlas, cell) resolved to a registered region
	image_hash: string, // the §19 §2 content hash of the resolved image (the dedup key)
	px_x:       int, // the cell's pixel rect into the image — the present pass's UV window
	px_y:       int,
	px_w:       int,
	px_h:       int,
}

// Draw_Cmd is the closed set of §20 draw commands a render behavior emits. A new
// command kind is a schema-version bump (the closed-enum discipline §04, and the
// frame digest folds the draw-list so a new arm bumps FRAME_DIGEST_SCHEMA_VERSION).
// Pong exercises Rect (paddles, ball) and Text (score); yard adds Camera (the 2D
// world↔screen view); krognid adds the four §20 §1 3D commands
// (Draw3_Camera/Light/Plane/Rigged); the dungeon's terrain adds the engine-emitted
// batched Draw_Tilemap (§18 §3) and its entities the behavior-emitted Draw_Sprite
// (§18 §1). New arms are APPENDED after the existing arms; the union is the
// draw-list's element type, mixing 2D and 3D commands in one flattened draw-list (an
// artifact emits one OR the other in practice, but the union admits both).
Draw_Cmd :: union {
	Draw_Rect,
	Draw_Text,
	Draw_Camera,
	Draw3_Camera,
	Draw3_Light,
	Draw3_Plane,
	Draw3_Rigged,
	Draw_Tilemap,
	Draw_Sprite,
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
	case Draw_Tilemap:
		// The batched layer carries slices (palette, cells), so the arm
		// compares structurally — tile_layers_equal walks both element-wise — and
		// the v17 resolved palette_textures compare element-wise too (a
		// Tile_Texture is simply-comparable: the image_hash string by value, the
		// rect ints by value), so two layers resolving the same terrain art are
		// equal and a re-resolved tile is unequal.
		y, ok := b.(Draw_Tilemap)
		if !ok || !tile_layers_equal(x.layer, y.layer) {
			return false
		}
		if len(x.palette_textures) != len(y.palette_textures) {
			return false
		}
		for tex, i in x.palette_textures {
			if tex != y.palette_textures[i] {
				return false
			}
		}
		return true
	case Draw_Sprite:
		// A sprite carries only simply-comparable fields (atlas/cell/flip strings,
		// at/size Vec2 by raw bits, tint ordinal, layer i64), so `==` is total over
		// it — the Rect arm's shape. A single-field diff (a moved `at`, a different
		// `cell`, a flipped `flip`, a re-tinted `tint`, a re-layered `layer`) is
		// unequal; a kind mismatch is unequal.
		y, ok := b.(Draw_Sprite)
		return ok && x == y
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
	// The §18 §3 tile layers lead the draw-list: one BATCHED Draw_Tilemap per
	// layer of the rendered VERSION's committed tile state, in artifact
	// declaration order (deterministic — a slice walk over committed tables),
	// BENEATH every behavior-emitted command (the terrain is the environment
	// entities draw over). Engine-emitted: no render behavior authors these,
	// and never per-tile commands (§18 §3). Reading the version — not the
	// program's pristine bake — is what makes a tick-end SetTile visible to
	// this tick's render and digest (§18 §4).
	for &layer in version.tilemaps {
		append(&cmds, Draw_Tilemap{layer = layer})
	}
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
	resolve_sprite_textures(program, cmds[:])
	resolve_tilemap_textures(program, cmds[:], allocator)
	return Draw_List{cmds = cmds[:]}
}

// resolve_tilemap_textures runs the §17/§19 textured-TILE resolution pass over the
// built draw-list: every Draw_Tilemap's palette resolves through tile_cell_rect
// against the layer's atlas to a parallel `palette_textures` slice — each palette
// tile's atlas-cell coordinate to its content-addressed image hash + pixel rect (the
// by-coordinate twin of resolve_sprite_textures' by-name resolution). It runs ONCE
// per render projection AFTER the engine emits the layers (the lowering carries the
// atlas name + per-tile cell coords; this pass binds the pixels), so the resolved
// terrain art is inside the §20 draw-list the frame digest folds — the determinism
// PROOF that the terrain resolved to the correct atlas cells. Assets are bake-static
// (Program.assets, never the COW version chain), so resolution is a pure function of
// (atlas name, the palette coords, the program's decode): two projections of the
// same committed layer resolve to the SAME textures bit-identically. A miss (a
// palette-less layer with no atlas, or a zero-region atlas with no cell dims) is
// fail-closed per palette entry — resolved stays false, the no-texture fallback —
// never a crash, never a guessed rect. Non-tilemap commands are untouched.
resolve_tilemap_textures :: proc(program: ^Program, cmds: []Draw_Cmd, allocator := context.allocator) {
	for &cmd in cmds {
		tilemap, is_tilemap := &cmd.(Draw_Tilemap)
		if !is_tilemap {
			continue
		}
		// One resolved texture per palette entry (parallel to layer.palette): the
		// present pass blits a cell by indexing this slice with the cell's palette
		// index. An empty palette yields an empty slice (a degenerate layer).
		textures := make([]Tile_Texture, len(tilemap.layer.palette), allocator)
		for tile, i in tilemap.layer.palette {
			image, region, ok := tile_cell_rect(program, tilemap.layer.atlas, tile.cell_x, tile.cell_y)
			if !ok {
				// Fail-closed: no atlas under the layer's name, or an atlas with no
				// regions to read the cell dims from — the no-texture fallback. The
				// tile's coordinate is still carried (in layer.palette); the digest
				// folds resolved=false, a stable deterministic miss.
				textures[i] = Tile_Texture{}
				continue
			}
			textures[i] = Tile_Texture {
				resolved   = true,
				image_hash = image.hash,
				px_x       = region.px_x,
				px_y       = region.px_y,
				px_w       = region.px_w,
				px_h       = region.px_h,
			}
		}
		tilemap.palette_textures = textures
	}
}

// resolve_sprite_textures runs the §19 texture-resolution pass over the built
// draw-list: every Draw_Sprite's (atlas, cell) handle pair resolves through
// asset_region against the program's baked [assets] section to its content-addressed
// image hash and pixel rect, written into the command's Sprite_Texture. It runs ONCE
// per render projection AFTER the behaviors emit their sprites (the lowering carries
// the NAMES; this pass binds the pixels), so the resolved reference is inside the §20
// draw-list the frame digest folds — the determinism PROOF that a sprite resolved to
// the correct atlas region. Assets are bake-static (Program.assets, never the COW
// version chain), so resolution is a pure function of (atlas name, cell name, the
// program's decode): two projections of the same committed sprite resolve to the SAME
// texture bit-identically. A miss (no atlas registered under the handle name, or no
// such cell) is fail-closed — Sprite_Texture.resolved stays false, the no-texture
// fallback — never a crash, never a guessed rect. Non-sprite commands are untouched.
resolve_sprite_textures :: proc(program: ^Program, cmds: []Draw_Cmd) {
	for &cmd in cmds {
		sprite, is_sprite := &cmd.(Draw_Sprite)
		if !is_sprite {
			continue
		}
		image, region, ok := asset_region(program, sprite.atlas, sprite.cell)
		if !ok {
			// Fail-closed: an unresolved sprite keeps the zero Sprite_Texture
			// (resolved=false) — the deliberate no-texture fallback the present pass
			// paints as the untextured stand-in. The handle name is carried verbatim
			// (the digest still folds it), but no atlas/cell answered the resolution.
			sprite.texture = Sprite_Texture{}
			continue
		}
		sprite.texture = Sprite_Texture {
			resolved   = true,
			image_hash = image.hash,
			px_x       = region.px_x,
			px_y       = region.px_y,
			px_w       = region.px_w,
			px_h       = region.px_h,
		}
	}
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
	case "Draw::Sprite":
		// the §20 §1 / §18 §1 atlas sprite: atlas handle NAME + cell key (Strings) +
		// at/size (Vec2, `at` the §20 §1 center) + tint (closed §20 palette) + flip
		// token + layer (Int). Every field is REQUIRED — a missing one, an
		// out-of-palette tint (record_color ok=false), or a malformed atlas/flip
		// REFUSES with ok=false: the documented fail-closed mold drops the command
		// rather than mispainting. The lowering carries the atlas/cell NAMES and
		// leaves Sprite_Texture zero (resolved=false); the post-emit
		// resolve_sprite_textures pass binds the §19 image hash + pixel rect through
		// asset_region, so the resolved reference enters the digest.
		atlas, atlas_ok := record_handle_name(record, "atlas")
		cell, cell_ok := record_text(record, "cell")
		at, at_ok := record_vec2(record, "at")
		size, size_ok := record_vec2(record, "size")
		tint, tint_ok := record_color(record, "tint")
		flip, flip_ok := record_variant_token(record, "flip")
		layer, layer_ok := record_int(record, "layer")
		if !atlas_ok || !cell_ok || !at_ok || !size_ok || !tint_ok || !flip_ok || !layer_ok {
			return nil, false
		}
		return Draw_Sprite {
				atlas = atlas,
				cell = cell,
				at = at,
				size = size,
				tint = tint,
				flip = flip,
				layer = layer,
			},
			true
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

// record_handle_name reads the atlas handle NAME off a Draw::Sprite record's `atlas`
// field — the §18 §1 atlas reference (`assets.dungeon_atlas`). It accepts BOTH shapes
// an atlas reference reaches the lowering as (the eval_mesh_name_arg / SoundHandle
// mold): a typed handle Record_Value carrying one `name` String field (the resolved
// atlas("…") / AtlasHandle{name} value the §19 assets epic will produce), AND a bare
// String_Value (the name carried directly when the asset graph is not yet wired). The
// digest carries the NAME — the present pass resolves the texture later, never the
// determinism path. ok=false when the field is absent or is neither shape
// (fail-closed — the malformed sprite drops rather than painting a guessed atlas).
record_handle_name :: proc(record: Record_Value, name: string) -> (atlas: string, ok: bool) {
	field, present := record.fields[name]
	if !present {
		return "", false
	}
	#partial switch f in field {
	case Record_Value:
		inner, inner_present := f.fields["name"]
		if !inner_present {
			return "", false
		}
		str, is_str := inner.(String_Value)
		if !is_str {
			return "", false
		}
		return str.text, true
	case String_Value:
		return f.text, true
	}
	return "", false
}

// record_variant_token reads a §18 §1 flip token off a Draw::Sprite record's `flip`
// field — the `Flip::None` / `Flip::Horizontal` enum case the present pass orients the
// quad by. It is carried verbatim as its case name (the same token-only form a unit
// variant digests under, variant_to_token); the lowering does not interpret it, only
// folds it. ok=false when the field is absent or not a variant (fail-closed) — distinct
// from record_color (which defaults an absent color to White): a flip has no §20
// default, a malformed flip refuses the command.
record_variant_token :: proc(record: Record_Value, name: string) -> (token: string, ok: bool) {
	field, present := record.fields[name]
	if !present {
		return "", false
	}
	variant, is_variant := field.(Variant_Value)
	if !is_variant {
		return "", false
	}
	return variant.case_name, true
}

// record_int reads an Int (i64) field off a draw-command record — a Draw::Sprite's
// §18 §1 `layer` draw-order key. ok=false when the field is absent or not an i64
// (fail-closed — never a lifted Fixed; the layer is a plain integer §03 ordinal).
record_int :: proc(record: Record_Value, name: string) -> (value: i64, ok: bool) {
	field, present := record.fields[name]
	if !present {
		return 0, false
	}
	v, is_int := field.(i64)
	return v, is_int
}

// record_color reads a draw command's color into a §20 §1 Draw_Color. An ABSENT
// color field defaults to named White — pong paints everything White, so the
// default is the common case and a missing field is the well-formed "no color
// stated" shape. A PRESENT field is EITHER a named palette variant OR the
// `Color::Rgb{r,g,b}` exact-value escape:
//   - a named color is a Variant_Value whose case_name must name one of the nine
//     closed-palette members (the spec render.fun `Color` enum, White..Gray); a
//     recognized name lowers to its named member with ok=true, an unrecognized
//     case_name (a typo, a future palette member) REFUSES with ok=false.
//   - Color::Rgb lands as a struct-payload variant — a Record_Value tagged
//     "Color::Rgb" (eval_record serializes a `Type::Case{…}` variant as a record,
//     interp.odin), so a Record receiver with that type_name reads its r/g/b Fixed
//     channels into an Rgb Draw_Color (the surface-parity restore — before it, a Color::Rgb
//     had no slot and refused). A missing or non-Fixed channel REFUSES (fail-closed
//     — never a partial color the present pass paints garbage from).
// The caller drops a refused command rather than silently mispainting it White (a
// silent White fallback renders e.g. a Gray ground plane White — the closed-palette
// violation this refusal exists to prevent). A present field that is neither a
// recognized variant nor a Color::Rgb record refuses.
record_color :: proc(record: Record_Value, name: string) -> (color: Draw_Color, ok: bool) {
	field, present := record.fields[name]
	if !present {
		return named_color(.White), true
	}
	// The §20 §1 Color::Rgb{r,g,b} exact-value escape: a struct-payload variant
	// serialized as a `record Color::Rgb` node, so it reaches here as a Record_Value
	// keyed by the `::`-joined type name (the same shape draw_command_from_record keys
	// a Draw::Rect off). Read its three 0..1 Fixed channels strictly — a missing or
	// non-Fixed channel is a fail-closed refusal.
	if rgb_record, is_record := field.(Record_Value); is_record && rgb_record.type_name == "Color::Rgb" {
		r, r_ok := record_color_channel(rgb_record, "r")
		g, g_ok := record_color_channel(rgb_record, "g")
		b, b_ok := record_color_channel(rgb_record, "b")
		if !r_ok || !g_ok || !b_ok {
			return named_color(.White), false
		}
		return rgb_color(r, g, b), true
	}
	variant, is_variant := field.(Variant_Value)
	if !is_variant {
		return named_color(.White), false
	}
	switch variant.case_name {
	case "White":
		return named_color(.White), true
	case "Black":
		return named_color(.Black), true
	case "Red":
		return named_color(.Red), true
	case "Green":
		return named_color(.Green), true
	case "Blue":
		return named_color(.Blue), true
	case "Yellow":
		return named_color(.Yellow), true
	case "Cyan":
		return named_color(.Cyan), true
	case "Magenta":
		return named_color(.Magenta), true
	case "Gray":
		return named_color(.Gray), true
	}
	return named_color(.White), false
}

// record_color_channel reads one §20 §1 Color::Rgb channel (r/g/b) strictly — the
// channel must be present AND a Fixed (the 0..1 kernel value the `Color::Rgb{ r:
// Fixed, … }` struct variant carries). ok is false when absent or not a Fixed, so a
// malformed Rgb color refuses the lowering (distinct from record_fixed, which
// defaults an absent scalar to 0 for a partially-built Camera — a color channel has
// no absent-safe default).
record_color_channel :: proc(record: Record_Value, name: string) -> (value: Fixed, ok: bool) {
	field, present := record.fields[name]
	if !present {
		return Fixed(0), false
	}
	v, is_fixed := field.(Fixed)
	return v, is_fixed
}
