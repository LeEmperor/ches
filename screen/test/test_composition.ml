open! Core
open Ches_screen

let row style text = Span.of_text text ~style ~special:style
let text spans = String.concat (List.map spans ~f:(fun (span : Span.t) -> span.text))
let rect x y width height : Geometry.Rect.t = { x; y; width; height }

let check_row spans width =
  assert (Span.total_width spans = width);
  List.iter spans ~f:(fun span ->
    assert (Stdlib.String.is_valid_utf_8 span.Span.text);
    assert (Cell_map.total_width (Cell_map.glyphs span.text) = span.width))
;;

let%test_unit "opaque coverage, styled edges, padding and horizontal clipping" =
  let base = row Status "abcdefgh" in
  let layer = row Title "XYZ" in
  let check x width expected =
    let result = Span.overlay base ~x ~width layer in
    check_row result 8;
    assert (String.equal (text result) expected)
  in
  check 2 3 "abXYZfgh";
  check (-1) 3 "YZcdefgh";
  check 7 3 "abcdefgX";
  check 2 5 "abXYZ  h";
  check 2 0 "abcdefgh";
  check 20 3 "abcdefgh";
  check (-20) 3 "abcdefgh";
  let result = Span.overlay base ~x:2 ~width:3 layer in
  assert (List.exists result ~f:(fun span ->
    Style.equal span.style Title && String.equal span.text "XYZ"));
  assert (List.exists result ~f:(fun span ->
    Style.equal span.style Status && String.equal span.text "ab"))
;;

let%test_unit "both edges blank cut wide glyphs and discard their combining marks" =
  let base = row Status "a界́bc界́d" in
  let result = Span.overlay base ~x:2 ~width:4 (row Title "WXYZ") in
  check_row result 8;
  assert (String.equal (text result) "a WXYZ d");
  let clipped = Span.overlay (row Status "abcd") ~x:(-1) ~width:6
      (row Title "界́ab界́") in
  check_row clipped 4;
  assert (String.equal (text clipped) " ab ");
  let surviving = Span.overlay base ~x:3 ~width:2 (row Title "XY") in
  check_row surviving 8;
  assert (String.equal (text surviving) "a界́XY界́d")
;;

let%test_unit "combining attachment crosses style spans but never attaches to a clipped base" =
  let base = [ Span.create Status "界" ~width:2
             ; Span.create Title "́" ~width:0
             ; Span.create Hint "xy" ~width:2 ] in
  let kept = Span.overlay base ~x:2 ~width:1 (row Border "Z") in
  check_row kept 4;
  assert (String.equal (text kept) "界́Zy");
  let cut = Span.overlay base ~x:1 ~width:1 (row Border "Z") in
  check_row cut 4;
  assert (String.equal (text cut) " Zxy");
  let layer = [ Span.create Title "e" ~width:1
              ; Span.create Hint "́" ~width:0 ] in
  let kept = Span.overlay (row Status "abcd") ~x:1 ~width:1 layer in
  check_row kept 4;
  assert (String.equal (text kept) "aécd");
  let kept = Span.take (layer @ row Status "xy") ~n:1 in
  check_row kept 1;
  assert (String.equal (text kept) "é")
;;

let%test_unit "Unicode row contract across every overlay edge" =
  List.iter [ ""; "abc"; "界́a界b"; "áb̈界́" ] ~f:(fun source ->
    let base = row Status source in
    let width = Span.total_width base in
    for x = -10 to 10 do
      for size = -1 to 12 do
        List.iter [ ""; "XYZ"; "界́ab界́" ] ~f:(fun source ->
          check_row (Span.overlay base ~x ~width:size (row Title source)) width)
      done
    done)
;;

let synthetic id layout : Frame.Floating_layer.t =
  { id; layout
  ; content =
      { title = "Synthetic"; footer = None
      ; body = [ row Title "é界 synthetic" ] }
  ; cursor = Some { row = 0; column = 3; shape = Bar }
  }
;;

let%test_unit "synthetic shell overlays a complete workspace without mutating allocation" =
  let ui = Ui_state.create (Ui_state.controller (Helpers.ui "first\nsecond")) in
  let width, height = 80, 24 in
  let workspace = Ui_state.workspace ui ~width ~height in
  let base = Frame.render ui ~width ~height in
  let layout = Tile_shell.layout Tile_shell.Policy.minor (rect 17 4 30 8) in
  let layer = synthetic (Ches_tile.View_id.of_string "synthetic") layout in
  let frame = Frame.render ~floating:layer ui ~width ~height in
  let shell = Tile_shell.render layout ~focused:false layer.content in
  List.iteri frame.rows ~f:(fun y actual ->
    check_row actual width;
    let base_row = List.nth_exn base.rows y in
    let expected =
      if y >= 4 && y < 12
      then Span.overlay base_row ~x:17 ~width:30 (List.nth_exn shell (y - 4))
      else base_row
    in
    assert (String.equal (text actual) (text expected));
    assert (String.equal (Sexp.to_string [%sexp (actual : Span.t list)])
              (Sexp.to_string [%sexp (expected : Span.t list)])));
  assert ([%equal: Workspace.t] workspace (Ui_state.workspace ui ~width ~height));
  assert ([%equal: Frame.Cursor.t option] frame.cursor base.cursor);
  assert (String.equal (Frame.to_string base)
            (Frame.to_string (Frame.render ui ~width ~height)))
;;

let%test_unit "focused capture owns a content-relative cursor and suppresses document smear" =
  let ui = Ui_state.create ~tiles_visible:false ~smear_enabled:true
      (Ui_state.controller (Helpers.ui "first\nsecond")) in
  let ui = Helpers.run ~width:80 ~height:24 ui (Helpers.keys " cc") in
  let layout = Tile_shell.layout Tile_shell.Policy.minor (rect 17 4 30 8) in
  let layer = synthetic Palette_tile.id layout in
  let frame = Frame.render ~floating:layer ui ~width:80 ~height:24 in
  assert (List.is_empty frame.smear);
  assert ([%equal: Frame.Cursor.t option] frame.cursor
    (Some { x = layout.content.x + 3; y = layout.content.y; shape = Bar }));
  let frame = Frame.render ~floating:{ layer with cursor = None } ui ~width:80 ~height:24 in
  assert (Option.is_none frame.cursor && List.is_empty frame.smear);
  let frame = Frame.render
      ~floating:{ layer with cursor = Some { row = -1; column = 0; shape = Bar } }
      ui ~width:80 ~height:24 in
  assert (Option.is_none frame.cursor)
;;

let%test_unit "shell layers clip on all terminal edges, including empty frames" =
  let ui = Helpers.ui "界́abc" in
  List.iter [ rect (-5) (-2) 20 8; rect 35 6 20 8; rect 60 30 20 8 ] ~f:(fun outer ->
    let layer = synthetic (Ches_tile.View_id.of_string "synthetic")
        (Tile_shell.layout Tile_shell.Policy.minor outer) in
    List.iter [ 40, 10; 0, 0; 0, 10; 40, 0 ] ~f:(fun (width, height) ->
      let frame = Frame.render ~floating:layer ui ~width ~height in
      assert (List.length frame.rows = height);
      List.iter frame.rows ~f:(fun row -> check_row row width)))
;;

let%test_unit "an unfocused opaque shell also occludes the document cursor" =
  let ui = Helpers.ui "first" in
  let base = Frame.render ui ~width:40 ~height:10 in
  let cursor = Option.value_exn base.cursor in
  let layer = synthetic (Ches_tile.View_id.of_string "synthetic")
      (Tile_shell.layout Tile_shell.Policy.minor (rect 0 0 40 10)) in
  assert (cursor.x >= 0 && cursor.y >= 0);
  let frame = Frame.render ~floating:layer ui ~width:40 ~height:10 in
  assert (Option.is_none frame.cursor)
;;
