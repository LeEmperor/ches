open! Core
open Ches_core
open Ches_highlight

(** Controller-owned runtime and immutable highlight cache. Runtime handles are
    shared by successive controller states, never editor history; operations must
    be serialized. Snapshots/keys/statuses remain immutable across updates. *)
type t

(** Inclusive synchronous work policy: size checks precede provider creation,
    UTF-8 validation, diff, parsing and querying. Out-of-policy revisions receive
    fresh empty snapshots and a reason in [status]. Size fallback recovers as soon
    as both size limits fit. Capture fallback retries after a 25% byte OR line
    shrink, reset/reload or language change; tiny edits do not repeat the work.
    No timing-outlier-based disabling and no notifications. *)
module Policy : sig
  val max_bytes : int
  val max_lines : int
  val max_captures : int
end

val create : Editor.t -> t
val update : t -> Editor.t -> reset:bool -> t
val snapshot : t -> Snapshot.Key.t * Snapshot.t
val status : t -> Ches_highlight_tree_sitter.Provider.Status.t option
val parse_count : t -> int
val close : t -> unit

module For_testing : sig
  val has_live_provider : t -> bool
  val incremental_count : t -> int
  (** Simulate a changed language association without adding editing commands. *)
  val with_language : t -> Editor.t -> Language.t -> t
  val fail_next_parse : t -> unit
end
