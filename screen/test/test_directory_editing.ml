open! Core
open Ches_core
open Ches_app
open Ches_screen
open Helpers

let width = 90
let height = 16
let run ui s = Helpers.run ~width ~height ui (keys s)
let directory ui = Session.directory_buffer (Ui_state.session ui) |> Option.value_exn
let dirty ui = Directory_buffer.is_dirty (directory ui)
let message ui s = assert (Option.exists (Ui_state.message ui) ~f:(fun m -> String.is_substring m.text ~substring:s))
let rec remove_fixture path =
  if Poly.equal (Core_unix.lstat path).st_kind Core_unix.S_DIR then (
    Array.iter (Stdlib.Sys.readdir path) ~f:(fun name -> remove_fixture (Filename.concat path name));
    Core_unix.rmdir path)
  else Core_unix.unlink path
;;
let fixture ?directory_config f =
  let root = Core_unix.mkdtemp "/tmp/opencode/ches-edit-directory-" in
  let a = Filename.concat root "a.txt" in
  let b = Filename.concat root "b.txt" in
  Out_channel.write_all a ~data:"a contents";
  Out_channel.write_all b ~data:"b contents";
  Core_unix.mkdir (Filename.concat root "child");
  Exn.protect ~f:(fun () ->
    let ui = Ui_state.create ?directory_config ~tiles_visible:false (Startup.open_path ~cell_width:Cell_map.width root |> Or_error.ok_exn) in
    f root a b ui)
    ~finally:(fun () -> remove_fixture root)
;;

let%test_unit "modal rename, undo, safe save, backing-path open and hidden dirty quit" =
  fixture (fun root a _ ui ->
    let ui = run ui " mmA.renamed<Esc>" in
    assert (dirty ui);
    assert (Set.length (directory ui).marks = 1);
    assert (List.length (Directory_buffer.plan (directory ui) |> Or_error.ok_exn) = 1);
    let frame = Frame.to_string (Frame.render ui ~width ~height) in
    assert (String.is_substring frame ~substring:"1 pending");
    assert (dirty ui && String.equal (In_channel.read_all a) "a contents");
    assert (not (Stdlib.Sys.file_exists (Filename.concat root "a.txt.renamed")));
    let ui = run ui " r" in
    message ui "unsaved edits";
    assert (dirty ui);
    let ui = run ui "<CR>" in
    assert (String.equal (Editor.path (Controller.editor (Ui_state.controller ui)) |> Option.value_exn) a);
    let ui = run ui " q" in
    message ui "Unsaved changes:";
    assert (not (Ui_state.exited ui));
    let ui = run ui "iFILE<Esc>" in
    (* Returning from the directory restores the original file, not pending name. *)
    let ui, outcomes = Ui_state.save_all ui ~width ~height in
    assert (List.length outcomes = 2);
    assert (List.for_all outcomes ~f:snd);
    let renamed = Filename.concat root "a.txt.renamed" in
    assert (not (Stdlib.Sys.file_exists a));
    assert (String.is_prefix (In_channel.read_all renamed) ~prefix:"FILE");
    let ui = run ui " o" in
    assert (not (dirty ui));
    let ui = run ui "u" in
    assert (not (dirty ui));
    assert (Set.length (directory ui).marks = 1);
    let ui = run ui "<C-r>" in
    assert (not (dirty ui) && List.is_empty (Directory_buffer.plan (directory ui) |> Or_error.ok_exn));
    let ui = run ui "u" in
    assert (not (dirty ui));
    Session.dispose (Ui_state.session ui))
;;

let%test_unit "default IDs never appear on active Insert or Visual rows in either placement" =
  fixture (fun _ _ _ ui ->
    let check ui =
      let text = Editor.text (Controller.editor (directory ui).controller) |> Text_buffer.to_string in
      let frame = Frame.to_string (Frame.render ui ~width ~height) in
      assert (not (String.is_substring text ~substring:"@ches["));
      assert (not (String.is_substring frame ~substring:"@ches[")) in
    check ui;
    let ui = run ui "iNEW" in check ui;
    let ui = run ui "<Esc>uVj" in check ui;
    let ui = run ui "<Esc><CR> df ds df" in check ui;
    let ui = run ui "iSIDE" in check ui;
    let ui = run ui "<Esc>uVj" in check ui;
    Session.dispose (Ui_state.session ui))
;;

let%test_unit "exposed backend setting is explicit and survives refresh and navigation" =
  fixture ~directory_config:Directory_buffer.Config.Exposed (fun _ _ _ ui ->
    let visible ui = Text_buffer.to_string (Editor.text (Controller.editor (directory ui).controller)) in
    assert (String.is_prefix (visible ui) ~prefix:"@ches[");
    let ui = run ui " rG<CR>-" in
    assert (String.is_prefix (visible ui) ~prefix:"@ches[");
    Session.dispose (Ui_state.session ui))
;;

let%test_unit "current rows reconcile blanks, reorder, dormant deleted marks, copy and invalid tokens" =
  fixture (fun _ _ _ ui ->
    let ui = run ui " mmdd" in
    assert (Set.length (directory ui).marks = 1);
    assert (List.is_empty (Directory_buffer.marked_entries (directory ui)));
    assert (String.equal (Directory_buffer.selected (directory ui) |> Option.value_exn).name "b.txt");
    assert (String.is_substring (Directory_plan.summary (Directory_buffer.plan (directory ui) |> Or_error.ok_exn)) ~substring:"Permanently delete");
    let ui = run ui "u" in
    assert (List.length (Directory_buffer.marked_entries (directory ui)) = 1);
    let ui = run ui "ddp" in
    assert (List.is_empty (Directory_buffer.plan (directory ui) |> Or_error.ok_exn));
    assert (String.equal (Directory_buffer.selected (directory ui) |> Option.value_exn).name "a.txt");
    let ui = run ui "yyp w" in message ui "copying existing rows is unsupported";
    let ui = run ui "<CR>" in
    assert (List.is_empty (Session.buffers (Ui_state.session ui)));
    let ui = run ui "u0i@<Esc> w" in message ui "Invalid directory plan";
    let ui = run ui "<CR>" in
    assert (List.is_empty (Session.buffers (Ui_state.session ui)));
    let ui = run ui "uo<Esc>" in
    assert (Option.is_none (Directory_buffer.selected (directory ui)));
    let ui = run ui "j" in
    assert (String.equal (Directory_buffer.selected (directory ui) |> Option.value_exn).name "child");
    Session.dispose (Ui_state.session ui))
;;

let%test_unit "fresh rows require save and dirty directory lifecycle preserves placement and navigation" =
  fixture (fun root _ _ ui ->
    let ui = run ui "ofresh/<Esc>" in
    assert (dirty ui);
    let ui = run ui " mm" in message ui "require save";
    assert (Set.is_empty (directory ui).marks);
    let ui = run ui "<CR>" in message ui "requires save";
    assert (String.equal (directory ui).path root);
    assert (not (Stdlib.Sys.file_exists (Filename.concat root "fresh")));
    let id = (directory ui).id in
    let session, closed = Session.close_buffer (Ui_state.session ui) id ~force:false in
    assert (not closed && Session.has_buffer session id);
    let ui = run ui " ds dmG<CR>-" in
    assert (Buffer_id.equal (directory ui).id id && dirty ui);
    let ui = run ui "gg<CR>" in
    let ui = run ui " ds dh ds" in
    assert (Buffer_id.equal (directory ui).id id && dirty ui);
    let ui = run ui " w" in message ui "Create directory fresh/";
    assert (Stdlib.Sys.is_directory (Filename.concat root "fresh"));
    assert (not (dirty ui));
    let session, closed = Session.close_buffer (Ui_state.session ui) id ~force:true in
    assert (closed && not (Session.has_buffer session id));
    Session.dispose session)
;;

let%test_unit "visual opens use current listing order, skip fresh rows and resolve pending backing paths" =
  fixture (fun _ a b ui ->
    let ui = run ui "ddpA.new<Esc>ofresh<Esc>ggV2j<CR>" in
    message ui "new rows require save";
    let paths = Session.buffers (Ui_state.session ui) |> List.map ~f:(fun (_, c) -> Editor.path (Controller.editor c) |> Option.value_exn) in
    assert (List.equal String.equal paths [ b; a ]);
    assert (String.equal (Editor.path (Controller.editor (Ui_state.controller ui)) |> Option.value_exn) b);
    let ui = run ui " o ds" in
    assert (dirty ui);
    let ui = run ui "<Tab>" in
    let rendered = Frame.to_string (Frame.render ui ~width ~height) in
    assert (String.is_substring rendered ~substring:"2 pending");
    let ui, outcomes = Ui_state.save_all ui ~width ~height in
    assert (List.length outcomes = 1 && snd (List.hd_exn outcomes));
    assert (String.equal (In_channel.read_all (a ^ ".new")) "a contents" && String.equal (In_channel.read_all b) "b contents");
    Session.dispose (Ui_state.session ui))
;;

let%test_unit "directory controllers cannot write listing text even when called outside Session" =
  fixture (fun _ a _ ui ->
    let controller = Controller.with_path (directory ui).controller a in
    let controller, _, _ = Controller.dispatch controller
      [ Ches_input.Keymap.Action.Editor (Enter_insert Before_cursor)
      ; Editor (Insert_text "edited listing")
      ; Editor Exit_insert; Editor Save; Editor Reload ] in
    assert (Editor.is_dirty (Controller.editor controller));
    assert (String.equal (In_channel.read_all a) "a contents");
    assert (Option.is_none (snd (Controller.take_saved controller)));
    Session.dispose (Ui_state.session ui))
;;

let%test_unit "rename restarts diagnostic lifetime even at unchanged text revision and on returning to old path" =
  fixture (fun _ a _ _ ->
    let ui = Ui_state.create ~tiles_visible:false ~source_attached:true
      (Controller.open_file ~cell_width:Cell_map.width a |> Or_error.ok_exn) in
    let ui, _ = Ui_state.take_source_requests ui in
    let id = Session.active_id (Ui_state.session ui) |> Option.value_exn in
    let original_generation = Session.source_generation (Ui_state.session ui) id |> Option.value_exn in
    let event resource generation message : Ches_error.Source_event.t =
      Owned { resource; generation; event = Diagnostics { source = "checker"; resource; revision = None
        ; findings = [ { severity = Error; message; location = Some { line = 1; column = 1 } } ] } } in
    let receive ui event = Helpers.run ~width ~height ui [ Ui_state.Input.Source event ] in
    let collections ui = Ches_error.Error.Diagnostics.collections
      (Ches_error.Error.diagnostics (Controller.feedback (Ui_state.controller ui))) in
    let ui = receive ui (event a original_generation "old diagnostics") in
    assert (List.length (collections ui) = 1);
    let ui = run ui " oA.new<Esc> w" in
    assert (List.is_empty (collections ui));
    let ui, requests = Ui_state.take_source_requests ui in
    let new_generation = Session.source_generation (Ui_state.session ui) id |> Option.value_exn in
    assert (original_generation <> new_generation);
    assert (List.exists requests ~f:(function Document_closed { resource } -> String.equal resource a | _ -> false));
    assert (List.exists requests ~f:(function Document_opened { resource; generation } ->
      String.equal resource (a ^ ".new") && generation = new_generation | _ -> false));
    assert (List.exists requests ~f:(function Document_changed { resource; revision; _ } ->
      String.equal resource (a ^ ".new") && revision = 0 | _ -> false));
    let ui = receive ui (event a original_generation "late old resource") in
    let ui = receive ui (event (a ^ ".new") original_generation "wrong generation") in
    assert (List.is_empty (collections ui));
    let ui = receive ui (event (a ^ ".new") new_generation "new diagnostics") in
    assert (List.length (collections ui) = 1);
    let ui = run ui "$3h4x w" in
    assert (List.is_empty (collections ui));
    let ui = receive ui (event a original_generation "late first lifetime") in
    assert (List.is_empty (collections ui));
    let ui, requests = Ui_state.take_source_requests ui in
    assert (List.exists requests ~f:(function Document_opened { resource; generation } ->
      String.equal resource a && generation <> original_generation && generation <> new_generation | _ -> false));
    Session.dispose (Ui_state.session ui))
;;
