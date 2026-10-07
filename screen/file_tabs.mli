open! Core

type tab =
  { id : Ches_app.Buffer_id.t
  ; label : string
  ; active : bool
  ; modified : bool
  }
[@@deriving sexp_of]

(** Open order; shortest distinguishing lexical path suffixes, terminal-safe ASCII. *)
val tabs : Ches_app.Session.t -> tab list

(** A deterministic contiguous window around the active tab. [<] / [>] indicate
    hidden neighbors. Even a one-cell strip retains the active style. *)
val render : tab list -> width:int -> Span.t list
