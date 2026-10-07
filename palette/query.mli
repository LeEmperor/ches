open! Core

(** Shared single-line UTF-8 query editing. CRLF, CR, LF and TAB become spaces;
    other C0/C1 controls are dropped and malformed UTF-8 is replaced. *)
val sanitize : string -> string
val append : string -> string -> string
val backspace : string -> string
val delete_word : string -> string
