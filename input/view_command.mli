(** Layout commands for the frontend's view: where the document tile sits and how
    wide its text is. They change UI preferences only, never the document, cursor,
    history, or dirty state, so they are routed to the UI rather than to the editor.
    Terminal-independent, like the rest of [ches_input]. *)

open! Core

type t =
  | Toggle_centered (** Switch between the centered tile and full width. *)
  | Shift of int (** Move the centered tile by this many display cells; negative is left. *)
  | Adjust_width of int (** Change the preferred text width by this many display cells. *)
  | Reset (** Centered, at the default width and offset. *)
[@@deriving sexp_of, equal]
