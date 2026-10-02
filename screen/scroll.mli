(** Scroll position of the text viewport. This is UI state, not editor state. *)

open! Core

type t =
  { top : int (** First visible line, zero-based. *)
  ; left : int (** First visible display cell. *)
  }
[@@deriving sexp_of, equal]

val zero : t

(** The scroll that shows the cursor, moving as little as possible from [t].

    [line] is the cursor's line; [span] is the cursor's [(first cell, width)], as from
    {!Cell_map.cursor_span}. [rows] and [cols] are the text viewport's size.

    - Vertically, the cursor line is made visible. With [fill], the first line is
      then lowered, if needed, so the viewport is not partly empty while earlier
      lines are hidden. Without it, a view scrolled past the end (as [Ctrl-e] may
      leave it, with the last line at the top) stays put while the cursor is
      visible.
    - Horizontally, the view starts at cell 0 whenever the span fits there. Otherwise
      the whole span is made visible; if it is wider than the viewport, its first cell
      is.
    - With zero [rows] or [cols], [t] is returned unchanged. *)
val fit
  :  t
  -> fill:bool
  -> line:int
  -> span:int * int
  -> rows:int
  -> cols:int
  -> line_count:int
  -> t
