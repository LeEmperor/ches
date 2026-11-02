(** A host owns one session. Start while running is a no-op; after exit it starts
    a fresh shell. Events are bounded and snapshots coalesce to the latest state.
    Stop ends the current session; shutdown additionally closes the host.
    Call these functions from the Async scheduler. No UI visibility signal is
    needed: output is drained for the entire lifetime of a session. *)
type t
val create : unit -> t
val submit : t -> Ches_terminal.Model.request list -> unit
(** Single-consumer event stream. A maximum of one snapshot and one failure are
    pending; intermediate snapshots and repeated failures coalesce. When idle,
    this waits for the next event (including after shutdown has completed). *)
val next_event : t -> Ches_terminal.Model.event Async.Deferred.t
(** Generation starts at zero and increments for every Start attempted while
    idle, including failed starts. Use this stream instead of [next_event] when
    delivery to a frontend is asynchronous and may overlap a restart. *)
val next_event_with_generation : t -> (int * Ches_terminal.Model.event) Async.Deferred.t
val stop : t -> unit
val shutdown : t -> unit Async.Deferred.t
