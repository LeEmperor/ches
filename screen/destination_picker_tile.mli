open! Core

type t [@@deriving sexp_of]
val id : Ches_tile.View_id.t
val spec : Ches_tile.Spec.t
val create : Ches_error.Language_query.target list -> t
(** Change the result heading without resetting query, selection, or scrolling.
    Rendered headings and default footers include matching/total counts. *)
val with_title : t -> string -> t
(** Exact original target, including both ranges and encoding. Selection identity
    is its original list index, allowing identical labels and duplicate targets. *)
val selected : t -> Ches_error.Language_query.target option
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
