open! Core
open Ches_core

let%expect_test "display columns of cursors, and the code points covering columns" =
  (* TAB in cells 0-7, x in 8, a wide character in 9-10, e in 11 with a combining
     mark after it. *)
  let line = "\tx\228\184\173e\204\129" in
  let glyphs = Cell_layout.glyphs ~width:Cell_width.f line in
  List.iter [ 0; 1; 2; 5; 6; 8 ] ~f:(fun pos ->
    let normal = Cell_layout.column glyphs ~pos ~insertion:false in
    let insert = Cell_layout.column glyphs ~pos ~insertion:true in
    print_s [%message (pos : int) (normal : int) (insert : int)]);
  [%expect
    {|
    ((pos 0) (normal 7) (insert 0))
    ((pos 1) (normal 8) (insert 8))
    ((pos 2) (normal 9) (insert 9))
    ((pos 5) (normal 11) (insert 11))
    ((pos 6) (normal 11) (insert 11))
    ((pos 8) (normal 12) (insert 12))
    |}];
  List.iter [ 0; 7; 8; 9; 10; 11; 12; 40 ] ~f:(fun col ->
    print_s [%message (col : int) (Cell_layout.pos_of_column glyphs col : int option)]);
  [%expect
    {|
    ((col 0) ("Cell_layout.pos_of_column glyphs col" (0)))
    ((col 7) ("Cell_layout.pos_of_column glyphs col" (0)))
    ((col 8) ("Cell_layout.pos_of_column glyphs col" (1)))
    ((col 9) ("Cell_layout.pos_of_column glyphs col" (2)))
    ((col 10) ("Cell_layout.pos_of_column glyphs col" (2)))
    ((col 11) ("Cell_layout.pos_of_column glyphs col" (5)))
    ((col 12) ("Cell_layout.pos_of_column glyphs col" ()))
    ((col 40) ("Cell_layout.pos_of_column glyphs col" ()))
    |}];
  (* A leading combining mark is never chosen; the empty line has no columns. *)
  let leading = Cell_layout.glyphs ~width:Cell_width.f "\204\129a" in
  print_s [%sexp (Cell_layout.pos_of_column leading 0 : int option)];
  print_s
    [%sexp
      (Cell_layout.pos_of_column (Cell_layout.glyphs ~width:Cell_width.f "") 0
       : int option)];
  [%expect
    {|
    (2)
    ()
    |}]
;;
