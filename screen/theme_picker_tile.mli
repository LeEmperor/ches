open! Core

(** In-process theme selection. The original committed choice stays immutable for
    the lifetime of the picker; [preview] retains the last match when filtering
    yields no results. Ui_state alone commits a selection. *)
type t [@@deriving sexp_of]

val id : Ches_tile.View_id.t
val spec : Ches_tile.Spec.t
val create : Ches_theme.Theme.t -> t
val original : t -> Ches_theme.Theme.t
val preview : t -> Ches_theme.Theme.t
val selected : t -> Ches_theme.Theme.t option
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
