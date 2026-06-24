# `.fun` — LL(1) analysis

Companion to [`fun.ebnf`](fun.ebnf). Enforces the spec's LL(1) claim (02 §1) with
FIRST/FOLLOW sets, a predict table, and the discrepancies — the points where the
surface as the **examples** show it is not pure-CFG LL(1), with options and
trade-offs. Examples lead; the resolutions are recorded here (01 §5).

**Verdict.** With the two lexical decisions in §1, `.fun` is **LL(1)** — the
statement layer strictly (unique leading keywords), expressions via the precedence
cascade. **No backtracking; max one token of lookahead.** Discrepancy A (the braced
initializer) is resolved at the language level — command-wrap is call syntax
(`Spawn(thing)`, `Despawn()`), so a brace is always a record literal
([§5 A](#a-braced-initializer-resolved-via-call-syntax-a2)). Two standard
conventions support the property (B, C); D (the `@todo` window grammar) is now
specified (§5 D).

---

## 1. The two lexical decisions LL(1) rests on

### 1.1 Two identifier classes (`UPPER_IDENT` / `LOWER_IDENT`)

Casing is a hard rule (02 §1), so the lexer decides the class. Only the Upper/lower
split is needed to parse (the three style bands are a lint). This resolves two
would-be conflicts with no left-factoring:

| Would-be conflict | Resolved because |
|---|---|
| `match side { … }` — record literal or scrutinee + arms? | a record literal is `UPPER_IDENT '{'`; `side` is `LOWER_IDENT`. |
| pattern `next` (binder) vs `Option::Some` (variant) | binders are `LOWER_IDENT`, variants `UPPER_IDENT '::' …` → disjoint FIRST. |

### 1.2 No record literal in a control-flow head

A record literal is a primary (`UPPER_IDENT '{'`), so only a bare leading
`UPPER_IDENT` before `{` can be misread (`if ENABLED {`, an `UPPER_SNAKE` `Bool`).
Resolution (Rust/Swift precedent): in an `if`/`match` head a `{` always opens the
block/arms; a record literal there must be parenthesized. Resets inside `(`/`[`.
A no-parser-mode alternative (a third `CONST_IDENT` class) is in [§5 C](#c-record-literal-in-a-control-flow-head).

### 1.3 Significant newlines + implicit line joining

`NEWLINE` is the statement terminator; it is suppressed inside `(`/`[` and across
leading-dot builder chains ([`lexical-core.ebnf`](lexical-core.ebnf) §8). Lexer-level;
it does not affect the analysis below.

---

## 2. Terminals

Reserved keywords: `import let return assert if else match fn extern type pipeline
test signal behavior and or not with true false`.
Contextual keywords (reserved only where they select a production): `data enum thing
singleton query mut on`.
Punctuation: `@ ( ) [ ] { } , : :: . -> => = == != < <= > >= + - * / %`.
Lexer classes: `UPPER_IDENT LOWER_IDENT INT FIXED FLOAT String TICKRATE`, the
keyword `_`, and `BOOL` (`true`/`false`).

---

## 3. FIRST sets (the decision points)

`ℓ` = `LOWER_IDENT`, `Ʉ` = `UPPER_IDENT`.

```
FIRST(Declaration)    = { let, mut, data, enum, thing, singleton, signal,
                          behavior, fn, query, pipeline, test, extern }    all distinct
FIRST(Statement)      = { let, return, if, match } ∪ FIRST(ExprStmt)
FIRST(TestStmt)       = { let, assert, if, match } ∪ FIRST(ExprStmt)
FIRST(Type)           = { Ʉ, '[', fn }
FIRST(ReturnType)     = { Ʉ, '[', fn, '(' }
FIRST(Pattern)        = { '_', ℓ, '(', Ʉ }
FIRST(VariantPat)     = { '(', '{' }
FIRST(StageValue)     = { '[', ℓ, Ʉ }
FIRST(FnBody)         = { '{', '@' }              ('@' = @stub only)
FIRST(MatchArm-RHS)   = { '{' } ∪ FIRST(Expr)     ('{' ⇒ Block, else Expr)

FIRST(Atom) = { INT, FIXED, FLOAT, String, true, false, TICKRATE,   (Literal)
                Ʉ, ℓ, '[', '(', fn, if, match, '@' }                (the 8 other atoms)
FIRST(Expr) = { not, '-' } ∪ FIRST(Atom)
```

The expression cascade's per-level operator sets are pairwise disjoint and form the
precedence ladder (02 §3): `or` · `and` · `== !=` · `< <= > >=` · `+ -` · `* / %` ·
unary `{not, -}` · `with` · postfix `{ . [ ( }` · atom.

---

## 4. Predict / conflict table

Letters reference §5. "✔" = single-token, disjoint.

| Nonterminal | Selected by | Verdict |
|---|---|---|
| `CompilationUnit` | leading `@doc` ⇒ ModuleDoc iff next is `import`/decl | **B** (1-token lookahead) |
| `DirectedDecl` | `@` ⇒ Annotation; decl keyword ⇒ Declaration | ✔ |
| `Annotation` | the `@name` (metadata `Directive` or `DebugDirective`) — finite, distinct | ✔ |
| `Declaration` | leading keyword (12 distinct) | ✔ |
| `ImportTail` (after `.`) | `Ʉ`/`ℓ` ⇒ PathSeg; `{` ⇒ member group | ✔ |
| `DataDecl` | `mut`/`data` | ✔ |
| `KindAsc?` | `:` ⇒ KindAsc; `{`/`[` ⇒ skip | ✔ |
| `TypeParams?` | `[` ⇒ params; else skip | ✔ |
| `VariantPayload?` | `(`⇒tuple; `{`⇒struct; else ε | ✔ |
| `RecordBody` | `}`⇒empty; `@`/`ℓ`⇒FieldDecl | ✔ |
| `FieldDecl ('=' …)?` | `=`⇒default; Sep/`}`⇒skip | ✔ |
| `FnBody` | `{`⇒Block; `@`⇒StubExpr | ✔ |
| `ReturnType` | `(`⇒TupleType; else Type | ✔ |
| `Type` | `Ʉ`⇒Named; `[`⇒List; `fn`⇒FnType | ✔ |
| `NamedType TypeArgs?` | `[`⇒args; else skip | ✔ |
| `StageValue` | `[`/`ℓ`/`Ʉ` | ✔ |
| `Statement` / `TestStmt` | `let`/`return`/`assert`/`if`/`match` first; else ExprStmt | ✔ (if/match pulled out) |
| `LetBinder` (after `let`) | `(`⇒tuple destructure; `ℓ`⇒single name | ✔ (1-token, no backtrack) |
| `Pattern` | `_`/`ℓ`/`(`/`Ʉ` | ✔ (§1.1) |
| `VariantPat` | `(`/`{` | ✔ |
| Expr cascade | lookahead ∈ this level's op set | ✔ |
| `UnaryExpr` | `not`/`-` ⇒ prefix; else WithExpr | ✔ |
| `Atom` | FIRST table §3 | ✔ |
| `UpperAtom` tail | `::`⇒variant (then `{`⇒struct payload); `{`⇒BracedInit; else ε | **C** |
| `PostfixExpr` loop | `.`/`[`/`(` ⇒ continue | ✔ |
| `.`-member `CallArgs?` | `(`⇒call; else stop | ✔ |
| `GroupOrTuple` | after `(`Expr: `,`⇒tuple; `)`⇒group | ✔ |
| `MatchArm` RHS | `{`⇒Block; else Expr | ✔ |
| `IfExpr` `else?` | `else`⇒branch; else stop (dangling: nearest) | ✔ |
| `BracedInit` body | `}`⇒empty; `ℓ`⇒FieldList | ✔ (**A** resolved — command-wrap is a call) |

> **if/match pullout.** `Atom` includes `IfExpr`/`MatchExpr`, so `FIRST(Atom)` holds
> `if`/`match`. At statement position they are dispatched to the if/match constructs
> first, and `ExprStmt` is taken only for the other FIRST(Atom) tokens — i.e.
> `FIRST(ExprStmt-as-used) = FIRST(Atom) \ {if, match}`. A value-producing if/match
> is still an expression elsewhere (`return if c { … } else { … }`).

---

## 5. Discrepancies & resolutions

### A. Braced initializer — RESOLVED via call syntax (A2)

A `{ … }` after `UPPER_IDENT` was either a **field list** (record literal) or a
**single positional expression** (the command-wrap). When the first body element was
a bare `LOWER_IDENT`, `slot:…` (field) and `snake` (positional) were
indistinguishable until the next token (`:` vs not) — i.e. LL(2):

```funpack
Goal{side: Side::Left}        // field list
Spawn{ snake }   Despawn{}    // was: positional wrap (the clash)
```

**Resolution (applied): A2 — command-wrap is call syntax.** `Spawn(thing)`,
`Despawn()`, parsed by `PostfixExpr`/`CallArgs`. A brace is now *always* a record
literal, so `.fun` is **strictly LL(1), no peek**. Propagated across the repo to
hold the contract "grammar-include only what runs" (01 §5): `fun.ebnf` §15.1, spec
`02 §2`, `stdlib/engine/world.fun`, and 28 example sites (25 `Spawn`, 3 `Despawn`).

| # | Resolution | LL(1)? | Surface | Trade-off |
|---|---|---|---|---|
| **A2** ✅ applied | Command-wrap as a call: `Spawn(thing)`, `Despawn()`. `Ʉ '{'…'}'` is always a field list. | **pure** | rewrote 28 sites + 02 §2 | The "a command wraps a value" visual moves from braces to parens — uniform with every other call. |
| A1 | One-token peek: body starting `ℓ ':'` ⇒ FieldList, else PositionalExpr. | LL(2) at one atom | none | Keeps brace-wrap; costs the pure-LL(1) badge. The prior default. |
| A3 | Reserve command names as a token class. | pure | medium | `Draw::Rect{…}` is a command yet uses fields — the split is wrap-vs-fields. Rejected. |
| A4 | Label the wrap: `Spawn{ it: thing }`. | pure | medium | Contradicts "positionally, no field name" (02 §2). Rejected. |

### B. Module `@doc` vs first declaration's `@doc`

A leading `@doc` documents the module (15 §2), but `@doc` also prefixes
declarations. Resolution: the first `@doc` is the module doc iff the construct after
it is an `import` or a declaration's directive run — one symbol of lookahead past the
`@doc(...)` group; imports carry no directives. Benign.

### C. Record literal in a control-flow head

`UpperAtom`'s `BracedInit?` puts `{` in its FIRST, and `if`/`match` put `{` in the
FOLLOW of the head — a clash only for a bare `UPPER_IDENT` head (`if ENABLED {`).
Resolved by the §1.2 control-head rule. *Alternative:* a third `CONST_IDENT` class
(`UPPER_SNAKE`), so only `TYPE_IDENT` (UpperCamel) takes a `BracedInit` and no parser
mode is needed — cost: single-letter type vars (`T`) lex as `CONST_IDENT` and must be
accepted in type position. Two classes + the control-head rule is the mainstream
choice and what `lexical-core.ebnf` specifies.

### D. `@todo` window grammar — resolved

Now specified: the four forms (relative duration / absolute date / build count /
task ref `T-NNNN`) in spec `05 §2`, reconciled with `29 §4`, and in
[`lexical-core.ebnf`](lexical-core.ebnf) §6. LL(1) by disjoint FIRST (trailing
time-unit / `builds` / two `-` / leading `T-`).

---

## 6. Expression cascade ≡ Pratt

The spec specifies expressions operationally as a Pratt parser (02 §1); `fun.ebnf`
§14 gives the equivalent stratified grammar (one nonterminal per precedence band).
Same language; the cascade is used here because it is manifestly LL(1) — each band's
continue/stop is one lookahead against a disjoint operator set. An implementer may
use either.
