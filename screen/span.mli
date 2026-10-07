(** Styled runs of text on one screen row, and the operations that lay them out by
    display cell. Each span's [text] is valid UTF-8 without control characters and, by
    {!Cell_map}'s widths, occupies exactly [width] cells. *)

open! Core

type t =
  { text : string
  ; width : int
  ; style : Style.t
  }
[@@deriving sexp_of]

(** [create style text ~width]: [text] must already be mapped (see {!of_text}). *)
val create : Style.t -> string -> width:int -> t

(** [width] spaces. *)
val blank : Style.t -> int -> t

(** Total width of a row of spans. *)
val total_width : t list -> int

(** Joins adjacent spans of the same style and drops empty ones. *)
val merge : t list -> t list

(** The cells [\[left, left + cols)] of a line laid out as [glyphs], exactly [cols]
    wide, in [text], with escape forms and clip markers in [special]. A partly visible
    TAB shows spaces, a partly visible escape form its visible characters, and a wide
    character cut by an edge [<] or [>]. [highlight] applies only to document
    styles and replaces only their overlay. As before, clipped escape fragments
    and wide-character markers keep [special] without the interaction overlay;
    clipped TAB cells retain their overlay. Combining marks attach only after a
    fully drawn plain glyph, retaining the supplied [text] style. Blank padding
     also uses [text], never an interaction overlay or syntax. [syntax] supplies
     a category per glyph (including combining marks); special treatment still
     takes foreground precedence. Clipped escape/wide markers stay plain special. *)
val of_glyphs
   :  ?syntax:(Cell_map.Glyph.t -> Style.Syntax.t)
   -> ?highlight:(Cell_map.Glyph.t -> [ `Match | `Current | `Selection | `Insert_cursor | `Insert_point ] option)
  -> Cell_map.Glyph.t array
  -> left:int
  -> cols:int
  -> text:Style.t
  -> special:Style.t
  -> t list

(** All of [s], mapped by {!Cell_map}, with escape forms in [special]. *)
val of_text : string -> style:Style.t -> special:Style.t -> t list

(** The first [n] cells of [spans], a single line of text. A glyph cut in two becomes
    spaces. *)
val take : t list -> n:int -> t list

(** Replace [width] cells of [base] starting at [x] with an opaque [layer].
    Clips to the base row, pads short layers with [Backdrop], and preserves the
    base width. Cut wide glyph fragments become spaces in their original style;
    combining marks survive only with a fully surviving base, even across spans.
    Inputs must satisfy the mapped-span contract. *)
val overlay : t list -> x:int -> width:int -> t list -> t list

(** The first [n] cells of [spans], ending with [>] in [marker_style] when cut. *)
val keep_left : t list -> n:int -> marker_style:Style.t -> t list

(** The last [n] cells of [spans], starting with [<] in [marker_style] when cut. *)
val keep_right : t list -> n:int -> marker_style:Style.t -> t list
