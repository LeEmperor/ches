open! Core

val prompt : string
val query_row : string -> width:int -> Span.t list
val cursor : string -> width:int -> Ches_tile.Cursor.t
(** Positions are UTF-8 byte starts in safe display text, not filesystem paths. *)
val matched_text : string -> positions:int list -> Span.t list
