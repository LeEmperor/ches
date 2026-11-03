open! Core

(** Immutable catalog, including bundled starters and user overrides. *)
type t

val builtins : t

(** Parse a complete version-1 JSON configuration, applying overrides/disables to
    the bundled catalog. Errors identify the entry; callers retain the old catalog.
    Input is bounded to 1 MiB and 1000 user entries. *)
val parse : string -> t Or_error.t

(** Prefix-only replacement, resolving filename variables against the raw lexical
    [path] before contextual indentation, preserving choices and linked fields.
    Missing paths match global snippets only. *)
val candidates
  :  t
  -> path:string option
  -> text:Ches_core.Text_buffer.t
  -> cursor:int
  -> limit:int
  -> Model.Candidate.t list
