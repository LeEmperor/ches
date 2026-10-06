open! Core

module Pane_id = struct
  type t =
    | Document
    | Status
    | Minor of Ches_tile.View_id.t
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
end

type t =
  { document : Pane.t
  ; status : Pane.t option
  ; minors : Pane.t list
  ; gaps : Geometry.Rect.t list
  ; reserve_status_row : bool
  }
[@@deriving sexp_of, equal]

let min_document_width = 16
let min_document_height = 1
let min_status_width = 8
let min_status_height = 3
let min_minor_width = 16
let gap = 1
let min_band_height = 3
let preferred_band_height = 10

let allocate_pair (prefs : Prefs.t) ~(allocation : Geometry.Rect.t) =
  let allocation =
    { allocation with
      width = Int.max 0 allocation.width
    ; height = Int.max 0 allocation.height
    }
  in
  let fits =
    match prefs.split.axis with
    | Horizontal ->
      allocation.width >= min_document_width + gap + min_status_width
      && allocation.height >= Int.max min_document_height min_status_height
    | Vertical ->
      allocation.width >= Int.max min_document_width min_status_width
      && allocation.height >= min_document_height + min_status_height
  in
  if not prefs.status_visible || not fits
  then
    { document = { id = Document; rect = allocation }
    ; status = None
    ; minors = []
    ; gaps = []
    ; reserve_status_row = true
    }
  else (
    let horizontal = Split.Axis.equal prefs.split.axis Horizontal in
    (* Side-by-side tiles are separated by a backdrop gap; stacked frames already are
       by their own border rows. *)
    let available, status_min, document_min, gap =
      if horizontal
      then allocation.width - gap, min_status_width, min_document_width, gap
      else allocation.height, min_status_height, min_document_height, 0
    in
    let status_size =
      Int.clamp_exn prefs.split.status_size ~min:status_min ~max:(available - document_min)
    in
    let document_size = available - status_size in
    let status_first = Pane_id.equal prefs.split.first Status in
    let document_start = if status_first then status_size + gap else 0 in
    let status_start = if status_first then 0 else document_size + gap in
    let rect start size =
      if horizontal
      then { allocation with x = allocation.x + start; width = size }
      else { allocation with y = allocation.y + start; height = size }
    in
    { document = { id = Document; rect = rect document_start document_size }
    ; status = Some { id = Status; rect = rect status_start status_size }
    ; minors = []
    ; gaps =
        (if gap = 0
         then []
         else [ rect (if status_first then status_size else document_size) gap ])
    ; reserve_status_row = false
    })
;;

let allocate ?(minors = []) prefs ~(allocation : Geometry.Rect.t) =
  let allocation =
    { allocation with width = Int.max 0 allocation.width; height = Int.max 0 allocation.height }
  in
  let original = allocate_pair prefs ~allocation in
  (* Document/status minima take precedence over the band. *)
  let minimum =
    match original.status, prefs.split.axis with
    | Some _, Split.Axis.Vertical -> min_document_height + min_status_height
    | Some _, Horizontal -> min_status_height
    | None, _ -> 2
  in
  let minors = List.take minors ((allocation.width + gap) / (min_minor_width + gap)) in
  if List.is_empty minors || allocation.width < min_document_width
     || allocation.height < minimum + min_band_height
  then original
  else (
    (* The band keeps the upper workspace at least two thirds of the height. *)
    let size =
      Int.min
        (Int.min preferred_band_height (allocation.height - minimum))
        (Int.max min_band_height (allocation.height / 3))
    in
    let upper = { allocation with height = allocation.height - size } in
    let workspace = allocate_pair prefs ~allocation:upper in
    let count = List.length minors in
    let shared = allocation.width - ((count - 1) * gap) in
    let start i = (shared * i / count) + (i * gap) in
    let minors =
      List.mapi minors ~f:(fun i id ->
        { Pane.id = Minor id
        ; rect =
            { Geometry.Rect.x = allocation.x + start i
            ; y = allocation.y + upper.height
            ; width = (shared * (i + 1) / count) - (shared * i / count)
            ; height = size
            }
        })
    in
    let gaps =
      List.init (count - 1) ~f:(fun i ->
        { Geometry.Rect.x = allocation.x + start (i + 1) - gap
        ; y = allocation.y + upper.height
        ; width = gap
        ; height = size
        })
    in
    { workspace with minors; gaps = workspace.gaps @ gaps })
;;

let minor t id =
  List.find t.minors ~f:(fun pane -> Pane_id.equal pane.id (Minor id))
;;

let document_geometry t prefs ~line_count =
  Geometry.compute_in prefs
    ~allocation:t.document.rect
    ~reserve_status_row:t.reserve_status_row
    ~line_count
;;
