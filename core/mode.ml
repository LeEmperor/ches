open! Core

type t =
  | Normal
  | Insert
  | Visual of [ `Characterwise | `Linewise | `Blockwise ]
[@@deriving sexp_of, equal]

let to_string = function
  | Normal -> "NORMAL"
  | Insert -> "INSERT"
  | Visual `Characterwise -> "VISUAL"
  | Visual `Linewise -> "VISUAL LINE"
  | Visual `Blockwise -> "VISUAL BLOCK"
;;

let%expect_test "status labels" =
  List.iter [ Normal; Insert ] ~f:(fun mode -> print_endline (to_string mode));
  [%expect
    {|
    NORMAL
    INSERT
    |}]
;;
