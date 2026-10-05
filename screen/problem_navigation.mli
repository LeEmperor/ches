open! Core

type t =
  { selected : Ches_error.Error.Identity.t option
  ; index : int
  ; top : int
  }
[@@deriving sexp_of]

val empty : t

(** Preserve identity; on removal/filtering select the previous index's next
    neighbor, or the last item. Keep selection within the visible rows. *)
val fit : t -> Ches_error.Error.Problem.t list -> rows:int -> t
val select : t -> Ches_error.Error.Problem.t list -> rows:int -> int -> t
