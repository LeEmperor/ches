(** Cell-exact rows for minor tile content, shared by content adapters so that none
    implements its own clipping or wrapping; the frame, padding, and labels around them
    are {!Tile_shell}'s. Every row is exactly the given width; text is sanitized by
    {!Cell_map}. *)

open! Core

(** One line of [text] in [style], cut with a [>] marker, padded to [width]. *)
val row : Style.t -> string -> width:int -> Span.t list

(** [row] with a [> ] selection marker or two blanks. *)
val item : selected:bool -> Style.t -> string -> width:int -> Span.t list

(** Exactly [rect.height] rows of [rows], padded with blank rows. *)
val fill : rect:Geometry.Rect.t -> Span.t list list -> Span.t list list

(** The visible rows of a read-only text view ({!Ches_tile.Text_view}) in a [width] by
    [rows] viewport, after fitting it there: glyphs as {!Cell_map} draws them, its
    selection in the document's selection style, and a selected line break as one
    selected cell after its row. Its cursor is the terminal cursor (see
    {!Ui_state.cursor_position}), not drawn here. *)
val text_view : Ches_tile.Text_view.t -> width:int -> rows:int -> Span.t list list

(** The visible row range and Visual state, with optional key hints (default [false]). *)
val text_footer : ?hotkey_hints:bool -> Ches_tile.Text_view.t -> width:int -> rows:int -> string
