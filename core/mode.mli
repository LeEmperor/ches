(** Editor modes. *)

open! Core

type t =
  | Normal
  | Insert
  | Visual of [ `Characterwise | `Linewise ]
[@@deriving sexp_of, equal]

(** Upper-case label for the status line, e.g. ["NORMAL"]. *)
val to_string : t -> string
