(** Undo/redo history of whole-text snapshots, with an explicit active transaction.

    The history knows nothing about modes or commands: {!Editor} decides where
    transactions begin and end. Retention is bounded across undo and redo together.
    After a changed commit the oldest steps are removed until both limits hold,
    except that the newest complete step always survives: its charge may exceed
    the soft byte budget. Thus complete-step charge is <= max(budget, newest step
    charge), and count <= max_steps, including after undo/redo. Active transactions
    are never evicted and their before snapshot is outside the complete-step budget.

    Each step charges 128 bytes plus both Text_buffer.retained_bytes estimates.
    Shared snapshots (including adjacent after/before) are deliberately double
    charged; no byte scans or content hashing. Layout caches are bounded separately,
    not charged here. This is a retention estimate, not an RSS bound.

    Persistent ordered maps give O(log n) undo/redo and commit without eviction;
    evicting k steps costs O(k log n), oversized replacement and redo invalidation
    drop roots directly. Old externally retained history values remain valid. *)

open! Core

type snapshot =
  { text : Text_buffer.t
  ; cursor : int
  }

type t

module Limits : sig
  type t = { max_steps : int; max_bytes : int } [@@deriving sexp_of, equal]
  val default : t
end

module Stats : sig
  type t = { undo_steps : int; redo_steps : int; retained_bytes : int }
  [@@deriving sexp_of, equal]
end

(** Limits are fixed per history. Requires max_steps >= 1 and max_bytes >= 0. *)
val create : ?limits:Limits.t -> unit -> t
val limits : t -> Limits.t
val stats : t -> Stats.t

val empty : t
val is_active : t -> bool

(** Start a transaction whose undo target is [before], unless one is already active
    (then [before] is ignored). *)
val ensure_active : t -> before:snapshot -> t

(** Close the active transaction, if any. It becomes an undo step only if its text
    changed overall; recording a step clears the redo stack. A transaction with no net
    change is dropped. *)
val commit : t -> after:snapshot -> t

(** [undo t] returns the snapshot to restore, or [None] if there is nothing to undo.
    Raises if a transaction is active: commit it first. *)
val undo : t -> (t * snapshot) option

(** Like {!undo}, in the other direction. *)
val redo : t -> (t * snapshot) option
