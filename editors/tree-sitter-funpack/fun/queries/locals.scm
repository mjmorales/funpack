; tree-sitter-funpack — .fun local scopes
;
; Drives scope-aware highlighting: a bound name (let / param / pattern binder) is a
; definition; other lower_idents are references resolved against the enclosing scope.

; --- scopes -------------------------------------------------------------------
[
  (source_file)
  (block)
  (lambda)
  (behavior_decl)
  (fn_decl)
  (query_decl)
  (step_method)
  (match_arm)
] @local.scope

; --- definitions --------------------------------------------------------------
(let_decl (lower_ident) @local.definition.var)
(let_stmt (lower_ident) @local.definition.var)
(tuple_binder (lower_ident) @local.definition.var)

(param (lower_ident) @local.definition.parameter)
(lambda (lower_ident) @local.definition.parameter)

; pattern binders (match arms): the bare-binder and struct field-pun forms
(pattern (lower_ident) @local.definition.var)
(variant_pat (lower_ident) @local.definition.var)

; --- references ---------------------------------------------------------------
(lower_ident) @local.reference
