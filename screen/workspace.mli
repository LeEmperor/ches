(** Pure allocation for one document and optional status/problems cells.
    This module owns layout, not document/controller state or status rendering.
    Measurements and allocated origins are terminal display cells. *)

open! Core

module Pane_id : sig
  (** Stable content identities, independent of split order, position, or visibility.
      Minor views (problems, reports) share the bottom band; what they can do is
      their {!Ches_tile.Spec}, not their placement. *)
  type t =
    | Document
    | Status
    | Minor of Ches_tile.View_id.t
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
end

type t =
  { document : Pane.t
  ; status : Pane.t option
  ; minors : Pane.t list
  (** Requested minor views that fit, left to right in the bottom band. *)
  ; reserve_status_row : bool
  (** True when status is hidden or cannot fit: use compact document-row feedback.
      The row remains within [document.rect], not a separate overlapping pane. *)
  }
[@@deriving sexp_of, equal]

val min_document_width : int
val min_document_height : int
val min_status_width : int
val min_status_height : int
val min_minor_width : int

(** Backdrop cells between side-by-side panes (document/status and minor views).
    Stacked panes have none: their frames' border rows already separate them. *)
val gap : int

(** The bottom band takes {!preferred_band_height} rows, but never more than a third of
    the workspace (or less than {!min_band_height}), nor what document/status minima
    need. *)
val min_band_height : int

val preferred_band_height : int

(** Normalize negative allocation dimensions to zero, preserving the origin. If
    requested and both pane minima fit, clamp status size along the split axis and
    give the document the remainder, less a {!gap} when side by side. Otherwise allocate the entire
    rectangle to the document and request compact feedback. Requests are never
    modified: callers retain [Prefs.t] and recompute on resize or hide/restore.
    No amount of available space independently enables a companion cell.
    [minors] (requested visible minor views, in order) share a bottom band (see
    {!preferred_band_height}), side by side with equal widths of at least
    {!min_minor_width} separated by {!gap}; the band is left out if document/status
    minima cannot coexist, and views that don't fit are left out from the end. Status is allocated within the remaining upper rectangle. *)
val allocate
  :  ?minors:Ches_tile.View_id.t list
  -> Prefs.t
  -> allocation:Geometry.Rect.t
  -> t

(** The allocated pane of a minor view, if it fits. *)
val minor : t -> Ches_tile.View_id.t -> Pane.t option

(** Pane-local document geometry, applying independent document placement prefs
    and this allocation's compact-feedback policy. No editor state is changed. *)
val document_geometry : t -> Geometry.Prefs.t -> line_count:int -> Geometry.t
