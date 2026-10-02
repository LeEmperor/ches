open! Core

type t =
  | Backdrop
  | Text
  | Text_cursor_line
  | Special
  | Special_cursor_line
  | Gutter
  | Gutter_cursor_line
  | Border
  | Title
  | Title_special
  | Status
  | Status_special
  | Mode of Ches_core.Mode.t
  | Dirty
  | Pending
  | Info
  | Warning
  | Error
[@@deriving sexp_of, equal]
