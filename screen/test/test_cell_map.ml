open! Core
open Ches_screen

let show s =
  Array.iter (Cell_map.glyphs s) ~f:(fun { pos; col; width; text; kind } ->
    printf
      !"%2d %2d %d %-7s %S\n"
      pos
      col
      width
      (Sexp.to_string [%sexp (kind : Cell_map.Kind.t)])
      text)
;;

let%expect_test "tabs expand to the next stop of 8" =
  show "\tab\tc\t";
  [%expect
    {|
    0  0 8 Tab     "        "
    1  8 1 Plain   "a"
    2  9 1 Plain   "b"
    3 10 6 Tab     "      "
    4 16 1 Plain   "c"
    5 17 7 Tab     "       "
    |}]
;;

let%expect_test "control characters, C1 controls, and bidi controls have escape forms"
  =
  show "\027[31m\001\127\194\128\194\159\226\128\174\239\187\191\216\156";
  [%expect
    {|
     0  0 2 Escape  "^["
     1  2 1 Plain   "["
     2  3 1 Plain   "3"
     3  4 1 Plain   "1"
     4  5 1 Plain   "m"
     5  6 2 Escape  "^A"
     6  8 2 Escape  "^?"
     7 10 4 Escape  "<80>"
     9 14 4 Escape  "<9f>"
    11 18 6 Escape  "<202e>"
    14 24 6 Escape  "<feff>"
    17 30 5 Escape  "<61c>"
    |}]
;;

let%expect_test "wide and zero-width characters; invalid bytes" =
  show "a\228\184\173e\204\129\255";
  [%expect
    {|
    0  0 1 Plain   "a"
    1  1 2 Plain   "\228\184\173"
    4  3 1 Plain   "e"
    5  4 0 Plain   "\204\129"
    7  4 4 Escape  "\\xff"
    |}]
;;

let%expect_test "cursor spans" =
  let line = "\tx\228\184\173e\204\129" in
  let glyphs = Cell_map.glyphs line in
  List.iter [ 0; 1; 2; 5; 6; 8 ] ~f:(fun pos ->
    let normal = Cell_map.cursor_span glyphs ~pos ~insertion:false in
    let insert = Cell_map.cursor_span glyphs ~pos ~insertion:true in
    print_s [%message (pos : int) (normal : int * int) (insert : int * int)]);
  [%expect
    {|
    ((pos 0) (normal (0 8)) (insert (0 1)))
    ((pos 1) (normal (8 1)) (insert (8 1)))
    ((pos 2) (normal (9 2)) (insert (9 1)))
    ((pos 5) (normal (11 1)) (insert (11 1)))
    ((pos 6) (normal (11 1)) (insert (11 1)))
    ((pos 8) (normal (12 1)) (insert (12 1)))
    |}];
  (* A zero-width code point at the start of the line puts the cursor on cell 0. *)
  print_s
    [%sexp
      (Cell_map.cursor_span (Cell_map.glyphs "\204\129a") ~pos:0 ~insertion:false
       : int * int)];
  [%expect {| (0 1) |}];
  print_s
    [%sexp
      (Cell_map.cursor_span (Cell_map.glyphs "") ~pos:0 ~insertion:false : int * int)];
  [%expect {| (0 1) |}]
;;
