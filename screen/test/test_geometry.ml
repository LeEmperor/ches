open! Core
open Ches_screen

let show ?(prefs = Geometry.Prefs.default) ?(line_count = 10) width height =
  let { Geometry.tile; border; gutter; gutter_digits = _; text; status; offset } =
    Geometry.compute prefs ~width ~height ~line_count
  in
  let rect ({ x; y; width; height } : Geometry.Rect.t) =
    sprintf "%d,%d %dx%d" x y width height
  in
  printf
    "%3dx%-3d tile %-14s border %-5b gutter %-12s text %-14s status %-12s offset %d\n"
    width
    height
    (rect tile)
    border
    (rect gutter)
    (rect text)
    (rect status)
    offset
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
  show ~prefs:{ centered = false; width = 40; offset = 30 } 160 48;
  [%expect
    {| 160x48  tile 0,0 160x47     border true  gutter 1,1 4x45     text 5,1 154x45     status 0,47 160x1   offset 0 |}]
;;

let%expect_test "the offset is clamped to the screen, and the request is kept" =
  let prefs offset = { Geometry.Prefs.default with width = 60; offset } in
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
