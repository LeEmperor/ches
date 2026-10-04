open! Core
open Ches_screen
open Helpers

let rect ({ x; y; width; height } : Geometry.Rect.t) = x, y, width, height

let show_geometry allocation reserve_status_row =
  let prefs = { Geometry.Prefs.default with width = 20; line_numbers = Hybrid } in
  let g = Geometry.compute_in prefs ~allocation ~reserve_status_row ~line_count:1000 in
  print_s
    [%sexp
      { tile = (rect g.tile : int * int * int * int)
      ; text = (rect g.text : int * int * int * int)
      ; gutter = (rect g.gutter : int * int * int * int)
      ; status = (rect g.status : int * int * int * int)
      ; offset = (g.offset : int)
      ; areas = (g.areas : Geometry.Area.t list)
      }]
;;

let%expect_test "offset allocation and explicit status reservation" =
  let allocation = { Geometry.Rect.x = 7; y = 4; width = 40; height = 8 } in
  show_geometry allocation true;
  show_geometry allocation false;
  [%expect {|
    ((tile (12 4 29 7)) (text (20 5 20 5)) (gutter (15 5 5 5))
     (status (7 11 40 1)) (offset 0)
     (areas
      (((rect ((x 13) (y 4) (width 27) (height 1))) (layout Border_title)
        (fields (Filename)))
       ((rect ((x 7) (y 11) (width 40) (height 1))) (layout Status_row)
        (fields (Mode Filename Dirty Message Pending Position))))))
    ((tile (12 4 29 8)) (text (20 5 20 6)) (gutter (15 5 5 6))
     (status (7 12 40 0)) (offset 0)
     (areas
      (((rect ((x 13) (y 4) (width 27) (height 1))) (layout Border_title)
        (fields (Filename))))))
    |}]
;;

let%expect_test "constrained and empty allocations retain their origin" =
  List.iter [ 1, 1, true; 1, 1, false; 0, 0, false; -2, -3, true ]
    ~f:(fun (width, height, reserve_status_row) ->
      show_geometry { Geometry.Rect.x = 7; y = 4; width; height } reserve_status_row);
  [%expect {|
    ((tile (7 4 1 0)) (text (7 4 1 0)) (gutter (7 4 0 0)) (status (7 4 1 1))
     (offset 0)
     (areas
      (((rect ((x 7) (y 4) (width 1) (height 1))) (layout Status_row)
        (fields (Mode Filename Dirty Message Pending Position))))))
    ((tile (7 4 1 1)) (text (7 4 1 1)) (gutter (7 4 0 1)) (status (7 5 1 0))
     (offset 0) (areas ()))
    ((tile (7 4 0 0)) (text (7 4 0 0)) (gutter (7 4 0 0)) (status (7 4 0 0))
     (offset 0) (areas ()))
    ((tile (7 4 0 0)) (text (7 4 0 0)) (gutter (7 4 0 0)) (status (7 4 0 0))
     (offset 0) (areas ()))
    |}]
;;

let%expect_test "full-screen defaults are unchanged and pane placement stays in bounds" =
  let inside (outer : Geometry.Rect.t) (r : Geometry.Rect.t) =
    assert (r.width >= 0 && r.height >= 0);
    assert (r.x >= outer.x && r.y >= outer.y);
    assert (r.x + r.width <= outer.x + Int.max 0 outer.width);
    assert (r.y + r.height <= outer.y + Int.max 0 outer.height)
  in
  List.iter [ -1; 0; 1; 17; 20; 24; 40; 160 ] ~f:(fun width ->
    List.iter [ -1; 0; 1; 4; 5; 6; 8 ] ~f:(fun height ->
      List.iter [ false; true ] ~f:(fun centered ->
        List.iter [ -500; 0; 500 ] ~f:(fun offset ->
          let prefs = { Geometry.Prefs.default with centered; offset; line_numbers = Hybrid } in
          let zero = { Geometry.Rect.x = 0; y = 0; width; height } in
          [%test_result: Sexp.t]
            (Geometry.sexp_of_t (Geometry.compute prefs ~width ~height ~line_count:1000))
            ~expect:(Geometry.sexp_of_t
              (Geometry.compute_in prefs ~allocation:zero ~reserve_status_row:true ~line_count:1000));
          let allocation = { zero with x = 7; y = 4 } in
          List.iter [ false; true ] ~f:(fun reserve_status_row ->
            let g = Geometry.compute_in prefs ~allocation ~reserve_status_row ~line_count:1000 in
            List.iter ([ g.tile; g.text; g.gutter; g.status ]
                       @ List.map g.areas ~f:(fun area -> area.rect))
              ~f:(inside allocation))))));
  print_endline "full-screen compatibility and allocation bounds passed";
  [%expect {| full-screen compatibility and allocation bounds passed |}]
;;

let%expect_test "pane rendering leaves backdrop above and below and offsets the cursor" =
  let t = ui "abcdef\nsecond\nthird\nfourth" in
  let allocation = { Geometry.Rect.x = 3; y = 2; width = 8; height = 3 } in
  List.iter [ false; true ] ~f:(fun reserve_status_row ->
    let frame = Frame.render ~allocation ~reserve_status_row t ~width:15 ~height:7 in
    print_endline (Frame.to_string frame));
  [%expect {|
                   |
                   |
       abcdef      |
       second      |
       third       |
                   |
                   |
    cursor: 3,2 Block
                   |
                   |
       abcdef      |
       second      |
        NORMAL     |
                   |
                   |
    cursor: 3,2 Block
    |}]
;;

let%expect_test "scroll and Unicode clipping use pane size, cursor uses terminal origin" =
  let t = run (ui "zero\nfirst\nsecond\n0123456789中éXYZ\nlast") (keys "3j10l") in
  let allocation = { Geometry.Rect.x = 3; y = 2; width = 4; height = 2 } in
  let scroll = Ui_state.fitted_scroll_in t ~allocation ~reserve_status_row:false in
  print_s [%sexp (scroll : Scroll.t)];
  print_endline (Frame.to_string
    (Frame.render ~allocation ~reserve_status_row:false t ~width:10 ~height:6));
  [%expect {|
    ((top 2) (left 8))
              |
              |
              |
       89中   |
              |
              |
    cursor: 5,3 Block
    |}]
;;

let%expect_test "border title, gutter, text, and status translate together" =
  let prefs = { Geometry.Prefs.default with width = 20; line_numbers = Hybrid } in
  let t = run ~width:40 ~height:8 (ui ~prefs "one\n\tx中é\nthree") (keys "j2l") in
  List.iter [ false; true ] ~f:(fun reserve_status_row ->
    let local = Frame.render ~reserve_status_row t ~width:40 ~height:8 in
    let allocation = { Geometry.Rect.x = 7; y = 4; width = 40; height = 8 } in
    let shifted = Frame.render ~allocation ~reserve_status_row t ~width:54 ~height:16 in
    List.iteri local.rows ~f:(fun i spans ->
      let expected = Span.merge
          ([ Span.blank Backdrop 7 ] @ spans @ [ Span.blank Backdrop 7 ]) in
      [%test_result: Sexp.t]
        ([%sexp (List.nth_exn shifted.rows (i + 4) : Span.t list)])
        ~expect:([%sexp (expected : Span.t list)]));
    assert ([%equal: Frame.Cursor.t option] shifted.cursor
      (Option.map local.cursor ~f:(fun c -> { c with x = c.x + 7; y = c.y + 4 })));
    List.iter (List.take shifted.rows 4 @ List.drop shifted.rows 12) ~f:(fun spans ->
      assert (List.for_all spans ~f:(fun span -> Style.equal span.style Backdrop))));
  print_endline "all document decorations and cursor translated; surrounding rows untouched";
  [%expect {| all document decorations and cursor translated; surrounding rows untouched |}]
;;

let%expect_test "render allocation is clipped to the screen, including empty intersections" =
  let t = ui "abcdef\nnext" in
  List.iter
    [ { Geometry.Rect.x = -2; y = -1; width = 6; height = 3 }
    ; { Geometry.Rect.x = 6; y = 3; width = 10; height = 10 }
    ; { Geometry.Rect.x = 20; y = 20; width = 2; height = 2 }
    ; { Geometry.Rect.x = 2; y = 1; width = 0; height = 0 }
    ]
    ~f:(fun allocation ->
      let frame = Frame.render ~allocation ~reserve_status_row:false t ~width:8 ~height:4 in
      List.iter frame.rows ~f:(fun spans ->
        assert (List.sum (module Int) spans ~f:(fun span -> span.width) = 8));
      print_endline (Frame.to_string frame));
  [%expect {|
    abcd    |
    next    |
            |
            |
    cursor: 0,0 Block
            |
            |
            |
          ab|
    cursor: 6,3 Block
            |
            |
            |
            |
    cursor: none
            |
            |
            |
            |
    cursor: none
    |}]
;;
