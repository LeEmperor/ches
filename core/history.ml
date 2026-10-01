open! Core

type snapshot =
  { text : Text_buffer.t
  ; cursor : int
  }

type step =
  { before : snapshot
  ; after : snapshot
  }

type t =
  { undo : step list
  ; redo : step list
  ; active : snapshot option (** The [before] of the open transaction. *)
  }

let empty = { undo = []; redo = []; active = None }
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
  | Some before -> { undo = { before; after } :: t.undo; redo = []; active = None }
;;

let check_inactive t ~fn =
  if is_active t then raise_s [%message "History: transaction still active" fn]
;;

let undo t =
  check_inactive t ~fn:"undo";
  match t.undo with
  | [] -> None
  | step :: undo -> Some ({ t with undo; redo = step :: t.redo }, step.before)
;;

let redo t =
  check_inactive t ~fn:"redo";
  match t.redo with
  | [] -> None
  | step :: redo -> Some ({ t with redo; undo = step :: t.undo }, step.after)
;;
