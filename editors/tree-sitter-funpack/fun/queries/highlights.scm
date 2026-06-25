; tree-sitter-funpack — .fun highlights
;
; Capture precedence is LAST-WINS: general fallbacks come first, specific overrides
; later. Deeper nodes already override their ancestors, so a string's interpolation
; expression keeps its own colours inside an @string span.

; --- fallback identifier colouring (overridden below by role) -----------------
(lower_ident) @variable
(upper_ident) @type

; --- literals -----------------------------------------------------------------
(int) @number
(fixed) @number.float
(float) @number.float
(tickrate) @number
(bool) @boolean
(string) @string
(raw_string) @string

; --- types --------------------------------------------------------------------
(named_type (upper_ident) @type)
(kind_asc (upper_ident) @type)
(type_params (upper_ident) @type.parameter)
(extern_type (upper_ident) @type)

; --- constructors / variants / constants (UpperAtom, enum variants) -----------
(upper_atom (upper_ident) @constructor)
(variant (upper_ident) @constructor)

; --- declaration names --------------------------------------------------------
(data_decl (upper_ident) @type)
(enum_decl (upper_ident) @type)
(thing_decl (upper_ident) @type)
(signal_decl (upper_ident) @type)
(pipeline_decl (upper_ident) @type)

(fn_decl (lower_ident) @function)
(query_decl (lower_ident) @function)
(extern_fn (lower_ident) @function)
(behavior_decl (lower_ident) @function)
(step_method (lower_ident) @function.method)

; --- bindings, params, fields, members ----------------------------------------
(param (lower_ident) @variable.parameter)
(lambda (lower_ident) @variable.parameter)
(field_decl (lower_ident) @property)
(field_init (lower_ident) @property)
(stage_entry (lower_ident) @property)
(member_expression member: (lower_ident) @property)
(member_expression member: (upper_ident) @constant)
(behavior_ref (lower_ident) @function)

; --- calls --------------------------------------------------------------------
(call_expression (lower_ident) @function.call)
(call_expression (member_expression member: (lower_ident) @function.method.call))

; --- keywords -----------------------------------------------------------------
[
  "import"
  "let"
  "mut"
  "data"
  "enum"
  "thing"
  "singleton"
  "signal"
  "behavior"
  "on"
  "pipeline"
  "query"
  "test"
  "extern"
  "type"
  "assert"
] @keyword

"fn" @keyword.function
"return" @keyword.return
["if" "else" "match"] @keyword.conditional
"with" @keyword.operator
["and" "or" "not"] @keyword.operator

; --- directives (the closed @-set) --------------------------------------------
[
  "@doc"
  "@gtag"
  "@todo"
  "@index"
  "@spatial"
  "@migrate"
  "@expose"
  "@server"
  "@client"
  "@break"
  "@log"
  "@watch"
  "@trace"
  "@stub"
] @attribute

; --- operators & punctuation --------------------------------------------------
["+" "-" "*" "/" "%" "==" "!=" "<" "<=" ">" ">="] @operator
"=" @operator
(wildcard) @character.special

["->" "=>" "::" ":" "."] @punctuation.delimiter
"," @punctuation.delimiter
["(" ")" "[" "]" "{" "}"] @punctuation.bracket
