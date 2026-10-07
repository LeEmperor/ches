open! Core
open Ches_highlight
open Ches_highlight_tree_sitter

let run provider source =
  let key = Provider.key provider ~document:(Snapshot.Document_id.create ()) ~revision:0 in
  let result = Provider.highlight provider ~key ~source in
  assert (Snapshot.matches result.snapshot key);
  result
;;

let check_slice source (result : Provider.result) token category =
  let slices =
    List.map (Snapshot.ranges result.snapshot) ~f:(fun range ->
      String.sub source ~pos:range.start ~len:(range.stop - range.start), range.category)
  in
  if not (List.exists slices ~f:(fun (text, cat) ->
    String.equal text token && Category.equal cat category))
  then raise_s [%sexp "missing SystemVerilog capture", (token : string),
    (category : Category.t), (slices : (string * Category.t) list)]
;;

let%test_unit "SystemVerilog query initializes, with declarations, literals, and preprocessing" =
  let source =
    "`timescale 1ns/1ps\n\
     `define WIDTH 8\n\
     // é: a counter\n\
     module counter(input logic clk, output logic [7:0] count);\n\
       localparam int LIMIT = 8'hff;\n\
       string message = \"hello é\";\n\
       /* block comment */\n\
       always_ff @(posedge clk) begin\n\
         count <= count + 1;\n\
         $display(message);\n\
       end\n\
       function automatic int increment(input int value);\n\
         return value + 1;\n\
       endfunction\n\
     endmodule\n"
  in
  let provider = Provider.create ~language:Systemverilog in
  let result = run provider source in
  assert (Provider.Status.equal result.status (Highlighted { syntax_errors = false }));
  List.iter
    [ "`timescale", Category.Keyword; "`define", Keyword; "// é: a counter", Comment
    ; "module", Keyword; "counter", Module; "logic", Type; "count", Variable
    ; "8'hff", Number; "\"hello é\"", String; "/* block comment */", Comment
    ; "always_ff", Keyword; "posedge", Keyword; "<=", Operator; "$display", Function
    ; "increment", Function; "int", Type; "return", Keyword; ";", Punctuation
    ] ~f:(fun (token, category) -> check_slice source result token category);
  let empty = run provider "" in
  assert (Provider.Status.equal empty.status (Highlighted { syntax_errors = false }));
  [%test_result: Snapshot.Range.t list] (Snapshot.ranges empty.snapshot) ~expect:[];
  Provider.close provider
;;

let%test_unit "Verilog syntax and malformed SystemVerilog still receive current highlights" =
  let provider = Provider.create ~language:Systemverilog in
  let source = "module top(input wire clk); reg q; always @(posedge clk) q <= 1'b1; endmodule\n" in
  let result = run provider source in
  assert (Provider.Status.equal result.status (Highlighted { syntax_errors = false }));
  check_slice source result "wire" Type;
  check_slice source result "reg" Type;
  let broken = "module top; logic q; assign q = ); endmodule" in
  let result = run provider broken in
  assert (Provider.Status.equal result.status (Highlighted { syntax_errors = true }));
  check_slice broken result "logic" Type;
  Provider.close provider
;;

let%test_unit "SystemVerilog incremental edits equal fresh parses and preserve old snapshots" =
  let provider = Provider.create ~language:Systemverilog in
  let fresh = Provider.create ~language:Systemverilog in
  let document = Snapshot.Document_id.create () in
  let initial = "module top; string s = \"é\"; logic q; assign q = 1'b0; endmodule\n" in
  let sources =
    [ initial; "/*\n" ^ initial; "/*\n" ^ initial ^ "*/\n"; initial
    ; String.substr_replace_all initial ~pattern:"é" ~with_:"😀"
    ; "`ifdef TEST\n" ^ initial ^ "`endif\n"; "module top; logic q = ; endmodule"
    ; ""; initial; "\n" ^ initial; initial
    ]
  in
  let history =
    List.mapi sources ~f:(fun revision source ->
      let key = Provider.key provider ~document ~revision in
      let actual = Provider.highlight_incremental provider ~key ~source in
      let expected = Provider.highlight fresh ~key ~source in
      assert (Provider.Status.equal actual.status expected.status);
      assert (match actual.status with Highlighted _ -> true | Plain _ -> false);
      [%test_result: Snapshot.Range.t list] (Snapshot.ranges actual.snapshot)
        ~expect:(Snapshot.ranges expected.snapshot);
      actual.snapshot, Snapshot.ranges actual.snapshot)
  in
  assert (Provider.incremental_count provider = List.length sources - 1);
  List.iter history ~f:(fun (snapshot, ranges) ->
    [%test_result: Snapshot.Range.t list] (Snapshot.ranges snapshot) ~expect:ranges);
  Provider.close provider;
  Provider.close fresh
;;
