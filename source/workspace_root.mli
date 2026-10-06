(** Where a diagnostic source is started for a document. *)
open! Core

(** The nearest directory at or above [path]'s that contains [dune-project], as an
    absolute path; [path]'s directory itself when none does or it cannot be resolved. *)
val find : string -> string
