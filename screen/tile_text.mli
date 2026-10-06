(** Cell-exact rows for minor tile content, shared by content adapters so that none
    implements its own clipping, wrapping, or capture layout. Every row is exactly
    the given width; text is sanitized by {!Cell_map}. *)

open! Core

(** One line of [text] in [style], cut with a [>] marker, padded to [width]. *)
val row : Style.t -> string -> width:int -> Span.t list

(** [row] with a [> ] selection marker or two blanks. *)
val item : selected:bool -> Style.t -> string -> width:int -> Span.t list

(** [text] wrapped by display cells into rows of [width], keeping whole glyphs. *)
val wrap : string -> width:int -> Span.t list list

(** Content rows between the header and footer of a focused view in [rect]. *)
val capacity : Geometry.Rect.t -> int

(** The footer: a notice, else a pending prefix, else [default]. *)
val footer
  :  notice:string option
  -> pending:string option
  -> default:string
  -> width:int
  -> Span.t list

(** A focused view: [header], then [body] padded or cut to {!capacity}, then [footer],
    all clipped to [rect.height] rows. *)
val capture
  :  rect:Geometry.Rect.t
  -> header:string
  -> body:Span.t list list
  -> footer:Span.t list
  -> Span.t list list

(** Exactly [rect.height] rows of [rows], padded with blank rows. *)
val fill : rect:Geometry.Rect.t -> Span.t list list -> Span.t list list
