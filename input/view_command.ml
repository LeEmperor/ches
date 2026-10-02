open! Core

type t =
  | Toggle_centered
  | Shift of int
  | Adjust_width of int
  | Reset
[@@deriving sexp_of, equal]
