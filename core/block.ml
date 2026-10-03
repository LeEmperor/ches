open! Core
module B = Text_buffer

type t =
  { first_line : int
  ; last_line : int
  ; left : int
  ; right : int option
  }
[@@deriving sexp_of, equal]

let glyphs text ~cell_width line = Cell_layout.glyphs ~width:cell_width (B.line_text text line)

(* The cells [(first, stop)] of a corner at [offset]. *)
let corner text ~cell_width offset =
  let line = B.line_of_offset text offset in
  let first, width =
    Cell_layout.cursor_span
      (glyphs text ~cell_width line)
      ~pos:(offset - B.line_start text line)
      ~insertion:false
  in
  line, first, first + width
;;

let of_corners text ~cell_width ~anchor ~active ~to_line_end =
  let anchor_line, anchor_first, anchor_stop = corner text ~cell_width anchor in
  let active_line, active_first, active_stop = corner text ~cell_width active in
  { first_line = Int.min anchor_line active_line
  ; last_line = Int.max anchor_line active_line
  ; left = Int.min anchor_first active_first
  ; right = (if to_line_end then None else Some (Int.max anchor_stop active_stop))
  }
;;

module Row = struct
  type t =
    { line : int
    ; start : int
    ; stop : int
    ; before : int
    ; after : int
    }
  [@@deriving sexp_of, equal]
end

let columns t glyphs =
  match t.right with
  | Some right -> t.left, right
  | None -> t.left, Int.max t.left (Cell_layout.total_width glyphs)
;;

let row text ~cell_width t line : Row.t =
  let glyphs = glyphs text ~cell_width line in
  let line_start = B.line_start text line in
  let left, stop = columns t glyphs in
  let n = Array.length glyphs in
  (* Indices of the glyphs in the block: those with a cell in [left, stop), each
     followed by its zero-width marks. A mark at the very start of a line has no base
     and goes with column 0. *)
  let inside i =
    let ({ col; width; _ } : Cell_layout.Glyph.t) = glyphs.(i) in
    if width > 0 then col < stop && col + width > left else i = 0 && left = 0 && stop > 0
  in
  match Array.findi glyphs ~f:(fun i _ -> inside i) with
  | None ->
    let line_end = B.line_end text line in
    { line; start = line_end; stop = line_end; before = 0; after = 0 }
  | Some (first, first_glyph) ->
    let rec last i =
      if i + 1 < n && (inside (i + 1) || glyphs.(i + 1).width = 0) then last (i + 1) else i
    in
    let last = last first in
    (* The last glyph with cells, for [after]. *)
    let rec base i = if i > first && glyphs.(i).width = 0 then base (i - 1) else glyphs.(i) in
    let base = base last in
    { line
    ; start = line_start + first_glyph.pos
    ; stop =
        (if last + 1 < n then line_start + glyphs.(last + 1).pos else B.line_end text line)
    ; before = Int.max 0 (left - first_glyph.col)
    ; after = Int.max 0 (base.col + base.width - stop)
    }
;;

let rows text ~cell_width t =
  List.init (t.last_line - t.first_line + 1) ~f:(fun i -> row text ~cell_width t (t.last_line - i))
;;
