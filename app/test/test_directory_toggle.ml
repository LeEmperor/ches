open! Core
open Ches_input
open Ches_app

let toggle t = let t, _, _ = Session.dispatch t [ Keymap.Action.View Toggle_directory ] in t
let presentation t = Session.directory_presentation t |> Option.value_exn

let fixture f =
  let root = Core_unix.mkdtemp (Filename.concat Filename.temp_dir_name "ches-toggle-") in
  let path = Filename.concat root "file.txt" in
  Out_channel.write_all path ~data:"file\n";
  let cell_width _ = 1 in
  let t = Session.create ~cell_width
    (Startup.open_path ~cell_width path |> Or_error.ok_exn) in
  Exn.protect ~f:(fun () -> f root path t) ~finally:(fun () ->
    Session.dispose t; Core_unix.unlink path; Core_unix.rmdir root)
;;

let%test_unit "file toggle promotes visible and hidden side and remembers the current file" =
  fixture (fun root _ t ->
    List.iter [ false; true ] ~f:(fun hidden ->
      let side = Session.set_directory_placement t Side in
      let id = (presentation side).buffer in
      let file = if hidden then Session.hide_directory side else Session.focus_directory side false in
      let major = toggle file in
      assert (Poly.equal (presentation major).placement Major);
      assert (Buffer_id.equal id (presentation major).buffer);
      assert (Option.equal Buffer_id.equal (presentation major).return_target (Session.active_id file));
      let d = Session.input_directory major |> Option.value_exn in
      assert (String.equal d.path root);
      assert (String.equal (Directory_buffer.selected d |> Option.value_exn).name "file.txt");
      let returned = toggle major in
      assert (Option.is_none (Session.directory_presentation returned));
      assert (Option.equal Buffer_id.equal (Session.active_id file) (Session.context_id returned));
      let again = toggle returned |> toggle in
      assert (Option.equal Buffer_id.equal (Session.context_id returned) (Session.context_id again)));
    let side = Session.set_directory_placement t Side in
    let returned = toggle side in
    assert (Poly.equal (presentation returned).placement Side);
    assert (Option.is_none (Session.input_directory returned)))
;;

let%test_unit "failed parent load preserves side placement, focus and return target" =
  fixture (fun root _ t ->
    let side = Session.set_directory_placement t Side in
    let file = Session.focus_directory side false in
    (* An uncached missing parent makes failure deterministic without permissions. *)
    let missing = Filename.concat root "missing/file.txt" in
    let file, _ = Session.open_or_activate file missing |> Or_error.ok_exn in
    let before = presentation file in
    let after = toggle file in
    assert (Poly.equal before (presentation after));
    assert (Option.is_none (Session.input_directory after));
    assert (Option.equal Buffer_id.equal (Session.active_id file) (Session.active_id after));
    Session.dispose after)
;;
