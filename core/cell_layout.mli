(** The one mapping from code points to display cells.

    Editing semantics that depend on what lines up on screen (the preferred column of
    vertical moves, soft tabs, and later rectangular selections) and the screen's
    drawing, clipping, cursor placement, and scrolling all lay text out with
    {!glyphs}, so they agree on where every code point lands.

    {v
      Code point                                  Shown as             Cells
      TAB                                         spaces to next stop  1-8
      C0 controls (other than TAB) and DEL        ^A ... ^_, ^?        2
      C1 controls U+0080-U+009F                   <80> ... <9f>        4
      Bidi controls and U+FEFF                    <202e>               6
      Other code points with negative width       <hex>                4+
      Other, width 0, 1 or 2                      itself               0-2
    v}

    LF never occurs in a document line; elsewhere it is a C0 control ([^J]). A byte
    that is not part of valid UTF-8 (possible only in filenames and messages) is shown
    as [\xNN] (4 cells).

    This module has no terminal dependency: the width of an ordinary code point comes
    from a {!Width.t} supplied by the frontend, which must be the same function the
    frontend draws with. *)

open! Core

module Width : sig
  (** Cells for a code point drawn as itself: 0, 1 or 2, or negative for one that
      cannot be drawn and is shown as an escape. Only consulted for code points not
      covered by the escape rules above. *)
  type t = Uchar.t -> int
end

(** Display cells between tab stops. *)
val tab_stop : int

module Kind : sig
  type t =
    | Plain (** The code point itself. *)
    | Tab (** Spaces up to the next tab stop. *)
    | Escape (** A visible escape form, such as [^\[] or [<202e>]; ASCII only. *)
  [@@deriving sexp_of, equal]
end

module Glyph : sig
  type t =
    { pos : int (** Byte offset of the code point in the string. *)
    ; col : int (** First display cell, counting from the start of the string. *)
    ; width : int (** Display cells, at least 0; 0 only for [Plain]. *)
    ; text : string
    (** What to draw in those cells: valid UTF-8 without control characters. *)
    ; kind : Kind.t
    }
  [@@deriving sexp_of]
end

(** The glyphs of [s], one per code point (or invalid byte), in order. *)
val glyphs : width:Width.t -> string -> Glyph.t array

(** Total display width of [glyphs]. *)
val total_width : Glyph.t array -> int

(** The cursor's cells in a line laid out as [glyphs], as [(first cell, width)], for a
    cursor at byte [pos] (a code-point boundary, or the line's length).

    The cursor sits on the first cell of the code point at [pos], or on the cell after
    the last one at the end of the line. A zero-width code point puts it on the first
    cell of the nearest preceding nonzero-width code point, or on cell 0.

    The span is the code point's cells; with [~insertion:true], at the line's end, or
    on a zero-width code point, it is the single cursor cell. *)
val cursor_span : Glyph.t array -> pos:int -> insertion:bool -> int * int

(** The display column a cursor at byte [pos] aims for when it moves vertically, as
    Vim's [curswant]: the first cell of {!cursor_span}, except that a cursor on a TAB
    (not an insertion point) uses the TAB's last cell, where Vim shows it. *)
val column : Glyph.t array -> pos:int -> insertion:bool -> int

(** The byte offset of the code point covering display column [col], skipping
    zero-width code points; [None] when [col] is at or past {!total_width}. A column
    inside a TAB or wide glyph gives that glyph. *)
val pos_of_column : Glyph.t array -> int -> int option
