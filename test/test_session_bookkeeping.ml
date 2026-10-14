open! Core
open Ches_core
open Ches_app

let width _ = 1
let base = "/__ches_session_bookkeeping__/"
let start path = Session.create ~cell_width:width
  (Controller.create (Editor.create ~path ~cell_width:width Text_buffer.empty))
let open_path t path = Session.open_or_activate t path |> Or_error.ok_exn
let keys t notation = List.fold (Key_notation.keys notation) ~init:t ~f:(fun t key ->
  let t, _, _ = Session.handle_input t key in t)
let label t id = List.Assoc.find_exn (Session.buffer_labels t) id ~equal:Buffer_id.equal
let row t id = List.find_exn (Open_buffers.of_session t) ~f:(fun b -> Buffer_id.equal b.id id)

(* Reference the exact old algorithm, including full-path suffix collisions. *)
let reference files =
  let parts path = Option.value_map path ~default:[ "[unnamed]" ] ~f:(fun p ->
    String.split p ~on:'/' |> List.filter ~f:(Fn.non String.is_empty)) in
  let suffix path n = let p = parts path in List.drop p (Int.max 0 (List.length p - n)) in
  List.map files ~f:(fun (id, path) ->
    let rec choose n =
      let candidate = suffix path n in
      if n < List.length (parts path) && List.exists files ~f:(fun (other, path) ->
        not (Buffer_id.equal id other) && List.equal String.equal candidate (suffix path n))
      then choose (n + 1)
      else String.concat ~sep:"/" (List.map candidate ~f:Directory_identity.encode_name) in
    id, choose 1)
;;

let%test_unit "reverse trie retains exact suffix and escaped byte/UTF-8 semantics" =
  let paths = [ None; Some "[unnamed]"; Some "/"; Some "/a/x"; Some "/b/a/x"
    ; Some "/left/common/deep/é\t\\.txt"; Some "/right/common/deep/é\t\\.txt"
    ; Some "/left/common/deep/é\t\\.txt"; Some "/a/\255\n"; Some "/b/\255\n" ] in
  (* All subsets cover unique, ambiguous, identical and terminal-node cases. *)
  for mask = 0 to (1 lsl List.length paths) - 1 do
    let files = List.filter_mapi paths ~f:(fun i path ->
      Option.some_if (mask land (1 lsl i) <> 0) (Buffer_id.of_int i, path)) in
    assert (List.equal (fun (a, x) (b, y) -> Buffer_id.equal a b && String.equal x y)
      (reference files) (Buffer_labels.create files))
  done
;;

let%test_unit "labels reuse only metadata; current flags/controllers and old snapshots stay coherent" =
  let t = start (base ^ "left/common/deep/é\t.txt") in
  let aid = Session.active_id t |> Option.value_exn in
  let initial = Session.buffer_labels t in
  let t, bid = open_path t (base ^ "right/common/deep/é\t.txt") in
  let cached = Session.buffer_labels t in
  let encoded = Directory_identity.encode_name "é\t.txt" in
  assert (not (phys_equal initial cached));
  assert (String.equal (label t aid) ("left/common/deep/" ^ encoded));
  assert (String.equal (label t bid) ("right/common/deep/" ^ encoded));
  let t = Session.activate t aid |> Or_error.ok_exn in
  let before = t in
  let t, _ = Session.take_source_changes t in
  let t = keys t "iX<Esc>yy" in
  assert (phys_equal cached (Session.buffer_labels t));
  assert ((row t aid).active && (row t aid).modified && not (row t bid).active);
  assert (not (row before aid).modified);
  assert (String.equal (Text_buffer.to_string (Editor.text (Controller.editor (Session.find before aid |> Option.value_exn)))) "");
  let t, changes = Session.take_source_changes t in
  assert (List.length changes = 1 && Buffer_id.equal (fst (List.hd_exn changes)) aid);
  let t = keys t "u" in
  assert (not (row t aid).modified); (* Undo to saved is clean, despite a new revision. *)
  let c = Session.active_controller t |> Option.value_exn |> Controller.mark_missing in
  let t = Session.replace_active t c in
  assert ((row t aid).missing && not (row before aid).missing);
  assert (phys_equal cached (Session.buffer_labels t));
  let t, _ = Session.take_source_changes t in
  let c = Session.active_controller t |> Option.value_exn |> fun c ->
    Controller.update_feedback c (Ches_error.Error.Notify
      { source = "test"; scope = None; severity = Info; text = "feedback only"; history = false }) in
  let t = Session.replace_active t c in
  assert (phys_equal cached (Session.buffer_labels t));
  let t, changes = Session.take_source_changes t in
  assert (List.is_empty changes);
  let t = keys t "lyy" in
  let t, changes = Session.take_source_changes t in
  assert (List.is_empty changes);
  let t, closed = Session.close_buffer t bid ~force:true in
  assert closed;
  assert (not (phys_equal cached (Session.buffer_labels t)));
  assert (String.equal (label t aid) encoded);
  assert (Option.is_none (Session.find t bid) && Option.is_none (Session.source_generation t bid));
  let t, reopened = open_path t (base ^ "right/common/deep/é\t.txt") in
  assert (not (Buffer_id.equal bid reopened));
  assert (String.equal (label t aid) ("left/common/deep/" ^ encoded));
  assert (List.equal Buffer_id.equal (List.map (Session.buffers t) ~f:fst) [ aid; reopened ]);
  Session.dispose t
;;

let%test_unit "1000 retained files: unrelated work emits nothing, one edit queues only its current revision" =
  let t = start (base ^ "0/shared/file.txt") in
  let first = Session.active_id t |> Option.value_exn in
  let t = List.fold (List.init 999 ~f:(fun i -> i + 1)) ~init:t ~f:(fun t i ->
    fst (open_path t (sprintf "%s%d/shared/file.txt" base i))) in
  let t, initial = Session.take_source_changes t in
  assert (List.length initial = 1000);
  let labels = Session.buffer_labels t in
  let revisions = List.map (Session.buffers t) ~f:(fun (id, c) -> id, Editor.revision (Controller.editor c)) in
  let t = Session.activate t first |> Or_error.ok_exn |> fun t -> keys t "lyy" in
  let t, changes = Session.take_source_changes t in
  assert (List.is_empty changes && phys_equal labels (Session.buffer_labels t));
  let old = t in
  let t = keys t "iXYZ<Esc>" in
  let t, changes = Session.take_source_changes t in
  let id, current = List.hd_exn changes in
  assert (List.length changes = 1 && Buffer_id.equal id first);
  let generation, c = Option.value_exn current in
  assert (Option.equal Int.equal (Session.source_generation t id) (Some generation));
  assert (String.equal (Text_buffer.to_string (Editor.text (Controller.editor c))) "XYZ");
  assert (Session.same_file_lifetimes old t && Session.same_buffer_membership old t);
  List.iter revisions ~f:(fun (id, revision) -> if not (Buffer_id.equal id first) then
    assert (Editor.revision (Controller.editor (Session.find t id |> Option.value_exn)) = revision));
  assert (phys_equal labels (Session.buffer_labels t));
  let t, changes = Session.take_source_changes t in
  assert (List.is_empty changes);
  Session.dispose t
;;
