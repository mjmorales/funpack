/**
 * tree-sitter-funpack — the .fcfg config-layer grammar
 *
 * Mirrors grammar/fcfg.ebnf (and lexical-core.ebnf via ../common). The config layer:
 * project identity, entrypoint wiring, build targets, the @gtag registry, and
 * dependency declarations. Deliberately simpler than .fun — `key = value` + `use`
 * refs, a fixed block set, no expressions. No comments (14 §2). No greedy postfix, so
 * (unlike .fun) it needs no external scanner; newlines are insignificant `extras`.
 *
 * Section numbers reference fcfg.ebnf.
 */

const lex = require('../common/lexical-core.js');

// newline-OR-comma separated body member (newlines are extras, so each member is
// just optionally comma-trailed — the funpack Sep).
function body(rule) {
  return repeat(seq(rule, optional(',')));
}

module.exports = grammar({
  name: 'fcfg',

  extras: $ => [/\s/],
  word: $ => $.lower_ident,

  conflicts: $ => [
    // `use name` with nothing after is both a single-segment ModuleRef (its
    // _path_seg) and a bare DepDecl (fcfg.ebnf §use); GLR keeps both, disambiguated
    // by what follows (`.` -> module ref, a dep clause -> dep, else a bare dep).
    [$._path_seg, $.dep_decl],
  ],

  rules: {
    // ConfigUnit ------------------------------------------------------------
    source_file: $ => body($.config_item),
    config_item: $ => seq(repeat($.directive), choice($._block, $.use_decl)),

    // §5 (lexical-core) shared metadata directive set. fcfg string args are raw.
    directive: $ => lex.metadataDirective($, $.string),
    _todo_window: $ => lex.todoWindow(),
    _migrate_args: $ => lex.migrateArgs($),

    // Blocks ----------------------------------------------------------------
    _block: $ => choice($.project_block, $.entrypoint_block, $.build_block, $.tags_block),
    project_block: $ => seq('project', $.lower_ident, '{', body($.assignment), '}'),
    entrypoint_block: $ => seq('entrypoint', $.lower_ident, '{', body($.assignment), '}'),
    build_block: $ => seq('build', $.lower_ident, '{', body($.assignment), '}'),
    tags_block: $ => seq('tags', '{', body($.tag_name), '}'),

    assignment: $ => seq(field('key', $.lower_ident), '=', field('value', $.value)),
    tag_name: $ => $.lower_ident,

    // Values: literals + name references only — no expressions (14 §2). NameRef
    // carries the modifier form: net = authoritative | p2p | p2p(rollback) (25 §1).
    value: $ => choice($.string, $.tickrate, $.resolution, $.int, $.bool, $.name_ref),
    name_ref: $ => seq(
      choice($.upper_ident, $.lower_ident),
      optional(choice(
        seq('::', $.upper_ident),
        seq('(', $.lower_ident, ')'),
      )),
    ),

    // use — module ref OR dependency decl (15 §3 / 30 §3) -------------------
    use_decl: $ => seq('use', choice($.module_ref, $.dep_decl)),
    module_ref: $ => seq(
      $._path_seg,
      repeat(seq('.', $._path_seg)),
      optional(seq('.', '{', body($._member_name), '}')),
    ),
    dep_decl: $ => seq($.lower_ident, repeat($.dep_clause)),
    dep_clause: $ => choice(
      seq('version', $.string),
      seq('path', $.string),
      seq('url', $.string),
      seq('hash', $.string),
    ),
    _path_seg: $ => choice($.lower_ident, $.upper_ident),
    _member_name: $ => choice($.lower_ident, $.upper_ident),

    // Tokens (lexical-core §1-§4). fcfg strings are raw (no interpolation). -----
    string: $ => lex.stringLit(null),
    int: $ => token(prec(1, lex.INT)),
    tickrate: $ => token(prec(3, lex.TICKRATE)),
    resolution: $ => token(prec(3, lex.RESOLUTION)),
    bool: $ => choice('true', 'false'),
    lower_ident: $ => token(lex.LOWER_IDENT),
    upper_ident: $ => token(lex.UPPER_IDENT),
  },
});
