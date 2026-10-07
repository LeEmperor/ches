open! Core
type t [@@deriving sexp_of, compare, equal, hash]
val of_int : int -> t
val to_int : t -> int
