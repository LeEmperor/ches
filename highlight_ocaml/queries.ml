open! Core

(* Ches-owned structural queries, authored against the bundled grammar symbols
   and phase 0 probe. No upstream query file or text predicates are used. *)
let common =
  {|
  (comment) @comment
  [(string) (quoted_string) (character)] @string
  (escape_sequence) @escape
  (number) @number
  (boolean) @constant
  [(type_constructor) (type_variable) (class_name) (class_type_name)] @type
  (constructor_name) @constructor
  [(module_name) (module_type_name)] @module
  [(field_name) (method_name) (label_name)] @property
  (tag) @constructor
  (value_name) @variable
  (value_pattern) @variable

  ["and" "as" "assert" "begin" "class" "constraint" "do" "done"
   "downto" "else" "end" "exception" "external" "for" "fun" "function"
   "functor" "if" "in" "include" "inherit" "initializer" "lazy" "let"
   "match" "method" "module" "mutable" "new" "nonrec" "object" "of"
   "open" "private" "rec" "sig" "struct" "then" "to" "try" "type"
   "val" "virtual" "when" "while" "with"] @keyword

  [(prefix_operator) (sign_operator) (pow_operator) (mult_operator)
   (add_operator) (concat_operator) (rel_operator) (and_operator)
   (or_operator) (assign_operator) (hash_operator) (indexing_operator)
   (let_operator) (let_and_operator) (match_operator)] @operator
  ["=" "->" "<-" ":=" ":>" "+=" "::"] @operator
  ["(" ")" "[" "]" "[|" "|]" ";" ";;" "," "." ":" "|"] @punctuation
  ; Quoted-string delimiters also contain braces. Capture only code braces.
  (record_expression ["{" "}"] @punctuation)
  (record_pattern ["{" "}"] @punctuation)
  (record_declaration ["{" "}"] @punctuation)

  (let_binding pattern: (value_name) @function (parameter))
  (let_binding pattern: (value_name) @function
    body: [(fun_expression) (function_expression)])
  (application_expression function: (value_path (value_name) @function))
  (value_specification (value_name) @function (function_type))
  (external (value_name) @function (function_type))
  |}
;;

let source = function
  | Ches_highlight.Language.Plain -> None
  | Ocaml | Ocaml_interface -> Some common
;;
