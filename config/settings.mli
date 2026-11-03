open Core

type t =
  { completion_enabled : bool
  ; completion_ghost_preview : bool
  ; completion_min_prefix_chars : int
  ; completion_prefer_local_snippets : bool
  ; line_numbers : bool
  ; theme : string
  }
[@@deriving sexp, equal]

val default : t

(** Checks a positive minimum prefix and a nonempty theme. Theme existence is
    checked by the screen before applying the snapshot. *)
val validate : t -> t Or_error.t
