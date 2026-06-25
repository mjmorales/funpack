; tree-sitter-funpack — .fcfg highlights (last-wins: fallbacks first, roles later)

; --- fallback identifier colouring --------------------------------------------
(lower_ident) @variable
(upper_ident) @type

; --- values -------------------------------------------------------------------
(string) @string
(int) @number
(tickrate) @number
(resolution) @number
(bool) @boolean
(name_ref (upper_ident) @constructor)
(name_ref (lower_ident) @constant)

; --- block labels (the project/entrypoint/build name) -------------------------
(project_block (lower_ident) @module)
(entrypoint_block (lower_ident) @module)
(build_block (lower_ident) @module)

; --- assignment keys & tags ---------------------------------------------------
(assignment key: (lower_ident) @property)
(tag_name (lower_ident) @attribute)

; --- use / module refs --------------------------------------------------------
(module_ref (lower_ident) @module)
(module_ref (upper_ident) @type)
(dep_decl (lower_ident) @module)

; --- directives ---------------------------------------------------------------
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
] @attribute

; --- keywords -----------------------------------------------------------------
[
  "project"
  "entrypoint"
  "build"
  "tags"
  "use"
  "version"
  "path"
  "url"
  "hash"
] @keyword

; --- operators & punctuation --------------------------------------------------
"=" @operator
["::" "."] @punctuation.delimiter
"," @punctuation.delimiter
["{" "}" "(" ")"] @punctuation.bracket
