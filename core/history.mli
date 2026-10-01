(** Undo/redo history of whole-text snapshots, with an explicit active transaction.

    The history knows nothing about modes or commands: {!Editor} decides where
    transactions begin and end. Storing whole snapshots is simple but retains every
    historical text; see the plan's note on large files. *)

open! Core

type snapshot =
  { text : Text_buffer.t
  ; cursor : int
  }

type t

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
