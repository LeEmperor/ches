open! Core
open Ches_screen

(* These tests are about the gutter, so they start from hybrid line numbers and no
   padding rather than the default, which has 2 cells of padding and no numbers. *)
let hybrid = { Geometry.Prefs.default with line_numbers = Hybrid; left_padding = 0 }

let show ?(prefs = hybrid) ?(line_count = 10) width height =
  let { Geometry.tile
      ; border
      ; padding
      ; gutter
      ; gutter_digits = _
      ; text
      ; status
      ; offset
      ; areas = _
      }
    =
    Geometry.compute prefs ~width ~height ~line_count
  in
  let rect ({ x; y; width; height } : Geometry.Rect.t) =
    sprintf "%d,%d %dx%d" x y width height
  in
  printf
    "%3dx%-3d tile %-14s border %-5b gutter %-12s text %-14s status %-12s offset %d%s\n"
    width
    height
    (rect tile)
    border
    (rect gutter)
    (rect text)
    (rect status)
    offset
    (if padding = 0 then "" else sprintf " padding %d" padding)
;;

let%expect_test "centered at the default width, with the overhead around it" =
  show 160 48;
  show 120 40;
  show 106 24;
  show 80 24;
  [%expect
    {|
    160x48  tile 27,0 106x47    border true  gutter 28,1 4x45    text 32,1 100x45    status 0,47 160x1   offset 0
    120x40  tile 7,0 106x39     border true  gutter 8,1 4x37     text 12,1 100x37    status 0,39 120x1   offset 0
    106x24  tile 0,0 106x23     border true  gutter 1,1 4x21     text 5,1 100x21     status 0,23 106x1   offset 0
     80x24  tile 0,0 80x23      border true  gutter 1,1 4x21     text 5,1 74x21      status 0,23 80x1    offset 0
    |}]
;;

let%expect_test "full width ignores the preferred width and offset" =
  show ~prefs:{ hybrid with centered = false; width = 40; offset = 30 } 160 48;
  [%expect
    {| 160x48  tile 0,0 160x47     border true  gutter 1,1 4x45     text 5,1 154x45     status 0,47 160x1   offset 0 |}]
;;

let%expect_test "the offset is clamped to the screen, and the request is kept" =
  let prefs offset = { hybrid with width = 60; offset } in
  show ~prefs:(prefs 10) 160 48;
  show ~prefs:(prefs (-500)) 160 48;
  show ~prefs:(prefs 500) 160 48;
  show ~prefs:(prefs 10) 66 24;
  [%expect
    {|
    160x48  tile 57,0 66x47     border true  gutter 58,1 4x45    text 62,1 60x45     status 0,47 160x1   offset 10
    160x48  tile 0,0 66x47      border true  gutter 1,1 4x45     text 5,1 60x45      status 0,47 160x1   offset -47
    160x48  tile 94,0 66x47     border true  gutter 95,1 4x45    text 99,1 60x45     status 0,47 160x1   offset 47
     66x24  tile 0,0 66x23      border true  gutter 1,1 4x21     text 5,1 60x21      status 0,23 66x1    offset 0
    |}]
;;

let%expect_test "the gutter grows past 999 lines" =
  show ~line_count:999 160 48;
  show ~line_count:1000 160 48;
  show ~line_count:123456 160 48;
  [%expect
    {|
    160x48  tile 27,0 106x47    border true  gutter 28,1 4x45    text 32,1 100x45    status 0,47 160x1   offset 0
    160x48  tile 26,0 107x47    border true  gutter 27,1 5x45    text 32,1 100x45    status 0,47 160x1   offset 0
    160x48  tile 25,0 109x47    border true  gutter 26,1 7x45    text 33,1 100x45    status 0,47 160x1   offset 0
    |}]
;;

let%expect_test "small screens drop the border, then the gutter" =
  List.iter
    [ 22, 24
    ; 21, 24
    ; 20, 24
    ; 19, 24
    ; 10, 3
    ; 80, 6
    ; 80, 5
    ; 80, 2
    ; 1, 1
    ; 1, 0
    ; 0, 1
    ; 0, 0
    ]
    ~f:(fun (w, h) -> show w h);
  [%expect
    {|
    22x24  tile 0,0 22x23      border true  gutter 1,1 4x21     text 5,1 16x21      status 0,23 22x1    offset 0
    21x24  tile 0,0 21x23      border false gutter 0,0 4x23     text 4,0 17x23      status 0,23 21x1    offset 0
    20x24  tile 0,0 20x23      border false gutter 0,0 4x23     text 4,0 16x23      status 0,23 20x1    offset 0
    19x24  tile 0,0 19x23      border false gutter 0,0 0x23     text 0,0 19x23      status 0,23 19x1    offset 0
    10x3   tile 0,0 10x2       border false gutter 0,0 0x2      text 0,0 10x2       status 0,2 10x1     offset 0
    80x6   tile 0,0 80x5       border true  gutter 1,1 4x3      text 5,1 74x3       status 0,5 80x1     offset 0
    80x5   tile 0,0 80x4       border false gutter 0,0 4x4      text 4,0 76x4       status 0,4 80x1     offset 0
    80x2   tile 0,0 80x1       border false gutter 0,0 4x1      text 4,0 76x1       status 0,1 80x1     offset 0
     1x1   tile 0,0 1x0        border false gutter 0,0 0x0      text 0,0 1x0        status 0,0 1x1      offset 0
     1x0   tile 0,0 1x0        border false gutter 0,0 0x0      text 0,0 1x0        status 0,0 1x0      offset 0
     0x1   tile 0,0 0x0        border false gutter 0,0 0x0      text 0,0 0x0        status 0,0 0x1      offset 0
     0x0   tile 0,0 0x0        border false gutter 0,0 0x0      text 0,0 0x0        status 0,0 0x0      offset 0
    |}]
;;

let%expect_test "with line numbers off there is no gutter" =
  let off = { hybrid with line_numbers = Off } in
  (* Centered with room: the text keeps its width and the tile narrows. *)
  show 160 48;
  show ~prefs:off 160 48;
  (* Full width, or a screen narrower than the request: the text widens. *)
  show ~prefs:{ hybrid with centered = false } 160 48;
  show ~prefs:{ off with centered = false } 160 48;
  show 80 24;
  show ~prefs:off 80 24;
  [%expect {|
    160x48  tile 27,0 106x47    border true  gutter 28,1 4x45    text 32,1 100x45    status 0,47 160x1   offset 0
    160x48  tile 29,0 102x47    border true  gutter 30,1 0x45    text 30,1 100x45    status 0,47 160x1   offset 0
    160x48  tile 0,0 160x47     border true  gutter 1,1 4x45     text 5,1 154x45     status 0,47 160x1   offset 0
    160x48  tile 0,0 160x47     border true  gutter 1,1 0x45     text 1,1 158x45     status 0,47 160x1   offset 0
     80x24  tile 0,0 80x23      border true  gutter 1,1 4x21     text 5,1 74x21      status 0,23 80x1    offset 0
     80x24  tile 0,0 80x23      border true  gutter 1,1 0x21     text 1,1 78x21      status 0,23 80x1    offset 0
    |}]
;;

let%expect_test "small screens: border, then gutter; off keeps a border that fits" =
  let off = { hybrid with line_numbers = Off } in
  List.iter [ 22; 21; 20; 19; 18; 17 ] ~f:(fun width ->
    show width 10;
    show ~prefs:off width 10);
  [%expect {|
    22x10  tile 0,0 22x9       border true  gutter 1,1 4x7      text 5,1 16x7       status 0,9 22x1     offset 0
    22x10  tile 0,0 22x9       border true  gutter 1,1 0x7      text 1,1 20x7       status 0,9 22x1     offset 0
    21x10  tile 0,0 21x9       border false gutter 0,0 4x9      text 4,0 17x9       status 0,9 21x1     offset 0
    21x10  tile 0,0 21x9       border true  gutter 1,1 0x7      text 1,1 19x7       status 0,9 21x1     offset 0
    20x10  tile 0,0 20x9       border false gutter 0,0 4x9      text 4,0 16x9       status 0,9 20x1     offset 0
    20x10  tile 0,0 20x9       border true  gutter 1,1 0x7      text 1,1 18x7       status 0,9 20x1     offset 0
    19x10  tile 0,0 19x9       border false gutter 0,0 0x9      text 0,0 19x9       status 0,9 19x1     offset 0
    19x10  tile 0,0 19x9       border true  gutter 1,1 0x7      text 1,1 17x7       status 0,9 19x1     offset 0
    18x10  tile 0,0 18x9       border false gutter 0,0 0x9      text 0,0 18x9       status 0,9 18x1     offset 0
    18x10  tile 0,0 18x9       border true  gutter 1,1 0x7      text 1,1 16x7       status 0,9 18x1     offset 0
    17x10  tile 0,0 17x9       border false gutter 0,0 0x9      text 0,0 17x9       status 0,9 17x1     offset 0
    17x10  tile 0,0 17x9       border false gutter 0,0 0x9      text 0,0 17x9       status 0,9 17x1     offset 0
    |}]
;;

let%expect_test "every numbered style has the same gutter" =
  List.iter [ Line_numbers.Absolute; Relative; Hybrid ] ~f:(fun line_numbers ->
    show ~prefs:{ hybrid with line_numbers } ~line_count:1000 160 48);
  [%expect {|
    160x48  tile 26,0 107x47    border true  gutter 27,1 5x45    text 32,1 100x45    status 0,47 160x1   offset 0
    160x48  tile 26,0 107x47    border true  gutter 27,1 5x45    text 32,1 100x45    status 0,47 160x1   offset 0
    160x48  tile 26,0 107x47    border true  gutter 27,1 5x45    text 32,1 100x45    status 0,47 160x1   offset 0
    |}]
;;

let%expect_test "the default has no line numbers and 2 cells of padding" =
  print_s [%sexp (Geometry.Prefs.default : Geometry.Prefs.t)];
  [%expect
    {| ((centered true) (width 100) (offset 0) (line_numbers Off) (left_padding 2)) |}]
;;

let%expect_test "left padding sits before the gutter, outside the text width" =
  let padded line_numbers = { hybrid with line_numbers; left_padding = 2 } in
  (* Centered with room: the text keeps its width and the tile widens. *)
  show ~prefs:(padded Off) 160 48;
  show ~prefs:(padded Hybrid) 160 48;
  (* Full width: the text gives up the padding's cells. *)
  show ~prefs:{ (padded Off) with centered = false } 160 48;
  (* Negative padding is none. *)
  show ~prefs:{ (padded Off) with left_padding = -3 } 160 48;
  [%expect {|
    160x48  tile 28,0 104x47    border true  gutter 31,1 0x45    text 31,1 100x45    status 0,47 160x1   offset 0 padding 2
    160x48  tile 26,0 108x47    border true  gutter 29,1 4x45    text 33,1 100x45    status 0,47 160x1   offset 0 padding 2
    160x48  tile 0,0 160x47     border true  gutter 3,1 0x45     text 3,1 156x45     status 0,47 160x1   offset 0 padding 2
    160x48  tile 29,0 102x47    border true  gutter 30,1 0x45    text 30,1 100x45    status 0,47 160x1   offset 0
    |}]
;;

let%expect_test "small screens drop the padding with the gutter" =
  let padded line_numbers = { hybrid with line_numbers; left_padding = 2 } in
  List.iter [ 24; 23; 22; 21; 20; 19; 18 ] ~f:(fun width ->
    show ~prefs:(padded Off) width 10;
    show ~prefs:(padded Hybrid) width 10);
  [%expect {|
    24x10  tile 0,0 24x9       border true  gutter 3,1 0x7      text 3,1 20x7       status 0,9 24x1     offset 0 padding 2
    24x10  tile 0,0 24x9       border true  gutter 3,1 4x7      text 7,1 16x7       status 0,9 24x1     offset 0 padding 2
    23x10  tile 0,0 23x9       border true  gutter 3,1 0x7      text 3,1 19x7       status 0,9 23x1     offset 0 padding 2
    23x10  tile 0,0 23x9       border false gutter 2,0 4x9      text 6,0 17x9       status 0,9 23x1     offset 0 padding 2
    22x10  tile 0,0 22x9       border true  gutter 3,1 0x7      text 3,1 18x7       status 0,9 22x1     offset 0 padding 2
    22x10  tile 0,0 22x9       border false gutter 2,0 4x9      text 6,0 16x9       status 0,9 22x1     offset 0 padding 2
    21x10  tile 0,0 21x9       border true  gutter 3,1 0x7      text 3,1 17x7       status 0,9 21x1     offset 0 padding 2
    21x10  tile 0,0 21x9       border false gutter 0,0 0x9      text 0,0 21x9       status 0,9 21x1     offset 0
    20x10  tile 0,0 20x9       border true  gutter 3,1 0x7      text 3,1 16x7       status 0,9 20x1     offset 0 padding 2
    20x10  tile 0,0 20x9       border false gutter 0,0 0x9      text 0,0 20x9       status 0,9 20x1     offset 0
    19x10  tile 0,0 19x9       border false gutter 2,0 0x9      text 2,0 17x9       status 0,9 19x1     offset 0 padding 2
    19x10  tile 0,0 19x9       border false gutter 0,0 0x9      text 0,0 19x9       status 0,9 19x1     offset 0
    18x10  tile 0,0 18x9       border false gutter 2,0 0x9      text 2,0 16x9       status 0,9 18x1     offset 0 padding 2
    18x10  tile 0,0 18x9       border false gutter 0,0 0x9      text 0,0 18x9       status 0,9 18x1     offset 0
    |}]
;;
