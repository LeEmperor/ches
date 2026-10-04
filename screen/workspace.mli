(** Pure allocation for one document and one optional, non-focusable status cell.
    This module owns layout, not document/controller state or status rendering.
    Measurements and allocated origins are terminal display cells. *)

open! Core

module Pane_id : sig
  (** Stable content identities, independent of split order, position, or visibility.
      These two identities suffice until additional panes are introduced. *)
  type t =
    | Document
    | Status
  [@@deriving sexp_of, equal]
end

module Split : sig
  module Axis : sig
    type t =
      | Horizontal (** Side by side. *)
      | Vertical (** Stacked. *)
    [@@deriving sexp_of, equal]
  end

  (** A two-leaf split. [first] names the left/top leaf; the other identity names
      the right/bottom leaf. This is layout intent, not status presentation. *)
  type t =
    { axis : Axis.t
    ; first : Pane_id.t
    ; status_size : int (** Requested cells along the split axis, before clamping. *)
    }
  [@@deriving sexp_of, equal]

  (** Horizontal, document first, requested status size 28. *)
  val default : t
end

module Prefs : sig
  type t =
    { status_visible : bool
    ; split : Split.t
    }
  [@@deriving sexp_of, equal]

  (** Status hidden; preserves full-screen editing with bottom-row feedback. *)
  val default : t
end

module Pane : sig
  type t =
    { id : Pane_id.t
    ; rect : Geometry.Rect.t
    }
  [@@deriving sexp_of, equal]

  (** Only the document is interactive. *)
  val focusable : t -> bool
end

type t =
  { document : Pane.t
  ; status : Pane.t option
  ; reserve_status_row : bool
  (** True when status is hidden or cannot fit: use compact document-row feedback.
      The row remains within [document.rect], not a separate overlapping pane. *)
  }
[@@deriving sexp_of, equal]

val min_document_width : int
val min_document_height : int
val min_status_width : int
val min_status_height : int

(** Normalize negative allocation dimensions to zero, preserving the origin. If
    requested and both pane minima fit, clamp status size along the split axis and
    give the document the remainder, with no gap. Otherwise allocate the entire
    rectangle to the document and request compact feedback. Requests are never
    modified: callers retain [Prefs.t] and recompute on resize or hide/restore.
    No amount of available space independently enables the status cell. *)
val allocate : Prefs.t -> allocation:Geometry.Rect.t -> t

(** Pane-local document geometry, applying independent document placement prefs
    and this allocation's compact-feedback policy. No editor state is changed. *)
val document_geometry : t -> Geometry.Prefs.t -> line_count:int -> Geometry.t
