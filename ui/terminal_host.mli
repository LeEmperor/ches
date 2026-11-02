(** One terminal runtime and cancellable event consumer per frontend instance.
    All operations run on the Async scheduler. *)
type t

val create : unit -> t
val submit : t -> Ches_terminal.Model.request list -> unit
val next_event : t -> Ches_terminal.Model.event option Async.Deferred.t
(** Generation-tagged variant for asynchronous injection into Ui_state. Use one
    consumer, choosing either this stream or [next_event]. *)
val next_update : t -> (int * Ches_terminal.Model.event) option Async.Deferred.t
val stop : t -> unit
val shutdown : t -> unit Async.Deferred.t
