open! Core

(** Scheduler-independent mutable session, owned by one host. No IO or opening.
    Updates coalesce; call [work] between input turns, never drain it synchronously
    from a key/render callback. Results remain visible but cannot be accepted or
    navigated while busy. Selection is retained by identity on publication, falling
    back to the first result if gone. *)
type 'token t

module Cache_limits : sig
  type t = { max_entries : int; max_bytes : int }
  (** Four nonblank queries, 96 MiB conservative reachable-ownership charge.
      Shared current corpus/identity/preparation/blank storage is counted once;
      each entry also reserves its maximum alignment cache. Zero disables caching;
      caller entry caps must be between 0 and 16. This is not a process RSS bound. *)
  val default : t
end
val create : token:'token -> discovery:Model.Discovery.t -> 'token t
val create_with_cache_limits : cache_limits:Cache_limits.t -> token:'token
  -> discovery:Model.Discovery.t -> 'token t
val model : 'token t -> 'token Model.t
val query : _ t -> string
val busy : _ t -> bool
val has_work : _ t -> bool
val refreshing : _ t -> bool
val acceptance_blocked : _ t -> bool
val refresh_count : _ t -> int
val closed : _ t -> bool
(** Cumulative candidates decoded, for headless cache checks/measurements. *)
val prepared_count : _ t -> int
(** Cumulative result records indexed, including abandoned jobs. Blank-result
    reuse adds none. Useful for checking per-turn work independently of decoding. *)
val indexed_count : _ t -> int
val compiled_count : _ t -> int
val scored_count : _ t -> int
val instance : _ t -> int
(** Explicit visual epoch: query/selection/status/count/busy/results/close, never
    preparation/scoring-only work. Capture BEFORE mutating the session. *)
val visible_revision : _ t -> int
(** Hits count actual one-turn cache publications; narrowed_count counts scheduled
    narrowed jobs. Examined counts are scoring calls, including abandoned jobs.
    Keys are representative raw strings; folded-token-equivalent aliases reuse the
    same entry. Byte charge includes shared owned data plus per-entry reservations. *)
val cache_hits : _ t -> int
val cache_evictions : _ t -> int
val cache_entries : _ t -> int
val cache_queries : _ t -> string list
val cache_bytes : _ t -> int
val narrowed_count : _ t -> int
val last_examined_count : _ t -> int
(** Explicit attribution probes; payload enumeration is outside timed work. *)
val prepared_payload_bytes : _ t -> int
val work_phase : _ t -> [ `Idle | `Snapshot | `Score | `Output | `Reuse ]
(** Reject other run/root snapshots. Reopening requires a fresh session. Provider
    owns snapshot ordering, candidate validity/deduplication and resource limits. *)
val install : _ t -> Model.Discovery.t -> bool
val install_update : _ t -> Model.Discovery.Update.t -> bool
module Snapshot : sig
  (** Data only: immutable candidate/preparation/index roots, sealed arrival slots,
      copied preparation slots and bounded query data. No UI/token/run,
      pipes/processes, previews, pending work or cancellation state. Pure index
      aligners capture immutable compiled/preparation values only. *)
  type t
  val candidates : t -> Model.Discovery.Candidates.t
  val bytes : t -> int
end
val snapshot : _ t -> Snapshot.t option
val set_snapshot_sink : _ t -> (Snapshot.t -> unit) -> unit
val restore_snapshot : _ t -> Snapshot.t -> Model.Discovery.Update.t -> bool
val update : _ t -> Ches_palette.Palette.Event.t -> unit
(** Process at most [budget] candidates or output records per turn (suggest 128).
    Compiled query and score scratch are reused throughout a job. Snapshot ID indices
    and ordinal preparation slots are shared across queries; decoding across batches.
    Ranking uses ordered inserts
    rather than an unbounded final sort. Output indexing is budgeted too, and final
    publication preserves selection by logarithmic ID lookup. Blank queries build
    an index once per snapshot without fuzzy preparation; subsequent blank queries
    reuse it in one work turn. Per-candidate long-query/path cost remains unbounded
    in time; these record bounds are not hard realtime.

    Exact completed-query hits publish in one work turn, preserving CURRENT
    selection; pending acceptance stays disabled. Identical folded token arrays
    also reuse scores/positions under the existing case/whitespace semantics.
    Prefix-compatible extensions rescore complete cached survivors with original
    ordinals. No narrowing after interruption, over whole-corpus parents, or across
    snapshots. Cache admission occurs only at full ranked-output publication. *)
val work : _ t -> budget:int -> unit
(** Exactly once, even on repeated/reentrant calls. Mark closed and discard work,
    then [release] must cancel discovery and release host input/paste capture before
    [consume]. No selection/busy/closed means no effects. Exceptions are not retried. *)
val accept : 'token t -> release:(unit -> unit) -> consume:('token Model.Request.t -> unit) -> unit
val cancel : _ t -> release:(unit -> unit) -> unit
