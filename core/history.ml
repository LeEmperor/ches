open! Core

type snapshot =
  { text : Text_buffer.t
  ; cursor : int
  }

type step =
  { before : snapshot
  ; after : snapshot
  ; charge : int
  }

module Limits = struct
  type t = { max_steps : int; max_bytes : int } [@@deriving sexp_of, equal]
  let default = { max_steps = 1000; max_bytes = 64 * 1024 * 1024 }
end

module Stats = struct
  type t = { undo_steps : int; redo_steps : int; retained_bytes : int }
  [@@deriving sexp_of, equal]
end

type t =
  { undo : step Int.Map.t
  ; redo : step Int.Map.t
  ; undo_bytes : int
  ; redo_bytes : int
  ; limits : Limits.t
  ; active : snapshot option (** The [before] of the open transaction. *)
  }

let create ?(limits = Limits.default) () =
  if limits.max_steps < 1 || limits.max_bytes < 0
  then invalid_arg "History.create: max_steps must be positive and max_bytes nonnegative";
  { undo = Int.Map.empty; redo = Int.Map.empty; undo_bytes = 0; redo_bytes = 0; limits; active = None }
;;
let empty = create ()
let limits t = t.limits
let stats t =
  { Stats.undo_steps = Map.length t.undo; redo_steps = Map.length t.redo
  ; retained_bytes = t.undo_bytes + t.redo_bytes }
;;
let is_active t = Option.is_some t.active

let ensure_active t ~before =
  match t.active with
  | Some _ -> t
  | None -> { t with active = Some before }
;;

let commit t ~after =
  match t.active with
  | None -> t
  | Some before when Text_buffer.equal before.text after.text -> { t with active = None }
  | Some before ->
    let charge = 128 + Text_buffer.retained_bytes before.text + Text_buffer.retained_bytes after.text in
    let step = { before; after; charge } in
    (* Oversized newest steps replace the entire old history directly. No drain. *)
    let undo, undo_bytes =
      if charge > t.limits.max_bytes then Int.Map.singleton 0 step, charge
      else (
        let key = Option.value_map (Map.max_elt t.undo) ~default:0 ~f:(fun (key, _) -> key + 1) in
        let rec trim undo bytes =
          if Map.length undo <= t.limits.max_steps && bytes <= t.limits.max_bytes
          then undo, bytes
          else
            let key, oldest = Map.min_elt_exn undo in
            trim (Map.remove undo key) (bytes - oldest.charge)
        in
        trim (Map.set t.undo ~key ~data:step) (t.undo_bytes + charge))
    in
    { t with undo; undo_bytes; redo = Int.Map.empty; redo_bytes = 0; active = None }
;;

let check_inactive t ~fn =
  if is_active t then raise_s [%message "History: transaction still active" fn]
;;

let undo t =
  check_inactive t ~fn:"undo";
  match Map.max_elt t.undo with
  | None -> None
  | Some (key, step) ->
    Some ({ t with undo = Map.remove t.undo key; redo = Map.set t.redo ~key ~data:step
      ; undo_bytes = t.undo_bytes - step.charge; redo_bytes = t.redo_bytes + step.charge }, step.before)
;;

let redo t =
  check_inactive t ~fn:"redo";
  match Map.min_elt t.redo with
  | None -> None
  | Some (key, step) ->
    Some ({ t with redo = Map.remove t.redo key; undo = Map.set t.undo ~key ~data:step
      ; redo_bytes = t.redo_bytes - step.charge; undo_bytes = t.undo_bytes + step.charge }, step.after)
;;
