(* Ches-owned structural captures for the pinned SystemVerilog grammar. No
   predicates or upstream editor queries are required. Identifiers get a base
   category, refined by their grammatical roles using Snapshot's priorities. *)
let source =
  {|
  [(one_line_comment) (block_comment)] @comment
  [(string_literal) (quoted_string) (system_lib_string)] @string
  [(integral_number) (unsigned_number) (real_number)
   (time_literal) (unbased_unsized_literal)] @number
  [(simple_identifier) (escaped_identifier)] @variable
  (system_tf_identifier) @function

  [(integer_vector_type) (integer_atom_type) (non_integer_type) (net_type)
   "string" "event" "chandle" "void" "signed" "unsigned"] @type
  (class_declaration name: [(simple_identifier) (escaped_identifier)] @type)
  (type_assignment name: [(simple_identifier) (escaped_identifier)] @type)

  (module_ansi_header name: [(simple_identifier) (escaped_identifier)] @module)
  (module_nonansi_header name: [(simple_identifier) (escaped_identifier)] @module)
  (interface_ansi_header name: [(simple_identifier) (escaped_identifier)] @module)
  (interface_nonansi_header name: [(simple_identifier) (escaped_identifier)] @module)
  (package_declaration name: [(simple_identifier) (escaped_identifier)] @module)
  (module_instantiation instance_type: [(simple_identifier) (escaped_identifier)] @module)

  (function_body_declaration name: [(simple_identifier) (escaped_identifier)] @function)
  (task_body_declaration name: [(simple_identifier) (escaped_identifier)] @function)
  (function_prototype name: [(simple_identifier) (escaped_identifier)] @function)
  (task_prototype name: [(simple_identifier) (escaped_identifier)] @function)
  (named_port_connection port_name: [(simple_identifier) (escaped_identifier)] @property)
  (named_parameter_assignment [(simple_identifier) (escaped_identifier)] @constant)
  (text_macro_usage (simple_identifier) @constant)

  [(module_keyword) (always_keyword) (edge_identifier) (lifetime)
   (case_keyword) (unique_priority) (random_qualifier)
   "endmodule" "interface" "endinterface" "package" "endpackage"
   "program" "endprogram" "class" "endclass" "extends" "implements"
   "function" "endfunction" "task" "endtask" "begin" "end"
   "input" "output" "inout" "ref" "parameter" "localparam" "genvar"
   "assign" "initial" "final" "if" "else" "endcase" "default"
   "for" "foreach" "while" "do" "repeat" "forever" "break" "continue"
   "return" "generate" "endgenerate" "typedef" "enum" "struct" "union"
   "packed" "const" "import" "export" "modport" "new" "this" "super"
   "assert" "assume" "cover" "property" "endproperty" "sequence" "endsequence"
   "disable" "iff" "inside" "with" "constraint" "endgroup" "covergroup"
   "coverpoint" "cross" "clocking" "endclocking" "fork" "join" "join_any"
   "join_none" "wait" "force" "release" "virtual" "extern" "pure"
   "timeunit" "timeprecision"
   "`include" "`define" "`ifdef" "`ifndef" "`elsif" "`else" "`endif"
   "`undef" "`timescale" "`default_nettype"] @keyword
  "null" @constant

  [(assignment_operator) (unary_operator) (inc_or_dec_operator)
   "+" "-" "*" "/" "%" "**" "=" "<=" "<" ">" ">="
   "==" "!=" "===" "!==" "&&" "||" "!" "~" "&" "|" "^"
   "<<" ">>" "<<<" ">>>" "?" "@" "#" "##" "|->" "|=>"] @operator
  ["(" ")" "[" "]" "{" "}" "'{" ";" ":" "::" "," "."] @punctuation
  |}
