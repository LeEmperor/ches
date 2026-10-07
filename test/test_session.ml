open! Core
open Ches_core
open Ches_app

let width _ = 1
let with_files f =
  let directory = Core_unix.mkdtemp "/tmp/opencode/ches-session-" in
  let a = Filename.concat directory "a.ml" and b = Filename.concat directory "b.ml" in
  Out_channel.write_all a ~data:"alpha\n";
  Out_channel.write_all b ~data:"beta\n";
  Exn.protect ~f:(fun () -> f directory a b)
    ~finally:(fun () ->
      List.iter [ a; b; Filename.concat directory "later.ml" ] ~f:(fun path ->
        if Option.is_some (Option.try_with (fun () -> Core_unix.lstat path)) then Core_unix.unlink path);
      Core_unix.rmdir directory)
;;
let start path = Session.create ~cell_width:width (Controller.open_file ~cell_width:width path |> Or_error.ok_exn)
let keys t notation = List.fold (Key_notation.keys notation) ~init:t ~f:(fun t input ->
  let t, _, status = Session.handle_input t input in assert (Controller.Status.equal status Running); t)
let editor t = Controller.editor (Option.value_exn (Session.active_controller t))
let text t = Text_buffer.to_string (Editor.text (editor t))

let%test_unit "lexical identity and independent lifetime/history/register/highlights" =
  with_files (fun directory a b ->
    assert (String.equal (Resource.normalize ~cwd:directory "./x/../a.ml//") a);
    assert (String.equal (Resource.normalize ~cwd:directory "/../../a") "/a");
    let t = start a in
    let aid = Option.value_exn (Session.active_id t) in
    let t = keys t "iA" in
    let parses = Controller.highlight_parse_count (Option.value_exn (Session.active_controller t)) in
    let t, bid = Session.open_or_activate t b |> Or_error.ok_exn in
    let a_key, _ = Controller.highlights (Option.value_exn (Session.find t aid)) in
    let b_key, _ = Controller.highlights (Option.value_exn (Session.find t bid)) in
    assert (not (Ches_highlight.Snapshot.Key.same_document a_key b_key));
    assert (Mode.equal (Editor.mode (Controller.editor (Option.value_exn (Session.find t aid)))) Normal);
    let t = keys t "iB<Esc>" in
    let t, same = Session.open_or_activate t (Filename.concat directory "./a.ml") |> Or_error.ok_exn in
    assert (Buffer_id.equal same aid && List.length (Session.buffers t) = 2);
    assert (String.equal (text t) "Aalpha\n");
    assert (Controller.highlight_parse_count (Option.value_exn (Session.active_controller t)) = parses);
    let t = keys t "uyy" in
    assert (String.equal (text t) "alpha\n");
    let t, clipboard = Session.take_clipboard t in
    assert (Option.equal String.equal clipboard (Some "alpha\n"));
    let t = Session.activate t bid |> Or_error.ok_exn in
    let t, clipboard = Session.take_clipboard t in
    assert (Option.is_none clipboard);
    assert (String.equal (text t) "Bbeta\n");
    let t = keys t "up" in
    assert (String.equal (text t) "beta\nalpha\n");
    let key, _ = Controller.highlights (Option.value_exn (Session.active_controller t)) in
    assert (Ches_highlight.Snapshot.Key.revision key = Editor.revision (editor t));
    Session.dispose t)
;;

let%test_unit "switch cancels outgoing and incoming prefixes and visual context" =
  with_files (fun _ a b ->
    let t = start a |> fun t -> keys t "d" in
    let aid = Option.value_exn (Session.active_id t) in
    let t, bid = Session.open_or_activate t b |> Or_error.ok_exn in
    let t = keys t "l" in
    assert (String.equal (text t) "beta\n");
    let t = Session.activate t aid |> Or_error.ok_exn |> fun t -> keys t "l" in
    assert (String.equal (text t) "alpha\n");
    let t = keys t "v" in
    let t = Session.activate t bid |> Or_error.ok_exn in
    let t = Session.activate t aid |> Or_error.ok_exn in
    assert (Mode.equal (Editor.mode (editor t)) Normal);
    let before = List.length (Session.buffers t) in
    assert (Result.is_error (Session.open_or_activate t (Filename.dirname a)));
    assert (List.length (Session.buffers t) = before);
    let t = keys t "0d" in
    let t, closed = Session.close_buffer t bid ~force:false in
    assert (closed && Option.equal Buffer_id.equal (Session.active_id t) (Some aid));
    let t = keys t "w" in
    assert (String.equal (text t) "\n");
    Session.dispose t)
;;

let%test_unit "symlink aliases stay distinct and lexical normalization also governs IO" =
  with_files (fun directory a _ ->
    let alias = Filename.concat directory "alias.ml" in
    Core_unix.symlink ~target:a ~link_name:alias;
    Exn.protect ~finally:(fun () -> Core_unix.unlink alias) ~f:(fun () ->
      let t = start a in
      let aid = Option.value_exn (Session.active_id t) in
      let t, aliasid = Session.open_or_activate t alias |> Or_error.ok_exn in
      assert (not (Buffer_id.equal aid aliasid) && List.length (Session.buffers t) = 2);
      let lexical = Filename.concat directory "does-not-exist/../a.ml" in
      let controller = Controller.open_file ~cell_width:width lexical |> Or_error.ok_exn in
      assert (String.equal (Text_buffer.to_string (Editor.text (Controller.editor controller))) "alpha\n");
      assert (Option.equal String.equal (Editor.path (Controller.editor controller)) (Some a));
      Controller.close controller;
      Session.dispose t))
;;

let%test_unit "save-current, partial save-all, hidden dirty quit, close versus exit" =
  with_files (fun directory a b ->
    let t = start a |> fun t -> keys t "iA<Esc>" in
    let aid = Option.value_exn (Session.active_id t) in
    let t, bid = Session.open_or_activate t b |> Or_error.ok_exn in
    let t = keys t "iB<Esc>v" |> Session.save_current in
    assert (Mode.equal (Editor.mode (editor t)) (Visual `Characterwise));
    assert (String.equal (In_channel.read_all a) "alpha\n");
    assert (String.equal (In_channel.read_all b) "Bbeta\n");
    let t, status = Session.quit t ~force:false in
    assert (Controller.Status.equal status Running);
    assert (String.is_substring (Option.value_exn (Ches_error.Error.notification (Session.feedback t))).text ~substring:a);
    let t, closed = Session.close_buffer t aid ~force:false in
    assert (not closed);
    let bad = Filename.concat directory "missing/bad.ml" in
    let t, badid = Session.open_or_activate t bad |> Or_error.ok_exn in
    let t = keys t "iFAIL<Esc>v" in
    let later = Filename.concat directory "later.ml" in
    let t, laterid = Session.open_or_activate t later |> Or_error.ok_exn in
    let t = keys t "iAFTER<Esc>" in
    let second_bad = Filename.concat directory "missing/second.ml" in
    let t, second_badid = Session.open_or_activate t second_bad |> Or_error.ok_exn in
    let t = keys t "iSECOND<Esc>" in
    let t = Session.activate t badid |> Or_error.ok_exn |> fun t -> keys t "v" in
    let t, results = Session.save_all t in
    assert ([%equal: (Buffer_id.t * bool) list] results [ aid, true; badid, false; laterid, true; second_badid, false ]);
    assert (String.equal (In_channel.read_all later) "AFTER");
    assert (Editor.is_dirty (editor t));
    assert (Mode.equal (Editor.mode (editor t)) (Visual `Characterwise));
    assert (Option.equal Buffer_id.equal (Session.active_id t) (Some badid));
    let problems = Ches_error.Error.problems (Session.feedback t) in
    assert (List.length problems = 2);
    List.iter [ bad; second_bad ] ~f:(fun path ->
      assert (List.exists problems ~f:(fun problem -> String.equal problem.identity.resource path)));
    let t, saved = Session.take_saved t in
    assert (List.equal String.equal (List.map saved ~f:(fun s -> s.Controller.Saved.path)) [ b; a; later ]);
    let t, closed = Session.close_current t ~force:true in
    assert closed;
    assert (Option.equal Buffer_id.equal (Session.active_id t) (Some laterid));
    let t, _ = Session.close_current t ~force:false in
    assert (Option.equal Buffer_id.equal (Session.active_id t) (Some second_badid));
    let t, _ = Session.close_current t ~force:true in
    assert (Option.equal Buffer_id.equal (Session.active_id t) (Some bid));
    let t, _ = Session.close_current t ~force:false in
    assert (Option.equal Buffer_id.equal (Session.active_id t) (Some aid));
    let t, _ = Session.close_current t ~force:false in
    assert (Option.is_none (Session.active_id t) && not (Session.exited t));
    let t, reopened = Session.open_or_activate t a |> Or_error.ok_exn in
    assert (not (Buffer_id.equal aid reopened));
    let t, status = Session.quit t ~force:false in
    assert (Controller.Status.equal status Exit && Session.exited t))
;;
