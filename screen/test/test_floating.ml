open! Core
open Ches_screen

let rect x y width height : Geometry.Rect.t = { x; y; width; height }
let preferred : Floating.Size.t = { width = 80; height = 14 }
let minimum : Floating.Size.t = { width = 14; height = 4 }
let place bounds = Floating.place ~bounds ~preferred ~minimum

let%expect_test "center, clamp, drop margins only as needed, reject undersized bounds" =
  List.iter
    [ rect 0 0 120 40
    ; rect 7 9 121 41
    ; rect 7 9 80 14
    ; rect 7 9 16 6
    ; rect 7 9 15 5
    ; rect 7 9 14 4
    ; rect 7 9 14 20
    ; rect 7 9 100 4
    ; rect 7 9 13 40
    ; rect 7 9 120 3
    ; rect 7 9 0 0
    ; rect 7 9 (-1) (-2)
    ]
    ~f:(fun bounds -> print_s [%sexp (place bounds : Geometry.Rect.t option)]);
  [%expect {|
    (((x 20) (y 13) (width 80) (height 14)))
    (((x 27) (y 22) (width 80) (height 14)))
    (((x 8) (y 10) (width 78) (height 12)))
    (((x 8) (y 10) (width 14) (height 4)))
    (((x 7) (y 9) (width 15) (height 5)))
    (((x 7) (y 9) (width 14) (height 4)))
    (((x 7) (y 12) (width 14) (height 14)))
    (((x 17) (y 9) (width 80) (height 4)))
    ()
    ()
    ()
    ()
  |}]
;;

let%expect_test "normalize preferences and minimum sizes" =
  print_s
    [%sexp
      (Floating.place
         ~bounds:(rect 3 5 10 8)
         ~preferred:{ width = -20; height = 0 }
         ~minimum:{ width = 4; height = 3 }
       : Geometry.Rect.t option)];
  print_s
    [%sexp
      (Floating.place
         ~bounds:(rect 3 5 1 1)
         ~preferred:{ width = 0; height = -1 }
         ~minimum:{ width = -1; height = 0 }
       : Geometry.Rect.t option)];
  [%expect {|
    (((x 6) (y 7) (width 4) (height 3)))
    (((x 3) (y 5) (width 1) (height 1)))
  |}]
;;

let%test_unit "placement invariants and resize restoration across terminal sizes" =
  for width = -2 to 125 do
    for height = -2 to 45 do
      let bounds = rect 7 9 width height in
      let original = place bounds in
      ignore (place (rect 7 9 (width / 2) (height / 2)) : Geometry.Rect.t option);
      assert ([%equal: Geometry.Rect.t option] original (place bounds));
      match original with
      | None -> assert (width < minimum.width || height < minimum.height)
      | Some outer ->
        assert (outer.width >= minimum.width && outer.height >= minimum.height);
        assert (outer.x >= bounds.x && outer.y >= bounds.y);
        assert (outer.x + outer.width <= bounds.x + width);
        assert (outer.y + outer.height <= bounds.y + height);
        let left = outer.x - bounds.x in
        let top = outer.y - bounds.y in
        assert (Int.abs (left - (width - outer.width - left)) <= 1);
        assert (Int.abs (top - (height - outer.height - top)) <= 1);
        if width >= minimum.width + 2 then assert (left >= 1);
        if height >= minimum.height + 2 then assert (top >= 1)
    done
  done
;;

let floating_layout bounds =
  Floating.layout ~bounds ~preferred ~minimum
    ~policy:{ Tile_shell.Policy.minor with min_content_height = 2 }
;;

let%test_unit "one shell layout supplies frame, content and terminal cursor origin" =
  List.iter [ rect 7 9 120 40; rect 7 9 14 4 ] ~f:(fun bounds ->
    let layout = Option.value_exn (floating_layout bounds) in
    assert (layout.framed);
    assert (layout.content.width >= 12 && layout.content.height >= 2);
    let rows =
      Tile_shell.render layout ~focused:true
        { title = "Synthetic"; footer = None; body = [ Tile_text.row Status "query" ~width:12 ] }
    in
    assert (List.length rows = layout.outer.height);
    assert (List.for_all rows ~f:(fun row -> Span.total_width row = layout.outer.width));
    let x, y = layout.content.x + 2, layout.content.y in
    assert (x > layout.outer.x && x < layout.outer.x + layout.outer.width - 1);
    assert (y = layout.outer.y + 1))
;;

let%test_unit "floating availability overrides tiled placement and drives the shared host" =
  let t = Ui_state.create (Ui_state.controller (Helpers.ui ~path:"a" "first\nsecond")) in
  let width, height = 120, 40 in
  let workspace = Ui_state.workspace t ~width ~height in
  let geometry = Ui_state.geometry t ~width ~height in
  let scroll = Ui_state.scroll t in
  let id = Ches_tile.View_id.of_string "synthetic-float" in
  let layout = floating_layout (rect 0 0 width height) in
  let available = Ui_state.view_available ~floating:(id, layout) t ~width ~height in
  let host =
    Ches_tile.Host.create ~leader:(Ches_input.Key.char ' ') ~primary:Ui_state.document_id
      [ Ches_tile.Spec.primary Ui_state.document_id ~title:"Document"
      ; Ches_tile.Spec.text_input id ~title:"Synthetic"
      ]
    |> fun host -> Ches_tile.Host.focus host id
  in
  assert (Ches_tile.View_id.equal (Ches_tile.Host.focused host ~available) id);
  assert ([%equal: Tile_shell.Layout.t option]
    (Ui_state.view_layout ~floating:(id, layout) t ~width ~height id) layout);
  assert (not (Ui_state.view_available t ~width ~height id));
  assert (Option.is_some (Ui_state.view_layout t ~width ~height Ui_state.status_id));
  assert (Option.is_none (Ui_state.view_layout t ~width ~height Ui_state.document_id));
  assert (Ui_state.view_available ~floating:(Ui_state.document_id, None) t ~width ~height Ui_state.document_id);
  let unavailable = Ui_state.view_available ~floating:(id, None) t ~width ~height in
  let host, result = Ches_tile.Host.reconcile host ~available:unavailable in
  (match result with
   | `Returned returned -> assert (Ches_tile.View_id.equal returned id)
   | `Kept -> assert false);
  assert (Ches_tile.View_id.equal (Ches_tile.Host.focused host ~available) Ui_state.document_id);
  (* An unavailable float must not accidentally reveal a docked duplicate. *)
  assert (Ui_state.view_available t ~width ~height Problems_tile.id);
  assert (not (Ui_state.view_available ~floating:(Problems_tile.id, None) t ~width ~height Problems_tile.id));
  assert ([%equal: Workspace.t] workspace (Ui_state.workspace t ~width ~height));
  assert ([%equal: Geometry.Rect.t] geometry.text (Ui_state.geometry t ~width ~height).text);
  assert (phys_equal scroll (Ui_state.scroll t));
  assert ([%equal: Tile_shell.Layout.t option]
    (Ui_state.minor_layout t ~width ~height Problems_tile.id)
    (Ui_state.view_layout t ~width ~height Problems_tile.id))
;;
