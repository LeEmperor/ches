open! Core
open Ches_core
module N = Ches_completion.Snippet
module S = N.Session
module D = Ches_completion.Snippet_definition

let all = Ches_completion.Sv_snippets.all
let find prefix = List.find_exn all ~f:(fun (d : D.t) -> String.equal d.prefix prefix)
let parse prefix = N.parse (find prefix).body |> Or_error.ok_exn
let expand prefix = N.text (parse prefix)
let contains text substring = assert (String.is_substring text ~substring)

let%test_unit "available SV descriptions expose Xilinx vocabulary for discovery" =
  let module U = Ches_completion.User_snippets in
  let available = U.available U.builtins ~path:(Some "rtl/register.sv") in
  List.iter [ "FDRE", "affre"; "FDSE", "affse"; "FDCE", "affce"; "FDPE", "affpe" ]
    ~f:(fun (term, prefix) ->
      let matches = List.filter available ~f:(fun (item : U.item) ->
        Option.exists item.declaration.description ~f:(fun description ->
          String.is_substring description ~substring:term)) in
      let item = List.hd_exn matches in
      assert (List.length matches = 1);
      [%test_eq: string] item.declaration.id ("sv." ^ prefix);
      [%test_eq: string] item.declaration.prefix prefix;
      let description = Option.value_exn item.declaration.description in
      contains description "generic";
      contains description "no primitive instantiation or mapping guarantee")
;;

let%test_unit "SV catalog metadata is unique, purpose-scoped and parseable" =
  let unique values =
    assert (Option.is_none (List.find_a_dup values ~compare:String.compare))
  in
  unique (List.map all ~f:(fun (d : D.t) -> d.id));
  unique (List.map all ~f:(fun (d : D.t) -> d.prefix));
  List.iter all ~f:(fun (d : D.t) ->
    [%test_eq: string list] d.scopes [ "systemverilog" ];
    assert (List.mem [ "sv.design"; "sv.verification" ] d.collection ~equal:String.equal);
    assert (not (String.is_empty d.description));
    let template = N.parse d.body |> Or_error.ok_exn in
    List.iter [ None; Some "rtl/猫.test.sv" ] ~f:(fun path ->
      let template = N.resolve template ~path |> Or_error.ok_exn in
      let template = N.indent template ~prefix:"    " |> Or_error.ok_exn in
      let text = Text_buffer.of_string (N.text template) |> Result.ok |> Option.value_exn in
      assert (Text_buffer.is_boundary text (N.final_cursor template));
      List.iter (N.fields template) ~f:(fun field ->
        assert (field.number > 0);
        let values = List.map field.ranges ~f:(fun range ->
          assert (Text_buffer.is_boundary text range.start);
          assert (Text_buffer.is_boundary text range.stop);
          Text_buffer.slice text ~pos:range.start ~len:(range.stop - range.start)) in
        assert (List.for_all values ~f:(String.equal (List.hd_exn values))));
      ignore (S.start template ~base:0 ~revision:0 ~text |> Or_error.ok_exn : S.t)))
;;

let%test_unit "five starter IDs, prefixes and raw bodies remain compatible" =
  List.iter
    [ "aff", "always_ff @(${1|posedge,negedge|} ${2:clk}) begin\n    $0\nend"
    ; "acomb", "always_comb begin\n    $0\nend"
    ; "mod", "module ${1:${TM_FILENAME_BASE:module_name}} (\n    $0\n);\nendmodule"
    ; "inst", "${1:module_name} ${2:instance_name} (\n    .${3:port}($3)$0\n);"
    ; "genfor", "for (genvar ${1:i} = 0; $1 < ${2:COUNT}; $1++) begin : ${3:gen_block}\n    $0\nend"
    ]
    ~f:(fun (prefix, body) ->
      let d = find prefix in
      [%test_eq: string] d.id ("sv." ^ prefix);
      [%test_eq: string] d.body body)
;;

let%test_unit "reset polarity, reset-before-enable priority and hold semantics" =
  [%test_eq: string] (expand "affre")
    "always_ff @(posedge clk) begin\n    if (rst)\n        q <= '0;\n    else if (en)\n        q <= d;\n    \nend";
  contains (expand "affarn") "@(posedge clk or negedge rst_n)";
  contains (expand "affarn") "if (!rst_n)";
  List.iter [ "affce", "clr", "'0"; "affpe", "pre", "'1" ]
    ~f:(fun (prefix, control, value) ->
      let text = expand prefix in
      contains text ("or posedge " ^ control);
      contains text ("if (" ^ control ^ ")\n        q <= " ^ value ^ ";\n    else if (en)"));
  contains (expand "affse") "@(posedge clk)";
  contains (expand "affse") "if (set)\n        q <= '1;\n    else if (en)"
;;

let%test_unit "FSM linked state edits update declarations, transitions, reset and recovery" =
  let template = parse "fsm" in
  let text = Text_buffer.of_string (N.text template) |> Result.ok |> Option.value_exn in
  let session = S.start template ~base:0 ~revision:0 ~text |> Or_error.ok_exn in
  let change = S.insert session ~revision:0 ~text "WAIT" |> Or_error.ok_exn in
  let text = Text_edit.apply text [ S.edits change ] |> Or_error.ok_exn in
  let session = S.applied change ~revision:1 in
  assert (S.matches session ~revision:1 ~text);
  let text = Text_buffer.to_string text in
  assert (not (String.is_substring text ~substring:"IDLE"));
  List.iter [ "WAIT = 2'd0"; "if (rst) state <= WAIT";
              "WAIT: if (start) state_next = BUSY";
              "BUSY: if (done) state_next = WAIT";
              "default: state_next = WAIT" ] ~f:(contains text)
;;

let%test_unit "braces and simulator dollars expand literally, filenames resolve and clocks link" =
  contains (expand "pstruct") "} payload_t;";
  contains (expand "enum") "} state_t;";
  let dump = parse "tbdump" |> fun t -> N.resolve t ~path:(Some "sim/counter_tb.sv")
    |> Or_error.ok_exn |> N.text in
  contains dump "$dumpfile(\"counter_tb.vcd\")";
  contains dump "$dumpvars(0, counter_tb)";
  let tb = expand "tb" in
  List.iter [ "timeunit 1ns;"; "timeprecision 1ps;"; "always #(5ns) clk = ~clk;";
              ".clk(clk)"; ".rst(rst)"; "@(negedge clk);\n        rst = 1'b0;";
              "$display(\"Test complete\")"; "$finish;"; "$fatal(1," ] ~f:(contains tb);
  contains (expand "tbtimeout") "#(100us)"
;;

let%test_unit "SVA implication choice changes only timing operator; bounds stay visible" =
  let template = parse "svaimp" in
  let text = Text_buffer.of_string (N.text template) |> Result.ok |> Option.value_exn in
  let session = S.start template ~base:0 ~revision:0 ~text |> Or_error.ok_exn in
  let rec operator session =
    match S.active session with
    | Some field when field.number = 5 -> session
    | Some _ -> operator (S.navigate session Next)
    | None -> failwith "missing implication choice"
  in
  let session = operator session in
  [%test_eq: string list option] (S.choices session) (Some [ "|->"; "|=>" ]);
  let change = S.cycle_choice session Next ~revision:0 ~text |> Or_error.ok_exn in
  let text = Text_edit.apply text [ S.edits change ] |> Or_error.ok_exn |> Text_buffer.to_string in
  contains text "@(posedge clk) disable iff (rst)";
  contains text "(request) |=> (acknowledge)";
  contains (expand "svabound") "(request) |-> ##[1:4] (acknowledge)";
  contains (expand "prop") "assert property (p_check)"
;;
