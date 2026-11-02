(** Lazy numbered terminal runtime pool per frontend instance.
    All operations run on the Async scheduler. *)
type t

val create : unit -> t
val submit_sessions : t -> (int * Ches_terminal.Model.request) list -> unit
(** One consumer for the pool. Each host retains at most one snapshot and one
    failure, with initial-generation ordering preserved. Ready hosts are served
    round-robin, including hidden terminals. *)
val next_session_update
  : t -> (int * int * Ches_terminal.Model.event) option Async.Deferred.t
(** Compatibility API for callers using only terminal 1. Do not mix consumers. *)
val submit : t -> Ches_terminal.Model.request list -> unit
val next_event : t -> Ches_terminal.Model.event option Async.Deferred.t
(** Generation-tagged variant for asynchronous injection into Ui_state. Use one
    consumer, choosing either this stream or [next_event]. *)
val next_update : t -> (int * Ches_terminal.Model.event) option Async.Deferred.t
val stop : t -> unit
val shutdown : t -> unit Async.Deferred.t
