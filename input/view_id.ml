open! Core

type t = string [@@deriving sexp_of, equal, compare]

let of_string t = t
let to_string t = t
