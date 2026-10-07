open! Core
open Ches_screen
open Ui_state.Input
module Model = Ches_content_picker.Model
let width = 120
let height = 40
let run t keys = Helpers.run ~width ~height t (Helpers.keys keys)
let apply t inputs = Helpers.run ~width ~height t inputs
let request n query : Model.request =
  { run_id = Model.Run_id.of_int n; root = "/project"; query }
let snapshot n query : Model.snapshot =
  { request = request n query; hits = []; status = Model.Status.Loading }
let open_picker ?(release = fun () -> ()) t n =
  Ui_state.open_content_picker t ~width ~height ~snapshot:(snapshot n "") ~release
let picker t = Option.value_exn (Ui_state.content_picker t)
let session t = Content_picker_tile.session (picker t)
let text t = Ches_core.Text_buffer.to_string
  (Ches_core.Editor.text (Ches_app.Controller.editor (Ui_state.controller t)))

let%test_unit "content shared float: zen, workspace/scroll preservation, cursor and exact cancel" =
  List.iter [ false; true ] ~f:(fun zen ->
    let initial = Helpers.ui (String.concat ~sep:"\n" (List.init 100 ~f:(sprintf "line %d"))) in
    let initial = run initial (if zen then " vzG" else "G") in
    let workspace = Ui_state.workspace initial ~width ~height in
    let scroll = Ui_state.scroll initial in
    let baseline = Frame.to_string (Frame.render initial ~width ~height) in
    let releases = ref 0 in
    let opened = open_picker initial 1 ~release:(fun () -> incr releases) |> fun t -> run t "界needle" in
    assert (String.equal (Model.query (session opened)) "界needle");
    assert ([%equal: Workspace.t] workspace (Ui_state.workspace opened ~width ~height));
    assert (Scroll.equal scroll (Ui_state.scroll opened) && String.equal (text initial) (text opened));
    let frame = Frame.render opened ~width ~height in
    let cursor = Option.value_exn frame.cursor in
    let x, y, shape = Option.value_exn (Ui_state.minor_cursor opened ~width ~height) in
    assert (cursor.x = x && cursor.y = y && Ches_tile.Cursor.Shape.equal shape Bar);
    assert (List.is_empty frame.smear);
    let allocation : Geometry.Rect.t = { x = 5; y = 2; width = 60; height = 10 } in
    assert (String.equal
      (Frame.to_string (Frame.render ~allocation initial ~width ~height))
      (Frame.to_string (Frame.render ~allocation opened ~width ~height)));
    let closed = run opened "<Esc>" in
    assert (!releases = 1 && Option.is_none (Ui_state.content_picker closed));
    assert (String.equal baseline (Frame.to_string (Frame.render closed ~width ~height)));
    assert (List.is_empty (snd (Ui_state.take_content_requests closed))))
;;

let%test_unit "content paste isolation, resize and focus: no late paste into document or same-id reopen" =
  let initial = run (Helpers.ui "untouched") " vo" in
  let releases = ref 0 in
  let t = open_picker initial 2 ~release:(fun () -> incr releases) in
  let t = apply t (Paste_start :: Helpers.keys "needle" @ [ Key Enter ] @ Helpers.keys "tail" @ [ Paste_end ]) in
  assert (String.equal (Model.query (session t)) "needle tail");
  let t = Helpers.run ~width:14 ~height:5 t [ Resize ] in
  assert (String.equal (Model.query (session t)) "needle tail");
  let t = run t "<Tab>" in
  assert (!releases = 1 && Ches_tile.View_id.equal (Ui_state.focused_view t ~width ~height) Problems_tile.id);
  let t = open_picker t 3 ~release:(fun () -> incr releases) in
  let t = apply t (Paste_start :: Helpers.keys "OLD") in
  let refused = ref 0 in
  let t' = open_picker t 4 ~release:(fun () -> incr refused) in
  assert (!refused = 1 && phys_equal (picker t') (picker t));
  let t = Helpers.run ~width:13 ~height:5 t' [ Resize ] in
  assert (!releases = 2 && Ui_state.pasting t && Option.is_none (Ui_state.content_picker t));
  let t = apply t (Helpers.keys "late" @ [ Paste_end ]) in
  assert (String.equal (text t) "untouched");
  assert (String.is_substring (Option.value_exn (Ui_state.message t)).text ~substring:"paste dropped");
  let t = open_picker t 5 in
  let t = apply t (Paste_start :: Helpers.keys "OLD") in
  let t = Helpers.run ~width:0 ~height:0 t [ Resize ] in
  (* Programmatic assembly can reopen a text-input identity after the paste ends;
     the old paste remains invalid even with that identity allocated again. *)
  let t = apply t (Helpers.keys "late" @ [ Paste_end ]) in
  let t = open_picker t 6 in
  assert (String.is_empty (Model.query (session t)) && String.equal (text t) "untouched");
  let t = run t "<Esc> cc" in
  assert (Option.is_some (Ui_state.palette t));
  let t = open_picker t 7 in
  assert (Option.is_none (Ui_state.palette t));
  let t = run t "<Esc> fl" in
  assert (Option.is_none (Ui_state.content_picker t) && Option.is_some (Ui_state.line_picker t));
  let t = open_picker t 8 in
  assert (Option.is_none (Ui_state.line_picker t));
  let noticed = run t "<C-c>" in
  assert (Option.is_some (Ui_state.content_picker noticed));
  assert (String.equal (Option.value_exn (Ui_state.capture_notice noticed)) "Escape returns to the editor");
  List.iter [ "<Esc>"; "<Tab>" ] ~f:(fun key ->
    let t = run t key in
    assert (Option.is_none (Ui_state.content_picker t) && String.equal (text t) "untouched"))
;;
