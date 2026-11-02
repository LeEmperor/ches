open! Core
open Ches_core
open Ches_app

let%test_unit "controller adoption updates session source change and highlight revision" =
  let editor = Editor.create ~path:"/completion-test.ml" ~cell_width:(fun _ -> 1)
      Text_buffer.empty in
  let editor = fst (Editor.dispatch editor (Enter_insert Before_cursor)) in
  let controller = Controller.create editor in
  let session = Session.create ~cell_width:(fun _ -> 1) controller in
  Exn.protect ~f:(fun () ->
    let session, _ = Session.take_source_changes session in
    let edits = [ [ { Text_edit.start = 0; stop = 0; text = "let value = 1" } ] ] in
    let updated = Controller.apply_insert_edits controller ~expected_revision:0
        ~edits ~cursor:13 |> Or_error.ok_exn in
    assert (Controller.last_input_dispatched updated);
    assert (Controller.Document_id.equal (Controller.document_id controller)
              (Controller.document_id updated));
    let session = Session.replace_active session updated in
    let _, changes = Session.take_source_changes session in
    assert (List.length changes = 1);
    assert (Editor.revision (Controller.editor updated) = 1);
    let key, snapshot = Controller.highlights updated in
    assert (Ches_highlight.Snapshot.Key.revision key = 1);
    assert (Ches_highlight.Snapshot.matches snapshot key);
    assert (Result.is_error (Controller.apply_insert_edits updated ~expected_revision:0
                              ~edits ~cursor:13));
    let directory = Controller.create ~kind:Directory editor in
    assert (Result.is_error (Controller.apply_insert_edits directory ~expected_revision:0
                              ~edits ~cursor:13));
    Controller.close directory)
    ~finally:(fun () -> Session.dispose session)
;;
