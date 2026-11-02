open! Core
open Ches_terminal

type t
external create_raw : int -> int -> t = "ches_vterm_create"
external resize_raw : t -> int -> int -> unit = "ches_vterm_resize"
external feed : t -> string -> string = "ches_vterm_feed"
external key_raw : t -> bool -> int -> int -> string = "ches_vterm_key"
external paste : t -> string -> string = "ches_vterm_paste"
external snapshot_raw : t -> Model.snapshot = "ches_vterm_snapshot"
external close : t -> unit = "ches_vterm_close"

let dimensions ~(rows : int) ~(cols : int) : unit =
  if rows < 1 || cols < 1 || rows > 500 || cols > 1000 || rows * cols > 250_000
  then invalid_arg "terminal dimensions must be positive and at most 250000 cells (500x1000)"
;;

let create ~(rows : int) ~(cols : int) : t =
  dimensions ~rows ~cols;
  create_raw rows cols
;;

let resize (t : t) ~(rows : int) ~(cols : int) : unit =
  dimensions ~rows ~cols;
  resize_raw t rows cols
;;

let key (t : t) ({ code; modifiers } : Model.key) : string =
  let mods : int =
    (if modifiers.shift then 1 else 0)
    lor (if modifiers.alt then 2 else 0)
    lor (if modifiers.ctrl then 4 else 0)
  in
  match code with
  | Char c -> key_raw t true (Uchar.to_scalar c) mods
  | _ ->
    let mods : int =
      match code with
      | Function n when n >= 13 && n <= 24 -> mods lor 1
      | Function n when n >= 25 && n <= 35 -> mods lor 4
      | _ -> mods
    in
    let code : int =
      match code with
      | Enter -> 1 | Tab -> 2 | Backspace -> 3 | Escape -> 4
      | Up -> 5 | Down -> 6 | Left -> 7 | Right -> 8
      | Insert -> 9 | Delete -> 10 | Home -> 11 | End -> 12
      | Page_up -> 13 | Page_down -> 14
      | Function n when n >= 1 && n <= 12 -> 256 + n
      | Function n when n >= 13 && n <= 24 -> 256 + n - 12
      | Function n when n >= 25 && n <= 35 -> 256 + n - 24
      | Function _ -> invalid_arg "terminal function key outside F1..F35"
      | Char _ -> assert false
    in
    key_raw t false code mods
;;

let snapshot (t : t) ~(exited : string option) : Model.snapshot =
  { (snapshot_raw t) with exited }
;;
