open! Core

type t =
  | Backdrop
  | Text
  | Text_cursor_line
  | Special
  | Special_cursor_line
  | Search_match
  | Search_match_current
  | Search_special_match
  | Search_special_match_current
  | Selection
  | Selection_special
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
  | Smear
[@@deriving sexp_of, equal]
