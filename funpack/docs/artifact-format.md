# funpack artifact format — v10

This document is the **process-boundary data contract** between `funpack` (the
pure `source → artifact` compiler) and the **runtime** (the impure native
executor, Odin, `runtime/**`). It is the spec-§29 Unix seam: a versioned byte
format plus a written layout, **not** a library link. A runtime parses the bytes
from *this document alone*, with **zero `funpack` imports** — nothing in
`funpack/**` is on the runtime's include path.

The artifact is the **serialized checked AST** of one game. Spec §09 §1 makes the
on-disk spelling (checked-AST vs. bytecode) an implementation detail of the
interpreter's canonical semantics; the checked AST is the cheapest loadable form,
so that is what this format carries. The runtime interprets it; this format does
not encode evaluation order beyond the pipeline's total order.

A golden fixture conforming to this v1 layout lives at
[`../testdata/pong.artifact`](../testdata/pong.artifact). The production emitter
(a later story) must reproduce that fixture **byte-for-byte** from
`examples/pong/`.

---

## 1. Versioning rule — exact match, no best-effort

The first line of every artifact is the schema stamp:

```
funpack-artifact 10
```

- `schema_version` is the integer after the space (here `10`).
- **Any** change to a section, field, ordering, or encoding **bumps the version**
  — there are no optional fields and no minor/compatible tier.
- **Version history.** v1 was the initial gameplay-golden format (the pong
  surface). v2 ratifies two §2.7 body-node arm KINDs the snake/hunt goldens
  introduce: `bare_binder` (a tuple position binding the whole element) and
  `tuple` (a positional tuple pattern). The `tuple` arm is the one arm kind that
  carries children — its positional sub-pattern arms — so it ends in a trailing
  `child_count`, unlike every other arm whose child count is fixed at 0 by kind.
  A new arm kind and an arm-with-children are both layout changes, so the version
  bumped 1 → 2. v3 ratifies the closed §14 binding SOURCE-form set: the emitter
  lowers every §23 §3 builder helper into it (a key-list button source spreads
  to one `key(…)` bind per key; `wasd()` lowers to the 2D
  `keys_quad(neg_x,pos_x,neg_y,pos_y)` form; `stick(Stick)` is a first-class 2D
  source). The source vocabulary is a closed taxonomy, so growing it bumped
  2 → 3. v4 adds the required `logical:WxH` field to the §15 entrypoint record
  — the fixed logical draw space (§20 §3) in integer world units, declared in
  the entrypoint block (§14 §4) — so the present pass letterboxes from the
  artifact instead of a hardcoded board constant. A required field on an
  existing record is a layout change: 3 → 4. v5 is the **yard cross-epic
  format** the §11 physics, §20 camera, and §24 persistence surfaces first
  reach. Four layout changes ride it: (a) the **§06 §2 singleton tick-0 spawn
  marker** — a `singleton`'s [things] row carries `SINGLETON true` plus its
  COMPLETE defaulted field schema, so the runtime spawns the singleton
  population (yard's Scoreboard/Camera/Menu) once before tick 0 from the artifact
  alone, accessed by type (§8); (b) the **§11 §3 physics-stage encoding** — the
  engine-closed `physics: solve` battery occupies a [pipeline_flattened] step
  (`stage:physics behavior:solve`), a battery step distinct from a behavior step,
  recording the engine boundary in the total order (§11); (c) the **§03 §4
  CollisionLayer enum KIND tag** — an `enum Layer: CollisionLayer` [enums] record
  stamps the `CollisionLayer` role kind (§5); (d) the **§6 engine-type field
  defaults** — an `Option[String]` singleton default (`status: Option[String] =
  Option::None`, an enum-variant token) and engine-type composite defaults (a
  Settings static-builder default `Settings.defaults()` lowered to its evaluated
  `Settings(volume=128,fullscreen=false)` record inline, decoded against a
  synthesized §8 Settings data projection, and a Body's inline composite default
  with its `impulse: Vec2 = zero` / `mass: Fixed = 1.0` field defaults applied).
  A marker row, a new flattened-step occupant kind, an enum KIND value, and
  widened §6/§8 default forms are each a layout change: 4 → 5. v6 is the **krognid
  multi-module format** — the first artifact the runtime executes whose
  [functions] section carries fn records from more than the entrypoint module. The
  single layout change is the **§17 cross-module seam-fn carry**: when the
  entrypoint module imports a fn from a sibling USER module (krognid's `stroll`
  imports `krognid_skeleton` / `krognid_parts` from the baked rig seam), the
  emitter appends that imported fn's full record — signature, body node run, and a
  span keyed to the SEAM module (`span:krognid:8`) — into [functions] after the
  entrypoint module's own records, so the Rigged draw body's `krognid_skeleton()` /
  `krognid_parts()` calls resolve to a self-contained record the runtime finds by
  bare name (the seam bodies would otherwise be absent and the call would return
  nil). The carried records keep their BARE names — the artifact disambiguates by
  the span's module, not a §15 qualifier, because the runtime resolves functions by
  bare name (the §15-qualification rule governs the SEPARATE Index Contract decl
  surface, not the artifact [functions] name token). NO new §2.7 node KIND rides
  this bump: the seam bodies and the entrypoint's first anim/Draw3 forms serialize
  through the existing call/field/variant/record/list/string node arms. A widened
  [functions] population is a layout change: 5 → 6. v7 carries the **§05 §2 typed
  hole** through to the runtime. A dev artifact of a holed declaration was
  hole-blind before this: a `@stub(T, fallback)` fn or behavior emitted an empty
  body and ticked as a no-op live, silently dropping the fallback approximation
  the compiler's test interpreter already runs (P8 — "the game stays playable").
  The single layout change is one new §2.7 node KIND, `stub`, standing as a holed
  body's **sole statement subtree** (`body_count` 1), exactly where the grammar
  puts the hole (`FnBody ::= Block | StubExpr`): `node stub fallback 1` carries
  the fallback approximation expression as its one child, and `node stub bare 0`
  is the typecheck-only `@stub(T)` the runtime **fails closed** on (the spec's
  defined no-value outcome — never undefined behavior). The hole's `T` is not
  carried: the typechecker proves it identical to the record's declared
  `return:TYPE`. The node-kind set is closed, so the new kind is a deliberate
  bump: 6 → 7. A **release** artifact never carries a `stub` node — the §29 §4
  hole-ban refuses the tree before emission, so the node is a dev-artifact form
  only. v8 carries the **§05 §6 `@migrate` schema-evolution channel** through to
  the loader — the rename/retype metadata the name-keyed schema-diff (§09 §4,
  §24) cannot derive on its own (rename and retype are the two structural breaks
  it cannot auto-resolve, so without the carry a restore or hot-reload under a
  renamed/retyped field could only refuse). The single layout change is one new
  **sub-record keyword**, `migrate` — a fixed three-token line `migrate FROM
  WITH` appearing in `[data]` records only (§6): following a `field` line it
  migrates that field (`FROM` the prior key or `-`, `WITH` the pure conversion
  fn's name or `-`, never both `-`), and between the `data` lead line and the
  first `field` line it carries a renamed **type** declaration's prior name
  (rename form only, so `WITH` is always `-` there). The line is emitted only
  where the source carries the directive, so an artifact of a migration-free
  source changes by the version stamp alone (the v7 stamp-only restamp
  precedent). The conversion fn is an ordinary `[functions]` record the loader
  resolves by name. The sub-record keyword set is closed (§2.1), so the new
  keyword is a deliberate bump: 7 → 8. v9 carries the **§08 §3 state-query
  declarations** through to the runtime — the first-class `query` declarations
  and their §05 §3 `@index`/`@spatial` index requirements, which the runtime
  needs to **maintain** the declared engine indices over the world database and
  to evaluate a query call from the artifact alone. Two layout changes ride it:
  (a) one new section, `[queries Q]` (§16), appended after `[entrypoint]` — one
  record per entrypoint-module `query` declaration in source order, the
  `[functions]` record mold extended with the declared requirement lines; (b)
  one new **sub-record keyword**, `index` — a fixed four-token line `index KIND
  THING FIELD` (`KIND` ∈ `index` | `spatial`) carrying one declared §05 §3
  requirement. A query body is a Block by grammar (no body-position hole), so
  its body run is the plain §2.7 statement forest. A new section and a new
  sub-record keyword are layout changes: 8 → 9. v10 ratifies the **§08 §3 world
  read `all[T]`** as a §2.7 node KIND: `node all THING 0` — a leaf carrying the
  read table's thing type name, evaluating to that thing's instance rows in
  stable `Id` order (the runtime reads its current version; the compiler's test
  interpreter the setup-seeded startup population). It is the form a spec-true
  query body reads the world through — a query takes **only value parameters**
  (the View-parameter interim shape is retired by the same bump), so the
  `[queries]` carry (§16) is unchanged in layout while every world read moves
  inside the body. A new node KIND is a layout change: 9 → 10.
- A runtime reads the stamp and **refuses a mismatch**: it loads only the exact
  version it was built for and rejects every other with a fix-it diagnostic,
  never a best-effort parse. An under- or over-shaped artifact is an error. This
  mirrors the Index Contract's exact-match discipline (§29 §2): the schema
  version is the single compatibility gate.

The version stamp is line 1 so a parser can reject a wrong version before reading
any payload.

---

## 2. Purity — bit-identical by construction

The artifact carries **no host nondeterminism** (§09, §29):

- **No clock** — no timestamps, build dates, or wall-clock anywhere.
- **No machine paths** — source spans are recorded as the **path-derived module
  name** (§15) plus a 1-based line, never an absolute or cwd-relative filesystem
  path.
- **No float** — every `Fixed` is stored as its **raw signed Q32.32 `i64` bits**
  in decimal (§2.3). There is no decimal-string round-trip, so emission and load
  are exact and identical on every machine.
- **No map iteration** — every list in this format is in a **defined total
  order** (declaration order, or the depth-first flattened pipeline order),
  never hash order.

Two emissions from the same source are therefore byte-identical: the format has
no field whose value depends on when, where, or on which machine it was emitted.

### 2.1 Lexical frame

- Encoding is **UTF-8**. Every line ends with a single `\n` (LF, `0x0A`); there
  is no `\r`, no trailing whitespace, and the file ends with a final `\n`.
- The format is **line-oriented**: one record per line. A record is a
  **kind tag** followed by space-separated fields:
  `KIND field1 field2 …`.
- Fields never contain a raw space, `\n`, or `\t` except inside a **string field**
  (§2.4), which is length-prefixed so a parser never scans for a delimiter inside
  it.
- A **section** is a `[section_name N]` header line stating the section name and
  its exact **top-level record count** `N`, followed by `N` top-level records.
- A top-level record may be **variable-length**: it is followed by a run of
  **sub-records** (e.g. `enum Side - 2` is followed by 2 `variant` lines; `thing
  Paddle false 1 5` is followed by 1 `gtag` and 5 `field` lines; a `function`/
  `behavior` record is followed by its `param`/`emit`/… lines **and** its body
  `node` run, §2.7). A **section body runs to the next `[` header** — header lines
  are the only line class that opens with `[`, so a parser reads a section's body
  unambiguously, then re-derives `N` by counting the **lead** lines (those whose
  keyword is *not* a sub-record keyword). The closed sub-record keyword set is:
  `variant`, `field`, `gtag`, `param`, `emit`, `producer`, `consumer`, `set`,
  `node`, `migrate` (v8, §6). A declared `N` that disagrees with the lead-line
  count is an error (an under- or over-shaped section, §29-style exact-match).

  This **lead-line reader is the single parse discipline** for top-level record
  boundaries: a top-level record runs from its lead line up to the next lead line
  (or the next `[` header). Per-record scalar count fields (`param_count`,
  `emits_count`, `body_count`, an enum's `variant_count`) tell a reader how to
  shape each sub-record run *within* a record — but the **record count `N`** is
  always the lead-line count, never a sum of declared sub-counts. The format does
  **not** offer a second, grammar-only reader that derives `N` from declared
  sub-counts: a `const`'s body `node` run and a record's mixed `param`/`emit`/
  `node` sub-records are not all reachable from a single declared sub-count on the
  lead line, so only the lead-line discipline is sound. `node` being a sub-record
  keyword keeps every body line a sub-record, so the lead-line count is exact.

### 2.2 Integer encoding (`Int`)

A funpack `Int` is a 64-bit signed saturating integer (§10). It is written in
**decimal**, with a leading `-` for negatives, no leading zeros (except the value
`0`), no `+`, no thousands separators. Range is `[-9223372036854775808,
9223372036854775807]`.

### 2.3 Fixed encoding (`Fixed`)

A funpack `Fixed` is signed Q32.32 (`i64` raw, §10). It is written as its **raw
`i64` bits in decimal** — i.e. `value * 2^32`, truncated to the integer that the
compiler's fixed-point lowering produced. Examples (these are the exact bits the
golden fixture carries):

| Source literal | Raw Q32.32 bits |
|---|---|
| `0.0` | `0` |
| `0.5` | `2147483648` |
| `1.0` | `4294967296` |
| `2.0` | `8589934592` |
| `3.0` | `12884901888` |
| `4.0` | `17179869184` |
| `8.0` | `34359738368` |
| `16.0` | `68719476736` |
| `40.0` | `171798691840` |
| `60.0` | `257698037760` |
| `70.0` | `300647710720` |
| `80.0` | `343597383680` |
| `90.0` | `386547056640` |
| `120.0` | `515396075520` |
| `152.0` | `652835028992` |
| `160.0` | `687194767360` |
| `-70.0` | `-300647710720` |

To recover the logical value, a runtime divides the raw bits by `2^32` in its own
fixed-point representation; it never parses a decimal point. A `Fixed` field is a
plain decimal integer, lexically indistinguishable from an `Int` field — the
field's **position** (per the record's documented signature) tells the parser
which it is.

### 2.4 String encoding (`String`)

A string field is **length-prefixed**: `Lbyte_count:raw_bytes`. `byte_count` is
the decimal UTF-8 byte length; the bytes follow the `:` verbatim, including any
space or `\n` they contain. A parser reads `byte_count` then consumes exactly that
many bytes — it never interprets the contents. The empty string is `L0:`.

Example: the doc string `Move the paddle` (15 bytes) is `L15:Move the paddle`.

### 2.5 Bool encoding

`true` or `false`, lowercase, as bare tokens.

### 2.6 Identifier / name fields

A name (module, type, field, behavior, stage, enum, variant, signal, function) is
a bare UTF-8 token with no spaces. Qualified names use `.` as the segment
separator (`engine.math`, `Side::Left` uses `::` for an enum variant).

### 2.7 Body encoding — the serialized checked-AST node line

Every executable body the runtime must interpret — each `fn` body, each behavior
`step` body, each `const` initializer, the `bindings()` body, and the `setup()`
body — is serialized **into** the artifact as a tree of checked-AST nodes. The
runtime parses pong from this document with **zero `funpack` imports** and **no
`funpack` source on disk**, so a body cannot be a span reference into source the
runtime can never read: the artifact carries the whole node graph and the runtime
interprets it directly (§09 §1 — the interpreter is the canonical semantics).

A body is a flat, **pre-order** (depth-first, node-then-children) run of `node`
lines. Each node is exactly one line:

```
node KIND field… child_count
```

- `node` is the line's sub-record keyword (it is in the closed
  `SUB_RECORD_KEYWORDS` set, §2.1), so a body run is read by the same lead-line
  discipline as every other sub-record.
- `KIND` is a closed node-kind tag (the table below).
- `field…` are that kind's **scalar** fields in the documented order, each a
  primitive (`Int` §2.2, `Fixed` §2.3, `String` §2.4, name §2.6) — never a nested
  node.
- `child_count` is the **last** field on every node line: the count of immediately
  following `node` lines that are this node's children, in their documented order.
  A reader consumes the node, reads its scalar fields, then recursively consumes
  exactly `child_count` child subtrees. The encoding is therefore total and
  count-driven — a reader never looks ahead past a node's own declared children.
  The **one exception** is the `arm` node (below): an `arm` always has 0 children
  and its trailing field is a variable-length `binders` list (sized by its
  `binder_count` scalar), so `arm`'s child count is fixed at 0 by its kind rather
  than read as a trailing token. Every other node ends in `child_count`.

The node-kind set is closed (a new kind is a schema-version bump, §1) and mirrors
the checked surface AST (spec §02 §5–§6). Children are listed **in evaluation /
source order**; a node's `child_count` plus the kinds below fully determine the
subtree shape:

| KIND | Scalar fields | Children (in order) | Surface form |
|---|---|---|---|
| `int` | `value:Int` | 0 | integer literal `0` |
| `fixed` | `bits:Fixed` | 0 | fixed literal `4.0` (raw Q32.32, §2.3) |
| `name` | `ident:name` | 0 | a bare name `self`, `BOARD`, `add_goal` |
| `string` | `value:String` | 0 | string literal `"…"` (length-prefixed, §2.4; interpolation holes retained verbatim) |
| `field` | `member:name` | 1 = receiver | field access `a.b` |
| `call` | (none) | 1 + N = callee then N args | `f(a, b)` |
| `variant` | `type:name` `case:name` `has_payload:Bool` | N = payload args | `Side::Left`, `Option::Some(x)` |
| `record` | `type:name` `field_count:Int` `child_count:Int` | `child_count` = `field_count` `recfield` nodes (one per field) | `Vec2{x: …, y: …}` |
| `recfield` | `name:name` | 1 = the field's value subtree | one `name: value` pair inside a `record`/`with` |
| `with` | `field_count:Int` `child_count:Int` | `child_count` = `1 + field_count`: the base value, then `field_count` `recfield` nodes | `value with { f: v }` |
| `list` | `len:Int` | `len` element subtrees | `[a, b]`, `[]` |
| `lambda` | `param_count:Int` `params:name…` | 1 = the single-`return` body expr | `fn(p) { return e }` |
| `unary` | `op:name` | 1 = operand | `-x`, `not x` (`op` ∈ `neg`,`not`) |
| `binary` | `op:name` | 2 = lhs, rhs | `a + b` (`op` table below) |
| `match` | `arm_count:Int` `child_count:Int` | `child_count` = 1 scrutinee + (per arm: an `arm` subtree then its body) = `1 + 2*arm_count` | `match e { … }` |
| `arm` (scalar) | `pat:name` `type:name` `case:name` `binder_count:Int` `binders:name…` | 0 (fixed by kind; no trailing `child_count`) | a `wildcard`/`bare_variant`/`variant_binds`/`bare_binder` pattern (its body is the following sibling) |
| `arm` (tuple, v2) | `tuple` `child_count:Int` | `child_count` = the positional sub-pattern `arm` subtrees | a `(p, q, …)` tuple pattern, e.g. `(Option::Some(cell), next)` |
| `let` | `name:name` | 1 = the bound value expr | `let n = e` |
| `if_return` | (none) | 2 = condition, returned value | early-return `if cond { return v }` |
| `return` | (none) | 1 = the returned value expr | `return e` |
| `stub` (v7) | `form:name` (`bare` or `fallback`) | `fallback`: 1 = the approximation expr; `bare`: 0 | a §05 §2 typed hole standing for the whole body: `@stub(T, fallback)` / `@stub(T)` |
| `all` (v10) | `thing:name` | 0 | the §08 §3 world read `all[Ball]` — the thing's instance rows in stable `Id` order |

- `binary` `op` is the closed glyph set, by name: `add` `sub` `mul` `div` `mod`
  `eq` `ne` `lt` `le` `gt` `ge` `and` `or`. `unary` `op` is `neg` or `not`.
- `arm` `pat` is the pattern kind. The **scalar** patterns carry no child of
  their own (their body is the next sibling under the `match`): `wildcard`
  (`type`/`case` are `-`, `binder_count` 0), `bare_variant` (`type::case`,
  `binder_count` 0), `variant_binds` (`type::case` with `binder_count` payload
  binder names following on the same line — a binder of `_` is the discard
  binder), and `bare_binder` (v2 — a single binder name binding the whole tuple
  position, e.g. snake's `next` Rng position; its body is likewise the next
  sibling and it carries 0 children). The **tuple** pattern (v2) is the one arm
  with children: `arm tuple child_count` is followed by `child_count` positional
  sub-pattern `arm` subtrees, each a nested arm of any pattern kind (a variant, a
  wildcard, a bare binder, or a nested tuple). A reader reads a scalar arm's
  child count as 0 by kind, and a `tuple` arm's as the trailing `child_count`
  token. A `match` declares a `child_count` of `1 + 2*arm_count`: the scrutinee
  subtree, then for each arm an `arm` SUBTREE (a scalar arm is one line; a tuple
  arm is its head plus its sub-pattern arms) immediately followed by its body
  subtree. (For pong every match is two-armed with scalar arms, so `arm_count`
  is `2` and `child_count` is `5`; snake's `match pick(free, rng)` is two-armed
  with tuple arms, still `arm_count` `2` and `child_count` `5` because each
  tuple arm and its sub-arms count as one subtree.)
- A body's **top** is a single statement subtree per body line of the source: a
  `fn`/`step`/`const` body is a sequence of statements (`let`, `if_return`,
  `return`), so the owning record declares a `body_count` of top-level statement
  subtrees and the run is those subtrees back-to-back (§9, §10). A `const`
  initializer and the `setup`/`bindings` bodies are a single top-level statement.
- A **holed** declaration (v7) has no statement sequence at all — the `stub`
  node IS its body, the single top-level subtree (`body_count` 1). A runtime
  evaluating `stub fallback` evaluates the child expression in the record's
  param-bound scope (the same environment an intact body's statements read), so
  the approximation is bit-identical to the compiler interpreter's dev
  evaluation; evaluating `stub bare` is the **defined fail-closed no-value
  outcome** — the behavior instance folds nothing this tick, a calling
  expression fails closed — never a trap or undefined behavior.

Example — `goal_side`'s body (`if at.x < 0.0 { return Option::Some(Side::Right) }`
then `if at.x > BOARD.w { … }` then `return Option::None`) serializes to three
top-level statement subtrees, the first being:

```
node if_return 2
node binary lt 2
node field x 1
node name at 0
node fixed 0 0
node variant Option Some true 1
node variant Side Right false 0
```

The `if_return` declares 2 children (condition, value); the `binary lt` declares 2
(`at.x`, `0.0`); the `field x` declares 1 (its receiver `at`); the literals and
the leaf `variant Side Right` declare 0. A reader rebuilds the tree by consuming
exactly each node's declared child count, with no source and no lookahead.

---

## 3. Top-level layout

The artifact is the version stamp, then these sections **in this fixed order**.
Each is a `[name N]` header followed by `N` records. A runtime reads them
sequentially; the order is part of the contract.

```
funpack-artifact 9
[meta 2]
…
[enums N]
…
[data N]
…
[signals N]
…
[things N]
…
[functions N]
…
[behaviors N]
…
[pipeline_flattened N]
…
[signal_routing N]
…
[setup N]
…
[bindings N]
…
[entrypoint 1]
…
[queries N]
…
```

Sections with no records still emit their header with `N = 0` and no body lines,
so a parser always reads a fixed sequence of headers.

---

## 4. `[meta]` — project identity

Two records, in order:

```
project NAME           # the §14 project.fcfg block label (package identity)
version L5:0.1.0       # the project.fcfg `version` value, as a String field
```

This is `(project.fcfg)` identity only (§14 §4): name + version. It carries no
build clock and no platform — platform is a build-driver concern (§14 §6), not an
artifact field.

---

## 5. `[enums]` — sum types and role kinds (§03 §2, §03 §4)

One record per declared enum, in source-declaration order. Each enum record is
followed by one `variant` record per variant, in declaration order:

```
enum NAME KIND variant_count
variant NAME PAYLOAD
…
```

- `KIND` is the §03 §4 role kind ascribed after the type name, or `-` for none:
  one of `Axis`, `Button`, `CollisionLayer`, `Num`, `-`. A `Steer: Axis` enum
  records `Axis`; a plain `Side` enum records `-`. The kind is type-constitutive
  (only an `Axis`-kinded enum binds to an analog input, §23), so it travels with
  the enum.
- `PAYLOAD` is the variant shape: `unit` (no payload, e.g. `Side::Left`),
  `tuple K` (K positional types — the type names follow on the same line), or
  `struct K` (K named fields `name:Type` follow). Pong's enums are all `unit`.

---

## 6. `[data]` — value records with field defaults (§03 §1, §08)

One `data` record per `data` declaration, in source order, each followed by its
fields. Every field carries its declared type and its default-presence flag:

```
data NAME field_count mut
migrate FROM -                  # v8, only for a renamed TYPE declaration
field NAME TYPE DEFAULT
migrate FROM WITH               # v8, only after a @migrate-prefixed field
…
```

- `mut` is `true` when the type was declared `mut data` (§03 §7), else `false`.
- `field` records carry: the field `NAME`, its `TYPE` (a name; a generic is
  written `Ctor[Arg]`, e.g. `Ref[Switch]`, `[Goal]` for a list), and `DEFAULT`.
- `DEFAULT` is `-` when the field has no default (it must be supplied at every
  literal), or `=ENCODED` where `ENCODED` is the default value in this format's
  primitive encoding. A defaulted field may be omitted from a literal (§03 §1), so
  the runtime applies `DEFAULT` when a `setup` Spawn omits it.
- `ENCODED` is **one space-free token** — a `field` line is whitespace-delimited
  (`field NAME TYPE DEFAULT`) and §2.1 forbids a raw space in a non-string field,
  so the default is the line's fourth token, never a multi-token run. The §13
  `set FIELD =vec2 x y` setup form (a 3-token spread) is a `[setup]`-only spelling
  a reader shapes by the `set` record; it is **not** the field-default form. The
  default-token forms, by `TYPE`:
  - a `Fixed`, `Int`, `Bool`, or `String` scalar in its §2 primitive encoding
    (`=0`, `=4294967296`, `=true`, `=L0:`) — the original scalar form, unchanged;
  - an **enum-variant** default as its `Type::Case` token (§2.6), e.g.
    `=Hunt::Patrol`, `=Dir::Right`. Already space-free; a reader carries it as the
    enum token verbatim (the same shape an enum column holds);
  - an **empty-list** default `[]` as `=[]` (the only list literal a default
    admits — a defaulted list seeds empty, e.g. snake's `body: [Cell] = []`);
  - a **composite record** default (`Vec2`, `Cell`, any constructor) as its
    inline constructor token `Type(field=enc,…)`: the type name, then a
    parenthesized, comma-joined `field=ENCODED` list with **no interior spaces**
    (each `ENCODED` itself a space-free scalar/enum/record token, so the form
    nests). A `Vec2{x: 0.0, y: 0.0}` default is `=Vec2(x=0,y=0)`; a
    `Cell{x: 10, y: 10}` default is `=Cell(x=10,y=10)`. This is the §6 single-token
    realization of "its constructor record inline" — the parens-and-no-spaces
    spelling (cf. the §14 builder-call `keys_axis(Key::W,Key::S)` form) keeps a
    composite default in the one token a `field` line allows, where the §13
    space-spread `vec2` form cannot fit.
  - an **engine-type composite** default (v5) — a §11/§24 engine record used as a
    default — reuses the same inline-constructor token `Type(field=enc,…)`, with
    two v5 wrinkles. (i) A `Settings.defaults()` **static-builder** default is a
    CALL, not a value the §29-pure artifact can carry verbatim, so the emitter
    **evaluates** it to its canonical factory record and inlines that:
    `=Settings(volume=128,fullscreen=false)` — `volume` the default gain (Int),
    `fullscreen` off (Bool). The Settings the artifact carries is the runtime's
    representable two-field projection (`{ volume: Int, fullscreen: Bool }`),
    **synthesized into [data] as a `Settings` data record** (§8) so a reader
    resolves the default's nested field types by declared type. (ii) A `Body`
    default inlines with its **§11 §2 field defaults applied** — an omitted
    `impulse: Vec2` seeds `Vec2(x=0,y=0)` (`zero`), an omitted `mass: Fixed` seeds
    `1.0` (`4294967296`) — so the emitted Body token carries the complete resolved
    field set, never a half-built record the runtime would have to default. An
    `Option[String]` default is the enum-variant token `=Option::None` (the bare
    `Type::Case` form above; the `[String]` element only shapes the field's
    declared TYPE column, not the default token).

This is a **value-encoding addition within the field-default token**, not a new
section or node kind: a `field` line still carries exactly `NAME TYPE DEFAULT`, and
`DEFAULT` is still the one `=ENCODED` token a reader reads at `sf[3]`. The v5 bump
(§1) is driven by the singleton marker (§8), the physics-stage step (§11), the
CollisionLayer KIND value (§5), and — for §6 — the **synthesized engine-type data
projection** the Settings default decode requires (a [data] record the source's
defaults add, a record-layout change). The gameplay (pong) surface emits only the
scalar forms, so every pong default is byte-identical to v1's scalar encoding; the
composite forms are reached by the snake (`Cell`, `Dir`, `[]`) and hunt
(`Hunt::Patrol`, `Vec2`) goldens, and the engine-type composite/static-builder
forms by the yard (`Settings.defaults()`, `Option::None`, `Body`) surface.

**Migration carry (v8, §05 §6).** A `migrate` line is the fixed three-token
sub-record `migrate FROM WITH` carrying a `@migrate` directive's rename/retype
metadata — the two structural breaks the §09 §4 name-keyed schema-diff cannot
auto-resolve. `FROM` is the prior key as a bare name token (§2.6) or `-`; `WITH`
is the pure `fn(Old) -> New` conversion's name or `-`; at least one is present
(the compiler rejects an empty form upstream). Its **position** selects the
target: a `migrate` line **immediately following a `field` line** migrates that
field (`@migrate(from: "old_pos") pos: Vec2` emits `migrate old_pos -`); a
`migrate` line **between the `data` lead line and the first `field` line** is
the renamed type declaration's prior name (`@migrate(from: "OldName") data
NewName` emits `migrate OldName -`) — rename form only, so `WITH` is always `-`
there. The line is emitted only where the source carries the directive: a
migration-free `data` record is byte-identical to the v7 shape, and `[signals]`
/ `[things]` records never carry one (the `data` schema is the evolution
channel). The conversion fn named by `WITH` is an ordinary `[functions]` record
(§9) the loader resolves by name and runs the old value through at
restore/hot-reload migration time (§09 §4, §24).

`Board` is the one pong `data` type; `BOARD` is a module-level `let`, recorded in
`[functions]` as a `const` (§9) since it is a named value, not a type.

---

## 7. `[signals]` — the cross-thing message values (§03 §6)

A `signal` is a `data` value declared with the `signal` keyword — the sole
cross-thing channel (§06 §5). One record per signal, same field grammar as
`[data]` (§6), but `mut` is always `false` (a signal is per-tick, never mutated):

```
signal NAME field_count
field NAME TYPE DEFAULT
…
```

Pong's one signal is `Goal { side: Side }`.

---

## 8. `[things]` — stateful entities with their blackboard schema (§06, §08)

One record per `thing` / `singleton`, in source order, each followed by its
blackboard schema (its `data` fields) and its `@gtag` set:

```
thing NAME SINGLETON gtag_count field_count
gtag L4:ball
field NAME TYPE DEFAULT
…
```

- `SINGLETON` is `true` for a `singleton` (§06 §2, a guaranteed-single-row thing
  spawned once before tick 0, accessed by type), `false` for a `thing`.
- `gtag` records (§05 registry, §14 §4) carry one registered tag each, as a
  String field, in source order. An unregistered tag never reaches the artifact —
  it is a compile error upstream.
- `field` records are the §6 field grammar: name, type, default. A defaulted
  field (`Scoreboard.left = 0`) records its default so a Spawn may omit it.

**Singleton tick-0 spawn marker (v5).** A `SINGLETON true` row IS the §06 §2
tick-0 spawn marker: a singleton is spawned **once before tick 0, accessed by
type**, and no `[setup]` Spawn supplies it (the §13 batch carries only `thing`
spawns). So the singleton's [things] row must carry its **complete defaulted
field schema** — every field with a §6 `=ENCODED` default — because that schema is
the *only* source the runtime has to fill the row's columns. A reader spawns one
row per `SINGLETON true` thing before tick 0, every column the field's decoded
default. yard's three singletons exercise the full §6 default vocabulary:
`Scoreboard { delivered: Int = 0 }` (a bare scalar), `Camera { at: Vec2 =
Vec2(x=…,y=…), zoom: Fixed = …, shake: Vec2 = … }` (composite Vec2 + Fixed), and
`Menu { settings: Settings = Settings(volume=128,fullscreen=false), dirty: Bool =
false, status: Option[String] = Option::None }` (an engine-type composite default,
a Bool, and an enum-variant Option default). A singleton field with no default
would leave a column the runtime cannot fill, so every singleton field carries one.

Pong's things: `Paddle`, `Ball`, `Scoreboard` (all `thing`; pong models the
score as a once-spawned `thing` in `setup`, not a `singleton`). yard's things:
`Player`, `Crate`, `Wall`, `Pad` (`thing`), and `Scoreboard`, `Camera`, `Menu`
(`singleton` — the tick-0 marker case).

---

## 9. `[functions]` — pure helpers, module constants, and bindings/setup heads (§02)

One record per module-level `fn`, `let`, the `bindings()` function, and the
`setup()` function, KIND-grouped in the fixed order fn-helpers → `const` →
`bindings` → `startup`, each group in source-declaration order (the golden
fixture and the emitter both embody this rule; readers locate records by
name, never by position). The function **body** is the serialized
checked AST, carried **in** the record as a run of `node` lines (§2.7) — never a
span reference into source the runtime can never read. The record opens with the
signature and a body statement count; the `param` lines and the `node` body run
follow:

```
function NAME KIND param_count return:TYPE body_count span:MODULE:LINE
param NAME TYPE
…
node …
…
```

- `KIND` is one of: `fn` (a pure helper, e.g. `advance`, `goal_side`), `const`
  (a module-level `let`, e.g. `BOARD` — `param_count` is 0 and `return` is the
  value's type), `bindings` (the one §23 `fn() -> Bindings`), `startup` (the one
  §06 Startup head, `setup() -> [Spawn]`).
- `return:TYPE` is the declared return type (a name or generic per §2.6; `[Goal]`
  for a signal list, `[Spawn]` for the setup command list, `Bindings` for the
  binding head, `Option[Side]` for an option).
- `body_count` is the number of **top-level statement subtrees** in the body
  (§2.7): one per source statement line (`let`/`if_return`/`return`). A `const`
  initializer and the `bindings`/`setup` bodies are a single top-level `return`
  subtree, so their `body_count` is `1`. The body `node` run follows the `param`
  lines and is exactly those statement subtrees back-to-back, in source order.
  A §05 §2 **holed** fn (v7, dev artifact only) carries the single `stub`
  subtree as its body — `node stub fallback 1` plus the approximation expression
  for `@stub(T, fallback)`, `node stub bare 0` for the typecheck-only
  `@stub(T)` — so its `body_count` is `1` (§2.7).
- `span:MODULE:LINE` is the §15 module name and 1-based source line, kept as
  **diagnostic provenance** — never a filesystem path (§2 purity) and never the
  sole body representation. A runtime executes the carried `node` tree; the span
  only locates the construct in a diagnostic.
- `param` records carry each parameter's name and type, in declaration order.

The `const` record for `BOARD` carries its initializer as the body `node` run
(here a single `return` of a `Board{ w: 160.0, h: 120.0 }` record), so the runtime
evaluates the constant from the artifact alone — a default or a Spawn that reads
`BOARD.w` / `BOARD.h` resolves against the interpreted constant, no source needed:

```
function BOARD const 0 return:Board 1 span:pong:19
node return 1
node record Board 2 2
node recfield w 1
node fixed 687194767360 0
node recfield h 1
node fixed 515396075520 0
```

---

## 10. `[behaviors]` — transitions keyed to their pipeline stage (§06 §3, §06 §6)

One record per `behavior`, in **source-declaration order** (the stable order the
node-check ran in). Each carries the stage slot it occupies, its reserved-step
signature, and its `@gtag` set:

```
behavior NAME on:THING stage:STAGE contract:CONTRACT gtag_count param_count emits_count body_count
gtag L4:ball
param NAME TYPE
…
emit TYPE
…
node …
…
```

- `on:THING` is the §06 §3 owning thing whose blackboard this behavior writes.
- `stage:STAGE` is the pipeline stage slot the behavior is listed in
  (`control`, `collision`, `scoring`, `render`, `startup`) — the slot **confers**
  the contract (§06 §6).
- `contract:CONTRACT` is the engine-closed §06 §6 contract conferred by that slot:
  one of `Update`, `Render`, `Ui`, `Audio`, `Startup`. `paddle_move` is `Update`;
  `draw_ball` is `Render`.
- The **reserved step signature**: every behavior's per-tick entry point is the
  built-in `step` (§06 §3) — not a user-chosen name — so the artifact records the
  signature of `step`, not a name. `param` records are `step`'s parameters **in
  order**: `self` (the blackboard, type = `on:THING`), then resources (`Input`,
  `Time`), inbound signal lists (`[Goal]`), and read-only views (`View[Paddle]`).
  Its parameters are its reads (§06 §3).
- `emit` records are `step`'s return-side emissions: the blackboard type it writes
  (always its own `on:THING`, or absent for a pure Render that returns only
  `[Draw]`), the signal lists `[S]` it emits, and the command lists (`[Draw]`,
  `[Spawn]`) it returns. Its return is its writes (§06 §3). `emits_count` is the
  count of `emit` records.
- `body_count` is the number of **top-level statement subtrees** in `step`'s body
  (§2.7), one per source statement line. The body `node` run (§2.7) follows the
  `emit` lines and is exactly those statement subtrees back-to-back, in source
  order — the runtime interprets it as the behavior's per-tick transition, with no
  `funpack` source on its path. `wall_bounce`'s body, for instance, is two
  statements (`if self.pos.y <= 0.0 or … { return self with { vel: … } }`, then
  `return self`), so its `body_count` is `2`. A §05 §2 **holed** step (v7, dev
  artifact only) carries the single `stub` subtree as its body (`body_count` 1):
  a `stub fallback` step ticks its approximation expression live (the P8
  playability surface), a `stub bare` step fails closed — the instance folds
  nothing that tick, a defined no-value outcome, never a trap.

A behavior with no `param` beyond `self` and no `emit` beyond its blackboard is
dead code (§06 §6 Update "must write or emit *something*") — that is an upstream
gate, never an artifact state.

---

## 11. `[pipeline_flattened]` — the one total order (§07 §2, §07 §3)

The pipeline is funpack's schedule: an explicit, ordered plan for a tick where
**stage order is its meaning** (§07). A pipeline tree is flattened **depth-first**
into one total order (§07 §3). This section records that flattened order as a flat
sequence — pong's `Pong` pipeline has no sub-pipelines, so the flattening is the
five named stages in order, each expanded to its behaviors in listed order:

```
step ORDINAL stage:STAGE behavior:NAME
```

- `ORDINAL` is the 0-based position in the **total order** — the index a tick's
  fold (§07 §4) visits this step at. It is contiguous and gap-free.
- `stage:STAGE` is the owning stage name (documentary; its position is the
  contract, §07 §1).
- `behavior:NAME` is the **occupant** run at this step — a user behavior, or (v5)
  an engine **battery**. A behavior occupant must have a `[behaviors]` record
  (§10); a battery occupant has none.

**Physics-stage encoding (v5, §11 §3).** The §11 §3 `physics:` stage is an
**engine-closed** stage whose single member is the `solve` battery — collision
resolution writes BOTH bodies, which a behavior may never do, so it is the engine's,
not a behavior. It still occupies a real pipeline **position**: stage position is
the ordering — intent is written by the stages **before** `solve`, reactions are
consumed by the stages **after** (§11 §3). So a `physics: solve` stage flattens to
one **battery step** in the total order, the same line shape as a behavior step:

```
step 2 stage:physics behavior:solve
```

A battery step is **distinct from a behavior step**: its `behavior:NAME` is the
battery name (`solve`), not a `[behaviors]` record, so a reader keeps the step
position but binds **no** user behavior — it dispatches the step to the native
solver by the `(stage, behavior) = (physics, solve)` pair, never a behavior lookup.
The battery name was validated against the engine battery set upstream (only `solve`
exists, §11 §3). Because a battery step holds no signature, it produces **no**
[signal_routing] endpoint (§12): the engine's `Contact`/`Trigger` outputs are an
optional inbound edge, not a user-emitted signal subject to effect closure.

This is the derived, never-drifting flattened tree (§07 §3): effect closure
(§12's routing) runs on the same order, so the order recorded here **is** the
order the runtime folds. `startup:` steps (run once before tick 0, §07 §1) are
recorded first with `stage:startup`; the interior Update stages (yard's `control`,
then the `physics:solve` battery step, then `delivery`/`menu`/`camera`) follow;
the terminal `render:` projection stage is last.

---

## 12. `[signal_routing]` — producer(s) → consumer(s) map (§07 §2, §07 §3)

The derived `signal → producer(s) → consumer(s)` routing map (§07 §3). One record
per signal type that is emitted or consumed anywhere, in signal-declaration order.
Producers and consumers are listed by **flattened-order ordinal** (§11) so the
runtime can verify forward flow without re-deriving it:

```
route SIGNAL producer_count consumer_count
producer ORDINAL behavior:NAME
…
consumer ORDINAL behavior:NAME
…
```

**Effect closure** (§07 §2) holds iff every signal has ≥1 consumer at an ordinal
**strictly greater** than at least one producer's ordinal (the consumer is
downstream in the flattened order). The artifact records the routing; the runtime
may re-check closure against it, but the upstream gate already guaranteed it. For
pong, `Goal` is produced by `score` (in `scoring`) and consumed by `tally` and
`serve` (also `scoring`, but later in the listed order, so downstream).

---

## 13. `[setup]` — the Startup `[Spawn]` program (§06 §6, §07 §4)

The Startup behavior's `[Spawn]` command list, fully evaluated to concrete
encoded values — the deterministic batch applied at the tick boundary before tick
0 (§07 §4). The setup program carries **no expressions**; every field is a
primitive-encoded value (§2), so the runtime spawns the initial population without
interpreting an initializer:

```
spawn THING field_count
set FIELD =ENCODED
…
```

- `spawn THING` names the thing type being spawned, in the **source list order**
  of the `setup()` body (Paddle P1, Paddle P2, Ball, Scoreboard; yard's 4 Walls, 1
  Pad, 1 Player, 3 Crates).
- `set FIELD =ENCODED` carries each supplied field's value in this format's
  encoding: an enum variant as `Side::Left` (a name field, §2.6), a `Fixed` as its
  raw bits (§2.3), an `Int` in decimal (§2.2), a `Vec2` as a nested
  `vec2 x_bits y_bits` record. A field omitted in the source (relying on a
  default, §6) is **not** emitted here — the runtime applies the type's default.
- **A composite engine record** (a §11 §2 `Body`) takes the **§6 single-token inline
  form** `Type(field=enc,…)`: a parenthesized, comma-joined `field=ENCODED` list with
  **no interior spaces**, each nested value itself a space-free token (a nested `Vec2`
  collapses to `Vec2(x=,y=)`, NOT the `vec2 x y` spread, since a token carries no
  interior space). **A list** field (a `mask: [Layer]`) takes the `[enc,…]` form — a
  bracketed comma-joined run of space-free element tokens. yard's setup is the first
  surface to reach these: its `setup()` spawns through user helper fns
  (`crate_at(…)`, `wall_body(size)`) and constructs `Body` records, so the emitter
  **constant-folds** the batch at compile time (inlines the calls, resolves the
  nested records) and **applies the §11 §2 Body defaults the source omits** —
  `mass=1.0` (`4294967296`), `restitution=0.0` (`0`), `friction=0.5` (`2147483648`),
  `sensor=false`, `impulse=zero` (`Vec2(x=0,y=0)`) — so the emitted Body token carries
  the complete resolved column set, never a half-built record the runtime would have
  to default. This is the **same single-token composite spelling §6 already defines**
  for a field default, reused in the `set` slot (a `set` line carries `ENCODED` at one
  position, so a composite there is one token exactly as a §6 default is); it is
  **not** a new node kind. A reader discriminates the forms by the leading byte of
  `ENCODED`: `vec2` opens the §13 Vec2 spread, `[` a list, `(`-after-a-name a
  composite record, `::` a bare enum token, a digit a scalar.

This is the §07 §4 fixed-population batch: population is fixed within a tick, and a
thing spawned this tick is first queryable next tick.

---

## 14. `[bindings]` — the §23 axis/button source map

The `bindings()` function's resolved binding table (§23 §3) — the **only**
device-aware data in the artifact. One record per `.axis(…)` / `.button(…)` call,
in **source-call order** (bindings stack, §23 §3, so order is preserved):

```
bind axis PLAYER ACTION source:SOURCE
bind button PLAYER ACTION source:SOURCE
```

- `axis` / `button` is the binding's analog/digital kind, matching the action's
  §03 §4 role kind (`Axis` → `axis`, `Button` → `button`).
- `PLAYER` is the `PlayerId` (`P1`..`P4`), a name field.
- `ACTION` is the enum variant the binding targets (`Steer::Move`), a name field.
- `source:SOURCE` is the device source, one of the **closed v3 source-form set**
  below, rendered as a builder call — the device names (§23 §3) appear **only
  here**, never in sim logic. Multiple bindings for one action stack (§23 §3);
  each is its own record.

The v3 SOURCE forms (a closed taxonomy — a new form bumps the version, §1):

| Form | Arity | Contribution |
|------|-------|--------------|
| `key(Key::X)` | 1 | digital button edge/level |
| `pad(PadButton::X)` | 1 | digital button edge/level |
| `keys_axis(neg,pos)` | 2 | 1D axis: neg key −1, pos key +1 |
| `stick_x(Stick::S)` / `stick_y(Stick::S)` | 1 | 1D axis: that stick component's deadzoned sample |
| `keys_quad(neg_x,pos_x,neg_y,pos_y)` | 4 | 2D axis: digital ±1 per component |
| `stick(Stick::S)` | 1 | 2D axis: both deadzoned stick components |

A 1D form contributes to the action's single 1D value (the slot `input.value`
reads); a 2D form (`keys_quad`, `stick`) contributes both components (the Vec2
`input.axis` reads). The emitter **lowers** the §23 §3 builder helpers into this
set: a key-list button source (`.button(P1, Move::Up, [Key::W, Key::Up])`)
spreads into one `key(…)` record per listed key (stacking, §23 §3); `wasd()`
lowers to `keys_quad(Key::A,Key::D,Key::W,Key::S)` — argument order
(neg_x, pos_x, neg_y, pos_y), where **up is `neg_y`** in the y-down draw space
(§20), matching stick polarity (stick-up samples negative) so keyboard and stick
contributions agree; `stick(Stick)` is recorded verbatim as a first-class 2D
source, **never** spread into the 1D `stick_x`/`stick_y` halves.

Pong binds P1 `Steer::Move` to `keys_axis(Key::W,Key::S)` and
`stick_y(Stick::Left)`, and P2 `Steer::Move` to `keys_axis(Key::Up,Key::Down)` and
`stick_y(Stick::Left)` — four binding records. Snake spreads its four key-list
button bindings into eight `key(…)` records; hunt binds P1 `Drive::Move` to
`keys_quad(Key::A,Key::D,Key::W,Key::S)` and `stick(Stick::Left)` — two 2D
records.

---

## 15. `[entrypoint]` — the runtime wiring (§07 §1, §14 §4)

Exactly one record for the selected entrypoint, lifting
`funpack_configs/entrypoints.fcfg` (§14 §4): the pipeline ↔ tick ↔ bindings
wiring that a pipeline carries **no** configuration for (§07 §1 — wiring lives in
the entrypoint, never the pipeline):

```
entrypoint NAME pipeline:PIPELINE tick_hz:HZ logical:WxH bindings:BINDINGS
```

- `NAME` is the entrypoint block label (`main`).
- `pipeline:PIPELINE` is the root pipeline (`Pong`) whose flattened order is
  §11.
- `tick_hz:HZ` is the fixed tick rate as an integer Hz (`60` for `60hz`). There
  are no multi-rate ticks (§07 §1); this is the single top-level tick.
- `logical:WxH` is the fixed logical draw space (§20 §3) in integer world units
  (`160x120` for pong, `160x160` for snake), lifted from the entrypoint block's
  required `logical = WxH` (§14 §4). The present pass scales and letterboxes
  this extent to the window; both dimensions are positive integers — a
  zero/negative or malformed extent is refused at fcfg parse and at load.
- `bindings:BINDINGS` names the `bindings` function (§14, §23) whose resolved
  table is §14's `[bindings]`.

`net:` topology (§25) is absent for pong; when present it would add a
`net:TOPOLOGY` field — its absence is the no-netcode capability (§14 §4 derives
the capability set; no `net:` ⇒ netcode off), and adding the field bumps the
schema version (§1).

---

## 16. `[queries]` — state-query declarations with their index requirements (§08 §3, §05 §3)

One record per entrypoint-module `query` declaration, in **source-declaration
order** (v9). A `query` is the §08 §3 read-only declaration form — pure over
`(version, params)`, within-tick memoized — and its prefixed `@index`/`@spatial`
directives are the engine-maintained index structures the runtime must build
and keep current over the world database. The record is the `[functions]` mold
(§9) extended with the requirement lines:

```
query NAME param_count return:TYPE index_count body_count span:MODULE:LINE
param NAME TYPE
…
index KIND THING FIELD
…
node …
…
```

- `param_count`, `return:TYPE`, `body_count`, and `span:MODULE:LINE` read
  exactly as a `[functions]` record's (§9); the body `node` run follows the
  `param` and `index` lines. A query body is a Block by grammar
  (`QueryDecl` admits no body-position `@stub`), so the run is always the plain
  §2.7 statement forest — never a `stub` subtree.
- `index_count` is the number of `index` lines — the §05 §3 requirements the
  query declared. Zero is legal (an index-free query).
- `index KIND THING FIELD` is one declared requirement: `KIND` is the closed
  two-value directive set `index` (engine-maintained reverse/key lookup) or
  `spatial` (deterministic radius/nearest structure); `THING` is the declared
  thing the index ranges over; `FIELD` is the indexed field on that thing. The
  typechecker proved the path (`check_index_paths`), so a reader takes the
  tokens as resolved names.
- Several queries may declare the same `(KIND, THING, FIELD)` requirement; the
  runtime maintains ONE structure per distinct requirement (§08 §3: an index is
  a cache — a pure function of state).
- Cross-module query carry is deliberately absent (the §17 seam carries fns
  only); widening it is a schema bump.

---

## 17. Parsing recipe (runtime, zero funpack imports)

A runtime parses an artifact thus, reading top-to-bottom, never seeking:

1. Read line 1; split on space; assert literal `funpack-artifact` and the integer
   version equals the runtime's built-for version, else **refuse** (§1).
2. For each section in the §3 fixed order: read the `[name N]` header, parse `N`,
   read the section body up to the next `[` header, and split it into `N`
   top-level records using the **single lead-line discipline** (§2.1) — a record
   spans its lead line up to the next lead line. Lead lines are those whose
   leading keyword is *not* in the closed sub-record keyword set (`variant`,
   `field`, `gtag`, `param`, `emit`, `producer`, `consumer`, `set`, `node`,
   `migrate`, `index`). This
   is the **only** parse discipline; the format does not promise a
   second grammar-only reader that derives `N` from declared sub-counts (it cannot
   be sound where a record carries an uncounted run, e.g. a `const`'s body `node`
   lines). Assert the lead-line count equals `N` or **refuse** (§29-style
   exact-match).
3. Within each record, decode each field by its **position** in the record's
   documented signature: a `Fixed` is the raw decimal `i64` (§2.3), an `Int` is
   decimal (§2.2), a `String` is `Lk:bytes` (§2.4), a name is a bare token (§2.6).
   Shape the record's sub-records using its declared scalar counts (`variant_count`,
   `param_count`, `emits_count`, `body_count`); read each body `node` run (§2.7) as
   a pre-order tree, consuming exactly each node's declared `child_count`.
4. Build the in-memory game model (enums, data/signal/thing schemas, function
   bodies, behaviors with their step bodies, the flattened pipeline, the routing
   map, the spawn batch, the binding table, the entrypoint, the query
   declarations with their index requirements) and interpret the carried
   checked-AST nodes per the §09 canonical semantics.

Because every section's `N` is the lead-line count, every record shapes its
sub-records by declared scalar counts, every body `node` declares its `child_count`,
and every field is positionally typed and length-explicit, the parse is total and
the byte layout is unambiguous. No `funpack` source is needed — this document is
the whole contract, bodies included.
