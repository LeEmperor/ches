(** Source events waiting for the UI, coalesced: only the newest diagnostics per
    (source, resource) are kept, so a burst costs the UI one snapshot per collection.
    [Started] and [Stopped] are never dropped, and a snapshot never moves across its
    source's [Started]/[Stopped]: one sent after a stop is not merged into one sent
    before it. Pure data. *)
open! Core

type t [@@deriving sexp_of]

val empty : t
val push : t -> Ches_error.Source_event.t -> t

(** Up to [max] events, oldest first, and the queue without them. *)
val take : t -> max:int -> t * Ches_error.Source_event.t list

val length : t -> int

(** Snapshots replaced by newer ones before they were taken, since [empty]. *)
val dropped : t -> int
