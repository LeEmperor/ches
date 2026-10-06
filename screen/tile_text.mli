(** Cell-exact rows for minor tile content, shared by content adapters so that none
    implements its own clipping or wrapping; the frame, padding, and labels around them
    are {!Tile_shell}'s. Every row is exactly the given width; text is sanitized by
    {!Cell_map}. *)

open! Core

(** One line of [text] in [style], cut with a [>] marker, padded to [width]. *)
val row : Style.t -> string -> width:int -> Span.t list

(** [row] with a [> ] selection marker or two blanks. *)
val item : selected:bool -> Style.t -> string -> width:int -> Span.t list

(** [text] wrapped by display cells into rows of [width], keeping whole glyphs. *)
val wrap : string -> width:int -> Span.t list list

(** Exactly [rect.height] rows of [rows], padded with blank rows. *)
val fill : rect:Geometry.Rect.t -> Span.t list list -> Span.t list list
