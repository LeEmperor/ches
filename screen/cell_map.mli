(** The one mapping from code points to screen cells.

    Drawing, clipping, cursor placement, and scrolling all go through {!glyphs}, so
    they agree on where every code point lands. Document lines, filenames, and
    messages all use it.

    {v
      Code point                                  Shown as             Cells
      TAB                                         spaces to next stop  1-8
      C0 controls (other than TAB) and DEL        ^A ... ^_, ^?        2
      C1 controls U+0080-U+009F                   <80> ... <9f>        4
      Bidi controls and U+FEFF                    <202e>               6
      Other code points with negative tty width   <hex>                4+
      Other, width 0, 1 or 2                      itself               0-2
    v}

    LF never occurs in a document line; elsewhere it is a C0 control ([^J]). A byte
    that is not part of valid UTF-8 (possible only in filenames and messages) is shown
    as [\xNN] (4 cells).

    Widths come from [Notty.Tty_width_hint], per code point. Notty measures grapheme
    clusters, so its width for a complex cluster, such as an emoji ZWJ sequence, can
    differ from the sum of ours; the frontend forces every drawn span to the width
    computed here. *)

open! Core

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
    (** What to draw in those cells: valid UTF-8 without control characters, which
        [View.text] passes through unchanged. *)
    ; kind : Kind.t
    }
  [@@deriving sexp_of]
end

(** The glyphs of [s], one per code point (or invalid byte), in order. *)
val glyphs : string -> Glyph.t array

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
