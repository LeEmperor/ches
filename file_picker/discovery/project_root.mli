open! Core

(** Nearest ancestor with either [.git] (file or directory) or [dune-project].
    Start at the document's directory, canonicalized when possible; otherwise use
    its absolute lexical directory. No marker means that starting directory.
    Call once for the project scope, then retain/pass the root explicitly when
    opening other files in that project. This does not change diagnostic roots. *)
val find : string -> string
