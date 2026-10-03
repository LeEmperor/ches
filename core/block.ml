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

(* The bytes of glyph [i] in [line]. *)
let glyph_bytes line glyphs i =
  let pos = glyphs.(i).Cell_layout.Glyph.pos in
  let stop = if i + 1 < Array.length glyphs then glyphs.(i + 1).pos else String.length line in
  String.sub line ~pos ~len:(stop - pos)
;;

let width text ~cell_width t =
  match t.right with
  | Some right -> right - t.left
  | None ->
    List.range t.first_line t.last_line ~stop:`inclusive
    |> List.fold ~init:0 ~f:(fun width line ->
      let left, stop = columns t (glyphs text ~cell_width line) in
      Int.max width (stop - left))
;;

let row_text text ~cell_width t ~width (row : Row.t) =
  let line = B.line_text text row.line in
  let glyphs = Cell_layout.glyphs ~width:cell_width line in
  let left, stop = columns t glyphs in
  if Cell_layout.total_width glyphs < t.left
  then String.make width ' '
  else (
    let line_start = B.line_start text row.line in
    let buffer = Buffer.create (row.stop - row.start + row.before + row.after) in
    (* A glyph cut by an edge becomes spaces for its cells inside the block, and takes
       its zero-width marks with it. *)
    let cut = ref false in
    Array.iteri glyphs ~f:(fun i (glyph : Cell_layout.Glyph.t) ->
      let pos = line_start + glyph.pos in
      if pos >= row.start && pos < row.stop
      then
        if glyph.width > 0 && (glyph.col < left || glyph.col + glyph.width > stop)
        then (
          cut := true;
          let inside = Int.min (glyph.col + glyph.width) stop - Int.max glyph.col left in
          Buffer.add_string buffer (String.make inside ' '))
        else if glyph.width > 0 || not !cut
        then (
          cut := false;
          Buffer.add_string buffer (glyph_bytes line glyphs i)));
    Buffer.contents buffer)
;;

let contents text ~cell_width t =
  let width = width text ~cell_width t in
  List.rev_map (rows text ~cell_width t) ~f:(row_text text ~cell_width t ~width), width
;;

module Insertion = struct
  type t =
    { pos : int
    ; remove : int
    ; pad_before : int
    ; pad_after : int
    ; at_end : bool
    }
  [@@deriving sexp_of, equal]
end

let insertion text ~cell_width ~line ~col : Insertion.t =
  let glyphs = glyphs text ~cell_width line in
  let line_start = B.line_start text line in
  let line_end = B.line_end text line in
  let total = Cell_layout.total_width glyphs in
  let at ?(remove = 0) ?(pad_before = 0) ?(pad_after = 0) pos =
    { Insertion.pos
    ; remove
    ; pad_before
    ; pad_after
    ; at_end = pos = line_end && remove = 0
    }
  in
  if col >= total
  then at line_end ~pad_before:(col - total)
  else (
    match
      Array.find glyphs ~f:(fun glyph ->
        glyph.width > 0 && glyph.col < col && col < glyph.col + glyph.width)
    with
    | Some ({ kind = Tab; _ } as glyph) ->
      at
        (line_start + glyph.pos)
        ~remove:1
        ~pad_before:(col - glyph.col)
        ~pad_after:(glyph.col + glyph.width - col)
    | Some glyph -> at (line_start + glyph.pos) ~pad_before:(col - glyph.col)
    | None ->
      (* Zero-width marks stay after their base, except at the very start of a line. *)
      (match
         Array.findi glyphs ~f:(fun i glyph -> glyph.col >= col && (glyph.width > 0 || i = 0))
       with
       | Some (_, glyph) -> at (line_start + glyph.pos)
       | None -> at line_end))
;;
