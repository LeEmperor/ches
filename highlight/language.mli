open! Core

type t = Plain | Ocaml | Ocaml_interface | Systemverilog [@@deriving sexp_of, equal]

(** Case-sensitive .ml/.mli and .sv/.svh/.v/.vh. Verilog uses the SystemVerilog
    grammar. Missing, extensionless and other paths are Plain.
    No source sniffing or external filetype configuration. *)
val of_path : string option -> t
