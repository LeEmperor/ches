open! Core

type t =
  { candidate_id : string
  ; kind : int option
  ; documentation : string option
  ; detail : string option
  ; resolvable : bool
  ; additional : Ches_core.Text_edit.t list option
  ; revision : int option
  }
[@@deriving sexp_of]
