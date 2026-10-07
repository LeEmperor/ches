(** Current-document adapter, registered in the shared transient float host. Host must validate
    on current-controller changes and before rendering, schedule/yield work, and
    install successful acceptance's controller. Requires three content rows. *)
open! Core
type t
val id : Ches_tile.View_id.t
val spec : Ches_tile.Spec.t
val create : Ches_app.Controller.t -> t
val session : t -> Ches_line_picker.Lines.t
val fit : t -> rows:int -> unit
val interpret : Ches_input.Key.t list -> File_picker_tile.action Ches_tile.Content_key.t
val update : t -> rows:int -> Ches_palette.Palette.Event.t -> unit
val work : t -> budget:int -> unit
val validate : t -> Ches_app.Controller.t -> bool
val accept : t -> current:(unit -> Ches_app.Controller.t) -> release:(unit -> unit)
  -> Ches_app.Controller.t option Or_error.t
val cancel : t -> release:(unit -> unit) -> unit
val cursor : t -> width:int -> Ches_tile.Cursor.t
(** Control hints default to hidden; counts, status and notices remain visible. *)
val render : ?hotkey_hints:bool -> ?notice:string -> t -> width:int -> rows:int -> Tile_shell.Content.t
