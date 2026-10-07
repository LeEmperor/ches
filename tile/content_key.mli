(** How a content adapter reads the keys typed into its focused view. *)

open! Core

type 'action t =
  | Prefix (** Incomplete: the host keeps the keys pending. *)
  | Action of 'action
  | Unbound
[@@deriving sexp_of]

val map : 'a t -> f:('a -> 'b) -> 'b t
