open Core

type t =
  { completion_enabled : bool
  ; signature_help_enabled : bool
  ; completion_ghost_preview : bool
  ; completion_min_prefix_chars : int
  ; completion_prefer_local_snippets : bool
  ; line_numbers : bool
  ; theme : string
  ; snippets : Ches_completion.User_snippets.operation list
  }
[@@deriving sexp, equal]

val default : t

(** Checks a positive minimum prefix, a nonempty theme, and all snippet operations
    against the builtin catalog. Theme existence is
    checked by the screen before applying the snapshot. *)
val validate : t -> t Or_error.t
