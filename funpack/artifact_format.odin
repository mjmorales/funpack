// The artifact-format primitive encoders and the golden-fixture seam.
// This is the funpack side of the spec-§29 process-boundary data contract
// with the runtime: a versioned byte format whose layout is written in
// docs/artifact-format.md and whose pong instance is committed at
// testdata/pong.artifact. The runtime (Odin, runtime/**) parses those
// bytes from the doc alone with ZERO funpack imports; this file owns only
// the funpack-side encoders the production emitter reuses, so the
// encoding rules are executable and the byte-identical-twice obligation is
// provable here under `odin test`.
//
// The format is deterministic by construction (spec §09, §29): no clock,
// no machine paths, no float. Every Fixed is its raw Q32.32 i64 bits in
// decimal — the same kernel representation as fixed.odin — so emission and
// load are exact and identical on every machine.
package funpack

import "core:strconv"
import "core:strings"

// ARTIFACT_SCHEMA_VERSION is the leading stamp every artifact carries
// (docs/artifact-format.md §1). Any field/layout/encoding change bumps it;
// a runtime exact-matches it and refuses a mismatch rather than
// best-effort parsing. It is the single compatibility gate.
//
// Version 2 ratifies two §2.7 body-node arm KINDs the snake/hunt goldens first
// emit: `bare_binder` (a tuple position binding the whole element — snake's
// `next` Rng position) and `tuple` (a positional tuple pattern, e.g.
// `(Option::Some(cell), next)`). The closed node-kind set gains the `tuple` arm,
// and — the layout-changing part — a `tuple` arm carries its positional
// sub-pattern arms as CHILDREN, so its line ends in a child count read the
// generic way, unlike every other arm whose child count is fixed at 0 by kind.
// A new arm kind and an arm-with-children are both layout changes, so the
// version bumps from 1 to 2 (it is the single compatibility gate, §1).
//
// Version 3 ratifies the closed §14 binding source-form set the emitter lowers
// the §23 §3 builder helpers into: a key-list button source spreads to one
// `key(…)` bind per listed key (stacking, §23 §3), `wasd()` lowers to the 2D
// `keys_quad(neg_x,pos_x,neg_y,pos_y)` form, and `stick(Stick)` is a
// first-class 2D source the runtime folds as both components — never spread
// into stick_x/stick_y 1D halves. The source vocabulary is a closed taxonomy,
// so growing it is a deliberate bump from 2 to 3 (§1; ADR
// 2026-06-06-binding-source-lowering-2d-quad-and-stick).
//
// Version 4 adds the required `logical:WxH` field to the §15 entrypoint record
// — the fixed logical draw space (§20 §3) in integer world units, lifted from
// the entrypoint block's `logical = WxH` (§14 §4) so the present pass
// letterboxes from the artifact instead of a hardcoded board constant. A
// required field on an existing record is a layout change: 3 → 4 (§1; ADR
// 2026-06-06-logical-space-entrypoint-field).
//
// Version 5 is the yard cross-epic format the §11 physics, §20 camera, and §24
// persistence surfaces first reach. Four layout changes ride it: (1) the §06 §2
// SINGLETON tick-0 spawn marker — a `singleton`'s [things] row carries SINGLETON
// true plus its COMPLETE defaulted field schema, so the runtime spawns the
// singleton population (Scoreboard/Camera/Menu) from the artifact alone; (2) the
// §11 §3 PHYSICS-STAGE encoding — the engine-closed `physics: solve` battery
// occupies a [pipeline_flattened] step (`stage:physics behavior:solve`), a battery
// step distinct from a behavior step, recording the engine boundary in the total
// order (intent before, reactions after); (3) the §03 §4 CollisionLayer KIND tag —
// an `enum Layer: CollisionLayer` [enums] record stamps the `CollisionLayer` role
// kind; (4) the §6 ENGINE-TYPE field defaults — Option[String] singleton defaults
// (`status: Option[String] = Option::None`), and engine-type composite defaults
// (a Settings static-builder default `Settings.defaults()` lowered to its evaluated
// `Settings(volume=128,fullscreen=false,access=AccessOpts(reduce_motion=false))`
// record inline, against a synthesized §8 Settings + AccessOpts data projection —
// the nested `access` sub-record yard reads back). A marker row, a new flattened-step
// occupant kind, an enum KIND value, and widened §6/§8 default forms are layout
// changes: 4 → 5 (§1).
//
// Version 6 is the krognid MULTI-MODULE format: the first artifact the runtime
// executes whose [functions] section carries fn records from MORE than the
// entrypoint module. The single layout change is the §17 CROSS-MODULE SEAM-FN
// CARRY — when the entrypoint module (krognid's `stroll`) imports a fn from a
// sibling USER module (`import krognid.{krognid_skeleton, krognid_parts}` from the
// baked rig seam), the emitter appends that imported fn's full record — signature,
// body node run, and a span keyed to the SEAM module (`span:krognid:8`) — into
// [functions] after the entrypoint module's own records, so the Rigged draw body's
// `krognid_skeleton()` / `krognid_parts()` calls resolve to a self-contained record
// the runtime's bare-name program_function lookup finds (the seam bodies would
// otherwise be absent and the call would return nil). The carried records keep
// their BARE names — the artifact disambiguates by the span's module, not a §15
// qualifier, because the runtime resolves functions by bare name (the §15
// qualification ADR governs the SEPARATE Index Contract decl surface, not the
// artifact [functions] name token). NO new §2.7 node KIND rides this bump: the seam
// bodies (`Skeleton.humanoid()`, a `.bind(Slot::…, mesh(…))` builder chain ending in
// `.mirror(Side::L, Side::R)`) and the entrypoint's first §05/§20 anim/Draw3 forms
// (`Draw3::Rigged{…}`, `Pose.blend(…)`, the `Audio.track(…).pitch(…)` chain) all
// serialize through the existing call/field/variant/record/list/string node arms —
// the body walk was already generic over them. A widened [functions] population
// (records from imported modules) is a layout change: 5 → 6 (§1).
//
// Version 7 carries the §05 §2 TYPED HOLE through to the runtime — the dev
// artifact of a holed declaration was hole-blind before this (a holed fn or
// behavior emitted an empty body and ticked as a no-op live, silently dropping
// the P8 "the game stays playable" fallback approximation that already ran in
// the compiler's test interpreter, evaluate.odin eval_stub_hole). The single
// layout change is one new §2.7 body-node KIND, `stub`, standing as a holed
// body's sole statement subtree (body_count 1) exactly where the grammar puts
// the hole (fun.ebnf §7: FnBody ::= Block | StubExpr): `node stub fallback 1`
// carries the @stub(T, fallback) approximation expression as its one child, and
// `node stub bare 0` is the typecheck-only @stub(T) the runtime FAILS CLOSED on
// (the spec's defined no-value outcome — never undefined behavior). The hole's
// T is NOT carried: the typechecker proves T identical to the record's declared
// return type, so `return:TYPE` already states it. The node-kind set is closed,
// so the new kind is a deliberate bump: 6 → 7 (§1). A release artifact never
// carries a `stub` node — the §29 §4 hole-ban refuses the tree before emission.
//
// Version 8 carries the §05 §6 @migrate SCHEMA-EVOLUTION channel through to the
// loader — the rename/retype metadata the name-keyed schema-diff (spec §09 §4,
// §24) cannot derive on its own. The single layout change is one new sub-record
// keyword, `migrate`, a fixed three-token line `migrate FROM WITH` appearing in
// [data] records only: after a `field` line it migrates that field (FROM the
// prior key or `-`, WITH the pure conversion fn's name or `-`, never both `-`),
// and between the `data` lead line and the first `field` line it is the renamed
// TYPE declaration's prior name (rename form only, so WITH is always `-`
// there). The line is emitted only where the source carries the directive, so
// an artifact of a migration-free source changes by the version stamp alone —
// the v7 stamp-only restamp precedent. The conversion fn is an ordinary
// [functions] record the loader resolves by name. The sub-record keyword set
// is closed, so the new keyword is a deliberate bump: 7 → 8 (§1).
//
// Version 9 carries the §08 §3 STATE-QUERY declarations through to the runtime —
// the first-class `query` declarations and their §05 §3 @index/@spatial index
// requirements, which the runtime needs to MAINTAIN the declared engine indices
// over the world database (an artifact-blind runtime could neither build the
// declared structures nor evaluate a query call). Two layout changes ride it:
// (1) one new section, `[queries Q]`, appended after [entrypoint] — one record
// per entrypoint-module `query` declaration in source order, the [functions]
// record mold (`query NAME param_count return:TYPE index_count body_count
// span:MODULE:LINE`, then the `param` lines, the `index` requirement lines, and
// the §2.7 body node run); (2) one new sub-record keyword, `index`, a fixed
// four-token line `index KIND THING FIELD` (KIND ∈ index|spatial) carrying one
// declared §05 §3 requirement. A query body is a Block by grammar (no
// body-position hole), so its body run is the plain statement forest. A new
// section and a new sub-record keyword are layout changes: 8 → 9 (§1).
//
// v10 ratifies the §08 §3 world read `all[T]` as a §2.7 node KIND: `node all
// THING 0` — a leaf carrying the read table's thing type name, the form a
// spec-true query body reads the world through (value parameters only; the
// View-parameter interim shape is retired by the same bump). A new node KIND
// is a layout change: 9 → 10 (§1).
//
// Version 11 carries the §18 §3 TILE LAYERS through to the runtime — the
// static environment a tilemap's ASCII grid bakes to, which the runtime
// renders BATCHED and collides against (never per-tile Draw::Sprite, §18 §3)
// and which an artifact-blind runtime could neither draw nor collide. Two
// layout changes ride it: (1) one new section, `[tilemaps T]`, appended after
// [queries] — one record per baked layer in level declaration order: a lead
// line `tilemap NAME CELL_SIZE COLS ROWS PALETTE_COUNT`, then PALETTE_COUNT
// `tile NAME SOLID` palette lines (the layer's legend-declared tile types in
// legend order, each carrying its §18 §2 baked collision verdict), then ROWS
// `row …` lines of COLS space-separated cells — a decimal palette index or
// `-` for a tile-less cell (an `empty` legend bind or a marker cell). Markers
// are NOT in this section: they lower to the spawn machinery like every
// placement. (2) two new closed sub-record keywords, `tile` and `row`. A new
// section and new sub-record keywords are layout changes: 10 → 11 (§1).
ARTIFACT_SCHEMA_VERSION :: 11

// ARTIFACT_MAGIC is the first token of line 1, before the version integer:
// `funpack-artifact <version>` (e.g. `funpack-artifact 2`). A parser asserts the
// magic and the version before reading any payload.
ARTIFACT_MAGIC :: "funpack-artifact"

// encode_int writes a funpack Int (64-bit signed saturating, §10) as plain
// decimal: a leading `-` for negatives, no leading zeros, no `+`, no
// separators (docs/artifact-format.md §2.2). The encoding is a pure
// function of the value, so it is byte-identical across emissions.
encode_int :: proc(value: i64, allocator := context.allocator) -> string {
	buf: [32]byte
	return strings.clone(strconv.write_int(buf[:], value, 10), allocator)
}

// encode_fixed writes a Fixed as its raw Q32.32 i64 bits in decimal
// (docs/artifact-format.md §2.3) — value*2^32, the exact integer the
// fixed-point lowering produced. There is no decimal-point round-trip, so
// the bits are bit-identical on every machine; the runtime divides by 2^32
// in its own fixed representation to recover the logical value.
encode_fixed :: proc(value: Fixed, allocator := context.allocator) -> string {
	return encode_int(i64(value), allocator)
}

// encode_string writes a length-prefixed string field `Lbyte_count:raw`
// (docs/artifact-format.md §2.4). The byte count is the UTF-8 length; the
// raw bytes follow the colon verbatim, so a value containing a space or
// newline never breaks the line-oriented frame and a parser consumes
// exactly byte_count bytes without scanning for a delimiter.
encode_string :: proc(value: string, allocator := context.allocator) -> string {
	b := strings.builder_make(allocator)
	strings.write_byte(&b, 'L')
	strings.write_int(&b, len(value))
	strings.write_byte(&b, ':')
	strings.write_string(&b, value)
	return strings.to_string(b)
}

// encode_bool writes the lowercase token `true`/`false`
// (docs/artifact-format.md §2.5).
encode_bool :: proc(value: bool) -> string {
	return "true" if value else "false"
}

// SUB_RECORD_KEYWORDS is the closed set of keywords that begin a
// SUB-record — a line that belongs to the preceding top-level record rather
// than starting a new one (docs/artifact-format.md §2.1). A top-level
// record (`enum`, `thing`, `behavior`, …) may be followed by a
// variable-length run of these; the section's declared count is the number
// of top-level records, so a reader separates the two by this set. Closed
// and format-fixed: a new sub-record kind is a schema-version bump.
@(rodata)
SUB_RECORD_KEYWORDS := []string{
	"variant", // an enum's variant (§5)
	"field", // a data/signal/thing field (§6-§8)
	"gtag", // a thing's/behavior's registered tag (§8, §10)
	"param", // a function's/behavior-step's parameter (§9, §10)
	"emit", // a behavior-step's return-side emission (§10)
	"producer", // a signal route's producer (§12)
	"consumer", // a signal route's consumer (§12)
	"set", // a setup spawn's supplied field (§13)
	"node", // a body checked-AST node line (§2.7) — every fn/step/const/bindings/setup body is a run of these
	"migrate", // a [data] record's §05 §6 rename/retype carry (§6, schema v8) — after a `field` line for that field, before any `field` line for the renamed type
	"index", // a [queries] record's §05 §3 @index/@spatial requirement `index KIND THING FIELD` (§16, schema v9)
	"tile", // a [tilemaps] record's palette entry `tile NAME SOLID` (§17, schema v11)
	"row", // a [tilemaps] record's row-major cell line `row …` (§17, schema v11)
}

// Artifact_Section is one parsed `[name N]` block from an artifact: the
// section name, its declared TOP-LEVEL record count, and every body line up
// to the next section header. A section's records are variable-length — a
// top-level record (e.g. `enum Side - 2`) is followed by its own count of
// sub-records (its `variant` lines) — so the body holds both; `count` is the
// top-level total, and section_lead_count separates lead lines from sub
// lines via SUB_RECORD_KEYWORDS (docs/artifact-format.md §2.1).
Artifact_Section :: struct {
	name:  string,
	count: int,
	body:  []string,
}

// Artifact_Doc is a parsed artifact: the schema version from line 1 and the
// ordered sections (docs/artifact-format.md §3). It is the funpack-side
// reader used to verify the committed golden fixture is well-formed against
// the written layout; the runtime carries its own zero-import parser.
Artifact_Doc :: struct {
	schema_version: int,
	sections:       []Artifact_Section,
}

Artifact_Parse_Error :: enum {
	None,
	Bad_Magic,
	Bad_Version,
	Bad_Section_Header,
	Count_Mismatch, // a section's declared count != its top-level record count
}

// parse_artifact reads an artifact's bytes into the ordered section model,
// validating the §1 stamp and every section's declared top-level count
// against the lead records that follow. It mirrors the runtime's §17
// parsing recipe (read line 1, then each `[name N]` header and its records)
// so the golden fixture is checked against the same count-driven discipline
// the runtime relies on. A section body runs to the next `[` header — the
// only line class that opens with `[` — so variable-length records inside a
// section are unambiguous. It is pure over the input bytes.
parse_artifact :: proc(content: string) -> (doc: Artifact_Doc, err: Artifact_Parse_Error) {
	lines := split_artifact_lines(content)
	if len(lines) == 0 {
		return Artifact_Doc{}, .Bad_Magic
	}
	magic, version, header_ok := parse_version_stamp(lines[0])
	if !header_ok || magic != ARTIFACT_MAGIC {
		return Artifact_Doc{}, .Bad_Magic
	}
	if version < 0 {
		return Artifact_Doc{}, .Bad_Version
	}
	sections := make([dynamic]Artifact_Section, 0, 12, context.temp_allocator)
	i := 1
	for i < len(lines) {
		name, count, ok := parse_section_header(lines[i])
		if !ok {
			return Artifact_Doc{}, .Bad_Section_Header
		}
		i += 1
		body_start := i
		for i < len(lines) && !is_section_header_line(lines[i]) {
			i += 1
		}
		section := Artifact_Section{name = name, count = count, body = lines[body_start:i]}
		if section_lead_count(section) != count {
			return Artifact_Doc{}, .Count_Mismatch
		}
		append(&sections, section)
	}
	return Artifact_Doc{schema_version = version, sections = sections[:]}, .None
}

// is_section_header_line reports whether a line opens a `[name N]` section
// header. Only headers begin with `[`, so this is the section delimiter.
is_section_header_line :: proc(line: string) -> bool {
	return len(line) > 0 && line[0] == '['
}

// section_lead_count counts a section's top-level records: body lines whose
// leading keyword is NOT in SUB_RECORD_KEYWORDS. A top-level record opens a
// new entry (an `enum`, `thing`, `behavior`, …); a sub-record continues the
// previous one (its `variant`/`field`/`param`/… lines). This is how the
// declared count and the body reconcile for variable-length records.
section_lead_count :: proc(section: Artifact_Section) -> int {
	lead := 0
	for line in section.body {
		if !is_sub_record_line(line) {
			lead += 1
		}
	}
	return lead
}

// is_sub_record_line reports whether a body line's leading keyword is a
// sub-record kind (SUB_RECORD_KEYWORDS). The keyword is the token up to the
// first space (or the whole line when there is none).
is_sub_record_line :: proc(line: string) -> bool {
	keyword := line
	if space := strings.index_byte(line, ' '); space >= 0 {
		keyword = line[:space]
	}
	for sub in SUB_RECORD_KEYWORDS {
		if keyword == sub {
			return true
		}
	}
	return false
}

// split_artifact_lines splits on the single LF the format mandates and
// drops the trailing empty element from the final terminator, so a file
// ending in exactly one `\n` yields one element per record line (no phantom
// empty line). It does not strip interior content — a length-prefixed
// string's bytes are inside a single line by construction.
split_artifact_lines :: proc(content: string) -> []string {
	trimmed := strings.trim_suffix(content, "\n")
	if trimmed == "" {
		return nil
	}
	return strings.split(trimmed, "\n", context.temp_allocator)
}

// parse_version_stamp splits line 1 into its magic token and integer
// version: `funpack-artifact <version>`. ok is false on a missing space or a
// non-integer version, which the caller maps to Bad_Magic/Bad_Version.
parse_version_stamp :: proc(line: string) -> (magic: string, version: int, ok: bool) {
	space := strings.index_byte(line, ' ')
	if space < 0 {
		return "", -1, false
	}
	version, ok = strconv.parse_int(line[space + 1:])
	return line[:space], version, ok
}

// parse_section_header parses `[name N]` into the section name and its
// record count. ok is false on a malformed bracket or a non-integer count.
parse_section_header :: proc(line: string) -> (name: string, count: int, ok: bool) {
	if len(line) < 3 || line[0] != '[' || line[len(line) - 1] != ']' {
		return "", 0, false
	}
	inner := line[1:len(line) - 1]
	space := strings.index_byte(inner, ' ')
	if space < 0 {
		return "", 0, false
	}
	count, ok = strconv.parse_int(inner[space + 1:])
	return inner[:space], count, ok
}

// artifact_find_section returns the first section with the given name, or
// found = false. The format fixes section order (docs/artifact-format.md
// §3), so a lookup by name is a convenience for verification, not the
// runtime's path — the runtime reads sections positionally.
artifact_find_section :: proc(doc: Artifact_Doc, name: string) -> (section: Artifact_Section, found: bool) {
	for candidate in doc.sections {
		if candidate.name == name {
			return candidate, true
		}
	}
	return Artifact_Section{}, false
}

// NODE_LINE_KEYWORD is the lead token of every body line (§2.7). A body is a
// pre-order run of these — one checked-AST node per line, each declaring how
// many of the immediately-following lines are its children.
NODE_LINE_KEYWORD :: "node"

// ARM_NODE_KIND is the node kind whose child count is governed by its arm
// PATTERN kind, not the generic trailing-token rule (§2.7). A scalar-pattern arm
// (`wildcard`/`bare_variant`/`variant_binds`/`bare_binder`) ends in its
// variable-length `binders` list and carries 0 children; a `tuple` arm
// (schema v2) instead carries its positional sub-pattern arms as children and
// ends in a trailing child count read the generic way.
ARM_NODE_KIND :: "arm"

// ARM_TUPLE_PATTERN is the one arm pattern kind that carries children: a `tuple`
// arm's positional sub-pattern arms (e.g. `(Option::Some(cell), next)` over its
// two sub-arms). Its line is `node arm tuple <child_count>`, so the count is the
// trailing token — unlike every scalar arm pattern, whose child count is fixed at
// 0 (§2.7, schema v2).
ARM_TUPLE_PATTERN :: "tuple"

// node_line_kind returns a body node line's KIND token — the second
// space-separated field after the `node` keyword (`node KIND field… count`).
// ok is false when the line is not a `node …` line or carries no kind.
node_line_kind :: proc(line: string) -> (kind: string, ok: bool) {
	prefix := NODE_LINE_KEYWORD + " "
	if !strings.has_prefix(line, prefix) {
		return "", false
	}
	tail := line[len(prefix):]
	if end := strings.index_byte(tail, ' '); end >= 0 {
		return tail[:end], true
	}
	return tail, true
}

// node_child_count returns a body node line's declared child count: the
// trailing decimal token (§2.7). An `arm` line is special: a scalar-pattern arm
// is fixed at 0 by its kind (its trailing field is the binder list), while a
// `tuple` arm (schema v2) carries its positional sub-pattern arms as children, so
// its trailing token IS the child count read the generic way. ok is false on a
// malformed line or a non-integer trailing token.
node_child_count :: proc(line: string) -> (count: int, ok: bool) {
	kind, kind_ok := node_line_kind(line)
	if !kind_ok {
		return 0, false
	}
	if kind == ARM_NODE_KIND {
		// A `tuple` arm carries children (the trailing count); every other arm
		// pattern is fixed at 0 (its trailing field is the binder list).
		if arm_pattern_kind(line) == ARM_TUPLE_PATTERN {
			space := strings.last_index_byte(line, ' ')
			if space < 0 {
				return 0, false
			}
			return strconv.parse_int(line[space + 1:])
		}
		return 0, true
	}
	space := strings.last_index_byte(line, ' ')
	if space < 0 {
		return 0, false
	}
	return strconv.parse_int(line[space + 1:])
}

// arm_pattern_kind returns an `arm` line's pattern-kind token — the field after
// the `node arm ` prefix (`wildcard`/`bare_variant`/`variant_binds`/`bare_binder`
// /`tuple`, §2.7). It is the empty string for a non-arm line or an arm with no
// pattern token; the caller distinguishes a `tuple` arm (children) from every
// other arm pattern (0 children) through this.
arm_pattern_kind :: proc(line: string) -> string {
	prefix := NODE_LINE_KEYWORD + " " + ARM_NODE_KIND + " "
	if !strings.has_prefix(line, prefix) {
		return ""
	}
	tail := line[len(prefix):]
	if end := strings.index_byte(tail, ' '); end >= 0 {
		return tail[:end]
	}
	return tail
}

// consume_node_subtree consumes one pre-order checked-AST subtree from a body
// node-line slice starting at index `start`: the node line, then recursively
// its declared `child_count` children (§2.7). It returns the index one past
// the subtree, or ok = false on a malformed node or a child run that overruns
// the slice. This is the runtime's count-driven body reader, expressed on the
// funpack side so the golden fixture's bodies are checked under `odin test`.
consume_node_subtree :: proc(nodes: []string, start: int) -> (next: int, ok: bool) {
	if start >= len(nodes) {
		return start, false
	}
	child_count, count_ok := node_child_count(nodes[start])
	if !count_ok {
		return start, false
	}
	i := start + 1
	for _ in 0 ..< child_count {
		i, ok = consume_node_subtree(nodes, i)
		if !ok {
			return i, false
		}
	}
	return i, true
}

// body_forest_is_well_formed reports whether a body's node-line slice is
// exactly `statement_count` back-to-back pre-order subtrees with no leftover
// lines (§2.7): the `body_count` a `function`/`behavior` record declares must
// account for every body `node` line and no more. A leftover line or an
// overrun is an under-/over-shaped body — the same exact-match discipline
// section counts enforce (§29).
body_forest_is_well_formed :: proc(nodes: []string, statement_count: int) -> bool {
	i := 0
	for _ in 0 ..< statement_count {
		next, ok := consume_node_subtree(nodes, i)
		if !ok {
			return false
		}
		i = next
	}
	return i == len(nodes)
}
