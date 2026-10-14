open! Core
open Ches_core
open Ches_app
open Ches_screen

(* In-memory initial document + missing resources: reads only, no writes or LSP.
   Construction is deliberately outside the measured hot paths. *)
let base = "/__ches_session_scale_probe__/"
let path i = sprintf "%s%d/common/deep/file.txt" base i
let measure label samples f =
  let allocated = Gc.allocated_bytes () in
  let start = Stdlib.Sys.time () in
  for _ = 1 to samples do f () done;
  printf "%s: %.4f ms CPU/op, %.0f allocated bytes/op (%d samples)\n%!"
    label ((Stdlib.Sys.time () -. start) *. 1000. /. Float.of_int samples)
    ((Gc.allocated_bytes () -. allocated) /. Float.of_int samples) samples
;;

let old_labels session =
  let files = Session.buffers session in
  let parts c = Option.value_map (Editor.path (Controller.editor c))
    ~default:[ "[unnamed]" ] ~f:(fun p -> String.split p ~on:'/' |> List.filter ~f:(Fn.non String.is_empty)) in
  let suffix p n = List.drop p (Int.max 0 (List.length p - n)) in
  List.map files ~f:(fun (id, c) ->
    let p = parts c in
    let rec choose n =
      let candidate = suffix p n in
      if n < List.length p && List.exists files ~f:(fun (other, c) ->
        not (Buffer_id.equal id other) && List.equal String.equal candidate (suffix (parts c) n))
      then choose (n + 1)
      else String.concat ~sep:"/" (List.map candidate ~f:Directory_identity.encode_name) in
    id, choose 1)
;;

let () =
  List.iter [ 10; 100; 1000 ] ~f:(fun count ->
    let ui = Ui_state.create ~source_attached:true ~tiles_visible:false
      (Controller.create (Editor.create ~path:(path 0) ~cell_width:Cell_map.width Text_buffer.empty)) in
    let ui = List.fold (List.init (count - 1) ~f:(fun i -> i + 1)) ~init:ui ~f:(fun ui i ->
      fst (Ui_state.open_file ui ~width:80 ~height:24 (path i) |> Or_error.ok_exn)) in
    let session = Ui_state.session ui in
    let name label = sprintf "%d %s" count label in
    let samples = if count = 1000 then 2 else 20 in
    measure (name "old pairwise labels") samples (fun () -> ignore (old_labels session));
    measure (name "cold cached labels") 1 (fun () -> ignore (Session.buffer_labels session));
    measure (name "warm cached labels") 1000 (fun () -> ignore (Session.buffer_labels session));
    measure (name "warm tab records (current dirty/missing/active)") 100 (fun () -> ignore (Open_buffers.of_session session));
    let ui, _ = Ui_state.take_source_requests ui in
    let live = Session.buffers session in
    let sent = List.map live ~f:(fun (id, c) -> id,
      (Session.source_generation session id |> Option.value_exn, Editor.revision (Controller.editor c))) in
    let generation id = List.find_exn sent ~f:(fun (other, _) -> Buffer_id.equal other id) |> snd |> fst in
    measure (name "old unchanged source scan") samples (fun () ->
      List.iter live ~f:(fun (id, c) ->
        ignore (List.Assoc.find sent id ~equal:Buffer_id.equal);
        ignore (generation id);
        ignore (Editor.revision (Controller.editor c)));
      ignore (List.map live ~f:(fun (id, c) -> id, (generation id, Editor.revision (Controller.editor c)))));
    measure (name "unchanged source take") 1000 (fun () -> ignore (Ui_state.take_source_requests ui));
    let c = Session.active_controller session |> Option.value_exn in
    let active = Session.active_id session |> Option.value_exn in
    measure (name "old active list replacement") 1000 (fun () ->
      ignore (List.map live ~f:(fun (id, retained) ->
        if Buffer_id.equal id active then id, c else id, retained)));
    measure (name "active replacement") 1000 (fun () -> ignore (Session.replace_active session c));
    let changed = Ui_state.apply_all ui ~width:80 ~height:24
      [ Key (Ches_input.Key.char 'i'); Key (Ches_input.Key.char 'X') ] |> fst in
    measure (name "one changed source take") 100 (fun () ->
      let _, requests = Ui_state.take_source_requests changed in
      assert (List.length requests = 1));
    Session.dispose (Ui_state.session changed))
;;
