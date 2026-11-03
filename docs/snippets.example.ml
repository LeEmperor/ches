open Ches_config

(* Copy the declarations you want into config.ml. Named quoted strings let
   choice syntax contain |} without ending the OCaml string. *)
let () =
  Snippets.add
    ~id:"personal.verilog-header"
    ~prefix:"header"
    ~scope:[ "systemverilog"; "verilog" ]
    ~description:"File header"
    {snippet|// File: $TM_FILENAME
// ${1:Description}

$0|snippet};

  Snippets.add
    ~id:"personal.ocaml-header"
    ~prefix:"header"
    ~scope:[ "ocaml" ]
    ~description:"File header"
    {snippet|(* File: $TM_FILENAME *)
(* ${1:Description} *)

$0|snippet};

  Snippets.add
    ~id:"sv.aff"
    ~prefix:"aff"
    ~scope:[ "systemverilog" ]
    ~description:"Clocked always block"
    {snippet|always_ff @(${1|posedge,negedge|} ${2:clk}) begin
    $0
end|snippet};

  Snippets.add
    ~id:"sv.mod"
    ~prefix:"mod"
    ~scope:[ "systemverilog" ]
    ~description:"Module named after this file"
    {snippet|module ${1:${TM_FILENAME_BASE:module_name}} (
    $0
);
endmodule|snippet}
