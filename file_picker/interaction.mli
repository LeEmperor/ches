open! Core

(** Scheduler-independent mutable session, owned by one host. No IO or opening.
    Updates coalesce; call [work] between input turns, never drain it synchronously
    from a key/render callback. Results remain visible but cannot be accepted or
    navigated while busy. Selection is retained by identity on publication, falling
    back to the first result if gone. *)
type 'token t

val create : token:'token -> discovery:Model.Discovery.t -> 'token t
val model : 'token t -> 'token Model.t
val query : _ t -> string
val busy : _ t -> bool
val closed : _ t -> bool
(** Cumulative candidates decoded, for headless cache checks/measurements. *)
val prepared_count : _ t -> int
(** Reject other run/root snapshots. Reopening requires a fresh session. Provider
    owns snapshot ordering, candidate validity/deduplication and resource limits. *)
val install : _ t -> Model.Discovery.t -> bool
val update : _ t -> Ches_palette.Palette.Event.t -> unit
(** Process at most [budget] candidates or output records per turn (suggest 128).
    Prepared decoding is reused across queries/batches. Ranking uses ordered inserts
    rather than an unbounded final sort. Final publication reverses the result list
    and validates selection in O(results); this explicit work turn is not hard
    realtime. Per-candidate long-query/path cost also remains unbounded in time. *)
val work : _ t -> budget:int -> unit
(** Exactly once, even on repeated/reentrant calls. Mark closed and discard work,
    then [release] must cancel discovery and release host input/paste capture before
    [consume]. No selection/busy/closed means no effects. Exceptions are not retried. *)
val accept : 'token t -> release:(unit -> unit) -> consume:('token Model.Request.t -> unit) -> unit
val cancel : _ t -> release:(unit -> unit) -> unit
