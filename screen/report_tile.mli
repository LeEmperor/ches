(** A static, error-free report: labelled items with a selectable list and wrapped,
    scrollable details. It demonstrates that a minor view needs only the shared host and
    navigation, never feedback, a file identity, or a producer. Its items are fixed
    when it is created; nothing it does posts feedback or touches the document. *)

open! Core

val id : Ches_tile.View_id.t
val spec : Ches_tile.Spec.t

module Item : sig
  type t =
    { key : string (** Stable selection key. *)
    ; title : string
    ; body : string
    }
  [@@deriving sexp_of, equal]
end

type t [@@deriving sexp_of]

val create : Item.t list -> t

(** Ten labelled synthetic items, one with details longer than a bottom-band
    viewport; for [--demo-report]. *)
val demo : Item.t list

val items : t -> Item.t list
val selection : t -> string Ches_tile.Navigation.Selection.t
val details : t -> bool
val detail_top : t -> int
val fit : t -> rows:int -> t
val leave : t -> t

type action [@@deriving sexp_of]

(** Shared list motions select, or scroll open details; [e] or Enter toggles details. *)
val interpret : Ches_input.Key.t list -> action Ches_tile.Content_key.t

val escape : t -> action option
val hint : string

(** [rows] and [width] are the focused view's content viewport. *)
val perform : t -> rows:int -> width:int -> action -> t

val render
  :  ?focused:bool
  -> ?notice:string
  -> ?pending:string
  -> t
  -> rect:Geometry.Rect.t
  -> Span.t list list
