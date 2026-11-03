open! Core

(** Immutable catalog, including bundled collections and user overrides. *)
type t

type declaration =
  { id : string
  ; prefix : string
  ; scopes : string list
  ; collection : string option
  ; description : string option
  ; body : string
  }
[@@deriving sexp, equal]

type origin = Bundled | Legacy_json | Ocaml [@@deriving sexp, equal]

type item = { declaration : declaration; origin : origin }
[@@deriving sexp, equal]

(** Enabled, applicable declarations sorted lexically by prefix, then ID.
    Bodies are the original templates, before variable/indentation expansion. *)
val available : t -> path:string option -> item list

(** Resolve an enabled, applicable ID in this catalog snapshot and insert at a valid UTF-8
    cursor boundary. The primary edit is always zero-width, even after a prefix. *)
val instantiate
  :  t
  -> id:string
  -> path:string option
  -> text:Ches_core.Text_buffer.t
  -> cursor:int
  -> Model.Candidate.t Or_error.t

(** Collections default to enabled; untagged declarations are always enabled.
    A toggle matches the named collection and its dotted descendants. The last
    matching toggle wins, including across successive [apply] calls. Toggles keep
    templates intact; [Disable] deletes an individual ID. Collection names contain
    nonempty dot-separated ASCII alphanumeric, underscore or hyphen segments. *)
type operation = Add of declaration | Disable of string
  | Set_collection_enabled of { collection : string; enabled : bool }
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
