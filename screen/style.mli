(** What each part of the screen is, for the frontend's theme to color. The theme maps
    every case to attributes in one place. *)

open! Core

type t =
  | Backdrop (** The screen outside the tile and status line. *)
  | Text
  | Text_cursor_line
  | Special (** Escape forms and clip markers in the text. *)
  | Special_cursor_line
  | Gutter
  | Gutter_cursor_line
  | Border
  | Status (** The status line's background and plain fields. *)
  | Status_special (** Escape forms in the filename and messages. *)
  | Mode of Ches_core.Mode.t (** The mode badge. *)
  | Dirty
  | Pending
  | Info
  | Warning
  | Error
[@@deriving sexp_of, equal]
