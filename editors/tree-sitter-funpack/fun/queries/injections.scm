; tree-sitter-funpack — .fun injections
;
; .fun string interpolation (`"score {m.score}"`) is parsed INLINE: the hole is a
; first-class `expression` child of the string node (grammar.js `string` rule), so it
; is already highlighted by highlights.scm with full .fun colouring. There is no
; same-language injection to do — embedding .fun into .fun would be redundant and
; recursive.
;
; This file is the seam for any FUTURE cross-language embedding (none today). When the
; language gains an embedded foreign sublanguage, add an (#set! injection.language …)
; rule here.
