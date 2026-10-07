open! Core

type 'action t =
  | Prefix
  | Action of 'action
  | Unbound
[@@deriving sexp_of]

let map t ~f =
  match t with
  | Prefix -> Prefix
  | Action a -> Action (f a)
  | Unbound -> Unbound
;;
