open! Core

(** Pure discovery UI over a captured effective catalog. Acceptance is interpreted
    but never executed here; the host validates its snapshot and instantiates ID. *)
type t [@@deriving sexp_of]

val id : Ches_tile.View_id.t
val spec : Ches_tile.Spec.t
val create : Ches_completion.User_snippets.item list -> t
val selected : t -> Ches_completion.User_snippets.item option
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
