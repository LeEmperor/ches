(** The unnamed internal register.  It is deliberately independent of undo history. *)

open! Core

module Kind : sig
  type t =
    | Characterwise
    | Linewise
  [@@deriving sexp_of, equal]
end

type t =
  | Protected_block of
      { rows : string list
      ; width : int
      }
  | Protected_text of
      { text : string
      ; kind : Kind.t
      ; scope : string
      ; identities : (int * string) list
      }
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

(** The register as plain text for the system clipboard: linewise text always ends
    with LF, and a block's rows are joined by LF. *)
val to_string : t -> string
