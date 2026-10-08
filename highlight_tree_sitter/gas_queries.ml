(* Ches-authored structural captures; no upstream query or predicates. Snapshot
   prefers narrower spans, then category priority. Capture immediate contents
   directly, and omit '@' punctuation so directive types stay wholly Property. *)
let source =
  {|
  (comment) @comment
  [(directive_name) (instruction_name) (instruction_prefix)] @keyword
  (register) @constant
  [(label) (local_label_reference)] @function
  (symbol) @variable
  (number) @number
  [(string) (char)] @string
  [(operand_modifier) (type)] @property
  ["+" "-" "*" "/" "="] @operator
  ["," ":" "(" ")" "$"] @punctuation
  |}
