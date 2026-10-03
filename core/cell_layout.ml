open! Core

module Width = struct
  type t = Uchar.t -> int
end

let tab_stop = 8

module Kind = struct
  type t =
    | Plain
    | Tab
    | Escape
  [@@deriving sexp_of, equal]
end

module Glyph = struct
  type t =
    { pos : int
    ; col : int
    ; width : int
    ; text : string
    ; kind : Kind.t
    }
  [@@deriving sexp_of]
end

let is_bidi_control = function
  | 0x061C | 0x200E | 0x200F | 0xFEFF -> true
  | c -> (c >= 0x202A && c <= 0x202E) || (c >= 0x2066 && c <= 0x2069)
;;

(* Text, kind, and width of the code point [u] starting in cell [col]. *)
let render ~width:cell_width u ~col : string * Kind.t * int =
  let escape text = text, Kind.Escape, String.length text in
  match Uchar.to_scalar u with
  | 0x09 ->
    let width = tab_stop - (col % tab_stop) in
    String.make width ' ', Tab, width
  | c when c < 0x20 -> escape (sprintf "^%c" (Char.of_int_exn (c + 0x40)))
  | 0x7F -> escape "^?"
  | c when c >= 0x80 && c <= 0x9F -> escape (sprintf "<%x>" c)
  | c when is_bidi_control c -> escape (sprintf "<%x>" c)
  | c ->
    let width = cell_width u in
    if width < 0
    then escape (sprintf "<%x>" c)
    else Uchar.Utf8.to_string u, Plain, width
;;

let glyphs ~width:cell_width s =
  let result = Queue.create () in
  let rec loop pos col =
    if pos < String.length s
    then (
      let decode = Stdlib.String.get_utf_8_uchar s pos in
      let length = Stdlib.Uchar.utf_decode_length decode in
      let text, kind, width =
        if Stdlib.Uchar.utf_decode_is_valid decode
        then render ~width:cell_width (Stdlib.Uchar.utf_decode_uchar decode) ~col
        else (
          (* An invalid sequence: show each of its bytes. *)
          let text =
            String.concat_map (String.sub s ~pos ~len:length) ~f:(fun c ->
              sprintf "\\x%02x" (Char.to_int c))
          in
          text, Escape, String.length text)
      in
      Queue.enqueue result { Glyph.pos; col; width; text; kind };
      loop (pos + length) (col + width))
  in
  loop 0 0;
  Queue.to_array result
;;

let total_width glyphs =
  match Array.last_exn glyphs with
  | exception _ -> 0
  | (last : Glyph.t) -> last.col + last.width
;;

let cursor_span glyphs ~pos ~insertion =
  match
    Array.binary_search glyphs `First_equal_to pos ~compare:(fun (g : Glyph.t) pos ->
      Int.compare g.pos pos)
  with
  | None -> total_width glyphs, 1
  | Some i ->
    let glyph = glyphs.(i) in
    if glyph.width > 0
    then glyph.col, if insertion then 1 else glyph.width
    else (
      let rec preceding j =
        if j < 0
        then 0
        else if glyphs.(j).width > 0
        then glyphs.(j).col
        else preceding (j - 1)
      in
      preceding (i - 1), 1)
;;

let column glyphs ~pos ~tab_end =
  match
    Array.binary_search glyphs `First_equal_to pos ~compare:(fun (g : Glyph.t) pos ->
      Int.compare g.pos pos)
  with
  | Some i when tab_end && Kind.equal glyphs.(i).kind Tab ->
    glyphs.(i).col + glyphs.(i).width - 1
  | _ -> fst (cursor_span glyphs ~pos ~insertion:false)
;;

let pos_of_column glyphs col =
  (* The last nonzero-width glyph starting at or before [col]. *)
  match
    Array.binary_search glyphs `Last_less_than_or_equal_to col ~compare:(fun (g : Glyph.t) col ->
      Int.compare g.col col)
  with
  | None -> None
  | Some i ->
    let rec covering j =
      if j < 0
      then None
      else (
        let glyph = glyphs.(j) in
        if glyph.width = 0
        then covering (j - 1)
        else Option.some_if (col < glyph.col + glyph.width) glyph.pos)
    in
    covering i
;;
