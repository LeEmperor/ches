open! Core

let max_count = 999_999

module Insert_position = struct
  type t =
    | Before_cursor
    | After_cursor
    | Line_end
    | First_nonblank
  [@@deriving sexp_of, equal]
end

type t =
  | Move of
      { motion : Motion.t
      ; count : int option [@sexp.option]
      }
  | Enter_insert of Insert_position.t
  | Open_line_below
  | Open_line_above
  | Exit_insert
  | Insert_text of string
  | Insert_newline
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
