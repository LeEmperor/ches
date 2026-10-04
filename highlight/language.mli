open! Core

type t = Plain | Ocaml | Ocaml_interface [@@deriving sexp_of, equal]

(** Case-sensitive .ml/.mli only. Missing, extensionless and other paths are Plain.
    No source sniffing or external filetype configuration. *)
val of_path : string option -> t
