(** A stable view identity, independent of placement, visibility, focus, and
    content. Applications name their views; this library enumerates none. It lives
    here, below {!Ches_tile}, so that {!View_command} can name a view; [Ches_tile]
    re-exports it as [Ches_tile.View_id]. *)

open! Core

type t [@@deriving sexp_of, equal, compare]

val of_string : string -> t
val to_string : t -> string
