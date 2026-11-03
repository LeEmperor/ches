open! Core

(** Side-channel metadata keyed by the enclosing event's exact completion token
    and [candidate_id]. Documentation is display-only text (possibly Markdown).
    Initial items have [revision=None] and [additional=None]. Resolved items carry
    the current editor revision supplied with Resolve_completion and validated
    additional edits in the original completion base snapshot's coordinates.
    Consumers must check current revision and selection before using them; edits
    belong in finalization, never in the asynchronous event handler. *)
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
