(** What each part of the screen is, for the frontend's theme to color. The theme maps
    every case to attributes in one place. *)

open! Core

type t =
  | Backdrop (** The screen outside the tile and status line. *)
  | Text
  | Text_cursor_line
  | Special (** Escape forms and clip markers in the text. *)
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
  | Title (** Text set into the top border, such as the filename. *)
  | Title_special (** Escape forms and cut markers there. *)
  | Status (** The status line's background and plain fields. *)
  | Status_special (** Escape forms in the filename and messages. *)
  | Mode of Ches_core.Mode.t (** The mode badge. *)
  | Dirty
  | Pending
  | Info
  | Warning
  | Error
[@@deriving sexp_of, equal]
