open! Core
open Ches_core
open Ches_app
open Ches_screen
open Helpers
module Feedback = Ches_error.Error

let width = 60
let height = 12
let with_files f =
  let directory = Core_unix.mkdtemp "/tmp/opencode/ches-session-ui-" in
  let a = Filename.concat directory "a.ml" and b = Filename.concat directory "b.ml" in
  let lines = String.concat (List.init 50 ~f:(fun i -> sprintf "line %d\n" i)) in
  Out_channel.write_all a ~data:lines;
  Out_channel.write_all b ~data:"beta\n";
  Exn.protect ~f:(fun () -> f a b)
    ~finally:(fun () -> List.iter [ a; b ] ~f:Core_unix.unlink; Core_unix.rmdir directory)
;;
let create a = Ui_state.create ~tiles_visible:false ~source_attached:true
  (Controller.open_file ~cell_width:Cell_map.width a |> Or_error.ok_exn)
let run ui notation = Helpers.run ~width ~height ui (keys notation)
let text ui = Text_buffer.to_string (Editor.text (Controller.editor (Ui_state.controller ui)))
let source ui event = Helpers.run ~width ~height ui [ Ui_state.Input.Source event ]
let diagnostics resource message : Ches_error.Source_event.t =
  Diagnostics { source = "checker"; resource; revision = None
    ; findings = [ { severity = Error; message; location = Some { line = 1; column = 1 } } ] }
let collections ui = Feedback.Diagnostics.collections (Feedback.diagnostics (Controller.feedback (Ui_state.controller ui)))

let%test_unit "per-buffer cursor/scroll and generation-safe paste through UI assembly" =
  with_files (fun a b ->
    let ui = create a |> fun ui -> run ui "30G2l" in
    let aid = Option.value_exn (Session.active_id (Ui_state.session ui)) in
    let scroll = Ui_state.scroll ui and cursor = Editor.cursor (Controller.editor (Ui_state.controller ui)) in
    assert (scroll.top > 0);
    let ui, bid = Ui_state.open_file ui ~width ~height b |> Or_error.ok_exn in
    assert ((Ui_state.scroll ui).top = 0);
    let ui = run ui "l" in
    let ui = Ui_state.activate_buffer ui ~width ~height aid |> Or_error.ok_exn in
    assert (Scroll.equal (Ui_state.scroll ui) scroll);
    assert (Editor.cursor (Controller.editor (Ui_state.controller ui)) = cursor);
    let ui = run ui "i" |> fun ui -> Helpers.run ~width ~height ui [ Paste_start; Key (Ches_input.Key.char 'X') ] in
    let ui = Ui_state.activate_buffer ui ~width ~height bid |> Or_error.ok_exn in
    assert (Ui_state.pasting ui);
    let ui = Ui_state.activate_buffer ui ~width ~height aid |> Or_error.ok_exn in
    let before = text ui in
    let ui = Helpers.run ~width ~height ui [ Paste_end ] in
    assert (String.equal (text ui) before);
    assert (Option.is_none (Ches_input.Keymap.notice (Controller.keymap (Ui_state.controller ui))));
    let ui, closed = Ui_state.close_current ui ~width ~height ~force:false in
    assert closed;
    let ui, closed = Ui_state.close_current ui ~width ~height ~force:false in
    assert (closed && Ui_state.has_document ui && not (Ui_state.exited ui));
    let frame = Frame.render ui ~width ~height in
    assert (String.is_substring (Frame.to_string frame) ~substring:"Directory:");
    assert (Option.is_some (Ui_state.cursor_owner ui ~width ~height));
    let ui, status = Ui_state.apply_all ui ~width ~height (keys " q") in
    assert (Controller.Status.equal status Exit && Ui_state.exited ui))
;;

let%test_unit "inactive and unknown source events never borrow active revisions; held lists release on switch" =
  with_files (fun a b ->
    let ui = create a |> fun ui -> run ui "iX" in
    let aid = Option.value_exn (Session.active_id (Ui_state.session ui)) in
    let revision_a = Editor.revision (Controller.editor (Ui_state.controller ui)) in
    let ui = source ui (diagnostics a "held A") in
    assert (List.is_empty (collections ui));
    let ui, bid = Ui_state.open_file ui ~width ~height b |> Or_error.ok_exn in
    let a_collection = List.find_exn (collections ui) ~f:(fun c -> String.equal c.resource a) in
    assert (Feedback.Diagnostics.Basis.revision a_collection.basis = revision_a);
    let ui = run ui "iXYZ<Esc>" in
    assert (Editor.revision (Controller.editor (Ui_state.controller ui)) <> revision_a);
    let ui = source ui (diagnostics a "inactive A") in
    let a_collection = List.find_exn (collections ui) ~f:(fun c -> String.equal c.resource a) in
    assert (Feedback.Diagnostics.Basis.revision a_collection.basis = revision_a);
    let unknown = Filename.concat (Filename.dirname a) "unknown.ml" in
    let ui = source ui (diagnostics unknown "workspace") in
    let unknown_collection = List.find_exn (collections ui) ~f:(fun c -> String.equal c.resource unknown) in
    assert (Feedback.Diagnostics.Basis.revision unknown_collection.basis = -1);
    let ui = Ui_state.activate_buffer ui ~width ~height aid |> Or_error.ok_exn in
    let ui, _ = Ui_state.close_current ui ~width ~height ~force:true in
    assert (Option.equal Buffer_id.equal (Session.active_id (Ui_state.session ui)) (Some bid));
    let ui, new_id = Ui_state.open_file ui ~width ~height a |> Or_error.ok_exn in
    let ui = source ui (Owned { resource = a; generation = Buffer_id.to_int aid; event = diagnostics a "late old A" }) in
    assert (not (List.exists (collections ui) ~f:(fun c -> String.equal c.resource a)));
    let ui = source ui (Owned { resource = a; generation = Buffer_id.to_int new_id; event = diagnostics a "new A" }) in
    let collection = List.find_exn (collections ui) ~f:(fun c -> String.equal c.resource a) in
    assert (List.exists collection.findings ~f:(fun f -> String.equal f.message "new A"));
    let ui, requests = Ui_state.take_source_requests ui in
    assert (List.exists requests ~f:(function Document_closed { resource } -> String.equal resource a | _ -> false));
    assert (List.count requests ~f:(function Document_changed _ -> true | _ -> false) = 2);
    Session.dispose (Ui_state.session ui))
;;
