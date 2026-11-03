open! Core

type location = { path : string; offset : int } [@@deriving sexp_of, equal]
type t [@@deriving sexp_of]
val empty : t
(** Successful jumps only. Equal origin/destination is a no-op. A new jump
    discards the forward branch. At most 128 prior locations are retained. *)
val record : t -> origin:location -> destination:location -> t
(** Tentative traversal: install the returned history only after the host has
    validated and successfully revealed the returned location. The actual current
    cursor is retained for the reverse traversal, including ordinary cursor moves. *)
val peek_back : t -> current:location -> (location * t) option
val peek_forward : t -> current:location -> (location * t) option
