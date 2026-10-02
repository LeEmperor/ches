open! Core
open Ches_screen
open Helpers

let lines n = String.concat (List.init n ~f:(fun i -> sprintf "line %d\n" (i + 1)))

let%expect_test "a small file at 80x24 in the centered tile" =
  show ~width:80 ~height:24 (ui "let foo x = x + 1\n\nlet bar = foo 41\n");
  [%expect
    {|
    ┌──────────────────────────────────────────────────────────────────────────────┐|
    │  1 let foo x = x + 1                                                         │|
    │  2                                                                           │|
    │  3 let bar = foo 41                                                          │|
    │  4                                                                           │|
    │                                                                              │|
    │                                                                              │|
    │                                                                              │|
    │                                                                              │|
    │                                                                              │|
    │                                                                              │|
    │                                                                              │|
    │                                                                              │|
    │                                                                              │|
    │                                                                              │|
    │                                                                              │|
    │                                                                              │|
    │                                                                              │|
    │                                                                              │|
    │                                                                              │|
    │                                                                              │|
    │                                                                              │|
    └──────────────────────────────────────────────────────────────────────────────┘|
     NORMAL  f.txt                                                              1:1 |
    cursor: 5,1 Block
    |}]
;;

let%expect_test "styles" =
  show_styled ~width:30 ~height:7 (ui "ab\tc\001\n\nx");
  [%expect
    {|
    Border[┌────────────────────────────┐]
    Border[│] Gutter_cursor_line[  1 ] Text_cursor_line[ab      c] Special_cursor_line[^A] Text_cursor_line[             ] Border[│]
    Border[│] Gutter[  2 ] Text[                        ] Border[│]
    Border[│] Gutter[  3 ] Text[x                       ] Border[│]
    Border[│] Gutter[    ] Text[                        ] Border[│]
    Border[└────────────────────────────┘]
    (Mode Normal)[ NORMAL ] Status[ f.txt            1:1 ]
    |}]
;;

let%expect_test "an empty file" =
  show ~width:30 ~height:6 (ui "");
  [%expect
    {|
    ┌────────────────────────────┐|
    │  1                         │|
    │                            │|
    │                            │|
    └────────────────────────────┘|
     NORMAL  f.txt            1:1 |
    cursor: 5,1 Block
    |}]
;;

let%expect_test "a tall file scrolls to keep the cursor visible" =
  let t = run ~width:30 ~height:8 (ui (lines 30)) (keys "jjjjjjjj") in
  show ~width:30 ~height:8 t;
  [%expect
    {|
    ┌────────────────────────────┐|
    │  5 line 5                  │|
    │  6 line 6                  │|
    │  7 line 7                  │|
    │  8 line 8                  │|
    │  9 line 9                  │|
    └────────────────────────────┘|
     NORMAL  f.txt            9:1 |
    cursor: 5,5 Block
    |}];
  let t = run ~width:30 ~height:8 t (keys "kkkkkkkkk") in
  show ~width:30 ~height:8 t;
  [%expect
    {|
    ┌────────────────────────────┐|
    │  1 line 1                  │|
    │  2 line 2                  │|
    │  3 line 3                  │|
    │  4 line 4                  │|
    │  5 line 5                  │|
    └────────────────────────────┘|
     NORMAL  f.txt            1:1 |
    cursor: 5,1 Block
    |}]
;;

let%expect_test "a wide line scrolls horizontally, and the cursor follows" =
  let line = String.concat (List.init 6 ~f:(fun i -> sprintf "%d________" i)) in
  let t = ui (line ^ "\nshort\n") in
  let t = run ~width:30 ~height:6 t (keys (String.make 25 'l')) in
  show ~width:30 ~height:6 t;
  [%expect
    {|
    ┌────────────────────────────┐|
    │  1 _______1________2_______│|
    │  2 ort                     │|
    │  3                         │|
    └────────────────────────────┘|
     NORMAL  f.txt           1:26 |
    cursor: 28,1 Block
    |}];
  (* Moving to a short line returns to cell 0. *)
  let t = run ~width:30 ~height:6 t (keys "j") in
  show ~width:30 ~height:6 t;
  [%expect
    {|
    ┌────────────────────────────┐|
    │  1 0________1________2_____│|
    │  2 short                   │|
    │  3                         │|
    └────────────────────────────┘|
     NORMAL  f.txt            2:5 |
    cursor: 9,2 Block
    |}]
;;

let%expect_test "control characters, C1 controls and bidi overrides show escape forms"
  =
  show
    ~width:40
    ~height:6
    (ui "\027[31mred\027[0m\n\194\133x\226\128\174y\239\187\191z\n");
  [%expect
    {|
    ┌──────────────────────────────────────┐|
    │  1 ^[[31mred^[[0m                    │|
    │  2 <85>x<202e>y<feff>z               │|
    │  3                                   │|
    └──────────────────────────────────────┘|
     NORMAL  f.txt                      1:1 |
    cursor: 5,1 Block
    |}]
;;

let%expect_test "tabs, wide and zero-width characters" =
  show ~width:40 ~height:6 (ui "\tx\n中文e\204\129!\n");
  [%expect
    {|
    ┌──────────────────────────────────────┐|
    │  1         x                         │|
    │  2 中文é!                            │|
    │  3                                   │|
    └──────────────────────────────────────┘|
     NORMAL  f.txt                      1:1 |
    cursor: 5,1 Block
    |}]
;;

let%expect_test "clipping at the text viewport's edges is exact to the cell" =
  (* Text viewport is 16 cells wide (20 - 4 for the gutter). *)
  let t = ui "ab\tcd\n0123456789abcde中\n0123456789abc\027[0m\n0中x\n0\027x\n" in
  let t = run ~width:20 ~height:6 t (keys "jjllllllllllllllll") in
  (* Lines 4 and 5 show the left edge cutting a wide character and an escape form. *)
  show ~width:20 ~height:6 t;
  [%expect
    {|
      1       cd        |
      2 23456789abcde中 |
      3 23456789abc^[[0m|
      4 <x              |
      5 [x              |
     NORMAL  f.txt 3:17 |
    cursor: 19,2 Block
    |}];
  let t = run ~width:20 ~height:6 t (keys "kk") in
  show ~width:20 ~height:6 t;
  [%expect
    {|
      1 ab      cd      |
      2 0123456789abcde>|
      3 0123456789abc^[[|
      4 0中x            |
      5 0^[x            |
     NORMAL  f.txt  1:5 |
    cursor: 13,0 Block
    |}]
;;

let%expect_test "the cursor sits on the first cell of a TAB, wide character, or \
                 escape form"
  =
  (* The text starts at x = 4, after the gutter. *)
  ignore
    (List.fold [ ""; "l"; "l"; "l"; "i" ] ~init:(ui "\tx中\001") ~f:(fun t k ->
       let t = run ~width:30 ~height:4 t (keys k) in
       show_cursor ~width:30 ~height:4 t;
       t)
     : Ui_state.t);
  [%expect
    {|
    cursor: 4,0 Block
    cursor: 12,0 Block
    cursor: 13,0 Block
    cursor: 15,0 Block
    cursor: 15,0 Bar
    |}]
;;

let%expect_test "tiny and zero dimensions" =
  let t = ui "hello\nworld\n" in
  List.iter
    [ 1, 1; 10, 3; 3, 2; 1, 2; 0, 0; 5, 0; 0, 5 ]
    ~f:(fun (width, height) ->
      printf "-- %dx%d\n" width height;
      show ~width ~height t);
  [%expect
    {|
    -- 1x1
     |
    cursor: none
    -- 10x3
    hello     |
    world     |
     NORMAL   |
    cursor: 0,0 Block
    -- 3x2
    hel|
     NO|
    cursor: 0,0 Block
    -- 1x2
    h|
     |
    cursor: 0,0 Block
    -- 0x0
    cursor: none
    -- 5x0
    cursor: none
    -- 0x5
    |
    |
    |
    |
    |
    cursor: none
    |}]
;;

let%expect_test "status line fields drop by priority as it narrows" =
  let t =
    run
      ~width:80
      (ui ~path:"/home/user/projects/ches/src/some_long_name.ml" "abc")
      (keys "ix<Esc> ")
  in
  List.iter [ 80; 60; 40; 30; 20; 16; 12; 8; 4 ] ~f:(fun width ->
    show ~width ~height:1 t);
  [%expect
    {|
     NORMAL  /home/user/projects/ches/src/some_long_name.ml [+]           Space 1:1 |
    cursor: none
     NORMAL  <projects/ches/src/some_long_name.ml [+] Space 1:1 |
    cursor: none
     NORMAL  <me_long_name.ml [+] Space 1:1 |
    cursor: none
     NORMAL  <me.ml [+] Space 1:1 |
    cursor: none
     NORMAL  [+]  Space |
    cursor: none
     NORMAL   Space |
    cursor: none
     NORMAL     |
    cursor: none
     NORMAL |
    cursor: none
     NOR|
    cursor: none
    |}];
  (* An error message outlasts the other fields. *)
  let t = run (ui ~path:"/nonexistent-dir/f.txt" "abc") (keys "x w") in
  List.iter [ 80; 40; 20 ] ~f:(fun width -> show ~width ~height:1 t);
  [%expect
    {|
     NORMAL  [+] Failed to write /nonexistent-dir/f.txt: No such file or directory  |
    cursor: none
     NORMAL  Failed to write /nonexistent-> |
    cursor: none
     NORMAL  Failed to> |
    cursor: none
    |}]
;;
