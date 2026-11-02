open! Core
val id : Ches_tile.View_id.t
val spec : Ches_tile.Spec.t
val placement : width:int -> height:int -> Tile_shell.Layout.t option
val placement_with_preferred : preferred:Floating.Size.t -> width:int -> height:int -> Tile_shell.Layout.t option
type inspection
(** Frozen screen grid, canonical UTF-8 text and read-only modal cursor. The grid
    never reflows when the float is resized: rendering clips around its cursor.
    No backend history is captured. *)
val inspect : Ches_terminal.Model.snapshot option -> inspection
(** Starts at the child cursor, snapped to the leading cell of a wide glyph. *)
val inspection_text : inspection -> Ches_tile.Text_view.t
(** In block mode the underlying Text_view keeps a latent characterwise Visual
    for motions and endpoints; use [block_selection] to distinguish its kind. *)
type block_selection =
  { first_row : int; last_row : int; left : int; right : int }
[@@deriving sexp_of, equal]
val block_selection : inspection -> block_selection option
(** Frozen-grid rectangle: inclusive rows, half-open display columns. Every wide
    glyph intersecting it is highlighted and copied atomically, with combining
    marks. Block yanks export [Register.Block], width at least the rectangle's
    width and large enough for every copied row. *)
val toggle_block : inspection -> rows:int -> inspection
val perform : inspection -> rows:int -> Ches_tile.Text_view.Action.t -> inspection * Ches_tile.Text_view.Effect.t option
val render : ?hotkey_hints:bool -> ?number:int -> ?inspection:inspection -> Ches_terminal.Model.snapshot option -> failure:string option -> width:int -> rows:int -> Tile_shell.Content.t
(** Hotkey hints default to [false]; mode and process status remain in the footer. *)
val cursor : ?inspection:inspection -> Ches_terminal.Model.snapshot option -> width:int -> rows:int -> Ches_tile.Cursor.t option
