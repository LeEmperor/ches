open! Core

(** Immutable catalog, including bundled starters and user overrides. *)
type t

type declaration =
  { id : string
  ; prefix : string
  ; scopes : string list
  ; description : string option
  ; body : string
  }
[@@deriving sexp, equal]

type origin = Bundled | Legacy_json | Ocaml [@@deriving sexp, equal]

type item = { declaration : declaration; origin : origin }
[@@deriving sexp, equal]

(** Effective, applicable declarations sorted lexically by prefix, then ID.
    Bodies are the original templates, before variable/indentation expansion. *)
val available : t -> path:string option -> item list

(** Resolve an applicable ID in this catalog snapshot and insert at a valid UTF-8
    cursor boundary. The primary edit is always zero-width, even after a prefix. *)
val instantiate
  :  t
  -> id:string
  -> path:string option
  -> text:Ches_core.Text_buffer.t
  -> cursor:int
  -> Model.Candidate.t Or_error.t

type operation = Add of declaration | Disable of string
[@@deriving sexp, equal]

(** Apply ordered, last-wins overrides to an immutable base. Every operation is
    validated, even if subsequently overridden. At most 1000 operations and 1 MiB
    of declaration strings are accepted. Errors include the operation ID. *)
val apply : t -> operation list -> t Or_error.t

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
