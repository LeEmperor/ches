open! Core
val id : Ches_tile.View_id.t
val spec : Ches_tile.Spec.t
val placement : width:int -> height:int -> Tile_shell.Layout.t option
val render : Ches_terminal.Model.snapshot option -> failure:string option -> width:int -> rows:int -> Tile_shell.Content.t
val cursor : Ches_terminal.Model.snapshot option -> width:int -> rows:int -> Ches_tile.Cursor.t option
