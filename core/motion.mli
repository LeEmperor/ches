(** Cursor motions, resolved as pure functions of the text and cursor.

    A motion resolves to a destination offset and carries the metadata a later
    operator needs to turn it into a range ({!kind}). Resolution never changes the
    text. Destinations are boundaries, but may be the end of a nonempty line; the
    editor steps back from there in Normal mode.

    {2 Words}

    A small word ([w], [b], [e]) is a run of identifier characters (ASCII letters,
    digits, [_], and every non-ASCII code point) or a run of other non-blank
    characters (punctuation). A big word ([W], [B], [E]) is a run of non-blank
    characters. Blanks are space, TAB, and LF. An empty line also counts as a word
    for [Word_forward] and [Word_backward], but not for [Word_end], as in Vim.

    - [Word_forward] goes to the start of the next word, or to the end of the text
      when there is none.
    - [Word_backward] goes to the start of the current word if the cursor is inside
      one, otherwise of the previous word, or to the start of the text.
    - [Word_end] goes to the end of the current word if the cursor is before its
      last character, otherwise of the next word. With no next word, it stops at the
      last word end it reached (staying put if there is none).

    A count repeats a word motion, stopping early at either end of the text, so the
    work is bounded by the text traversed and not by the count.

    {2 Lines}

    - [Line_start] and [First_nonblank] (the first character other than space or
      TAB, or the line end for a blank line) take no count.
    - [Line_end] with count [n] goes to the end of the [n]th line, counting the
      current line as the first, clamped at the last line.
    - [First_nonblank_down] ([_]) and [Last_nonblank] ([g_]) choose the line the same
      way, and go to its first or last character other than space or TAB. On a
      blank line, [Last_nonblank] goes to the line start, as in Vim.
    - [First_line] and [Last_line] go to the first non-blank of line [n] (one-based)
      when given a count [n], clamped to the document; without a count, of the first
      or last line. The empty line after a trailing LF is the last line.
    - [Left]/[Right] move by code points within the line; [Up]/[Down] move by lines,
      to the code point covering the {i preferred column}, a display column (see
      {!Cell_layout}), or to the line's end when the line is shorter. All four clamp
      at their boundaries.

    {2 Matching delimiters}

    [Matching_delimiter] ([%]) finds the first of [( ) \[ \] { }] at or after the
    cursor on the cursor's line, then goes to its properly nested mate, searching
    forward from an opening delimiter or backward from a closing one, across lines.
    Mixed types nest on one stack, so [( \] )] is misnested. Matching is lexical:
    delimiters inside strings and comments count too. It fails, leaving the cursor
    where it is, when the line has no delimiter from the cursor on
    ({!Failure.No_delimiter}) or the delimiter has no properly nested mate
    ({!Failure.Unmatched}). It takes no count (Vim's [50%] is not supported). The
    scan is linear in the text it crosses. *)

open! Core

module Word : sig
  type t =
    | Small (** [w], [b], [e]. *)
    | Big (** [W], [B], [E]. *)
  [@@deriving sexp_of, equal, enumerate]
end

module Find : sig
  type direction = Forward | Backward [@@deriving sexp_of, equal]
  type t = { target : Uchar.t; direction : direction; till : bool } [@@deriving sexp_of, equal]
end

type t =
  | Left
  | Right
  | Up
  | Down
  | Word_forward of Word.t
  | Word_backward of Word.t
  | Word_end of Word.t
  | Line_start
  | First_nonblank
  | First_nonblank_down
  | Line_end
  | Last_nonblank
  | First_line
  | Last_line
  | Matching_delimiter
  | Find of Find.t
[@@deriving sexp_of, equal]

val all : t list

module Failure : sig
  type t =
    | No_delimiter (** No delimiter on the line at or after the cursor. *)
    | Unmatched of char (** This delimiter has no properly nested mate. *)
    | No_character of Uchar.t
    | No_previous_find
  [@@deriving sexp_of, equal]

  (** For feedback: [No delimiter on this line], [No match for (]. *)
  val to_string : t -> string
end

module Kind : sig
  (** How an operator will use the motion's range (from phase 5 on): whole lines, or
      characters up to the destination, including it when [inclusive]. *)
  type t =
    | Characterwise of { inclusive : bool }
    | Linewise
  [@@deriving sexp_of, equal]
end

(** [Up]/[Down]/[First_nonblank_down]/[First_line]/[Last_line] are linewise;
    [Word_end], [Line_end], [Last_nonblank], and [Matching_delimiter] are inclusive;
    the rest are exclusive. *)
val kind : t -> Kind.t

(** All but [Line_start], [First_nonblank], and [Matching_delimiter]. *)
val takes_count : t -> bool

(** Whether the move keeps the cursor's preferred column ([Up], [Down]) instead of
    resetting it to the destination's column. *)
val keeps_preferred_column : t -> bool

(** The destination from [cursor]. [count] is [None] when none was given; a given
    count must be positive. [preferred_column] is the display column [Up]/[Down]
    aim for, measured with [cell_width]. Only [Matching_delimiter] can fail; the
    others clamp. *)
val destination
  :  Text_buffer.t
  -> t
  -> cell_width:Cell_layout.Width.t
  -> cursor:int
  -> preferred_column:int
  -> count:int option
  -> (int, Failure.t) Result.t

(** The boundary of [line] at display column [column], measured with [cell_width], or
    the line's end when the line is shorter. *)
val offset_of_display_column
  :  Text_buffer.t
  -> cell_width:Cell_layout.Width.t
  -> line:int
  -> int
  -> int

val find_destination
  :  Text_buffer.t
  -> Find.t
  -> cursor:int
  -> count:int
  -> skip:int option
  -> ((int * int), Failure.t) Result.t
