open! Core
(** Read-only retained file lookup, including dirty/missing buffers. No activation,
    tab creation, disk IO, highlighting or language-server work. Call with the
    frontend's CURRENT session after debounce, not a captured opening session. *)
val lookup : Ches_app.Session.t -> path:string -> Model.state option
