open! Core
open Bonsai_term
open Ches_input

let is_control u =
  let c = Uchar.to_scalar u in
  c < 0x20 || (c >= 0x7F && c <= 0x9F)
;;

let key (key : Event.Key.t) (mods : Event.Modifier.t list) : Key.t option =
  let char u = if is_control u then None else Some (Key.Char u) in
  match key, mods with
  | ASCII c, ([] | [ Shift ]) -> char (Uchar.of_char c)
  | Uchar u, ([] | [ Shift ]) -> char u
  | ASCII c, ([ Ctrl ] | [ Ctrl; Shift ] | [ Shift; Ctrl ]) when Char.is_alpha c ->
    Some (Ctrl (Char.lowercase c))
  | Enter, [] -> Some Enter
  | Tab, [] -> Some Tab
  | Backspace, ([] | [ Ctrl ]) -> Some Backspace
  | Delete, [] -> Some Delete
  | Escape, [] -> Some Escape
  | _ -> None
;;

let inputs (event : Event.t) : Ches_screen.Ui_state.Input.t list =
  match event with
  | Paste `Start -> [ Paste_start ]
  | Paste `End -> [ Paste_end ]
  | Mouse _ -> []
  | Key_press { key = k; mods } ->
    let meta, mods =
      List.partition_tf mods ~f:(function
        | Meta -> true
        | Ctrl | Shift -> false)
    in
    let rest = Option.to_list (key k mods) in
    let keys = if List.is_empty meta then rest else Key.Escape :: rest in
    List.map keys ~f:(fun key -> Ches_screen.Ui_state.Input.Key key)
;;
