(** A stable view identity, independent of placement, visibility, focus, and
    content. Applications name their views; this library enumerates none. This is
    {!Ches_input.View_id}, re-exported so tile code keeps one name for it. *)

open! Core

type t = Ches_input.View_id.t [@@deriving sexp_of, equal, compare]

val of_string : string -> t
val to_string : t -> string
