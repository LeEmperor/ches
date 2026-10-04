open! Core
open Ches_core
open Ches_screen
open Helpers

let rect ({ x; y; width; height } : Geometry.Rect.t) =
  sprintf "%d,%d %dx%d" x y width height
;;

let summary ?(width = 80) ?(height = 12) t =
  let requested = Ui_state.workspace_prefs t in
  let w = Ui_state.workspace t ~width ~height in
  printf "visible %b zen %b size %d; document %s; status %s; row %b\n"
    requested.status_visible (Ui_state.zen t) requested.split.status_size
    (rect w.document.rect)
    (Option.value_map w.status ~default:"none" ~f:(fun pane -> rect pane.rect))
    w.reserve_status_row
;;

let%expect_test "workspace keys place cells on all sides and remember both axis sizes" =
  let t = ui "hello" in
  summary t;
  ignore (List.fold [ " vt"; " vp+"; " vph"; " vpk"; " vp="; " vpj"; " vpl"; " vt"; " vt" ]
    ~init:t ~f:(fun t input ->
      let t = run ~width:80 ~height:12 t (keys input) in
      summary t;
      t) : Ui_state.t);
  [%expect {| |}]
;;

let%expect_test "zen and resize restore requested placement without changing document preferences" =
  let t = run ~width:160 ~height:24 (ui "hello") (keys " vL vph") in
  summary ~width:160 ~height:24 t;
  summary ~width:40 ~height:24 t;
  summary ~width:23 ~height:24 t;
  summary ~width:160 ~height:24 t;
  let t = run ~width:160 ~height:24 t (keys " vz") in
  summary ~width:160 ~height:24 t;
  let t = run ~width:160 ~height:24 t (keys " vpk vp+") in
  summary ~width:160 ~height:24 t;
  let t = run ~width:160 ~height:24 t (keys " vz") in
  summary ~width:160 ~height:24 t;
  let t = run ~width:160 ~height:24 t (keys " vpl") in
  summary ~width:160 ~height:24 t;
  printf "document offset %d width %d\n" (Ui_state.prefs t).offset (Ui_state.prefs t).width;
  [%expect {| |}]
;;

let%expect_test "document and status compose in separate rectangles with one document cursor" =
  let right = run ~width:40 ~height:4 (ui "hello\nworld") (keys " vt") in
  print_endline (Frame.to_string (Frame.render right ~width:40 ~height:4));
  let left = run ~width:40 ~height:4 right (keys " vph") in
  print_endline (Frame.to_string (Frame.render left ~width:40 ~height:4));
  let above = run ~width:40 ~height:8 left (keys " vpk") in
  print_endline (Frame.to_string (Frame.render above ~width:40 ~height:8));
  [%expect {| |}]
;;

let%expect_test "workspace transitions preserve editor state and undo/redo behavior" =
  let t = run ~width:80 ~height:12 (ui "abc") (keys "iX<Esc>") in
  let editor = Ches_app.Controller.editor (Ui_state.controller t) in
  let t = List.fold [ " vt"; " vph"; " vp+"; " vpk"; " vp-"; " vpj"; " vpl"; " vz"; " vt"; " vz"; " vr" ]
      ~init:t ~f:(fun t command ->
        let t = run ~width:80 ~height:12 t (keys command) in
        (* Identity verifies all document, cursor, revision, and history state remains
           untouched, not just the visible text. *)
        assert (phys_equal editor (Ches_app.Controller.editor (Ui_state.controller t)));
        t)
  in
  let undone = run ~width:80 ~height:12 t (keys "u") in
  let redone = run ~width:80 ~height:12 undone (keys "<C-r>") in
  List.iter [ t; undone; redone ] ~f:(fun t ->
    let editor = Ches_app.Controller.editor (Ui_state.controller t) in
    print_s [%sexp (Text_buffer.to_string (Editor.text editor) : string), (Editor.is_dirty editor : bool)]);
  [%expect {|
    (Xabc true)
    (abc false)
    (Xabc true)
    |}]
;;

let%expect_test "errors and pending feedback survive workspace, compact, and zen transitions" =
  let t = run ~width:160 ~height:12 (ui "hello") (keys "iX<Esc> q") in
  let error = Ui_state.message t in
  let t = run ~width:160 ~height:12 t (keys " vt") in
  assert ([%equal: Ui_state.Message.t option] error (Ui_state.message t));
  let pending = run ~width:160 ~height:12 t (keys " ") in
  List.iter [ 160, 12; 23, 12; 1, 1; 0, 0; 160, 12 ] ~f:(fun (width, height) ->
    let frame = Frame.render pending ~width ~height in
    assert (List.length frame.rows = height);
    List.iter frame.rows ~f:(fun row -> assert (Span.total_width row = width));
    if width = 160 then (
      let text = Frame.to_string frame in
      assert (String.is_substring text ~substring:"Space");
      assert (String.is_substring text ~substring:"Unsaved changes")));
  let zen = run ~width:160 ~height:12 pending (keys "<Esc> vz ") in
  assert ([%equal: Ui_state.Message.t option] error (Ui_state.message zen));
  let frame = Frame.render zen ~width:160 ~height:12 in
  let bottom = String.concat (List.map (List.last_exn frame.rows) ~f:(fun span -> span.text)) in
  assert (String.is_substring bottom ~substring:"NORMAL");
  assert (String.is_substring bottom ~substring:"Space");
  assert (String.is_substring bottom ~substring:"Unsaved changes");
  print_endline "error message preserved; mode, pending, and error visible in tile and zen";
  [%expect {| error message preserved; mode, pending, and error visible in tile and zen |}]
;;

let%expect_test "workspace scrolling and frame cursor share geometry through all placements" =
  let source = String.concat (List.init 40 ~f:(fun _ -> "0123456789\t中éXYZ\n")) in
  let t = run ~width:80 ~height:12 (ui source) (keys "30j12l vt") in
  ignore (List.fold [ " vph"; " vpl"; " vpk"; " vpj"; " vz"; " vz" ] ~init:t ~f:(fun t command ->
    let t = run ~width:80 ~height:12 t (keys command) in
    List.iter [ 80, 12; 24, 4; 10, 3; 0, 0; 80, 12 ] ~f:(fun (width, height) ->
      let g = Ui_state.geometry t ~width ~height in
      let frame = Frame.render t ~width ~height in
      List.iter frame.rows ~f:(fun row -> assert (Span.total_width row = width));
      match frame.cursor with
      | None -> assert (g.text.width = 0 || g.text.height = 0)
      | Some cursor ->
        assert (cursor.x >= g.text.x && cursor.x < g.text.x + g.text.width);
        assert (cursor.y >= g.text.y && cursor.y < g.text.y + g.text.height);
        assert ([%equal: (int * int) option] (Ui_state.cursor_position t ~width ~height) (Some (cursor.x, cursor.y))));
    let t = run ~width:80 ~height:12 t (keys "<C-e><C-y><C-d><C-u>ztzzzb") in
    t) : Ui_state.t);
  print_endline "shared scroll/cursor geometry passed for workspace, compact, zen, and resize";
  [%expect {| shared scroll/cursor geometry passed for workspace, compact, zen, and resize |}]
;;

let%expect_test "paste and Insert keys never become workspace actions; prefixes cancel cleanly" =
  let t = run (ui "") (keys "i" @ paste " vt vz vph" @ keys "<Esc>") in
  assert (not (Ui_state.workspace_prefs t).status_visible && not (Ui_state.zen t));
  let text = Text_buffer.to_string (Editor.text (Ches_app.Controller.editor (Ui_state.controller t))) in
  print_s [%sexp (text : string)];
  let t = run t (keys " vp<Esc> vpx") in
  assert (not (Ui_state.workspace_prefs t).status_visible);
  print_s [%sexp (Ui_state.message t : Ui_state.Message.t option)];
  let t = run t (keys "2 vt") in
  assert (not (Ui_state.workspace_prefs t).status_visible);
  print_s [%sexp (Ui_state.message t : Ui_state.Message.t option)];
  [%expect {| |}]
;;
