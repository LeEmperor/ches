(** Read-only text inspection for a focused view: a snapshot of canonical text, a
    cursor, characterwise/linewise Visual selection, and yank. It never edits; keys that
    would edit are rejected. Like the rest of this library it knows no content type: an
    adapter supplies the text (say, a report item's details) and decides when to open,
    update, or close the view.

    {2 Positions and rows}

    The text is split into logical lines at LF. Positions are byte offsets into the
    text, always the start of a glyph with display cells (a zero-width code point
    belongs to the glyph before it), or the start of an empty line. Lines are wrapped by
    display cells into rows of the viewport width with {!Ches_core.Cell_layout}, using
    the [cell_width] the screen draws with, so rows, the cursor cell, selection
    highlighting, and copied bytes all agree. A TAB keeps the width it has in its
    unwrapped line.

    {2 Movement}

    [h]/[l] move by glyph within a logical line; [0], [^], [$] go to its start, first
    non-blank, and last glyph; [w]/[b] go to the next/previous small-word start (as in
    the editor: identifier runs, punctuation runs, empty lines) across lines. [j]/[k]
    move by display row, keeping a preferred display column; [gg]/[G] go to the first
    and last row; [Ctrl-d]/[Ctrl-u] scroll and move by half the viewport. No counts.

    {2 Selection and copying}

    [v]/[V] start characterwise/linewise Visual, switch kind, or end it; [o] swaps
    the selection's ends. A characterwise selection is inclusive of the glyph under
    each end, with any combining marks, and of a line break when an end is on an empty
    line. A linewise one is whole logical lines, never wrapped rows. [y] in Visual
    (or [Y]) copies the selection, ends Visual, and puts the cursor at its start;
    outside Visual, [yy] or [Y] copies the cursor's logical line. Copied text is the snapshot's bytes: never wrap
    breaks, padding, markers, or escape forms. *)

open! Core
open Ches_input

module Kind : sig
  type t =
    | Characterwise
    | Linewise
  [@@deriving sexp_of, equal]
end

module Motion : sig
  type t =
    | Left
    | Right
    | Down
    | Up
    | Line_start
    | First_nonblank
    | Line_end
    | Word_forward
    | Word_backward
    | Half_down
    | Half_up
    | First
    | Last
  [@@deriving sexp_of, equal]
end

module Action : sig
  type t =
    | Move of Motion.t
    | Visual of Kind.t (** Start, switch to, or (the same kind) end Visual. *)
    | Swap_ends
    | Yank (** The Visual selection. *)
    | Yank_line
    | Exit_visual
    | Edit (** A key that would edit; always rejected. *)
  [@@deriving sexp_of, equal]
end

(** What a performed action asks of the application. *)
module Effect : sig
  type t =
    | Copy of Ches_core.Register.t
    (** Copy to the shared clipboard destinations (see the application). *)
    | Notice of string
  [@@deriving sexp_of, equal]

  (** ["Copied 12 characters"], ["Copied 2 lines"]. *)
  val describe_copy : Ches_core.Register.t -> string
end

type t [@@deriving sexp_of]

(** A view of [text] with the cursor at its start, not in Visual. *)
val create : cell_width:Ches_core.Cell_layout.Width.t -> string -> t

val text : t -> string
val cursor : t -> int
val visual : t -> Kind.t option

(** First visible row, as last fitted. *)
val top : t -> int

(** The selected bytes [\[start, stop)] of {!text}, while in Visual. *)
val selection : t -> (int * int) option

(** Keys typed into the view. [o] means Swap_ends and [y]/[Y] Yank only in Visual;
    otherwise [o] is an edit key, [y] is a prefix of [yy], and [Y] is Yank_line. Edit keys ([i a o x d c s r p u J ~ < >], their
    capitals, [.], and [Ctrl-r]) are [Edit]. *)
val interpret : t -> Key.t list -> Action.t Content_key.t

(** Escape ends Visual; otherwise the adapter decides. *)
val escape : t -> Action.t option

(** Keys for a read-only list item rather than its text: [yy] or [Y] copies the
    selected item, and edit keys are rejected. *)
val interpret_item : Key.t list -> [ `Copy | `Edit ] Content_key.t

(** A whole item's text, linewise. *)
val copy_item : string -> Effect.t

(** The notice for a rejected edit or paste. *)
val read_only : string

(** Keep the cursor on a glyph and within the [rows] visible from {!top} at this
    [width]. Rendering and every action fit first. *)
val fit : t -> width:int -> rows:int -> t

val perform : t -> width:int -> rows:int -> Action.t -> t * Effect.t option

(** A new snapshot from the source. When [text] differs, Visual ends and the cursor
    stays on the same logical line and display column where they still exist; it is
    never moved onto content the user did not reach. [`Changed true] says a selection
    was dropped. *)
val update : t -> string -> t * [ `Same | `Changed of bool ]

(** One display row of the wrapped text. *)
module Row : sig
  type t =
    { line_start : int (** Offset of the row's logical line; glyph [pos]es add to it. *)
    ; glyphs : Ches_core.Cell_layout.Glyph.t array
    ; first_col : int (** Display column of the row's first cell within its line. *)
    ; break : int option
    (** The offset of the line break ending this row's logical line, on its last
        row; [None] on other rows and at the end of the text. *)
    }
  [@@deriving sexp_of]
end

(** Every row at [width]. *)
val rows : t -> width:int -> Row.t list

(** The cursor's row and the column within it, after {!fit}. *)
val cursor_cell : t -> width:int -> int * int
