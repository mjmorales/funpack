/**
 * tree-sitter-funpack — the .fun language grammar
 *
 * Mirrors grammar/fun.ebnf (and lexical-core.ebnf via ../common). This is an
 * EDITOR parser, deliberately separate from the Odin compiler frontend; it favours
 * error-tolerant highlighting over byte-exact LL(1) parsing. Newlines are treated as
 * whitespace `extras` (see common/lexical-core.js header) rather than significant
 * separators, so block/record members just repeat with an optional comma.
 *
 * Section numbers below reference fun.ebnf.
 */

const lex = require('../common/lexical-core.js');

// Expression precedence — the fun.ebnf cascade (§14), low → high, encoded as a
// tree-sitter precedence table instead of one rule per level (same precedence,
// fewer nodes). WITH binds tighter than unary and looser than postfix (the EBNF
// order UnaryExpr → WithExpr → PostfixExpr).
const PREC = {
  or: 1,
  and: 2,
  eq: 3,
  rel: 4,
  add: 5,
  mul: 6,
  unary: 7,
  with: 8,
  postfix: 9,
};

// comma-delimited list, optional trailing comma (call/type args, tuples, params).
function commaSep1(rule) {
  return seq(rule, repeat(seq(',', rule)), optional(','));
}
// newline-OR-comma separated body member (record/enum/pipeline/match/with/braced).
// Newlines are extras (invisible), so each member is just optionally comma-trailed.
function body(rule) {
  return repeat(seq(rule, optional(',')));
}

module.exports = grammar({
  name: 'fun',

  // Whitespace incl. newlines are insignificant; .fun has no comments (02 §1, P6).
  extras: $ => [/\s/],

  // Zero-width lookahead from src/scanner.c: asserts the next token is on the SAME
  // line as the previous one. Gates postfix call/index so a newline terminates the
  // expression (lexical-core §8) instead of greedily extending it across arms/stmts.
  externals: $ => [$._same_line],

  // Single word token for contextual-keyword extraction: `data enum thing … on`
  // are contextual (06 §1), so they must fall back to lower_ident off keyword
  // position. tree-sitter's keyword extraction off `word` gives this for free.
  word: $ => $.lower_ident,

  conflicts: $ => [
    // A leading `@doc(...)` is either the module doc (15 §2) or a directive on the
    // first declaration; resolved by position in the compiler, ambiguous to GLR.
    [$.module_doc, $.directive],
    // Record-literal-vs-block in a control-flow head: `if X { … }` — the `{` is the
    // block, never a `X{…}` record literal (fun.ll1.md §C). The shift (into
    // braced_init) vs reduce (bare upper_atom, `{` starts the block) is internal to
    // upper_atom; GLR keeps both and the invalid head-record-literal branch dies.
    [$.upper_atom],
  ],

  rules: {
    // §1 Compilation unit ---------------------------------------------------
    source_file: $ => seq(
      optional($.module_doc),
      repeat($.import_decl),
      repeat($.directed_decl),
    ),

    module_doc: $ => seq('@doc', '(', $.raw_string, ')'),

    directed_decl: $ => seq(repeat($.annotation), $._declaration),

    annotation: $ => choice($.directive, $.debug_directive),

    // §5 (lexical-core) the closed metadata directive set + §28 debug family.
    // Directive string args are RAW (a doc/tag/todo never interpolates).
    directive: $ => lex.metadataDirective($, $.raw_string),
    _todo_window: $ => lex.todoWindow(),
    _migrate_args: $ => lex.migrateArgs($),

    debug_directive: $ => choice(
      seq('@break', '(', $.expression, ')'),
      seq('@log', '(', $.expression, ')'),
      seq('@watch', '(', $.expression, ')'),
      '@trace',
    ),

    _declaration: $ => choice(
      $.let_decl, $.data_decl, $.enum_decl, $.thing_decl, $.signal_decl,
      $.behavior_decl, $.fn_decl, $.query_decl, $.pipeline_decl, $.test_decl,
      $.extern_decl,
    ),

    // §2 Imports ------------------------------------------------------------
    import_decl: $ => seq('import', $._path_seg, repeat($.import_tail)),
    import_tail: $ => choice(
      seq('.', $._path_seg),
      seq('.', '{', lex.listOf($._member_name), '}'),
    ),
    _path_seg: $ => choice($.lower_ident, $.upper_ident),
    _member_name: $ => choice($.lower_ident, $.upper_ident),

    // §3 let ----------------------------------------------------------------
    let_decl: $ => seq('let', $._let_name, optional(seq(':', $.type)), '=', $.expression),
    _let_name: $ => choice($.upper_ident, $.lower_ident),

    // §4 data / enum --------------------------------------------------------
    data_decl: $ => seq(optional('mut'), 'data', $.upper_ident, optional($.type_params), optional($.kind_asc), $.record_body),
    enum_decl: $ => seq('enum', $.upper_ident, optional($.type_params), optional($.kind_asc), '{', body($.variant), '}'),

    variant: $ => seq(repeat($.directive), $.upper_ident, optional($.variant_payload)),
    variant_payload: $ => choice(
      seq('(', commaSep1($.type), ')'),
      seq('{', body($.field_decl), '}'),
    ),

    type_params: $ => seq('[', commaSep1($.upper_ident), ']'),
    kind_asc: $ => seq(':', $.upper_ident),

    // §5 thing / singleton / signal ----------------------------------------
    thing_decl: $ => seq(choice('thing', 'singleton'), $.upper_ident, $.record_body),
    signal_decl: $ => seq('signal', $.upper_ident, $.record_body),
    record_body: $ => seq('{', body($.field_decl), '}'),
    field_decl: $ => seq(repeat($.annotation), $.lower_ident, ':', $.type, optional(seq('=', $.expression))),

    // §6 behavior -----------------------------------------------------------
    behavior_decl: $ => seq('behavior', $.lower_ident, 'on', $.upper_ident, '{', $.step_method, '}'),
    step_method: $ => seq(repeat($.directive), 'fn', $.lower_ident, '(', optional($.param_list), ')', '->', $.return_type, $.block),

    // §7 fn / query ---------------------------------------------------------
    fn_decl: $ => seq('fn', $.lower_ident, '(', optional($.param_list), ')', '->', $.return_type, $._fn_body),
    _fn_body: $ => choice($.block, $.stub_expr),
    query_decl: $ => seq('query', $.lower_ident, '(', optional($.param_list), ')', '->', $.return_type, $.block),

    param_list: $ => commaSep1($.param),
    param: $ => seq($.lower_ident, ':', $.type),
    return_type: $ => $.type,
    tuple_type: $ => seq('(', $.type, repeat1(seq(',', $.type)), ')'),

    // §8 extern -------------------------------------------------------------
    extern_decl: $ => seq('extern', choice($.extern_fn, $.extern_type)),
    extern_fn: $ => seq('fn', $.lower_ident, '(', optional($.param_list), ')', '->', $.return_type),
    extern_type: $ => seq('type', $.upper_ident, optional($.type_params)),

    // §9 pipeline -----------------------------------------------------------
    pipeline_decl: $ => seq('pipeline', $.upper_ident, '{', body($.stage_entry), '}'),
    stage_entry: $ => seq(repeat($.annotation), $.lower_ident, ':', $._stage_value),
    _stage_value: $ => choice(
      seq('[', optional(lex.listOf($.behavior_ref)), ']'),
      $.lower_ident,
      $.upper_ident,
    ),
    behavior_ref: $ => $.lower_ident,

    // §10 test --------------------------------------------------------------
    test_decl: $ => seq('test', $.raw_string, '{', repeat($._statement_or_assert), '}'),
    _statement_or_assert: $ => choice($.assert_stmt, $._statement),
    assert_stmt: $ => seq('assert', $.expression),

    // §11 Types. fun.ebnf restricts TupleType to return position, but the stdlib
    // surface uses tuple element types inside lists ([(Cell, String, Bool)]), so the
    // real compiler admits tuple_type as a general type — modelled here.
    type: $ => choice($.named_type, $.list_type, $.fn_type, $.tuple_type),
    named_type: $ => seq($.upper_ident, optional($.type_args)),
    type_args: $ => seq('[', commaSep1($.type), ']'),
    list_type: $ => seq('[', $.type, ']'),
    fn_type: $ => seq('fn', '(', optional(commaSep1($.type)), ')', '->', $.type),

    // §12 Statements & blocks ----------------------------------------------
    block: $ => seq('{', repeat($._statement), '}'),
    _statement: $ => choice($.let_stmt, $.return_stmt, $.expression),
    let_stmt: $ => seq('let', $._let_binder, optional(seq(':', $.type)), '=', $.expression),
    _let_binder: $ => choice($.lower_ident, $.tuple_binder),
    tuple_binder: $ => seq('(', $.lower_ident, repeat1(seq(',', $.lower_ident)), ')'),
    return_stmt: $ => seq('return', $.expression),

    // §13 Patterns ----------------------------------------------------------
    pattern: $ => choice(
      $.wildcard,
      $.lower_ident,
      seq('(', commaSep1($.pattern), ')'),
      seq($.upper_ident, '::', $.upper_ident, optional($.variant_pat)),
    ),
    wildcard: $ => '_',
    variant_pat: $ => choice(
      seq('(', commaSep1($.pattern), ')'),
      seq('{', commaSep1($.lower_ident), '}'),
    ),

    // §14 Expressions -------------------------------------------------------
    expression: $ => $._expression,
    _expression: $ => choice(
      $.binary_expression,
      $.unary_expression,
      $.with_expression,
      $._postfix_expression,
    ),

    binary_expression: $ => {
      const table = [
        ['or', PREC.or],
        ['and', PREC.and],
        ['==', PREC.eq], ['!=', PREC.eq],
        ['<', PREC.rel], ['<=', PREC.rel], ['>', PREC.rel], ['>=', PREC.rel],
        ['+', PREC.add], ['-', PREC.add],
        ['*', PREC.mul], ['/', PREC.mul], ['%', PREC.mul],
      ];
      return choice(...table.map(([op, p]) => prec.left(p, seq(
        field('left', $._expression),
        field('operator', op),
        field('right', $._expression),
      ))));
    },

    unary_expression: $ => prec.right(PREC.unary, seq(
      field('operator', choice('not', '-')),
      $._expression,
    )),

    with_expression: $ => prec.left(PREC.with, seq($._expression, 'with', $.with_body)),
    with_body: $ => seq('{', body($.field_init), '}'),
    field_init: $ => seq($.lower_ident, ':', $.expression),

    _postfix_expression: $ => choice(
      $._atom,
      $.member_expression,
      $.index_expression,
      $.call_expression,
    ),
    // member `.` may cross a newline (leading-dot join); the trailing call_args may
    // not (it is same-line, like any call).
    member_expression: $ => prec.left(PREC.postfix, seq(
      $._expression, '.', field('member', choice($.lower_ident, $.upper_ident)),
      optional(seq($._same_line, $.call_args)),
    )),
    index_expression: $ => prec.left(PREC.postfix, seq($._expression, $._same_line, '[', $.expression, ']')),
    call_expression: $ => prec.left(PREC.postfix, seq($._expression, $._same_line, $.call_args)),
    call_args: $ => seq('(', optional(lex.listOf($.expression)), ')'),

    // §15 Atoms -------------------------------------------------------------
    _atom: $ => choice(
      $._literal,
      $.upper_atom,
      $.lower_ident,
      $.list_literal,
      $.paren_expression,
      $.lambda,
      $.if_expr,
      $.match_expr,
      $.stub_expr,
    ),

    _literal: $ => choice($.int, $.fixed, $.float, $.string, $.bool, $.tickrate),
    int: $ => token(prec(1, lex.INT)),
    fixed: $ => token(prec(2, lex.FIXED)),
    float: $ => token(prec(3, lex.FLOAT)),
    tickrate: $ => token(prec(3, lex.TICKRATE)),
    bool: $ => choice('true', 'false'),
    // Interpolating string (expression position) vs raw string (directive/test args).
    string: $ => lex.stringLit($.expression),
    raw_string: $ => lex.stringLit(null),

    // UpperAtom: variant value (Side::Left / Draw::Rect{…}) | braced init (Vec2{…})
    // | bare type/constant (Fixed, BOARD). Tuple-payload Option::Some(x) is a call
    // (postfix CallArgs) on the bare `Option::Some`.
    upper_atom: $ => seq($.upper_ident, optional(choice(
      seq('::', $.upper_ident, optional($.braced_init)),
      $.braced_init,
    ))),
    braced_init: $ => seq('{', body($.field_init), '}'),

    list_literal: $ => seq('[', optional(lex.listOf($.expression)), ']'),
    paren_expression: $ => seq('(', $.expression, repeat(seq(',', $.expression)), ')'),

    lambda: $ => seq('fn', '(', optional(commaSep1($.lower_ident)), ')', '{', $._statement, '}'),
    stub_expr: $ => seq('@stub', '(', $.type, optional(seq(',', $.expression)), ')'),

    if_expr: $ => prec.right(seq('if', $.expression, $.block, optional(seq('else', choice($.block, $.if_expr))))),
    match_expr: $ => seq('match', $.expression, '{', body($.match_arm), '}'),
    match_arm: $ => seq($.pattern, '=>', choice($.block, $.expression)),

    // Tokens (lexical-core §1-§2). lower_ident is the `word`.
    lower_ident: $ => token(lex.LOWER_IDENT),
    upper_ident: $ => token(lex.UPPER_IDENT),
  },
});
