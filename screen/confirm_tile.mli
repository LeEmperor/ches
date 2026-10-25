(** The confirmation float: a registered view's yes/no question
    ({!View_registry.Ask.Confirm}), opened on the single float slot over that view,
    which is neither left nor changed meanwhile. The default answer is No: only [y]
    confirms; [n], Escape, Tab and Ctrl-c decline ({!Ui_state} routes the last
    three). Either answer closes it and returns focus to the view. *)

open! Core

val id : Ches_tile.View_id.t
val spec : Ches_tile.Spec.t

type t [@@deriving sexp_of]

val create : origin:Ches_tile.View_id.t -> title:string -> message:string -> t

(** The view that asked, and that focus returns to. *)
val origin : t -> Ches_tile.View_id.t

val title : t -> string
val message : t -> string

(** Outer size that shows the whole message when the screen allows. *)
val preferred_size : t -> Floating.Size.t

(** The smallest outer size: a frame, one message row and the answer row. *)
val minimum : Floating.Size.t

type action =
  | Yes
  | No
[@@deriving sexp_of, equal]

(** [y] is [Yes] and [n] is [No]; every other key is unbound. *)
val interpret : Ches_input.Key.t list -> action Ches_tile.Content_key.t

val hint : string

(** Shell content for a [width] by [rows] content viewport: the message, word-wrapped,
    then the answer row, which is always shown. *)
val render : ?notice:string -> t -> width:int -> rows:int -> Tile_shell.Content.t
