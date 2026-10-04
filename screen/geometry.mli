(** Screen geometry: where the document tile, its border, gutter, and text, and the
    status line go. Rendering, clipping, scrolling, and cursor placement all use the
    rectangles computed here. All measurements are display cells.

    By default the status line is the bottom row of the screen, across its full
    width. [compute_in] instead uses an allocated rectangle and explicitly chooses
    whether to reserve its bottom row for status. The tile fills the remaining rows.
    Within the tile, a single-cell border surrounds blank
    left padding (when requested), a line-number gutter (unless line numbers are
    [Off]), and the text viewport. The
    gutter is as wide in every numbered style, so switching between them never moves
    the text.

    On a small screen the border is dropped first, then the padding and gutter
    together, so the text keeps at least {!min_decorated_text_width} cells while any
    of them is shown. With line numbers [Off], the border needs no room for a
    gutter. Any dimensions, including
    zero, are accepted. *)

open! Core

module Rect : sig
  type t =
    { x : int
    ; y : int
    ; width : int
    ; height : int
    }
  [@@deriving sexp_of, equal]
end

(** Requested layout. These are kept as requested, even when the screen is too small
    to honor them, so the layout returns when the screen grows. *)
module Prefs : sig
  type t =
    { centered : bool (** Centered tile; otherwise the tile uses the full width. *)
    ; width : int (** Preferred text width when centered. *)
    ; offset : int (** Shift of the centered tile; negative is left. *)
    ; line_numbers : Line_numbers.t (** [Off] has no gutter. *)
    ; left_padding : int
    (** Blank cells between the left border and the gutter, or the text when
        there is no gutter. Counted outside the text width; negative is 0. *)
    }
  [@@deriving sexp_of, equal]

  (** Centered, width 100, offset 0, no line numbers, left padding 2. *)
  val default : t
end

val min_decorated_text_width : int

(** Where status fields are shown: a rectangle, the layout that arranges fields in
    it, and which fields, in display order. *)
module Area : sig
  type layout =
    | Status_row
    (** One row of fields, the most important leading at the left, the rest dropped
        by priority as the row narrows. *)
    | Border_title
    (** Fields set into a top border, between its corners, while they fit. *)
  [@@deriving sexp_of, equal]

  type t =
    { rect : Rect.t
    ; layout : layout
    ; fields : Status_field.Id.t list
    }
  [@@deriving sexp_of]
end

type t =
  { tile : Rect.t (** Includes the border. *)
  ; border : bool
  ; padding : int
  (** Left padding cells: [Prefs.left_padding], or 0 when the screen has no room. *)
  ; gutter : Rect.t (** Zero width when there is no gutter. *)
  ; gutter_digits : int (** Digit cells; the gutter adds one separator cell. *)
  ; text : Rect.t
  ; status : Rect.t (** Zero height when not reserved or the allocation has no rows. *)
  ; offset : int
  (** The effective offset of the tile from its centered position: [Prefs.offset]
      clamped to the screen, or 0 in full-width mode. *)
  ; areas : Area.t list
  (** The status line gets every field. The top border, when there is one, gets the
      filename. *)
  }
[@@deriving sexp_of]

(** [max 3 (digits line_count)], so the tile only moves when a file passes 999 lines. *)
val gutter_digits : line_count:int -> int

val compute : Prefs.t -> width:int -> height:int -> line_count:int -> t

(** Pane-relative layout in terminal coordinates. Negative dimensions become zero;
    origins are preserved. Every rectangle lies within the normalized allocation
    (empty rectangles may sit on its edge). Placement and effective [offset] are
    relative to this allocation, not to the terminal. No status area is produced
    when [reserve_status_row] is false. Preferences are never modified. *)
val compute_in
  :  Prefs.t
  -> allocation:Rect.t
  -> reserve_status_row:bool
  -> line_count:int
  -> t
