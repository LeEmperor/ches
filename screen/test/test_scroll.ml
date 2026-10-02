open! Core
open Ches_screen

let fit
  ?(from = Scroll.zero)
  ?(fill = true)
  ?(rows = 10)
  ?(cols = 20)
  ?(line_count = 100)
  line
  span
  =
  let { Scroll.top; left } = Scroll.fit from ~fill ~line ~span ~rows ~cols ~line_count in
  printf "top %d left %d\n" top left
;;

let%expect_test "vertical: move as little as possible" =
  fit 5 (0, 1);
  fit 10 (0, 1);
  fit 50 (0, 1);
  fit ~from:{ top = 50; left = 0 } 45 (0, 1);
  fit ~from:{ top = 50; left = 0 } 55 (0, 1);
  [%expect
    {|
    top 0 left 0
    top 1 left 0
    top 41 left 0
    top 45 left 0
    top 50 left 0
    |}]
;;

let%expect_test "vertical: no empty rows below the end while earlier lines are hidden"
  =
  (* After deleting lines, or after the viewport grows. *)
  fit ~from:{ top = 95; left = 0 } 97 (0, 1);
  fit ~from:{ top = 95; left = 0 } ~line_count:5 3 (0, 1);
  fit ~from:{ top = 95; left = 0 } ~rows:40 97 (0, 1);
  [%expect {|
    top 90 left 0
    top 0 left 0
    top 60 left 0
    |}]
;;

let%expect_test "vertical: without fill, a view past the end stays while the cursor \
                 is visible"
  =
  fit ~fill:false ~from:{ top = 95; left = 0 } 97 (0, 1);
  fit ~fill:false ~from:{ top = 99; left = 0 } 99 (0, 1);
  fit ~fill:false ~from:{ top = 95; left = 0 } ~line_count:5 3 (0, 1);
  fit ~fill:false ~from:{ top = 95; left = 0 } 40 (0, 1);
  [%expect {|
    top 95 left 0
    top 99 left 0
    top 3 left 0
    top 40 left 0
    |}]
;;

let%expect_test "horizontal: cell 0 when the span fits there, else minimal movement" =
  fit 0 (19, 1);
  fit 0 (20, 1);
  fit 0 (18, 8);
  fit ~from:{ top = 0; left = 30 } 0 (25, 1);
  fit ~from:{ top = 0; left = 30 } 0 (40, 2);
  fit ~from:{ top = 0; left = 30 } 0 (49, 2);
  fit ~from:{ top = 0; left = 30 } 0 (5, 1);
  [%expect
    {|
    top 0 left 0
    top 0 left 1
    top 0 left 6
    top 0 left 25
    top 0 left 30
    top 0 left 31
    top 0 left 0
    |}]
;;

let%expect_test "a span wider than the viewport shows its first cell" =
  fit ~cols:4 0 (16, 8);
  [%expect {| top 0 left 16 |}]
;;

let%expect_test "zero rows or columns leave the scroll unchanged" =
  fit ~from:{ top = 7; left = 3 } ~rows:0 50 (60, 1);
  fit ~from:{ top = 7; left = 3 } ~cols:0 50 (60, 1);
  [%expect {|
    top 7 left 3
    top 7 left 3
    |}]
;;
