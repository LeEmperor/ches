(** Status fields computed from the UI state, and the layouts that arrange them.
    {!Geometry.Area} says which rectangle gets which layout and fields. *)

open! Core

(** The mode badge, filename, dirty indicator, message, pending keys, and position, in
    that order; absent fields are omitted. Priorities, most important first: mode,
    an error message, pending keys, dirty indicator, position, filename, any other
    message. *)
val fields : Ui_state.t -> Status_field.t list

(** The spans for [area], exactly [area.rect.width] cells wide, from those [fields]
    whose ids [area] lists, in [area]'s order.

    - [Status_row]: the most important field leads at the left end, cut at the right
      edge if it must be. The others follow on their own side, each after a separator
      cell, with one cell kept free at the right end. Space goes to fields in priority
      order; a field that does not fit is cut, if its [fit] allows and at least 4 cells
      remain, and every field of lower priority is dropped, so fields disappear
      strictly by priority as the row narrows.
    - [Border_title]: [─], then the fields, each after a separator cell, then one
      more space, then [─] to the end. Fields are fitted as in a row; if none fit, the
      border is unbroken. The status-line styles of the fields' text become the
      border-title styles. *)
val render : Geometry.Area.t -> Status_field.t list -> Span.t list

module Tile : sig
  (** Pane-local rows; row [i] starts at terminal [rect.x, rect.y + i]. No surrounding
      terminal backdrop or cursor is supplied. All rows occupy [rect.width] cells. *)
  type t =
    { rect : Geometry.Rect.t
    ; rows : Span.t list list
    }
  [@@deriving sexp_of]
end

(** Vertical status within any allocation. Negative dimensions normalize to zero;
    the origin is preserved. Output has exactly [rect.height] rows, each exactly
    [rect.width] display cells, including blank unused rows.

    Order: mode, filename/dirty, position, pending, message. Absent fields consume
    no rows. Height priority: mode, error message (priority 1), pending, dirty/file,
    clean file, position, routine message (priority 6). Selected rows keep presentation
    order, independently of [side] and input field order. Message urgency comes from
    the existing field priority; other vertical priorities are explicit.

    Filename retains its tail with [<], reserving space for the dirty marker. Other
    text retains its start with [>]; mode strips badge margins and retains initial
    letters without a marker. Dirty, pending, and error cut markers retain their
    semantic styles even in a one-cell allocation. Unicode cell boundaries use the
    existing span operations. No borders, message lifecycle, or UI integration are
    introduced here. *)
val vertical : rect:Geometry.Rect.t -> Status_field.t list -> Tile.t
