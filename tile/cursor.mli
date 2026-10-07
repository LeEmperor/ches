(** A focused minor view's terminal-cursor intent: where in its content area the cursor
    goes, and how it looks. A view supplies one only while it owns the cursor
    ({!Spec.t.owns_cursor}) and is focused ({!Host.cursor_owner}); the screen clips it to
    the content area and draws nothing outside it. *)

open! Core

module Shape : sig
  type t =
    | Block (** Over a cell, as in Normal mode or read-only text. *)
    | Bar (** Between cells, as at a text-entry point. *)
  [@@deriving sexp_of, equal]
end

type t =
  { row : int (** From the top of the content area. *)
  ; column : int (** Display cells from the content area's left edge. *)
  ; shape : Shape.t
  }
[@@deriving sexp_of, equal]
