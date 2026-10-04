open! Core

module Document_id : sig
  type t
  val create : unit -> t
end

module Key : sig
  type t
  val create : document:Document_id.t -> revision:int -> language:Language.t -> configuration:string -> t
  val equal : t -> t -> bool
  val same_document : t -> t -> bool
  val revision : t -> int
  val language : t -> Language.t
  val configuration : t -> string
end

module Range : sig
  (** Raw provider ranges, half-open document byte offsets. *)
  type t = { start : int; stop : int; category : Category.t }
  [@@deriving sexp_of, equal, compare]
end

type t

(** Source must be valid UTF-8. Invalid source raises Invalid_argument. Discards
    invalid/empty/non-boundary/Plain ranges, deduplicates, then sweeps overlaps:
    shortest original range wins, followed by category priority and ascending
    (start, stop, category). Adjacent identical categories merge. O(bytes + n log n).
    The source is not retained; keys must uniquely identify its immutable version. *)
val create : key:Key.t -> source:string -> Range.t list -> t
val key : t -> Key.t
val ranges : t -> Range.t list
val matches : t -> Key.t -> bool

(** O(log n), including offsets outside the source (which return Plain). *)
val category_at : t -> int -> Category.t

(** Returns intersecting spans, not clipped, in O(log n + result size). *)
val intersecting : t -> start:int -> stop:int -> Range.t list

(** A per-line lookup cursor, O(log n) to initialize and O(glyphs + crossed spans)
    for monotonically increasing offsets. Repeated offsets are allowed (split TABs).
    Backward offsets safely reset using binary search. *)
val lookup_from : t -> int -> (int -> Category.t)
