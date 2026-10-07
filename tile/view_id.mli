(** A stable view identity, independent of placement, visibility, focus, and
    content. Applications name their views; this library enumerates none. *)

open! Core

type t [@@deriving sexp_of, equal, compare]

val of_string : string -> t
val to_string : t -> string
