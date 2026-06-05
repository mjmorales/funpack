# funpack artifact format — v1

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
funpack-artifact 1
```

- `schema_version` is the integer after the space (here `1`).
- **Any** change to a section, field, ordering, or encoding **bumps the version**
  — there are no optional fields and no minor/compatible tier.
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
- A top-level record may be **variable-length**: it carries its own count field
  and is followed by exactly that many **sub-records** (e.g. `enum Side - 2` is
  followed by 2 `variant` lines; `thing Paddle false 1 5` is followed by 1 `gtag`
  and 5 `field` lines). A **section body runs to the next `[` header** — header
  lines are the only line class that opens with `[`, so a parser reads a section's
  body unambiguously, then re-derives `N` by counting the **lead** lines (those
  whose keyword is *not* a sub-record keyword). The closed sub-record keyword set
  is: `variant`, `field`, `gtag`, `param`, `emit`, `value`, `producer`,
  `consumer`, `set`. A declared `N` that disagrees with the lead-line count is an
  error (an under- or over-shaped section, §29-style exact-match).

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

---

## 3. Top-level layout

The artifact is the version stamp, then these sections **in this fixed order**.
Each is a `[name N]` header followed by `N` records. A runtime reads them
sequentially; the order is part of the contract.

```
funpack-artifact 1
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
field NAME TYPE DEFAULT
…
```

- `mut` is `true` when the type was declared `mut data` (§03 §7), else `false`.
- `field` records carry: the field `NAME`, its `TYPE` (a name; a generic is
  written `Ctor[Arg]`, e.g. `Ref[Switch]`, `[Goal]` for a list), and `DEFAULT`.
- `DEFAULT` is `-` when the field has no default (it must be supplied at every
  literal), or `=ENCODED` where `ENCODED` is the default value in this format's
  primitive encoding (a `Fixed`, `Int`, `Bool`, or `String` per §2; a composite
  default is its constructor record inline — pong has none). A defaulted field may
  be omitted from a literal (§03 §1), so the runtime applies `DEFAULT` when a
  `setup` Spawn omits it.

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

Pong's things: `Paddle`, `Ball`, `Scoreboard` (all `thing`; pong models the
score as a once-spawned `thing` in `setup`, not a `singleton`).

---

## 9. `[functions]` — pure helpers, module constants, and bindings/setup heads (§02)

One record per module-level `fn`, `let`, the `bindings()` function, and the
`setup()` function, in source order. The function **body** is the serialized
checked AST; this format records the **signature and a body-AST reference**, not a
re-rendering of every expression — the runtime interprets bodies, and the body
node graph is the cheapest loadable form. For v1 the body is recorded as a
**source-span reference** (`module:line`) plus its **return shape**, sufficient
for the runtime to locate and interpret it against the same checked AST:

```
function NAME KIND param_count return:TYPE span:MODULE:LINE
param NAME TYPE
…
```

- `KIND` is one of: `fn` (a pure helper, e.g. `advance`, `goal_side`), `const`
  (a module-level `let`, e.g. `BOARD` — `param_count` is 0 and `return` is the
  value's type), `bindings` (the one §23 `fn() -> Bindings`), `startup` (the one
  §06 Startup head, `setup() -> [Spawn]`).
- `return:TYPE` is the declared return type (a name or generic per §2.6; `[Goal]`
  for a signal list, `[Spawn]` for the setup command list, `Bindings` for the
  binding head, `Option[Side]` for an option).
- `span:MODULE:LINE` is the §15 module name and 1-based source line — **never** a
  filesystem path (§2 purity).
- `param` records carry each parameter's name and type, in declaration order.

The `const` record for `BOARD` additionally carries its evaluated fields as an
inline `value` record per field (`value w =ENCODED`), because a default and a
Spawn may reference `BOARD.w` / `BOARD.h`, so the runtime needs the constant's
fixed bits without re-interpreting its initializer:

```
function BOARD const 0 return:Board span:pong:19
value w =687194767360
value h =515396075520
```

---

## 10. `[behaviors]` — transitions keyed to their pipeline stage (§06 §3, §06 §6)

One record per `behavior`, in **source-declaration order** (the stable order the
node-check ran in). Each carries the stage slot it occupies, its reserved-step
signature, and its `@gtag` set:

```
behavior NAME on:THING stage:STAGE contract:CONTRACT gtag_count param_count emits_count
gtag L4:ball
param NAME TYPE
…
emit TYPE
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
- `behavior:NAME` is the behavior run at this step. A behavior referenced here
  must have a `[behaviors]` record (§10).

This is the derived, never-drifting flattened tree (§07 §3): effect closure
(§12's routing) runs on the same order, so the order recorded here **is** the
order the runtime folds. `startup:` steps (run once before tick 0, §07 §1) are
recorded first with `stage:startup`; the interior Update stages
(`control`, `collision`, `scoring`) follow; the terminal `render:` projection
stage is last.

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
  of the `setup()` body (Paddle P1, Paddle P2, Ball, Scoreboard).
- `set FIELD =ENCODED` carries each supplied field's value in this format's
  encoding: an enum variant as `Side::Left` (a name field, §2.6), a `Fixed` as its
  raw bits (§2.3), an `Int` in decimal (§2.2), a `Vec2` as a nested
  `vec2 x_bits y_bits` record. A field omitted in the source (relying on a
  default, §6) is **not** emitted here — the runtime applies the type's default.

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
- `source:SOURCE` is the device source, recorded as the builder call that produced
  it: `keys_axis(Key::W,Key::S)`, `stick_y(Stick::Left)` — the device names
  (§23 §3) appear **only here**, never in sim logic. Multiple bindings for one
  action stack (§23 §3); each is its own record.

Pong binds P1 `Steer::Move` to `keys_axis(Key::W,Key::S)` and
`stick_y(Stick::Left)`, and P2 `Steer::Move` to `keys_axis(Key::Up,Key::Down)` and
`stick_y(Stick::Left)` — four binding records.

---

## 15. `[entrypoint]` — the runtime wiring (§07 §1, §14 §4)

Exactly one record for the selected entrypoint, lifting
`funpack_configs/entrypoints.fcfg` (§14 §4): the pipeline ↔ tick ↔ bindings
wiring that a pipeline carries **no** configuration for (§07 §1 — wiring lives in
the entrypoint, never the pipeline):

```
entrypoint NAME pipeline:PIPELINE tick_hz:HZ bindings:BINDINGS
```

- `NAME` is the entrypoint block label (`main`).
- `pipeline:PIPELINE` is the root pipeline (`Pong`) whose flattened order is
  §11.
- `tick_hz:HZ` is the fixed tick rate as an integer Hz (`60` for `60hz`). There
  are no multi-rate ticks (§07 §1); this is the single top-level tick.
- `bindings:BINDINGS` names the `bindings` function (§14, §23) whose resolved
  table is §14's `[bindings]`.

`net:` topology (§25) is absent for pong; when present it would add a
`net:TOPOLOGY` field — its absence is the no-netcode capability (§14 §4 derives
the capability set; no `net:` ⇒ netcode off), and adding the field bumps the
schema version (§1).

---

## 16. Parsing recipe (runtime, zero funpack imports)

A runtime parses an artifact thus, reading top-to-bottom, never seeking:

1. Read line 1; split on space; assert literal `funpack-artifact` and the integer
   version equals the runtime's built-for version, else **refuse** (§1).
2. For each section in the §3 fixed order: read the `[name N]` header, parse `N`,
   then read `N` top-level records of that section's grammar — each top-level
   record consumes its own count of sub-records (§2.1), and the section body ends
   at the next `[` header. A runtime may read records by grammar (consuming each
   record's declared sub-count) or read the whole body to the next header and
   split on lead lines; both yield the same `N` top-level records.
3. Decode each field by its **position** in the record's documented signature:
   a `Fixed` is the raw decimal `i64` (§2.3), an `Int` is decimal (§2.2), a
   `String` is `Lk:bytes` (§2.4), a name is a bare token (§2.6).
4. Build the in-memory game model (enums, data/signal/thing schemas, function
   spans, behaviors, the flattened pipeline, the routing map, the spawn batch, the
   binding table, the entrypoint) and interpret the checked AST per the §09
   canonical semantics.

Because every section states its count and every field is positionally typed and
length-explicit, the parse is total and the byte layout is unambiguous. No
`funpack` source is needed — this document is the whole contract.
