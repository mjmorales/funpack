/**
 * tree-sitter-funpack — lexical stub grammar factory
 *
 * A baseline highlighter for a file type whose FULL grammar is not yet authored. It
 * recognises comments, strings, numbers, identifiers, and punctuation, and consumes
 * anything else through a low-precedence catch-all so it never emits ERROR nodes.
 * This gives immediate comment/string/number colouring while the structural grammar
 * is pending.
 *
 * Each stub dir's grammar.js is a one-liner:
 *     module.exports = require('../common/stub.js')({ name: 'fpm', comment: '//' });
 *
 * To implement a file type for real, replace that grammar.js with a structural
 * grammar mirroring grammar/<type>.ebnf (see fun/ and fcfg/ for the pattern) and add
 * it to scripts/check-corpus.sh's drift gate.
 */
const lex = require('./lexical-core.js');

module.exports = function stubGrammar(opts) {
  const comment = opts.comment || null; // '//' | '#' | null
  return grammar({
    name: opts.name,

    extras: $ => [/\s/].concat(comment ? [$.comment] : []),

    rules: {
      source_file: $ => repeat($._token),
      _token: $ => choice($.string, $.number, $.identifier, $.punctuation, $._any),

      string: $ => token(seq('"', repeat(choice(/[^"\\]/, /\\./)), '"')),
      number: $ => token(choice(lex.FLOAT, lex.RESOLUTION, lex.TICKRATE, lex.FIXED, lex.INT)),
      identifier: $ => token(choice(lex.UPPER_IDENT, lex.LOWER_IDENT)),
      punctuation: $ => token(choice('{', '}', '(', ')', '[', ']', ':', '=', '.', ',', '->', '::', '@')),

      // Catch-all so no byte is ever an ERROR; lower precedence than the real tokens.
      _any: $ => token(prec(-1, /./)),

      ...(comment ? { comment: $ => token(seq(comment, /[^\n]*/)) } : {}),
    },
  });
};
