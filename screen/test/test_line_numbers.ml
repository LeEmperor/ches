open! Core
open Ches_screen

let%expect_test "both toggles from every style" =
  List.iter Line_numbers.all ~f:(fun style ->
    printf
      !"%-8s  n -> %-8s  N -> %s\n"
      (Line_numbers.to_string style)
      (Line_numbers.to_string (Line_numbers.toggle_absolute style))
      (Line_numbers.to_string (Line_numbers.toggle_relative style)));
  [%expect {|
    off       n -> absolute  N -> relative
    absolute  n -> off       N -> hybrid
    relative  n -> hybrid    N -> off
    hybrid    n -> relative  N -> absolute
    |}]
;;

let%expect_test "labels around the cursor line, in every style" =
  let show ~line_count ~cursor_line lines =
    let digits = Geometry.gutter_digits ~line_count in
    printf "%d lines, cursor on line %d:\n" line_count (cursor_line + 1);
    List.iter lines ~f:(fun line ->
      printf
        "  line %-6d %s\n"
        (line + 1)
        (String.concat
           ~sep:"|"
           (List.map Line_numbers.all ~f:(fun style ->
              Line_numbers.label style ~digits ~line ~cursor_line))))
  in
  print_endline "             off|absolute|relative|hybrid";
  show ~line_count:9 ~cursor_line:0 [ 0; 1; 8 ];
  show ~line_count:9 ~cursor_line:8 [ 0; 7; 8 ];
  show ~line_count:999 ~cursor_line:499 [ 0; 498; 499; 500; 998 ];
  show ~line_count:1000 ~cursor_line:999 [ 0; 998; 999 ];
  show ~line_count:120000 ~cursor_line:5 [ 0; 5; 6; 119999 ];
  [%expect {|
                 off|absolute|relative|hybrid
    9 lines, cursor on line 1:
      line 1          |  1 |  0 |1
      line 2          |  2 |  1 |  1
      line 9          |  9 |  8 |  8
    9 lines, cursor on line 9:
      line 1          |  1 |  8 |  8
      line 8          |  8 |  1 |  1
      line 9          |  9 |  0 |9
    999 lines, cursor on line 500:
      line 1          |  1 |499 |499
      line 499        |499 |  1 |  1
      line 500        |500 |  0 |500
      line 501        |501 |  1 |  1
      line 999        |999 |499 |499
    1000 lines, cursor on line 1000:
      line 1           |   1 | 999 | 999
      line 999         | 999 |   1 |   1
      line 1000        |1000 |   0 |1000
    120000 lines, cursor on line 6:
      line 1             |     1 |     5 |     5
      line 6             |     6 |     0 |6
      line 7             |     7 |     1 |     1
      line 120000        |120000 |119994 |119994
    |}]
;;
