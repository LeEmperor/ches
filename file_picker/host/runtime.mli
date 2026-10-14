open! Core
open! Async

(** Async assembly, separate from the pure screen model. Reuse one runtime per
    frontend. Root is explicit/retained by the caller, not inferred on each query.
    There is deliberately no file opener or default acceptance consumer. *)
type t
module Cache_limits : sig
  type t = { max_roots : int; max_bytes : int; ttl : Time_ns.Span.t }
  (** Per runtime: two roots, 128 MiB conservative data charge, 30-second age since
      validation. Every hit still starts rg refresh; no acceptance until validated. *)
  val default : t
end
val create
  : ?prog:string -> ?limits:Ches_file_discovery.Provider.Limits.t
  -> ?cache_limits:Cache_limits.t -> ?now:(unit -> Time_ns.t) -> unit -> t
val cache_bytes : t -> int
val cache_entries : t -> int
val cache_hits : t -> int
val cache_evictions : t -> int
val invalidate_cache : t -> unit
val open_picker_with_policy : t -> Ches_screen.Ui_state.t -> root:string -> policy:string
  -> width:int -> height:int -> Ches_screen.Ui_state.t Or_error.t
val open_picker
  : t -> Ches_screen.Ui_state.t -> root:string -> width:int -> height:int
  -> Ches_screen.Ui_state.t Or_error.t
(** Await, inject returned inputs, install resulting UI state, then repeat while
    nonempty. Async yields between 128-record work turns, polls one provider batch,
    and idles briefly during discovery. Stale queued turns are rejected by Ui_state.
    After a query edit, call again even if a previous chain reached quiescence. *)
val next : t -> Ches_screen.Ui_state.t -> Ches_screen.Ui_state.Input.t list Deferred.t
val cancel : t -> unit
val finished : t -> unit Deferred.t
  (** Latest child has closed/reaped, not a snapshot-consumption notification. *)

(** Single frontend-owned pump; [inject] must install the resulting state before
    resolving. Reads current state between turns, not a captured initial model.
    Ends on close or completed filtering/discovery; restart after query input.
    Do not run concurrent pumps on one runtime. No background worker mutates UI. *)
val pump
  : t -> current:(unit -> Ches_screen.Ui_state.t)
  -> inject:(Ches_screen.Ui_state.Input.t list -> unit Deferred.t)
  -> unit Deferred.t
