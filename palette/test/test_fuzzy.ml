open! Core
open Ches_palette

let field ?(weight = 100) text : string Fuzzy.Field.t = { tag = text; text; weight }

let mark = Marked.mark

(* Rank single-field candidates and print them best first, with matches marked. *)
let rank query texts =
  Fuzzy.rank ~query (List.map texts ~f:(fun text -> text, [ field text ]))
  |> List.iter ~f:(fun (result : _ Fuzzy.Match.t) ->
    match result.positions with
    | [] -> print_endline result.item
    | positions ->
      List.iter positions ~f:(fun ((field : _ Fuzzy.Field.t), offsets) ->
        print_endline (mark field.text offsets)))
;;

let%expect_test "an ordered subsequence matches, ignoring ASCII case" =
  rank "rln" [ "Toggle relative line numbers"; "Toggle absolute line numbers"; "nlr" ];
  [%expect {| Toggle [r]elative [l]ine [n]umbers |}];
  rank "TOGGLE" [ "Toggle centered layout" ];
  [%expect {| [Toggle] centered layout |}]
;;

let%expect_test "an empty or blank query matches everything in order" =
  rank "" [ "b"; "a"; "c" ];
  [%expect
    {|
    b
    a
    c
    |}];
  rank " \t " [ "b"; "a" ];
  [%expect
    {|
    b
    a
    |}]
;;

let%expect_test "no match" =
  rank "xyz" [ "Save file"; "Quit" ];
  [%expect {| |}];
  rank "q" [];
  [%expect {| |}]
;;

let%expect_test "every token must match, each in any field" =
  let candidates =
    [ "relative", [ field "Toggle relative line numbers"; field "gutter" ]
    ; "absolute", [ field "Toggle absolute line numbers"; field "gutter" ]
    ; "centered", [ field "Toggle centered layout" ]
    ]
  in
  let show query =
    Fuzzy.rank ~query candidates
    |> List.iter ~f:(fun (result : _ Fuzzy.Match.t) ->
      print_s
        [%sexp
          (result.item : string)
          , (List.map result.positions ~f:(fun (field, offsets) ->
               mark field.text offsets)
             : string list)])
  in
  show "gutter relative";
  [%expect {| (relative ("Toggle [relative] line numbers" [gutter])) |}];
  show "toggle lay";
  [%expect {| (centered ("[Toggle] centered [lay]out")) |}]
;;

let%expect_test "whole-field and prefix matches rank first" =
  rank "undo" [ "Run do-over"; "Undo all"; "Undo" ];
  [%expect
    {|
    [Undo]
    [Undo] all
    R[un] [do]-over
    |}]
;;

let%expect_test "contiguous runs beat scattered matches" =
  rank "line" [ "Lift inner edges"; "Toggle line numbers" ];
  [%expect
    {|
    Toggle [line] numbers
    [L]ift [in]ner [e]dges
    |}]
;;

let%expect_test "word boundaries beat matches inside words" =
  rank "rn" [ "Burn"; "Relative numbers" ];
  [%expect
    {|
    [R]elative [n]umbers
    Bu[rn]
    |}];
  (* Punctuation and case changes start words too. *)
  rank "tr" [ "Fontrender"; "view.toggle-relative"; "toggleRelative" ];
  [%expect
    {|
    view.[t]oggle-[r]elative
    [t]oggle[R]elative
    Fon[tr]ender
    |}]
;;

let%expect_test "letters scattered through unrelated words do not match" =
  rank "abs" [ "Toggle relative line numbers"; "Toggle absolute line numbers" ];
  [%expect {| Toggle [abs]olute line numbers |}];
  rank "rel" [ "Narrow document tile by 10 columns"; "Toggle relative line numbers" ];
  [%expect {| Toggle [rel]ative line numbers |}];
  (* Initials, letters skipped within a word, and runs inside a word still match. *)
  rank "tgl" [ "Toggle" ];
  [%expect {| [T]og[gl]e |}];
  rank "save" [ "Quit, discarding unsaved changes" ];
  [%expect {| Quit, discarding un[save]d changes |}];
  (* A single code point matches anywhere. *)
  rank "v" [ "Save" ];
  [%expect {| Sa[v]e |}]
;;

let%expect_test "field weights scale scores" =
  let candidates =
    [ "keyword", [ field ~weight:10 "save" ]; "title", [ field ~weight:100 "Save file" ] ]
  in
  Fuzzy.rank ~query:"save" candidates
  |> List.iter ~f:(fun (result : _ Fuzzy.Match.t) -> print_endline result.item);
  [%expect
    {|
    title
    keyword
    |}]
;;

let%expect_test "equal scores keep input order" =
  rank "a" [ "xa"; "ya"; "za" ];
  [%expect
    {|
    x[a]
    y[a]
    z[a]
    |}]
;;

let%expect_test "offsets are bytes at code-point starts; non-ASCII matches exactly" =
  rank "cr" [ "café crème" ];
  [%expect {| café [cr]ème |}];
  rank "èm" [ "café crème" ];
  [%expect {| café cr[èm]e |}];
  (* No Unicode case folding. *)
  rank "É" [ "café" ];
  [%expect {| |}];
  Fuzzy.rank ~query:"cr" [ (), [ field "café crème" ] ]
  |> List.iter ~f:(fun (result : _ Fuzzy.Match.t) ->
    print_s [%sexp (List.map result.positions ~f:snd : int list list)]);
  [%expect {| ((6 7)) |}]
;;

let%expect_test "malformed UTF-8 is safe" =
  rank "\xff" [ "a\xffb"; "plain" ];
  [%expect {| a[�]b |}];
  rank "a\xe2" [ "a\xe2\x82"; "ab" ];
  [%expect {| [a�] |}]
;;

let%expect_test "loose policy is opt-in, accepts even negative-score subsequences" =
  let text = "a" ^ String.make 100 'x' ^ "b" ^ String.make 100 'y' ^ "c" in
  let candidates = [ text, [ field text ] ] in
  assert (List.is_empty (Fuzzy.rank ~query:"abc" candidates));
  let loose = Fuzzy.rank ~policy:Loose_subsequence ~query:"abc" candidates in
  let matched = List.hd_exn loose in
  assert (matched.score < 0);
  assert (List.equal Int.equal (snd (List.hd_exn matched.positions)) [ 0; 101; 202 ]);
  assert (List.is_empty (Fuzzy.rank ~policy:Loose_subsequence ~query:"acb" candidates));
  assert (List.is_empty (Fuzzy.rank ~query:"abc" candidates));
  print_endline "command default unchanged";
  [%expect {| command default unchanged |}]
;;

let%expect_test "prepared and uncached ranking agree under both policies" =
  let candidates =
    [ "one", [ field ~weight:150 "caféFile"; field "src/caféFile.ml" ]
    ; "two", [ field "a-long/b-scattered/c.ml" ]
    ; "three", [ field "a-long/b-scattered/c.ml" ]
    ; "bad", [ field "a\xffb" ]
    ]
  in
  let prepared = List.map candidates ~f:Fuzzy.Prepared.create in
  List.iter [ Fuzzy.Policy.Command; Loose_subsequence ] ~f:(fun policy ->
    List.iter [ ""; " \t"; "cf"; "café ml"; "abc"; "not-found"; "�" ] ~f:(fun query ->
      let uncached = Fuzzy.rank ~policy ~query candidates in
      let cached = Fuzzy.rank_prepared ~policy ~query prepared in
      assert (Sexp.equal ([%sexp_of: (string, string) Fuzzy.Match.t list] uncached)
        ([%sexp_of: (string, string) Fuzzy.Match.t list] cached))));
  print_endline "prepared equivalence passed";
  [%expect {| prepared equivalence passed |}]
;;
