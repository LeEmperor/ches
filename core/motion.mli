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
    - [First_line] and [Last_line] go to the first non-blank of line [n] (one-based)
      when given a count [n], clamped to the document; without a count, of the first
      or last line. The empty line after a trailing LF is the last line.
    - [Left]/[Right] move by code points within the line; [Up]/[Down] move by lines,
      to the {i preferred column}, clamped to the line's length. All four clamp at
      their boundaries. *)

open! Core

module Word : sig
  type t =
    | Small (** [w], [b], [e]. *)
    | Big (** [W], [B], [E]. *)
  [@@deriving sexp_of, equal, enumerate]
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
  | Line_end
  | First_line
  | Last_line
[@@deriving sexp_of, equal, enumerate]

module Kind : sig
  (** How an operator will use the motion's range (from phase 5 on): whole lines, or
      characters up to the destination, including it when [inclusive]. *)
  type t =
    | Characterwise of { inclusive : bool }
    | Linewise
  [@@deriving sexp_of, equal]
end

(** [Up]/[Down]/[First_line]/[Last_line] are linewise; [Word_end] and [Line_end] are
    inclusive; the rest are exclusive. *)
val kind : t -> Kind.t

(** All but [Line_start] and [First_nonblank]. *)
val takes_count : t -> bool

(** Whether the move keeps the cursor's preferred column ([Up], [Down]) instead of
    resetting it to the destination's column. *)
val keeps_preferred_column : t -> bool

(** The destination from [cursor]. [count] is [None] when none was given; a given
    count must be positive. [preferred_column] is the code-point column [Up]/[Down]
    aim for. *)
val destination
  :  Text_buffer.t
  -> t
  -> cursor:int
  -> preferred_column:int
  -> count:int option
  -> int
