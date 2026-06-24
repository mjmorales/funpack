# funpack grammar reference

The complete declaration/expression grammar and edge cases, for when `SKILL.md` isn't enough. Forms
are quoted from the in-repo `grammar/` (`fun.ebnf`, `fun.ll1.md`, `lexical-core.ebnf`) and the
worked examples.

## Reserved & contextual keywords

**Reserved** (always keywords): `import let return assert if else match fn extern type pipeline test
signal behavior and or not with true false`.

**Contextual** (keywords only where they select a production, so `let thing = …` stays legal):
`data enum thing singleton query mut on`. Kind names after a `:` (`Axis`, `Button`, `Num`,
`CollisionLayer`) are contextual too.

**Two identifier classes** (by initial char): `UPPER_IDENT` = types and enum variants;
`LOWER_IDENT` = values, fields, functions, behaviors, stage labels. Module constants are
`UPPER_SNAKE`. This split is load-bearing for LL(1).

## All declaration productions

```
Declaration ::= LetDecl | DataDecl | EnumDecl | ThingDecl | SignalDecl
              | BehaviorDecl | FnDecl | QueryDecl | PipelineDecl | TestDecl | ExternDecl
```

### import
```
ImportDecl ::= 'import' PathSeg ImportTail*
ImportTail ::= '.' PathSeg | '.' '{' MemberName (Sep MemberName)* Sep? '}'
```
Whole module (`import engine.math`), one item (`import engine.math.max`), or a brace group
(`import engine.math.{Fixed, Vec2, clamp}`). A generated seam imports by bare module name
(`import arena.{arena_spawns}`). Absolute only.

### let
```
LetDecl ::= 'let' LetName (':' Type)? '=' Expr                          (* module constant *)
LetStmt ::= 'let' LetBinder (':' Type)? '=' Expr                        (* local binding *)
LetBinder ::= LOWER_IDENT                                               (* single name *)
            | '(' LOWER_IDENT (',' LOWER_IDENT)+ ')'                    (* tuple destructure *)
```
`LetName` is `UPPER_IDENT` (module constants) or `LOWER_IDENT` (locals / asset handles). Type
annotation optional where inferable. The only binding form; locals are immutable.
A **tuple destructure** `let (a, b, …) = expr` binds each name to its position in a return-position
tuple — the threaded-`Rng` consume site `let (value, next) = draw(rng)`. The binder count must equal
the tuple arity; the binders are plain names, not a nested pattern (structural matching stays in
`match`). The `(` after `let` selects this form.

### enum
```
EnumDecl ::= 'enum' UPPER_IDENT TypeParams? KindAsc? '{' Variant (Sep Variant)* Sep? '}'
Variant  ::= UPPER_IDENT | UPPER_IDENT '(' Type (',' Type)* ')' | UPPER_IDENT RecordBody
KindAsc  ::= ':' UPPER_IDENT
```
Plain (`Up`), tuple (`MoveTo(Vec2)`), or struct (`CubicTo{ c1: Vec2, c2: Vec2, to: Vec2 }`)
variants. `TypeParams` (generics) are engine-only. Matched exhaustively. Kind-ascribed input enums:
`enum Steer: Axis { Move }`, `enum Cmd: Button { Jump, Fire }`.

### data
```
DataDecl ::= 'mut'? 'data' UPPER_IDENT TypeParams? KindAsc? RecordBody
RecordBody ::= '{' (Field (Sep Field)* Sep?)? '}'
Field      ::= LOWER_IDENT ':' Type ('=' Expr)?
```
A typed, schema'd, immutable record (ptr-backed COW with structural sharing). `mut data` is the only
sanctioned in-place mutation. `TypeParams`/`: Num` kind are engine-only. Defaults make a field
omittable.

### thing / singleton
```
ThingDecl ::= ('thing' | 'singleton') UPPER_IDENT RecordBody
```
A `thing` owns colocated state; behaviors attach. A `singleton` is engine-spawned before tick 0 and
accessed by type (canonical for exactly-one state — see `funpack-game-model`).

### signal
```
SignalDecl ::= 'signal' UPPER_IDENT RecordBody
```
Plain `data` declared with `signal`; the sole cross-thing channel. Empty payload legal
(`signal Died {}`). Subject to effect closure (every emit needs a downstream consumer).

### behavior
```
BehaviorDecl ::= 'behavior' LOWER_IDENT 'on' UPPER_IDENT '{' StepMethod '}'
StepMethod   ::= Directive* 'fn' LOWER_IDENT '(' ParamList? ')' '->' ReturnType Block
```
The method name is the reserved entry point **`step`** (semantic constraint, not grammar). First
param is `self: T` matching `on T`; the rest are dependency-injected resources/signals/views. Pure:
returns new state and/or command/signal lists.

### fn
```
FnDecl ::= 'fn' LOWER_IDENT '(' ParamList? ')' '->' ReturnType FnBody
FnBody ::= Block | StubExpr
StubExpr ::= '@stub' '(' Type (',' Expr)? ')'
```
Return type mandatory. Value produced only via `return`. A body may be replaced by a typed hole.

### query (spec-defined; rare in examples)
```
QueryDecl ::= 'query' LOWER_IDENT '(' ParamList? ')' '->' ReturnType Block
```
A read-only, memoized world read. May be prefixed `@index(Thing.field)` / `@spatial(Thing.field)`.

### extern (stdlib only — you never author this)
```
ExternFn   ::= 'extern' 'fn' LOWER_IDENT '(' ParamList? ')' '->' ReturnType   // no body
ExternType ::= 'extern' 'type' UPPER_IDENT TypeParams?
```

### pipeline
```
PipelineDecl ::= 'pipeline' UPPER_IDENT '{' StageEntry (Sep StageEntry)* Sep? '}'
StageEntry   ::= Annotation* LOWER_IDENT ':' StageValue
StageValue   ::= '[' (BehaviorRef (Sep BehaviorRef)* Sep?)? ']'   // a behavior list
              | LOWER_IDENT                                       // an engine-stage symbol, e.g. `solve`
              | UPPER_IDENT                                       // a sub-pipeline name (fan-out)
```
Stage labels are documentary; their **order is the contract**. A bare-symbol value (`physics: solve`)
is an engine-owned stage; a `[list]` value is your behaviors; an `UPPER_IDENT` is a sub-pipeline the
engine flattens depth-first. An empty pipeline `pipeline Drift {}` is legal. A stage may be prefixed
`@trace`.

### test
```
TestDecl   ::= 'test' String '{' (TestStmt (Sep TestStmt)* Sep?)? '}'
TestStmt   ::= LetStmt | AssertStmt | IfExpr | MatchExpr | ExprStmt
AssertStmt ::= 'assert' Expr
```
Name is a string literal. `assert` is legal only inside a test. Use engine fixtures — `View.of([…])`,
`Input.empty()`, `Time.at(dt)`, `Nav.of(route)` — to drive a behavior as `name.step(args)`.

## Types
```
Type      ::= NamedType | ListType | FnType | TupleType
NamedType ::= UPPER_IDENT TypeArgs?              // Option[T], Map[K,V], View[Paddle]
TypeArgs  ::= '[' Type (',' Type)* ']'
ListType  ::= '[' Type ']'                       // [Cell], [Spawn]
FnType    ::= 'fn' '(' (Type (',' Type)*)? ')' '->' Type   // fn(A, T) -> A   (combinator params)
TupleType ::= '(' Type (',' Type)+ ')'           // RETURN POSITION ONLY
```
Function-typed `data` fields are rejected (serialization closure). Tuples are not a stored type.

## Expressions

### Statements
```
Statement  ::= LetStmt | ReturnStmt | IfExpr | MatchExpr | ExprStmt
LetStmt    ::= 'let' LOWER_IDENT (':' Type)? '=' Expr
ReturnStmt ::= 'return' Expr
```
Newline terminates a statement; separators are newline **or** `,` (trailing `,` legal). Whitespace
is never counted (a canonical formatter re-indents).

### match
```
MatchExpr ::= 'match' Expr '{' MatchArm (Sep MatchArm)* Sep? '}'
MatchArm  ::= Pattern '=>' (Block | Expr)
Pattern   ::= '_' | LOWER_IDENT | '(' Pattern (',' Pattern)* ')'
            | UPPER_IDENT '::' UPPER_IDENT VariantPat?
VariantPat ::= '(' Pattern (',' Pattern)* ')' | '{' FieldPun (',' FieldPun)* '}'
```
Exhaustive. Patterns: variant-with-binders (`Option::Some(v)`), struct-field-pun
(`Shape2::Box{size} => size`), tuple (`(Option::Some(cell), next) => …`), wildcard `_`. An arm RHS is
a block if it opens `{`, else an expression.

### Record literal, `with`, lambda, if
```
BracedInit ::= UPPER_IDENT '{' (FieldInit (Sep FieldInit)* Sep?)? '}'   // ALWAYS a record literal
FieldInit  ::= LOWER_IDENT ':' Expr
WithExpr   ::= PostfixExpr ('with' '{' FieldInit (Sep FieldInit)* '}')*
Lambda     ::= 'fn' '(' (LOWER_IDENT (',' LOWER_IDENT)*)? ')' '{' Statement '}'   // ONE statement, params untyped
IfExpr     ::= 'if' Expr Block ('else' (Block | IfExpr))?
```
A record literal inside an `if`/`match` head must be parenthesized (a bare `{` after `if`/`match`
opens the block). Lambda body is a single expression / if-expr / `return` — never a multi-statement
block; put real logic in a named `fn`. `else` is required when `if` is used as an expression.

### Postfix / calls
```
PostfixExpr ::= Atom PostfixOp*
PostfixOp   ::= '.' (LOWER_IDENT | UPPER_IDENT) CallArgs?   // member / UFCS / associated fn or const
             | '[' Expr ']'                                  // index (prefer xs.get(i) -> Option)
             | CallArgs
CallArgs    ::= '(' (Expr (',' Expr)*)? ')'
```
`recv.f(x)` resolves as a field of `recv`, then UFCS (a `fn` whose first param `self` is `recv`'s
type), then an associated fn in the receiver type's module. `Type.f(x)` / `Type.CONST` are
associated. Leading-dot builder chains line-join implicitly across newlines.

### Operator precedence (low → high)
`or` → `and` → `== !=` → `< <= > >=` → `+ -` → `* / %` → unary (`not`, `-`) → `with` →
call/index/member → atom.

### One concept per glyph
`=` binding only · `:` type ascription / field separator · `::` enum-variant selector only · `.`
member/UFCS/associated · `->` fn return type · `=>` match arm · `[ ]` list/index/generic · `{ }`
block/record/body · `( )` group/args/return-tuple · `@` directive · `with` record-update.
`and`/`or`/`not` are words. No `&&`/`||`/`!`, no `<>` generics, no pointer/deref sigils, no `..`
range (the level DSL has ranges; `.fun` has no loops), no string `+`.

## Directives (the closed set)
```
Directive ::= '@doc'     '(' String ')'
            | '@gtag'    '(' String (',' String)* ')'
            | '@todo'    '(' String ',' Window ')'
            | '@index'   '(' FieldPath ')'        // query-prefix only
            | '@spatial' '(' FieldPath ')'        // query-prefix only
            | '@migrate' '(' MigrateArgs ')'      // field/type/variant rename or retype
            | '@expose' | '@server' | '@client'
            | '@break' '(' Expr ')' | '@log' '(' Expr ')' | '@watch' '(' Expr ')' | '@trace'
            | '@stub' '(' Type (',' Expr)? ')'
FieldPath ::= UPPER_IDENT '.' LOWER_IDENT
Window    ::= INT('h'|'d'|'w'|'mo'|'q'|'y') | ISO_DATE | INT 'builds' | 'T-' DIGITS
```
`@index`/`@spatial` prefix a `query` only (their `FieldPath` head must name a declared
`thing`/`singleton`). `@server`/`@client` assign a network realm (usually inferred). The debug
family `@break`/`@log`/`@watch`/`@trace` are dev-only, release-forbidden, and task-registered like
`@stub` — they never alter logic. `@log(expr)` is the typed replacement for `print` (emits queryable
NDJSON).

## The LL(1) "why"

Every declaration opens with a unique keyword → one token of lookahead selects the production, no
backtracking. The decisive choice making expressions LL(1): **command-wrap is call syntax**
(`Spawn(thing)`, `Despawn()`), so `UPPER_IDENT '{'` is unambiguously a record literal. Two lexical
rules underpin it: the upper/lower identifier split, and "no record literal in a control-flow head"
(parenthesize one there).

## Structural floors (compile errors, not warnings)

The compiler caps complexity with **fixed constants, no per-site waiver**: cyclomatic ≤ 10, nesting
≤ 3, function ≤ 40 statements, parameters ≤ 5, plus a duplication ceiling. The only sanctioned
escape for *incomplete* (never *complex*) code is `@stub`. See the `funpack-determinism` skill for
the full gate list.

## Forms that are spec/grammar-real but not shown in examples

`query` declarations, `mut data`, `Map[K,V]` usage in game code, `@expose`, `@todo`, `@migrate`. Use
the grammar forms above as canonical, but expect your toolchain to be the final arbiter.
