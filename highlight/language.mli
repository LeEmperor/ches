open! Core

type t = Plain | Ocaml | Ocaml_interface | Systemverilog | Gas [@@deriving sexp_of, equal]

(** Case-sensitive .ml/.mli, .sv/.svh/.v/.vh and .s/.S. Verilog uses the
    SystemVerilog grammar; .s/.S use AT&T/GAS, not Intel syntax (.asm is Plain).
    Missing, extensionless and other paths are Plain.
    No source sniffing or external filetype configuration. *)
val of_path : string option -> t
