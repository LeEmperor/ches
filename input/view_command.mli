(** Layout commands for the frontend's view: where the document tile sits, how wide its
    text is, and how lines are numbered. They change UI preferences only, never the
    document, cursor, history, or dirty state, so they are routed to the UI rather than to
    the editor. Terminal-independent, like the rest of [ches_input]. *)

open! Core

(** Scrolling the view. Unlike the other view commands, these may move the cursor, but
    only to keep it in view, and never edit. *)
module Scroll : sig
  type t =
    | Line_down (** [Ctrl-e]: the view down by one line, or by a count. *)
    | Line_up (** [Ctrl-y]: the view up by one line, or by a count. *)
    | Half_page_down
    (** [Ctrl-d]: the view and cursor down half the viewport, or by a count. *)
    | Half_page_up
    (** [Ctrl-u]: the view and cursor up half the viewport, or by a count. *)
    | Cursor_middle (** [zz]: the cursor line to the middle of the viewport. *)
    | Cursor_top (** [zt]: the cursor line to the top of the viewport. *)
    | Cursor_bottom (** [zb]: the cursor line to the bottom of the viewport. *)
  [@@deriving sexp_of, equal, enumerate]

  (** All but [Cursor_middle], [Cursor_top], and [Cursor_bottom]. *)
  val takes_count : t -> bool
end

module Status_position : sig
  type t =
    | Left
    | Right
    | Above
    | Below
  [@@deriving sexp_of, equal]
end

type t =
  | Toggle_centered (** Switch between the centered tile and full width. *)
  | Shift of int
  (** Move the centered tile by this many display cells; negative is left. *)
  | Adjust_width of int (** Change the preferred text width by this many display cells. *)
  | Toggle_absolute_numbers
  (** Flip the absolute line-number switch (Vim's ['number']). *)
  | Toggle_relative_numbers
  (** Flip the relative line-number switch (Vim's ['relativenumber']). *)
  | Toggle_smear (** Enable or disable the animated terminal cursor. *)
  | Toggle_status (** Show/hide the requested status cell, independent of zen. *)
  | Position_status of Status_position.t (** Place status and request visibility. *)
  | Adjust_status_size of int (** Adjust requested status cells along its split axis. *)
  | Inspect_problems (** Cycle retained problem details, without retrying. *)
  | Toggle_problems (** Show/hide the read-only bottom preview. *)
  | Toggle_problems_filter (** Workspace/current-document preview filter. *)
  | Focus_problems (** Show/focus problems, or return to the document. *)
  | Toggle_zen (** Hide status temporarily, or restore saved workspace intent. *)
  | Reset (** Centered, at the default width and offset, with hybrid line numbers. *)
  | Scroll of
      { scroll : Scroll.t
      ; count : int option
      (** [None] when none was given; only when [Scroll.takes_count]. *)
      }
[@@deriving sexp_of, equal]
