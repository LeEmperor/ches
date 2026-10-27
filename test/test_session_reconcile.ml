(* Open-buffer reconciliation ([Session.reconcile], [Controller.reconcile_with_disk]):
   after something outside Ches rewrote files, clean buffers are reloaded or marked
   missing, and dirty, busy and unreadable ones are left alone. *)

open! Core
open Ches_core
open Ches_app

let width _ = 1

let with_dir f =
  let directory = Core_unix.mkdtemp (Filename.concat Filename.temp_dir_name "ches-reconcile-") in
  Exn.protect
    ~f:(fun () -> f directory)
    ~finally:(fun () -> ignore (Core_unix.system (sprintf "rm -rf %s" (Filename.quote directory)) : Core_unix.Exit_or_signal.t))
;;

let write path text = Out_channel.write_all path ~data:text
let start path = Session.create ~cell_width:width (Controller.open_file ~cell_width:width path |> Or_error.ok_exn)

let keys t notation =
  List.fold (Key_notation.keys notation) ~init:t ~f:(fun t input ->
    let t, _, _ = Session.handle_input t input in
    t)
;;

let label t id =
  Option.value_exn (List.Assoc.find (Session.buffer_labels t) id ~equal:Buffer_id.equal)
;;

let show ?(dir = "") t (reconciled : Session.Reconciled.t) =
  let ids name list = printf "%s: [%s]\n" name (String.concat ~sep:", " (List.map list ~f:(label t))) in
  ids "reloaded" reconciled.reloaded;
  ids "missing" reconciled.missing;
  ids "dirty" reconciled.dirty;
  ids "busy" reconciled.busy;
  List.iter reconciled.failed ~f:(fun (id, _) -> printf "failed: %s\n" (label t id));
  printf "feedback: %s\n"
    (Option.value_map (Ches_error.Error.notification (Session.feedback t)) ~default:"(none)"
       ~f:(fun n ->
         if String.is_empty dir then n.text
         else String.substr_replace_all n.text ~pattern:dir ~with_:"$DIR"))
;;

let buffer t id =
  let c = Option.value_exn (Session.find t id) in
  let editor = Controller.editor c in
  printf "%s: %S, line %d, column %d, dirty %b, missing %b\n" (label t id)
    (Text_buffer.to_string (Editor.text editor))
    (Editor.cursor_line editor + 1) (Editor.cursor_column editor + 1)
    (Editor.is_dirty editor) (Controller.is_missing c)
;;

let%expect_test "clean buffers within the roots are reloaded or marked missing; others untouched" =
  with_dir (fun dir ->
    let repo = Filename.concat dir "repo" and outside = Filename.concat dir "outside.txt" in
    Core_unix.mkdir repo;
    let a = Filename.concat repo "a.txt" and b = Filename.concat repo "b.txt" in
    let same = Filename.concat repo "same.txt" in
    write a "one\ntwo\nthree\n";
    write b "bee\n";
    write same "same\n";
    write outside "out\n";
    let t = start outside in
    let t, aid = Session.open_or_activate t a |> Or_error.ok_exn in
    let t = keys t "jll" in
    let t, bid = Session.open_or_activate t b |> Or_error.ok_exn in
    let t, sid = Session.open_or_activate t same |> Or_error.ok_exn in
    let oid = Option.value_exn (Session.find_resource t outside) |> fst in
    let t, _ = Session.take_source_changes t in
    write a "ONE\nTWO\nTHREE\n";
    Core_unix.unlink b;
    write outside "changed outside\n";
    let t, reconciled = Session.reconcile t ~under:[ repo ] in
    show t reconciled;
    List.iter [ aid; bid; sid; oid ] ~f:(buffer t);
    let _, changes = Session.take_source_changes t in
    printf "source changes: [%s]\n"
      (String.concat ~sep:", " (List.map changes ~f:(fun (id, _) -> label t id)));
    [%expect
      {|
      reloaded: [a.txt]
      missing: [b.txt]
      dirty: []
      busy: []
      feedback: Reloaded from disk: a.txt; Deleted on disk (kept, marked missing): b.txt
      a.txt: "ONE\nTWO\nTHREE\n", line 2, column 3, dirty false, missing false
      b.txt: "bee\n", line 1, column 1, dirty false, missing true
      same.txt: "same\n", line 1, column 1, dirty false, missing false
      outside.txt: "out\n", line 1, column 1, dirty false, missing false
      source changes: [a.txt]
      |}];
    (* The missing file comes back: reloaded, no longer missing. Nothing else changed,
       so a second pass changes nothing and says nothing. *)
    write b "bee again\n";
    let t, reconciled = Session.reconcile t ~under:[ b ] in
    show t reconciled;
    buffer t bid;
    let t', reconciled = Session.reconcile t ~under:[ repo ] in
    printf "unchanged session: %b\n" (phys_equal t t');
    show t' reconciled;
    [%expect
      {|
      reloaded: [b.txt]
      missing: []
      dirty: []
      busy: []
      feedback: Reloaded from disk: b.txt
      b.txt: "bee again\n", line 1, column 1, dirty false, missing false
      unchanged session: true
      reloaded: []
      missing: []
      dirty: []
      busy: []
      feedback: Reloaded from disk: b.txt
      |}];
    Session.dispose t)
;;

let%expect_test "dirty, busy and unreadable buffers are left alone" =
  with_dir (fun dir ->
    let a = Filename.concat dir "a.txt" and b = Filename.concat dir "b.txt" in
    let c = Filename.concat dir "c.txt" in
    write a "a\n";
    write b "b\n";
    write c "c\n";
    let t = start a in
    let aid = Option.value_exn (Session.active_id t) in
    let t = keys t "iA<Esc>" in
    let t, cid = Session.open_or_activate t c |> Or_error.ok_exn in
    let t, bid = Session.open_or_activate t b |> Or_error.ok_exn in
    (* b is active and in Insert mode, still clean. *)
    let t = keys t "i" in
    write a "a on disk\n";
    write b "b on disk\n";
    Core_unix.unlink c;
    Core_unix.mkdir c;
    let t, reconciled = Session.reconcile t ~under:[ dir ] in
    (* The read failure is a reload problem, which outranks the summary. *)
    show ~dir t reconciled;
    List.iter [ aid; bid; cid ] ~f:(buffer t);
    [%expect
      {|
      reloaded: []
      missing: []
      dirty: [a.txt]
      busy: [b.txt]
      failed: c.txt
      feedback: Failed to reload $DIR/c.txt: is a directory
      a.txt: "Aa\n", line 1, column 1, dirty true, missing false
      b.txt: "b\n", line 1, column 1, dirty false, missing false
      c.txt: "c\n", line 1, column 1, dirty false, missing false
      |}];
    let problems = Ches_error.Error.problems (Session.feedback t) in
    printf "problems: %d\n" (List.length problems);
    [%expect {| problems: 1 |}];
    Session.dispose t)
;;
