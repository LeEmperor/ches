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
    }
  [@@deriving sexp_of, equal]

  let default = { centered = true; width = 100; offset = 0 }
end

let min_decorated_text_width = 16

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
  }
[@@deriving sexp_of]

let gutter_digits ~line_count = Int.max 3 (String.length (Int.to_string line_count))

let compute (prefs : Prefs.t) ~width ~height ~line_count =
  let width = Int.max 0 width
  and height = Int.max 0 height in
  let status_height = Int.min 1 height in
  let tile_height = height - status_height in
  let gutter_digits = gutter_digits ~line_count in
  let full_gutter_width = gutter_digits + 1 in
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
  { tile = { x = tile_x; y = 0; width = tile_width; height = tile_height }
  ; border
  ; gutter
  ; gutter_digits
  ; text =
      { x = gutter.x + gutter_width
      ; y = inner_y
      ; width = text_width
      ; height = inner_height
      }
  ; status = { x = 0; y = tile_height; width; height = status_height }
  ; offset = (if prefs.centered then tile_x - centered_x else 0)
  }
;;
