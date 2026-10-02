open! Core

module Rect = struct
  type t =
    { x : int
    ; y : int
    ; width : int
    ; height : int
    }
  [@@deriving sexp_of, equal]
end

module Prefs = struct
  type t =
    { centered : bool
    ; width : int
    ; offset : int
    ; line_numbers : Line_numbers.t
    }
  [@@deriving sexp_of, equal]

  let default = { centered = true; width = 100; offset = 0; line_numbers = Hybrid }
end

let min_decorated_text_width = 16

module Area = struct
  type layout =
    | Status_row
    | Border_title
  [@@deriving sexp_of, equal]

  type t =
    { rect : Rect.t
    ; layout : layout
    ; fields : Status_field.Id.t list
    }
  [@@deriving sexp_of]
end

(* The border also needs this many text rows. *)
let min_bordered_text_height = 3

type t =
  { tile : Rect.t
  ; border : bool
  ; gutter : Rect.t
  ; gutter_digits : int
  ; text : Rect.t
  ; status : Rect.t
  ; offset : int
  ; areas : Area.t list
  }
[@@deriving sexp_of]

let gutter_digits ~line_count = Int.max 3 (String.length (Int.to_string line_count))

let compute (prefs : Prefs.t) ~width ~height ~line_count =
  let width = Int.max 0 width
  and height = Int.max 0 height in
  let status_height = Int.min 1 height in
  let tile_height = height - status_height in
  let gutter_digits = gutter_digits ~line_count in
  let full_gutter_width =
    match prefs.line_numbers with
    | Off -> 0
    | Absolute | Relative | Hybrid -> gutter_digits + 1
  in
  let border =
    tile_height >= min_bordered_text_height + 2
    && width >= 2 + full_gutter_width + min_decorated_text_width
  in
  let border_width = if border then 1 else 0 in
  let gutter_width =
    if width - (2 * border_width) >= full_gutter_width + min_decorated_text_width
    then full_gutter_width
    else 0
  in
  let overhead = (2 * border_width) + gutter_width in
  let text_width =
    let available = Int.max 0 (width - overhead) in
    if prefs.centered then Int.min available (Int.max 0 prefs.width) else available
  in
  let tile_width = text_width + overhead in
  let centered_x = (width - tile_width) / 2 in
  let tile_x =
    if prefs.centered
    then Int.clamp_exn (centered_x + prefs.offset) ~min:0 ~max:(width - tile_width)
    else 0
  in
  let inner_y = border_width in
  let inner_height = Int.max 0 (tile_height - (2 * border_width)) in
  let gutter =
    { Rect.x = tile_x + border_width
    ; y = inner_y
    ; width = gutter_width
    ; height = inner_height
    }
  in
  let tile = { Rect.x = tile_x; y = 0; width = tile_width; height = tile_height } in
  let status = { Rect.x = 0; y = tile_height; width; height = status_height } in
  let areas =
    let status_area =
      { Area.rect = status
      ; layout = Status_row
      ; fields = [ Mode; Filename; Dirty; Message; Pending; Position ]
      }
    in
    let title_area =
      { Area.rect = { tile with x = tile.x + 1; width = tile.width - 2; height = 1 }
      ; layout = Border_title
      ; fields = [ Filename ]
      }
    in
    List.filter_opt
      [ Option.some_if border title_area
      ; Option.some_if (status_height > 0) status_area
      ]
  in
  { tile
  ; border
  ; gutter
  ; gutter_digits
  ; text =
      { x = gutter.x + gutter_width
      ; y = inner_y
      ; width = text_width
      ; height = inner_height
      }
  ; status
  ; offset = (if prefs.centered then tile_x - centered_x else 0)
  ; areas
  }
;;
