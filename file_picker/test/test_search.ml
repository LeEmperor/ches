open! Core
open Ches_file_picker

let candidate path = Model.Candidate.create ~root:"/project" ~relative_path:path |> Or_error.ok_exn
let rank query paths = Search.rank ~query (Search.prepare (List.map paths ~f:candidate))
let paths results = List.map results ~f:(fun r -> Model.Candidate.relative_path r.Model.Query_result.candidate)
let check_order query input expected = assert (List.equal String.equal (paths (rank query input)) expected)

let%expect_test "basename weighting, quality, directory tokens and stable duplicate ties" =
  check_order "model" [ "model/other.ml"; "src/model.ml"; "src/modular_entry_list.ml" ]
    [ "src/model.ml"; "src/modular_entry_list.ml"; "model/other.ml" ];
  check_order "src model" [ "test/model.ml"; "src/model.ml"; "src/other.ml" ] [ "src/model.ml" ];
  check_order "model.ml" [ "b/model.ml"; "a/model.ml" ] [ "b/model.ml"; "a/model.ml" ];
  check_order "a model.ml" [ "b/model.ml"; "a/model.ml" ] [ "a/model.ml" ];
  check_order "fp" [ "src/file_picker.ml"; "src/fp.ml"; "src/fileParser.ml" ]
    [ "src/fp.ml"; "src/file_picker.ml"; "src/fileParser.ml" ];
  print_endline "ranking assertions passed";
  [%expect {| ranking assertions passed |}]
;;

let%expect_test "loose scattered subsequences, punctuation, Unicode and empty queries" =
  let scattered = "a" ^ String.make 100 'x' ^ "b" ^ String.make 100 'y' ^ "c.ml" in
  check_order "abc" [ scattered; "abc.ml"; "acb.ml" ] [ "abc.ml"; scattered ];
  check_order "sfp" [ "src/file_picker/search.ml"; "other.ml" ] [ "src/file_picker/search.ml" ];
  check_order "f-p" [ "src/file-picker.ml"; "src/file_picker.ml" ] [ "src/file-picker.ml" ];
  check_order "ème" [ "café/crème.ml"; "café/creme.ml" ] [ "café/crème.ml" ];
  check_order "É" [ "café.ml" ] [];
  check_order "modle" [ "model.ml" ] [];
  check_order "xyz" [ "model.ml" ] [];
  check_order " \t\n" [ "b.ml"; "a.ml" ] [ "b.ml"; "a.ml" ];
  assert (List.for_all (rank "" [ "b.ml"; "a.ml" ]) ~f:(fun r -> r.score = 0 && List.is_empty r.positions));
  print_endline "acceptance assertions passed";
  [%expect {| acceptance assertions passed |}]
;;

let only query path = List.hd_exn (rank query [ path ])
let check_positions query path expected =
  let r = only query path in
  assert (List.equal Int.equal r.positions expected);
  List.iter r.positions ~f:(fun offset ->
    let text = Model.Candidate.display_path r.candidate in
    assert (offset >= 0 && offset < String.length text);
    assert (Char.to_int text.[offset] land 0xC0 <> 0x80))
;;

let%expect_test "basename/path token highlights are merged at display byte starts" =
  check_positions "src model" "src/model.ml" [ 0; 1; 2; 4; 5; 6; 7; 8 ];
  check_positions "model model" "src/model.ml" [ 4; 5; 6; 7; 8 ];
  check_positions "èm" "café/crème.ml" [ 8; 10 ];
  (* Escapes before matches shift both directory and basename offsets. *)
  check_positions "src model" "\xff/src/\nmodel.ml" [ 5; 6; 7; 13; 14; 15; 16; 17 ];
  (* A matched backslash marks BOTH displayed slashes; a malformed raw byte
     matches U+FFFD and marks its complete hex representation, not the 'x'. *)
  check_positions "\\" "dir/a\\b.ml" [ 5; 6 ];
  check_positions "�" "dir/a\xffb.ml" [ 5; 6; 7; 8 ];
  check_positions "\127" "dir/a\127b.ml" [ 5; 6; 7; 8 ];
  check_positions "\226\128\168" "dir/a\226\128\168b.ml" (List.range 5 17);
  check_positions "b" "dir/a\226\128\168b.ml" [ 17 ];
  let raw = "dir/a\\\xff\nb.ml" in
  assert (String.equal (Model.Candidate.path (only "b" raw).candidate) ("/project/" ^ raw));
  print_endline "highlight assertions passed";
  [%expect {| highlight assertions passed |}]
;;
