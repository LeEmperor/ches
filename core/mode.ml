open! Core

type t =
  | Normal
  | Insert
[@@deriving sexp_of, equal]

let to_string = function
  | Normal -> "NORMAL"
  | Insert -> "INSERT"
;;

let%expect_test "status labels" =
  List.iter [ Normal; Insert ] ~f:(fun mode -> print_endline (to_string mode));
  [%expect
    {|
    NORMAL
    INSERT
    |}]
;;
