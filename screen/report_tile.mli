(** A static, error-free report: labelled items with a selectable list and wrapped,
    scrollable details. It demonstrates that a minor view needs only the shared host and
    navigation and read-only text, never feedback, a file identity, or a producer. Its
    items are fixed when it is created; nothing it does posts feedback or touches the
    document. An item's text is ["title: body"]: its details, and what copying copies. *)

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

(** Whether the selected item's details are open, and their first visible row. *)
val details : t -> bool

val detail_top : t -> int

(** The open details as read-only text. *)
val text_view : t -> Ches_tile.Text_view.t option

(** Reconcile the selection and open details with a [width] by [rows] content viewport.
    Details close when the selected item changes. *)
val fit : t -> rows:int -> width:int -> t

val leave : t -> t

type action [@@deriving sexp_of]

(** In the list, shared list motions select, [yy]/[Y] copy the selected item's text,
    and edit keys are rejected. [e] or Enter opens its details as read-only text
    ({!Ches_tile.Text_view}: movement, Visual selection, yank), and closes them again. *)
val interpret : t -> Ches_input.Key.t list -> action Ches_tile.Content_key.t

(** Escape ends Visual, then closes details. *)
val escape : t -> action option

val hint : string

(** [rows] and [width] are the focused view's content viewport. *)
val perform
  :  t
  -> rows:int
  -> width:int
  -> action
  -> t * Ches_tile.Text_view.Effect.t option

(** Shell content for a [width] by [rows] content viewport. *)
val render
  :  ?focused:bool
  -> ?notice:string
  -> ?pending:string
  -> t
  -> width:int
  -> rows:int
  -> Tile_shell.Content.t
