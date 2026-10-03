(** Rectangular (blockwise Visual) selections, resolved in display columns.

    A block is laid out with {!Cell_layout}, so it is rectangular on screen around
    TABs, wide characters and zero-width marks, as in Vim with its default options.
    Columns are zero-based display cells.

    {2 Bounds}

    Each corner (the anchor and the active cursor) covers the cells of the code point
    it is on, or the single cell after the text when it is at a line's end (which
    Visual mode allows; an empty line's corner is cell 0). The block spans from the
    smallest first cell to the largest last cell of the two corners, so a corner on a
    TAB or wide glyph covers the whole glyph, and every arrangement of the same two
    corners gives the same block. After [$] the block instead reaches each line's own
    end.

    {2 Rows}

    {!rows} turns a block into one byte range per line, without changing anything. A
    code point with a cell inside the block belongs to its line's range, so a TAB or
    wide glyph cut by an edge is included whole, and [before]/[after] say how many of
    its cells lie outside. A zero-width code point goes with the code point before
    it. A line that ends before the block's first column (a short or empty line) has
    an empty range at its end. *)

open! Core

type t =
  { first_line : int
  ; last_line : int
  ; left : int (** First display column. *)
  ; right : int option
  (** The display column after the last one, or [None] when the block reaches every
      line's end. *)
  }
[@@deriving sexp_of, equal]

(** The block with corners at byte offsets [anchor] and [active] (code-point
    boundaries, possibly a line's end). [to_line_end] is the state after [$]. *)
val of_corners
  :  Text_buffer.t
  -> cell_width:Cell_layout.Width.t
  -> anchor:int
  -> active:int
  -> to_line_end:bool
  -> t

module Row : sig
  type t =
    { line : int
    ; start : int (** Byte offset of the first code point in the block. *)
    ; stop : int (** Byte offset after the last code point in the block. *)
    ; before : int
    (** Cells of the code point at [start] left of the block: nonzero only when the
        left edge is inside a TAB or wide glyph. *)
    ; after : int
    (** Cells of the code point ending at [stop] right of the block, likewise. *)
    }
  [@@deriving sexp_of, equal]
end

(** The display columns [\[left, stop)] the block covers in a line laid out as
    [glyphs]: [stop] is [right], or the line's width (empty for a line no wider than
    [left]) when the block reaches line ends. *)
val columns : t -> Cell_layout.Glyph.t array -> int * int

(** One row per line of the block, ordered from the last line to the first: editing
    the rows in this order leaves the offsets of the rows not yet edited valid. *)
val rows : Text_buffer.t -> cell_width:Cell_layout.Width.t -> t -> Row.t list

(** What a block yank or delete puts in the register: one row per line, top first,
    and the block's width in display cells, as in Vim.

    A row is the text of its line's range from {!rows}, except that the cells of a TAB
    or wide glyph cut by an edge that lie inside the block become spaces (dropping
    any zero-width marks on it). A line too short to reach the block's first column
    gives a row of [width] spaces; a line that reaches the block but ends inside it
    gives only its text, so rows can be narrower than [width]. Vim pads too-short
    lines after [$] with one more space than its width; this gives [width].

    The width is that of the rectangle, or after [$] that of the widest row. *)
val contents : Text_buffer.t -> cell_width:Cell_layout.Width.t -> t -> string list * int

(** Where text inserted at a display column of a line goes, as for a blockwise paste
    (and, later, block insert). *)
module Insertion : sig
  type t =
    { pos : int (** Byte offset at which to insert. *)
    ; remove : int
    (** Bytes at [pos] that the insertion replaces: 1 when the column is inside a TAB,
        which is split into spaces, otherwise 0. *)
    ; pad_before : int
    (** Spaces to insert before the text: up to the column on a line too short to
        reach it, or for the part of a split TAB or of a wide glyph before the
        column. A wide glyph is not split: it moves right, whole, after the text. *)
    ; pad_after : int (** Spaces after the text: the rest of a split TAB. *)
    ; at_end : bool (** Nothing follows the insertion on its line. *)
    }
  [@@deriving sexp_of, equal]
end

(** Insertion at display column [col] of [line]: before the code point starting at
    [col] (after any zero-width marks on the code point before it), or at the
    line's end. *)
val insertion
  :  Text_buffer.t
  -> cell_width:Cell_layout.Width.t
  -> line:int
  -> col:int
  -> Insertion.t
