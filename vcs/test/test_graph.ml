(* The commit graph (phase 8): fixed commit lists, newest first in topological order,
   printed one row per commit followed by the commit's id, so each expectation reads as
   the picture the Commits panel shows. *)

open! Core
open Ches_vcs

let show ?max_width commits =
  let rows = Graph.rows ?max_width commits in
  if List.is_empty rows then print_endline "(no rows)";
  List.iter2_exn rows commits ~f:(fun row (id, _) -> printf "%s%s\n" row id)
;;

let%expect_test "a straight line" =
  show [ "C", [ "B" ]; "B", [ "A" ]; "A", [] ];
  [%expect
    {|
    ● C
    ● B
    ● A
    |}]
;;

let%expect_test "a merge of a side branch" =
  show [ "M", [ "A"; "S" ]; "S", [ "A" ]; "A", [] ];
  [%expect
    {|
    ●─╮ M
    │ ● S
    ●─╯ A
    |}]
;;

let%expect_test "two side branches open at once" =
  (* M2 merges T into M1, which merged S; S and T both fork from A. *)
  show [ "M2", [ "M1"; "T" ]; "M1", [ "A"; "S" ]; "S", [ "A" ]; "T", [ "A" ]; "A", [] ];
  [%expect
    {|
    ●─╮ M2
    ●─┼─╮ M1
    │ │ ● S
    │ ● │ T
    ●─╯─╯ A
    |}]
;;

let%expect_test "an octopus merge" =
  show [ "O", [ "A"; "X"; "Y"; "Z" ]; "X", [ "A" ]; "Y", [ "A" ]; "Z", [ "A" ]; "A", [] ];
  [%expect
    {|
    ●─╮─╮─╮ O
    │ ● │ │ X
    │ │ ● │ Y
    │ │ │ ● Z
    ●─╯─╯─╯ A
    |}];
  (* Lanes follow parent order, whatever order the side commits come in. *)
  show [ "O", [ "A"; "X"; "Y"; "Z" ]; "Z", [ "A" ]; "Y", [ "A" ]; "X", [ "A" ]; "A", [] ];
  [%expect
    {|
    ●─╮─╮─╮ O
    │ │ │ ● Z
    │ │ ● │ Y
    │ ● │ │ X
    ●─╯─╯─╯ A
    |}]
;;

let%expect_test "a lane freed on a row is reused on the next row, not the same row" =
  (* B ends Y's lane (1) and starts one for D: in lane 2, not 1. W, the next tip, takes
     lane 1. *)
  show
    [ "X", [ "B" ]
    ; "Y", [ "B" ]
    ; "B", [ "C"; "D" ]
    ; "W", [ "D" ]
    ; "D", [ "C" ]
    ; "C", []
    ];
  [%expect
    {|
    ● X
    │ ● Y
    ●─╯─╮ B
    │ ● │ W
    │ ●─╯ D
    ●─╯ C
    |}];
  (* A root frees its lane; a free lane at the right end is dropped, so the next tip
     takes a new lane in the same place. *)
  show [ "M", [ "A"; "R" ]; "R", []; "T", [ "A" ]; "A", [] ];
  [%expect
    {|
    ●─╮ M
    │ ● R
    │ ● T
    ●─╯ A
    |}]
;;

let%expect_test "a lane started left of the commit" =
  (* A's root frees lane 0; S's second parent starts there. *)
  show [ "M", [ "A"; "S" ]; "A", []; "S", [ "T"; "U" ]; "U", []; "T", [] ];
  [%expect
    {|
    ●─╮ M
    ● │ A
    ╭─● S
    ● │ U
      ● T
    |}]
;;

let%expect_test "criss-cross merges" =
  (* X and Y each merge the other's tip. *)
  show
    [ "MX", [ "X"; "Y" ]
    ; "MY", [ "Y"; "X" ]
    ; "X", [ "B" ]
    ; "Y", [ "B" ]
    ; "B", []
    ];
  [%expect
    {|
    ●─╮ MX
    ├─┼─● MY
    ● │ │ X
    │ ●─╯ Y
    ●─╯ B
    |}]
;;

let%expect_test "a parent beyond the list keeps its lane to the end" =
  show [ "M", [ "B"; "Z" ]; "B", [ "A" ]; "A", [] ];
  [%expect
    {|
    ●─╮ M
    ● │ B
    ● │ A
    |}];
  (* Its lane is in use, so a new tip goes to the free lane left of it. *)
  show [ "M", [ "B"; "Z" ]; "B", []; "T", [ "U" ] ];
  [%expect
    {|
    ●─╮ M
    ● │ B
    ● │ T
    |}]
;;

let%expect_test "max_width cuts long rows" =
  let octopus =
    ("O", List.init 12 ~f:(sprintf "p%d"))
    :: List.init 11 ~f:(fun i -> sprintf "p%d" (11 - i), [ "p0" ])
  in
  show (List.take octopus 2);
  [%expect
    {|
    ●─╮─╮─╮─╮─╮─╮─╮─╮─╮─╮─╮ O
    │ │ │ │ │ │ │ │ │ │ │ ● p11
    |}];
  (* 13 lanes are 26 characters: cut to 22 and "… ". *)
  show [ "O", List.init 13 ~f:(sprintf "p%d"); "p12", [ "p0" ] ];
  [%expect
    {|
    ●─╮─╮─╮─╮─╮─╮─╮─╮─╮─╮─… O
    │ │ │ │ │ │ │ │ │ │ │ … p12
    |}];
  show ~max_width:8 [ "O", [ "A"; "X"; "Y"; "Z" ] ];
  show ~max_width:7 [ "O", [ "A"; "X"; "Y"; "Z" ] ];
  show ~max_width:2 [ "O", [ "A"; "X"; "Y"; "Z" ] ];
  [%expect
    {|
    ●─╮─╮─╮ O
    ●─╮─╮… O
    … O
    |}]
;;

let%expect_test "duplicate ids: the later ones are commits nothing waits for" =
  show [ "X", [ "A" ]; "A", [ "R" ]; "Y", [ "A" ]; "A", [ "R" ]; "R", [] ];
  [%expect
    {|
    ● X
    ● A
    │ ● Y
    │ │ ● A
    ●─┼─╯ R
    |}]
;;

let%expect_test "the empty list" =
  show [];
  [%expect {| (no rows) |}]
;;
