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
  (* With CR-to-LF translation disabled, Notty reports Enter as Ctrl-M. *)
  | ASCII ('M' | 'm'), [ Ctrl ] -> Some Enter
  | ASCII c, ([ Ctrl ] | [ Ctrl; Shift ] | [ Shift; Ctrl ]) when Char.is_alpha c ->
    Some (Ctrl (Char.lowercase c))
  | Enter, [] -> Some Enter
  | Tab, [] -> Some Tab
  | Tab, [ Shift ] -> Some Shift_tab
  | Backspace, [] -> Some Backspace
  (* What most terminals send for Ctrl-Backspace, and for Ctrl-h: ^H, which notty
     reports as Ctrl-Backspace. As in Vim, it backspaces in Insert mode and prompts;
     the command palette deletes a word with it. *)
  | Backspace, [ Ctrl ] -> Some (Ctrl 'h')
  | Delete, [] -> Some Delete
  | Arrow `Left, [] -> Some Left
  | Arrow `Right, [] -> Some Right
  | Home, [] -> Some Home
  | End, [] -> Some End
  | Escape, [] -> Some Escape
  | _ -> None
;;

let terminal_key (key : Event.Key.t) (mods : Event.Modifier.t list)
  : Ches_terminal.Model.key =
  let open Ches_terminal.Model in
  let code : key_code = match key with
    | ASCII c -> Char (Uchar.of_char c)
    | Uchar u -> Char u
    | Enter -> Enter | Tab -> Tab | Backspace -> Backspace | Escape -> Escape
    | Insert -> Insert | Delete -> Delete | Home -> Home | End -> End
    | Arrow `Up -> Up | Arrow `Down -> Down
    | Arrow `Left -> Left | Arrow `Right -> Right
    | Page `Up -> Page_up | Page `Down -> Page_down
    | Function n -> Function n
  in
  let has modifier = List.mem mods modifier ~equal:Event.Modifier.equal in
  (* Notty calls a literal LF [Enter]; the physical Enter key arrives as
     ASCII M + Ctrl. Keep LF as Ctrl-J when forwarding to a child terminal. *)
  match key with
  | Enter ->
    { code = Char (Uchar.of_char 'j')
    ; modifiers = { shift = has Shift; alt = has Meta; ctrl = true } }
  | _ -> { code; modifiers = { shift = has Shift; alt = has Meta; ctrl = has Ctrl } }
;;

let inputs ?(terminal = false) (event : Event.t) : Ches_screen.Ui_state.Input.t list =
  match event with
  | Paste `Start -> [ Paste_start ]
  | Paste `End -> [ Paste_end ]
  | Mouse _ -> []
  | Key_press { key; mods } when terminal ->
    [ Terminal_key (terminal_key key mods) ]
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
