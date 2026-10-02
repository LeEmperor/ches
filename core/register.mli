(** The unnamed internal register.  It is deliberately independent of undo history. *)

open! Core

module Kind : sig
  type t =
    | Characterwise
    | Linewise
  [@@deriving sexp_of, equal]
end

type t =
  { text : string
  ; kind : Kind.t
  }
[@@deriving sexp_of, equal]
