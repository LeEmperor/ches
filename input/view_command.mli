(** Layout commands for the frontend's view: where the document tile sits, how wide
    its text is, and how lines are numbered. They change UI preferences only, never
    the document, cursor, history, or dirty state, so they are routed to the UI rather
    than to the editor. Terminal-independent, like the rest of [ches_input]. *)

open! Core

(** Scrolling the view. Unlike the other view commands, these may move the cursor,
    but only to keep it in view, and never edit. *)
module Scroll : sig
  type t =
    | Line_down (** [Ctrl-e]: the view down by one line, or by a count. *)
    | Line_up (** [Ctrl-y]: the view up by one line, or by a count. *)
    | Half_page_down
    (** [Ctrl-d]: the view and cursor down half the viewport, or by a count. *)
    | Half_page_up (** [Ctrl-u]: the view and cursor up half the viewport, or by a count. *)
    | Cursor_middle (** [zz]: the cursor line to the middle of the viewport. *)
    | Cursor_top (** [zt]: the cursor line to the top of the viewport. *)
    | Cursor_bottom (** [zb]: the cursor line to the bottom of the viewport. *)
  [@@deriving sexp_of, equal, enumerate]

  (** All but [Cursor_middle], [Cursor_top], and [Cursor_bottom]. *)
  val takes_count : t -> bool
end

type t =
  | Toggle_centered (** Switch between the centered tile and full width. *)
  | Shift of int (** Move the centered tile by this many display cells; negative is left. *)
  | Adjust_width of int (** Change the preferred text width by this many display cells. *)
  | Toggle_absolute_numbers
  (** Flip the absolute line-number switch (Vim's ['number']). *)
  | Toggle_relative_numbers
  (** Flip the relative line-number switch (Vim's ['relativenumber']). *)
  | Reset (** Centered, at the default width and offset, with hybrid line numbers. *)
  | Scroll of
      { scroll : Scroll.t
      ; count : int option
      (** [None] when none was given; only when [Scroll.takes_count]. *)
      }
[@@deriving sexp_of, equal]
