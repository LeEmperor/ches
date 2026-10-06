(** Shared read-only list movement: the keys, item selection by adapter-supplied
    keys, and a clamped row offset for scrollable content such as details. No content
    type, identity, or domain policy appears here. *)

open! Core
open Ches_input

module Motion : sig
  type t =
    | Down (** [j] *)
    | Up (** [k] *)
    | Half_down (** [Ctrl-d]: half the viewport rows, at least 1. *)
    | Half_up (** [Ctrl-u] *)
    | First (** [gg] *)
    | Last (** [G] *)
  [@@deriving sexp_of, equal]
end

(** [j], [k], [G], [Ctrl-d], [Ctrl-u], and [gg]; [g] alone is a prefix. *)
val interpret : Key.t list -> Motion.t Content_key.t

(** Selection over a list of opaque item keys, with a viewport of [rows]. *)
module Selection : sig
  type 'key t =
    { selected : 'key option
    ; index : int
    ; top : int (** First visible item. *)
    }
  [@@deriving sexp_of]

  val empty : 'key t

  (** Keep the selected key. When it is gone (removed or filtered out), select the
      item now at the previous index, or the last item; an empty list selects
      nothing. Then keep the selection within the [rows] visible from [top]. *)
  val fit : 'key t -> 'key list -> equal:('key -> 'key -> bool) -> rows:int -> 'key t

  (** Select the item at [index], clamped to the list. *)
  val select
    :  'key t
    -> 'key list
    -> equal:('key -> 'key -> bool)
    -> rows:int
    -> int
    -> 'key t

  val move
    :  'key t
    -> 'key list
    -> equal:('key -> 'key -> bool)
    -> rows:int
    -> Motion.t
    -> 'key t
end

(** The first visible row of [total] rows in a viewport of [rows], after [motion],
    within [0 .. max 0 (total - rows)]. *)
val move_offset : int -> total:int -> rows:int -> Motion.t -> int
