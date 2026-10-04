open! Core

module Pane_id = struct
  type t =
    | Document
    | Status
  [@@deriving sexp_of, equal]
end

module Split = struct
  module Axis = struct
    type t =
      | Horizontal
      | Vertical
    [@@deriving sexp_of, equal]
  end

  type t =
    { axis : Axis.t
    ; first : Pane_id.t
    ; status_size : int
    }
  [@@deriving sexp_of, equal]

  let default = { axis = Horizontal; first = Document; status_size = 28 }
end

module Prefs = struct
  type t =
    { status_visible : bool
    ; split : Split.t
    }
  [@@deriving sexp_of, equal]

  let default = { status_visible = false; split = Split.default }
end

module Pane = struct
  type t =
    { id : Pane_id.t
    ; rect : Geometry.Rect.t
    }
  [@@deriving sexp_of, equal]

  let focusable t = Pane_id.equal t.id Document
end

type t =
  { document : Pane.t
  ; status : Pane.t option
  ; reserve_status_row : bool
  }
[@@deriving sexp_of, equal]

let min_document_width = 16
let min_document_height = 1
let min_status_width = 8
let min_status_height = 3

let allocate (prefs : Prefs.t) ~(allocation : Geometry.Rect.t) =
  let allocation =
    { allocation with
      width = Int.max 0 allocation.width
    ; height = Int.max 0 allocation.height
    }
  in
  let fits =
    match prefs.split.axis with
    | Horizontal ->
      allocation.width >= min_document_width + min_status_width
      && allocation.height >= Int.max min_document_height min_status_height
    | Vertical ->
      allocation.width >= Int.max min_document_width min_status_width
      && allocation.height >= min_document_height + min_status_height
  in
  if not prefs.status_visible || not fits
  then
    { document = { id = Document; rect = allocation }
    ; status = None
    ; reserve_status_row = true
    }
  else (
    let horizontal = Split.Axis.equal prefs.split.axis Horizontal in
    let available, status_min, document_min =
      if horizontal
      then allocation.width, min_status_width, min_document_width
      else allocation.height, min_status_height, min_document_height
    in
    let status_size =
      Int.clamp_exn prefs.split.status_size ~min:status_min ~max:(available - document_min)
    in
    let document_size = available - status_size in
    let status_first = Pane_id.equal prefs.split.first Status in
    let document_start = if status_first then status_size else 0 in
    let status_start = if status_first then 0 else document_size in
    let rect start size =
      if horizontal
      then { allocation with x = allocation.x + start; width = size }
      else { allocation with y = allocation.y + start; height = size }
    in
    { document = { id = Document; rect = rect document_start document_size }
    ; status = Some { id = Status; rect = rect status_start status_size }
    ; reserve_status_row = false
    })
;;

let document_geometry t prefs ~line_count =
  Geometry.compute_in prefs
    ~allocation:t.document.rect
    ~reserve_status_row:t.reserve_status_row
    ~line_count
;;
