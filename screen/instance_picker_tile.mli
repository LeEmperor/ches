open! Core

(** Pure hierarchy-path picker. Selection returns the exact captured instance;
    activation and navigation belong to the host. The active path is marked in
    the list independently of the keyboard selection. *)
type t [@@deriving sexp_of]

val id : Ches_tile.View_id.t
val spec : Ches_tile.Spec.t
val create
  :  module_name:string
  -> active:string option
  -> Ches_error.Language_query.instance list
  -> t
val selected : t -> Ches_error.Language_query.instance option
val query : t -> string
val fit : t -> rows:int -> t
val interpret : Ches_input.Key.t list -> Palette_tile.action Ches_tile.Content_key.t
val update : t -> rows:int -> Ches_palette.Palette.Event.t -> t
val cursor : t -> width:int -> Ches_tile.Cursor.t
val render
  :  ?hotkey_hints:bool
  -> ?notice:string
  -> t
  -> width:int
  -> rows:int
  -> Tile_shell.Content.t
