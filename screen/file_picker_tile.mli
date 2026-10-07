open! Core
open Ches_file_picker

(** Shared floating adapter, assembled explicitly through Ui_state (no binding).
    Host owns discovery polling, yielding work turns, capture and focus. Content
    reserves query/status rows, then results; root is in title and errors/limits
    also in footer. Tiny content areas may clip status (phase 5 must set minima). *)
val id : Ches_tile.View_id.t
val spec : Ches_tile.Spec.t
type 'token t
val create : token:'token -> discovery:Model.Discovery.t -> 'token t
val session : 'token t -> 'token Interaction.t
val view : _ t -> Model.Candidate.Id.t Ches_tile.Navigation.Selection.t
val preview : _ t -> Ches_file_preview_model.Model.snapshot option
val expect_preview : _ t -> Ches_file_preview_model.Model.request option -> unit
val clear_preview : _ t -> unit
val install_preview : _ t -> Ches_file_preview_model.Model.snapshot -> bool
val columns : width:int -> int * int option
val fit : _ t -> rows:int -> unit
type action = Event of Ches_palette.Palette.Event.t | Accept [@@deriving sexp_of]
(** Tab/Shift-Tab and Ctrl-n/p navigate results. Escape and Ctrl-c remain
    host-owned. Paste is delivered as an Event. *)
val interpret : Ches_input.Key.t list -> action Ches_tile.Content_key.t
val update : _ t -> rows:int -> Ches_palette.Palette.Event.t -> unit
val install : _ t -> Model.Discovery.t -> bool
val work : _ t -> budget:int -> unit
val accept : 'token t -> release:(unit -> unit) -> consume:('token Model.Request.t -> unit) -> unit
val cancel : _ t -> release:(unit -> unit) -> unit
val cursor : _ t -> width:int -> Ches_tile.Cursor.t
val render : ?notice:string -> _ t -> width:int -> rows:int -> Tile_shell.Content.t
