open! Core

module Direction = struct
  type t =
    | Left
    | Right
    | Up
    | Down
  [@@deriving sexp_of, equal, enumerate]
end

type t =
  | Move of Direction.t
  | Enter_insert
  | Exit_insert
  | Insert_text of string
  | Delete_backward
  | Delete_forward
  | Insert_soft_tab of int
  | Delete_soft_tab_backward of int
  | Delete_char
  | Undo
  | Redo
  | Save
  | Quit
  | Force_quit
[@@deriving sexp_of, equal]
