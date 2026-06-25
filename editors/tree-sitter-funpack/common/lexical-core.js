/**
 * tree-sitter-funpack — shared lexical core
 *
 * Mirrors grammar/lexical-core.ebnf: the token classes and lexical conventions
 * shared by every funpack file type. Each per-type grammar.js `require`s this module
 * and composes its declaration/expression layer on top, so token shapes are defined
 * once (the EBNF's "imports lexical-core.ebnf" relationship, in code).
 *
 * Two kinds of export:
 *   - TOKEN regexes (lexer-level, no grammar dependency): the identifier classes and
 *     numeric/literal forms (§1-§4).
 *   - rule BUILDERS that take the grammar's `$` (and, where the EBNF leaves a hole, the
 *     hole rule) and return a tree-sitter rule: the string-with-interpolation literal
 *     and the closed metadata directive set (§4, §5). These call the tree-sitter DSL
 *     globals (seq/choice/repeat/...), which are in scope when the builder runs during
 *     grammar() construction.
 *
 * Newlines (§8): funpack's separator is newline-or-comma with implicit line joining.
 * A faithful newline-significant lexer needs an external scanner; for an editor
 * highlighter we deliberately treat newlines as whitespace `extras` and make element
 * separators optional commas (see README "Simplifications"). This keeps the grammar
 * scanner-free and still parses real sources with zero ERROR nodes.
 */

// ---------------------------------------------------------------------------
// §1-§2 Identifiers — TWO disjoint classes selected by the initial character.
// The Upper/lower split is load-bearing (it is what keeps .fun LL(1)).
// ---------------------------------------------------------------------------
const UPPER_IDENT = /[A-Z][A-Za-z0-9_]*/;
const LOWER_IDENT = /[a-z_][A-Za-z0-9_]*/;

// ---------------------------------------------------------------------------
// §3 Numeric literals — type is directed by FORM, never by promotion. The
// suffixed/compound forms must out-rank the bare forms at the lexer, so the
// importing grammar wraps each in `token(prec(N, ...))` with FLOAT/TICKRATE/
// RESOLUTION above FIXED above INT. The bare regexes live here; precedence is
// applied at the use site to keep this module DSL-call-free at load time.
// ---------------------------------------------------------------------------
const INT = /[0-9]+/;
const FIXED = /[0-9]+\.[0-9]+/;
const FLOAT = /[0-9]+\.[0-9]+f/;
const TICKRATE = /[0-9]+hz/;
const RESOLUTION = /[0-9]+x[0-9]+/;

// §4 Booleans are keyword tokens, surfaced as a rule for highlighting.
const BOOL = ['true', 'false'];

// ---------------------------------------------------------------------------
// §8 Separator combinators. The EBNF's `Sep` is (NEWLINE | ',')+; with newlines
// as extras we model the comma as an OPTIONAL separator between repeated items,
// which accepts newline-, comma-, and mixed-separated lists alike.
// ---------------------------------------------------------------------------
function sepBy1(separator, rule) {
  return seq(rule, repeat(seq(separator, rule)));
}
function sepBy(separator, rule) {
  return optional(sepBy1(separator, rule));
}
/** comma-or-newline separated, trailing separator allowed (the funpack Sep). */
function listOf(rule) {
  return seq(rule, repeat(seq(optional(','), rule)), optional(','));
}

// ---------------------------------------------------------------------------
// §4 String literal with `{ hole }` interpolation. STRING_TEXT is any run that
// is not an unescaped '"' '{' '}'; `\{` `\}` escape a brace; the importing
// grammar fills the hole (.fun -> Expr, .fui -> Path). Pass `holeRule = null`
// for an opaque string (config/manifest treat `{ }` as ordinary text).
//
// String inner pieces are `token.immediate` so the global whitespace `extras`
// do not leak into string content.
// ---------------------------------------------------------------------------
function stringLit(holeRule) {
  const text = token.immediate(prec.right(/[^"{}\\]+/));
  const escapedBrace = token.immediate(/\\[{}]/);
  const pieces = holeRule
    ? choice(text, escapedBrace, seq(token.immediate('{'), field('interpolation', holeRule), '}'))
    : choice(text, escapedBrace, token.immediate(/[{}]/));
  return seq('"', repeat(pieces), token.immediate('"'));
}

// ---------------------------------------------------------------------------
// §5 The CLOSED metadata directive set, shared by .fun and .fcfg (the DEBUG
// family @break/@log/@watch/@trace and the typed-hole @stub take a host
// Expr/Type, so they are defined in fun/grammar.js, not here). `str` is the
// grammar's string rule; `$` exposes named-ident rules the args reference.
// ---------------------------------------------------------------------------
function metadataDirective($, str) {
  const fieldPath = seq($.upper_ident, '.', $.lower_ident); // Thing.field
  return choice(
    seq('@doc', '(', str, ')'),
    seq('@gtag', '(', listOf(str), ')'),
    seq('@todo', '(', str, ',', $._todo_window, ')'),
    seq('@index', '(', fieldPath, ')'),
    seq('@spatial', '(', fieldPath, ')'),
    seq('@migrate', '(', $._migrate_args, ')'),
    '@expose', '@server', '@client',
  );
}

// §6 The @todo window forms (Duration | BuildCount | Date | TaskRef), exposed
// as a builder so each grammar can name the node `todo_window`.
function todoWindow() {
  return choice(
    token(/[0-9]+(h|d|w|mo|q|y)/),     // Duration: 30d, 72h, 2w
    token(/[0-9]+builds/),             // BuildCount: 50builds
    token(/[0-9]+-[0-9]+-[0-9]+/),     // Date: 2026-09-01
    token(/T-[0-9]+/),                 // TaskRef: T-0042
  );
}

// §5 @migrate arguments, exposed as a builder (`from:`/`with:` contextual keys).
function migrateArgs($) {
  return choice(
    seq('from', ':', $.string, optional(seq(',', 'with', ':', $.lower_ident))),
    seq('with', ':', $.lower_ident),
  );
}

module.exports = {
  UPPER_IDENT,
  LOWER_IDENT,
  INT,
  FIXED,
  FLOAT,
  TICKRATE,
  RESOLUTION,
  BOOL,
  sepBy1,
  sepBy,
  listOf,
  stringLit,
  metadataDirective,
  todoWindow,
  migrateArgs,
};
