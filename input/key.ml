open! Core

type t =
  | Char of Uchar.t
  | Ctrl of char
  | Enter
  | Tab
  | Backspace
  | Delete
  | Escape
[@@deriving sexp_of, equal]

let char c = Char (Uchar.of_char c)

let digit = function
  | Char u ->
    let code = Uchar.to_scalar u in
    if code >= Char.to_int '0' && code <= Char.to_int '9'
    then Some (code - Char.to_int '0')
    else None
  | Ctrl _ | Enter | Tab | Backspace | Delete | Escape -> None
;;

let is_control u =
  let code = Uchar.to_scalar u in
  code < 0x20 || (code >= 0x7f && code < 0xa0)
;;

let to_string_hum = function
  | Char u when Uchar.equal u (Uchar.of_char ' ') -> "Space"
  | Char u when is_control u -> sprintf "U+%04X" (Uchar.to_scalar u)
  | Char u -> Uchar.Utf8.to_string u
  | Ctrl c -> sprintf "Ctrl-%c" c
  | Enter -> "Enter"
  | Tab -> "Tab"
  | Backspace -> "Backspace"
  | Delete -> "Delete"
  | Escape -> "Escape"
;;

let text = function
  | Char u when is_control u -> None
  | Char u -> Some (Uchar.Utf8.to_string u)
  | Enter -> Some "\n"
  | Tab -> Some "\t"
  | Ctrl _ | Backspace | Delete | Escape -> None
;;
