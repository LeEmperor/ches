open! Core
open Ches_screen

let request ?(axis = Workspace.Split.Axis.Horizontal) ?(first = Workspace.Pane_id.Document)
  ?(size = 28) () : Workspace.Prefs.t =
  { status_visible = true; split = { axis; first; status_size = size } }
;;

let allocation width height : Geometry.Rect.t = { x = 7; y = 4; width; height }

let rect ({ x; y; width; height } : Geometry.Rect.t) =
  sprintf "%d,%d %dx%d" x y width height
;;

let show prefs width height =
  let t = Workspace.allocate prefs ~allocation:(allocation width height) in
  printf "document %s; status %s; row %b\n"
    (rect t.document.rect)
    (Option.value_map t.status ~default:"none" ~f:(fun p -> rect p.rect))
    t.reserve_status_row
;;

let%expect_test "status follows either split leaf horizontally and vertically" =
  show (request ()) 80 12;
  show (request ~first:Status ()) 80 12;
  show (request ~axis:Vertical ~size:4 ()) 80 12;
  show (request ~axis:Vertical ~first:Status ~size:4 ()) 80 12;
  [%expect {|
    document 7,4 52x12; status 59,4 28x12; row false
    document 35,4 52x12; status 7,4 28x12; row false
    document 7,4 80x8; status 7,12 80x4; row false
    document 7,8 80x8; status 7,4 80x4; row false
    |}]
;;

let%expect_test "compact fallback boundaries and requested-size clamping" =
  List.iter [ 24, 3; 23, 3; 24, 2 ] ~f:(fun (w, h) -> show (request ()) w h);
  List.iter [ 16, 4; 15, 4; 16, 3 ] ~f:(fun (w, h) ->
    show (request ~axis:Vertical ~size:7 ()) w h);
  show (request ~size:(-10) ()) 80 12;
  show (request ~size:500 ()) 80 12;
  show (request ~axis:Vertical ~size:(-10) ()) 80 12;
  show (request ~axis:Vertical ~size:500 ()) 80 12;
  [%expect {|
    document 7,4 16x3; status 23,4 8x3; row false
    document 7,4 23x3; status none; row true
    document 7,4 24x2; status none; row true
    document 7,4 16x1; status 7,5 16x3; row false
    document 7,4 15x4; status none; row true
    document 7,4 16x3; status none; row true
    document 7,4 72x12; status 79,4 8x12; row false
    document 7,4 16x12; status 23,4 64x12; row false
    document 7,4 80x9; status 7,13 80x3; row false
    document 7,4 80x1; status 7,5 80x11; row false
    |}]
;;

let%expect_test "resize and hide restore intent; extra space does not enable status" =
  let prefs = request ~first:Status ~size:32 () in
  List.iter [ 160; 40; 23; 0; 160 ] ~f:(fun w -> show prefs w 24);
  show { prefs with status_visible = false } 160 24;
  show prefs 160 24;
  show Workspace.Prefs.default 400 100;
  print_s [%sexp (prefs : Workspace.Prefs.t)];
  [%expect {|
    document 39,4 128x24; status 7,4 32x24; row false
    document 31,4 16x24; status 7,4 24x24; row false
    document 7,4 23x24; status none; row true
    document 7,4 0x24; status none; row true
    document 39,4 128x24; status 7,4 32x24; row false
    document 7,4 160x24; status none; row true
    document 39,4 128x24; status 7,4 32x24; row false
    document 7,4 400x100; status none; row true
    ((status_visible true)
     (split ((axis Horizontal) (first Status) (status_size 32))))
    |}]
;;

let%expect_test "document placement preferences remain independent and restorable" =
  let workspace = request () in
  let prefs = { Geometry.Prefs.default with offset = 12 } in
  List.iter [ 160; 40; 23; 160 ] ~f:(fun width ->
    let t = Workspace.allocate workspace ~allocation:(allocation width 12) in
    let geometry = Workspace.document_geometry t prefs ~line_count:10 in
    printf "tile %s; text %s; offset %d; status rows %d\n"
      (rect geometry.tile) (rect geometry.text) geometry.offset geometry.status.height);
  let t = Workspace.allocate Workspace.Prefs.default ~allocation:(allocation 160 12) in
  let geometry = Workspace.document_geometry t { prefs with centered = false } ~line_count:10 in
  printf "full-width tile %s; text %s\n" (rect geometry.tile) (rect geometry.text);
  print_s [%sexp (prefs : Geometry.Prefs.t)];
  [%expect {|
    tile 33,4 104x12; text 36,5 100x10; offset 12; status rows 0
    tile 7,4 16x12; text 7,4 16x12; offset 0; status rows 0
    tile 7,4 23x11; text 10,5 19x9; offset 0; status rows 1
    tile 33,4 104x12; text 36,5 100x10; offset 12; status rows 0
    full-width tile 7,4 160x11; text 10,5 156x9
    ((centered true) (width 100) (offset 12) (line_numbers Off) (left_padding 2))
    |}]
;;

let%expect_test "tiny and empty workspace allocations are safe" =
  List.iter [ 1, 1; 0, 5; 5, 0; 0, 0; -2, -3 ] ~f:(fun (width, height) ->
    let prefs = request () in
    show prefs width height;
    let t = Workspace.allocate prefs ~allocation:(allocation width height) in
    let g = Workspace.document_geometry t Geometry.Prefs.default ~line_count:1 in
    printf "text %s; status %s\n" (rect g.text) (rect g.status));
  [%expect {|
    document 7,4 1x1; status none; row true
    text 7,4 1x0; status 7,4 1x1
    document 7,4 0x5; status none; row true
    text 7,4 0x4; status 7,8 0x1
    document 7,4 5x0; status none; row true
    text 7,4 5x0; status 7,4 5x0
    document 7,4 0x0; status none; row true
    text 7,4 0x0; status 7,4 0x0
    document 7,4 0x0; status none; row true
    text 7,4 0x0; status 7,4 0x0
    |}]
;;

let%expect_test "allocations are bounded, disjoint, exhaustive, with stable focus identities" =
  let inside (outer : Geometry.Rect.t) (r : Geometry.Rect.t) =
    assert (r.width >= 0 && r.height >= 0);
    assert (r.x >= outer.x && r.y >= outer.y);
    assert (r.x + r.width <= outer.x + Int.max 0 outer.width);
    assert (r.y + r.height <= outer.y + Int.max 0 outer.height)
  in
  List.iter [ -1; 0; 1; 15; 16; 23; 24; 40; 160 ] ~f:(fun width ->
    List.iter [ -1; 0; 1; 2; 3; 4; 12 ] ~f:(fun height ->
      List.iter [ Workspace.Split.Axis.Horizontal; Vertical ] ~f:(fun axis ->
        List.iter [ Workspace.Pane_id.Document; Status ] ~f:(fun first ->
          List.iter [ false; true ] ~f:(fun status_visible ->
            List.iter [ -10; 0; 1; 4; 28; 500 ] ~f:(fun size ->
              let prefs = { (request ~axis ~first ~size ()) with status_visible } in
              let allocation = allocation width height in
              let t = Workspace.allocate prefs ~allocation in
              assert (Workspace.Pane_id.equal t.document.id Document);
              inside allocation t.document.rect;
              match t.status with
              | None ->
                assert t.reserve_status_row;
                assert (t.document.rect.width = Int.max 0 width);
                assert (t.document.rect.height = Int.max 0 height)
              | Some status ->
                assert status_visible;
                assert (not t.reserve_status_row);
                assert (Workspace.Pane_id.equal status.id Status);
                inside allocation status.rect;
                let d = t.document.rect and s = status.rect in
                assert (d.x + d.width <= s.x || s.x + s.width <= d.x
                        || d.y + d.height <= s.y || s.y + s.height <= d.y);
                assert (d.width * d.height + s.width * s.height
                        = Int.max 0 width * Int.max 0 height)))))));
  print_endline "bounds, disjoint coverage, visibility, and identity checks passed";
  [%expect {| bounds, disjoint coverage, visibility, and identity checks passed |}]
;;
