(** Phase 1 placeholder screen: proves Bonsai_term can launch, follow resizes, and
    restore the terminal on exit. Phase 6 replaces it with the real editor view.

    Temporary exit keys: [q] or [Ctrl-C]. *)

open! Core
open! Async

val run : unit -> unit Deferred.Or_error.t
