(** The [?] help float: a read-only list of the local commands that a registered
    view ({!View_registry}) declares in its current state, with their keys. It runs
    nothing. It opens on the single float slot over the view it describes, which is
    neither left nor changed meanwhile; closing it ([q], [?], Escape, or Tab) returns
    focus to that view. *)

open! Core

val id : Ches_tile.View_id.t
val spec : Ches_tile.Spec.t

type t [@@deriving sexp_of]

(** Help for [origin], whose title is [title]. *)
val create : origin:Ches_tile.View_id.t -> title:string -> Ches_tile.Local_command.t list -> t

(** The view that focus returns to. *)
val origin : t -> Ches_tile.View_id.t

val commands : t -> Ches_tile.Local_command.t list

(** The first visible command. *)
val top : t -> int

(** Outer size that shows every command when the screen allows. *)
val preferred_size : t -> Floating.Size.t

type action =
  | Scroll of Ches_tile.Navigation.Motion.t
  | Close
[@@deriving sexp_of]

(** The shared list motions scroll; [q] and [?] close. *)
val interpret : Ches_input.Key.t list -> action Ches_tile.Content_key.t

val hint : string

(** Scroll within a content viewport [rows] tall. *)
val scroll : t -> rows:int -> Ches_tile.Navigation.Motion.t -> t

(** Shell content for a [width] by [rows] content viewport: one command per row, its
    keys in a column before its description. Key hints default to hidden; notices
    remain visible. *)
val render : ?hotkey_hints:bool -> ?notice:string -> t -> width:int -> rows:int -> Tile_shell.Content.t
