(** The command palette as a minor view: the {!Ches_palette.Palette} state for the view
    that opened it, a viewport over its ranked results, and the keys, rows, and cursor
    that present it on the shared host ({!Ches_tile.Spec.text_input}). It runs nothing:
    {!Ui_state} accepts it and dispatches the command through the controller, as its key
    binding would. It exists only while open and focused; closing discards the query.

    Content rows: the query prompt, then one result per row with its matched title
    letters highlighted and its shortcut, derived from the active bindings, on the
    right. *)

open! Core
open Ches_input
open Ches_palette

val id : Ches_tile.View_id.t
val spec : Ches_tile.Spec.t

type t [@@deriving sexp_of]

(** An open palette over [catalog] for [token], the view a command will apply to.
    [bindings] are the active Normal bindings ({!Bindings.to_list}), for shortcuts. *)
val create
  :  Catalog.t
  -> Catalog.Context.t
  -> token:Ches_tile.View_id.t
  -> bindings:(Key.t list * Bindings.Target.t) list
  -> t

val palette : t -> Ches_tile.View_id.t Palette.t

(** The viewport over results: the palette's selection and the first visible row. *)
val view : t -> Catalog.Id.t Ches_tile.Navigation.Selection.t

(** Keep the selected result within a content area [rows] tall (the query takes the
    first row). Never changes the query or which command is selected. *)
val fit : t -> rows:int -> t

type action =
  | Event of Palette.Event.t
  | Accept
[@@deriving sexp_of]

(** Characters, including Space and [j]/[k], edit the query; Backspace deletes a
    character, and Ctrl-w or Ctrl-h (most terminals' Ctrl-Backspace) a word;
    Ctrl-n and Ctrl-p select the next and previous result; Enter accepts. Escape, Tab,
    and Ctrl-c are the host's ({!Ches_tile.Host.key}). *)
val interpret : Key.t list -> action Ches_tile.Content_key.t

val hint : string

(** Apply [event], then {!fit} to [rows]. *)
val update : t -> rows:int -> Palette.Event.t -> t

(** The text-entry point after the query on the prompt row, in a [width]-cell content
    area: a bar, always within the area when [width > 0]. *)
val cursor : t -> width:int -> Ches_tile.Cursor.t

(** Shell content for a [width] by [rows] content viewport. *)
val render : ?notice:string -> t -> width:int -> rows:int -> Tile_shell.Content.t
