open! Core
type t [@@deriving sexp_of, compare, equal, hash]
include Comparable.S with type t := t
val of_int : int -> t
val to_int : t -> int
