(** Pure centered placement of a single floating tile. Dimensions are terminal
    display cells; placement knows nothing about content, focus, or commands. *)
open! Core

module Size : sig
  type t =
    { width : int
    ; height : int
    }
  [@@deriving sexp_of, equal]
end

(** Clamp the preferred outer size to the bounds while retaining the minimum.
    Reserve a one-cell margin on each side of an axis when its minimum still fits.
    Otherwise use that full axis. Center with any odd spare cell on the right or
    bottom. Preserve the bounds' origin. Negative bounds become empty; minimum
    dimensions are at least one; preferences below the minimum become the minimum.
    Return [None] if either minimum cannot fit. No resize history is retained. *)
val place
  :  bounds:Geometry.Rect.t
  -> preferred:Size.t
  -> minimum:Size.t
  -> Geometry.Rect.t option

(** Feed placement through the shared shell exactly once. Callers choose outer
    minima sufficient for their shell policy and required content, then reuse this
    layout for drawing, viewport fitting, and cursor coordinates. *)
val layout
  :  bounds:Geometry.Rect.t
  -> preferred:Size.t
  -> minimum:Size.t
  -> policy:Tile_shell.Policy.t
  -> Tile_shell.Layout.t option
