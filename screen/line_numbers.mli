(** Line-number styles for the gutter, modelled as Vim's two independent switches,
    ['number'] and ['relativenumber']: neither is [Off], both are [Hybrid].

    Relative numbers are the distance from the cursor line, so labels are computed at
    render time from the cursor line; nothing is stored per line. *)

open! Core

type t =
  | Off (** No gutter. *)
  | Absolute (** Every line shows its line number. *)
  | Relative (** Every line shows its distance from the cursor line, which shows 0. *)
  | Hybrid
  (** The cursor line shows its line number, left-aligned; the others their distance. *)
[@@deriving sexp_of, equal, enumerate]

(** Flips the absolute ('number') switch, keeping the relative one. *)
val toggle_absolute : t -> t

(** Flips the relative ('relativenumber') switch, keeping the absolute one. *)
val toggle_relative : t -> t

(** Lowercase, for feedback: [off], [absolute], [relative], [hybrid]. *)
val to_string : t -> string

(** The gutter text for 0-based [line] with the cursor on [cursor_line]: [digits]
    cells of number, aligned as the style says, then one separator space. [Off] gives
    blanks of the same width. Numbers wider than [digits] are not truncated. *)
val label : t -> digits:int -> line:int -> cursor_line:int -> string
