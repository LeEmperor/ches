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
