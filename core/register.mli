(** The unnamed internal register.  It is deliberately independent of undo history. *)

open! Core

module Kind : sig
  type t =
    | Characterwise
    | Linewise
  [@@deriving sexp_of, equal]
end

type t =
  | Text of
      { text : string
      ; kind : Kind.t
      }
  | Block of
      { rows : string list
      (** One per line of the block, top first, never empty; no row contains LF. *)
      ; width : int
      (** Display cells of the block. Rows can be narrower: a line that ended
          inside the block, or every line but the longest after [$]. A paste pads
          them to this width when text follows. *)
      }
[@@deriving sexp_of, equal]
