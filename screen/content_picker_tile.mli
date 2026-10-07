open! Core
open Ches_content_picker
val id : Ches_tile.View_id.t
val spec : Ches_tile.Spec.t
type 'token t
val create : token:'token -> snapshot:Model.snapshot -> 'token t
val session : 'token t -> 'token Model.t
val view : _ t -> Model.hit Ches_tile.Navigation.Selection.t
val fit : _ t -> rows:int -> unit
type action = Event of Ches_palette.Palette.Event.t | Accept [@@deriving sexp_of]
val interpret : Ches_input.Key.t list -> action Ches_tile.Content_key.t
val update : _ t -> rows:int -> Ches_palette.Palette.Event.t -> unit
val expect : _ t -> Model.request -> unit
val install : _ t -> Model.snapshot -> bool
val accept : 'token t -> release:(unit -> unit) -> consume:('token Model.intent -> unit) -> unit
val cancel : _ t -> release:(unit -> unit) -> unit
val cursor : _ t -> width:int -> Ches_tile.Cursor.t
val render : ?notice:string -> _ t -> width:int -> rows:int -> Tile_shell.Content.t
