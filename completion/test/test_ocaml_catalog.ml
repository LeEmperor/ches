open! Core
open Ches_core
module N = Ches_completion.Snippet
module S = N.Session
module D = Ches_completion.Snippet_definition

let catalog = Ches_completion.Ocaml_snippets.all
let find prefix = List.find_exn catalog ~f:(fun (d : D.t) -> String.equal d.prefix prefix)
let parse (d : D.t) = N.parse d.body |> Or_error.ok_exn
let expand prefix = N.text (parse (find prefix))

let%test_unit "OCaml catalog parses with bounded fields, valid indentation and mirrors" =
  List.iter catalog ~f:(fun (d : D.t) ->
    let template = parse d in
    assert (not (String.is_empty (N.text template)));
    assert (not (String.is_empty d.description));
    assert (String.is_prefix d.id ~prefix:(d.collection ^ "."));
    let indented = N.indent template ~prefix:"    " |> Or_error.ok_exn in
    [%test_eq: string] (N.text indented)
      (String.concat ~sep:"\n    " (String.split (N.text template) ~on:'\n'));
    let text = Text_buffer.of_string (N.text indented) |> Result.ok |> Option.value_exn in
    assert (Text_buffer.is_boundary text (N.final_cursor indented));
    assert (List.length (N.fields template) <= 8);
    List.iter (N.fields indented) ~f:(fun field ->
      let contents = List.map field.ranges ~f:(fun range ->
        assert (Text_buffer.is_boundary text range.start);
        assert (Text_buffer.is_boundary text range.stop);
        String.sub (N.text indented) ~pos:range.start ~len:(range.stop - range.start)) in
      assert (List.for_all contents ~f:(String.equal (List.hd_exn contents)))))
;;

let%test_unit "collections, IDs, triggers and extension-only applicability" =
  let unique values = assert (Option.is_none (List.find_a_dup values ~compare:String.compare)) in
  unique (List.map catalog ~f:(fun (d : D.t) -> d.id));
  unique (List.map catalog ~f:(fun (d : D.t) -> d.prefix));
  [%test_eq: string list]
    (List.map catalog ~f:(fun (d : D.t) -> d.collection)
     |> List.dedup_and_sort ~compare:String.compare)
    [ "hardcaml.design"; "hardcaml.verification"; "ocaml.core"
    ; "ocaml.jane-street"; "ocaml.testing" ];
  List.iter catalog ~f:(fun (d : D.t) ->
    assert (not (List.is_empty d.scopes));
    assert (List.for_all d.scopes ~f:(fun s -> List.mem [ ".ml"; ".mli" ] s ~equal:String.equal));
    if String.is_prefix d.collection ~prefix:"hardcaml."
    then assert (String.is_prefix d.prefix ~prefix:"hc"));
  List.iter [ "ocmod"; "ocfunctor"; "ocfun"; "ocrec"; "ocexpect"; "occommand"
            ; "hci"; "hccircuit"; "hcsim"; "hcexpect" ]
    ~f:(fun prefix -> [%test_eq: string list] (find prefix).scopes [ ".ml" ]);
  List.iter [ "ocabstract"; "ocmoddecl" ]
    ~f:(fun prefix -> [%test_eq: string list] (find prefix).scopes [ ".mli" ]);
  List.iter [ "ocsig"; "ocrecord"; "ocvariant"; "ocval"; "hcfield" ]
    ~f:(fun prefix -> [%test_eq: string list] (find prefix).scopes [ ".ml"; ".mli" ])
;;

let edit_field prefix ~number ~replacement =
  let template = parse (find prefix) in
  let text = Text_buffer.of_string (N.text template) |> Result.ok |> Option.value_exn in
  let session = S.start template ~base:0 ~revision:1 ~text |> Or_error.ok_exn in
  let rec navigate session =
    match S.active session with
    | Some field when field.number = number -> session
    | Some _ -> navigate (S.navigate session Next)
    | None -> failwith "missing catalog field"
  in
  let session = navigate session in
  let change = S.insert session ~revision:1 ~text replacement |> Or_error.ok_exn in
  let text = Text_edit.apply text [ S.edits change ] |> Or_error.ok_exn in
  let session = S.applied change ~revision:2 in
  assert (S.matches session ~revision:2 ~text);
  Text_buffer.to_string text
;;

let%test_unit "circuit widths and scoped output names remain linked during editing" =
  let text = edit_field "hccircuit" ~number:2 ~replacement:"16" in
  assert (String.is_substring text ~substring:"d : 'a [@bits 16]");
  assert (String.is_substring text ~substring:"q : 'a [@bits 16]");
  assert (not (String.is_substring text ~substring:"[@bits 8]"));
  let text = edit_field "hccreate" ~number:1 ~replacement:"data_out" in
  assert (String.is_substring text ~substring:"let data_out = reg spec i.d -- \"data_out\" in");
  assert (String.is_substring text ~substring:"{ O.data_out = data_out }");
  [%test_eq: string]
    (edit_field "hcwave" ~number:2 ~replacement:"traced_sim")
    "let waves, traced_sim = Cyclesim.Waveform.create traced_sim in\n"
;;

let%test_unit "Hardcaml defaults preserve control semantics and observation timing" =
  [%test_eq: string] (expand "hcregspec")
    "let spec = Signal.Reg_spec.create ~clock:i.clock ~clear:i.clear () in\n";
  assert (String.is_substring (expand "hcregspecreset") ~substring:"~reset_level:High ()");
  assert (String.is_substring (expand "hcregreset") ~substring:"~reset_to:(Bits.of_int_trunc");
  assert (String.is_substring (expand "hcregclear") ~substring:"~clear_to:(Signal.of_int_trunc");
  [%test_eq: string] (expand "hchandles")
    "let inputs = Cyclesim.inputs sim in\nlet outputs = Cyclesim.outputs ~clock_edge:After sim in\n";
  [%test_eq: string] (expand "hcclear")
    "inputs.clear := Bits.vdd;\nCyclesim.cycle sim;\ninputs.clear := Bits.gnd;\nCyclesim.cycle sim;\n";
  assert (String.is_substring (expand "hcrtl")
            ~substring:"Rtl.print ~database:(Scope.circuit_database scope) Verilog circuit");
  [%test_eq: string] (expand "hcwire")
    "let next = Signal.wire 8 in\nSignal.assign next data;\n";
  assert (String.is_substring (expand "hcexpect") ~substring:"[%expect {|00101010|}]");
  assert (String.is_substring (expand "ocexpect") ~substring:"[%expect {|hello|}]")
;;
