open! Core

type t = Plain | Ocaml | Ocaml_interface [@@deriving sexp_of, equal]

let of_path = function
  | Some path when String.is_suffix path ~suffix:".mli" -> Ocaml_interface
  | Some path when String.is_suffix path ~suffix:".ml" -> Ocaml
  | Some _ | None -> Plain
;;
