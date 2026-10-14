open! Core
open Ches_core
open Ches_app
open Ches_screen
open Helpers

let width = 60
let height = 12
let run ui notation = Helpers.run ~width ~height ui (keys notation)
let base = "/__ches_session_ui_bookkeeping__/"

let%test_unit "source requests are coalesced, ordered and lifecycle-safe across unrelated UI turns" =
  let a = base ^ "a.txt" and b = base ^ "b.txt" in
  let ui = Ui_state.create ~tiles_visible:false ~source_attached:true
    (Controller.create (Editor.create ~path:a ~cell_width:Cell_map.width Text_buffer.empty)) in
  let aid = Session.active_id (Ui_state.session ui) |> Option.value_exn in
  let generation = Session.source_generation (Ui_state.session ui) aid |> Option.value_exn in
  let ui, requests = Ui_state.take_source_requests ui in
  assert (List.length requests = 2);
  assert (match requests with
    | [ Document_opened opened; Document_changed changed ] ->
      String.equal opened.resource a && opened.generation = generation && String.equal changed.text ""
    | _ -> false);
  let ui, bid = Ui_state.open_file ui ~width ~height b |> Or_error.ok_exn in
  let ui, requests = Ui_state.take_source_requests ui in
  assert (List.length requests = 2);
  let labels = Session.buffer_labels (Ui_state.session ui) in
  let ui = run ui "lyy" in
  let ui = Ui_state.activate_buffer ui ~width ~height aid |> Or_error.ok_exn in
  let ui, requests = Ui_state.take_source_requests ui in
  assert (List.is_empty requests);
  assert (phys_equal labels (Session.buffer_labels (Ui_state.session ui)));
  let before = Ui_state.session ui in
  let ui = run ui "iXYZ<Esc>" in
  let ui, requests = Ui_state.take_source_requests ui in
  assert (match requests with
    | [ Document_changed changed ] -> String.equal changed.resource a && String.equal changed.text "XYZ"
    | _ -> false);
  assert (not (Editor.is_dirty (Controller.editor (Session.find before aid |> Option.value_exn))));
  assert (Editor.revision (Controller.editor (Session.find (Ui_state.session ui) bid |> Option.value_exn)) = 0);
  let ui = run ui "u" in
  let ui, requests = Ui_state.take_source_requests ui in
  assert (match requests with [ Document_changed changed ] -> String.equal changed.text "" | _ -> false);
  assert (not (Editor.is_dirty (Controller.editor (Ui_state.controller ui))));
  let ui, closed = Ui_state.close_current ui ~width ~height ~force:true in
  assert closed;
  let ui, reopened = Ui_state.open_file ui ~width ~height a |> Or_error.ok_exn in
  let new_generation = Session.source_generation (Ui_state.session ui) reopened |> Option.value_exn in
  assert (new_generation > generation);
  let ui, requests = Ui_state.take_source_requests ui in
  assert (match requests with
    | [ Document_closed closed; Document_opened opened; Document_changed changed ] ->
      String.equal closed.resource a && String.equal opened.resource a && opened.generation = new_generation
      && String.equal changed.resource a && String.equal changed.text ""
    | _ -> false);
  let ui, requests = Ui_state.take_source_requests ui in
  assert (List.is_empty requests);
  Session.dispose (Ui_state.session ui)
;;
