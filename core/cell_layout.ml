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

(* A sparse, lazily extended index over a valid document line. No glyph strings
   are allocated during seeking. Checkpoints retain the preceding visible column
   so a combining sequence crossing a checkpoint has the same cursor semantics. *)
module Index = struct
  type checkpoint = { pos : int; col : int; preceding : int; scalar : int }
  type t =
    { source : string
    ; start : int
    ; stop : int
    ; width : Width.t
    ; stride : int
    ; checkpoints : checkpoint array
    ; mutable count : int
    ; mutable frontier : checkpoint
    ; mutable steps : int
    }

  let create ~width source ~start ~stop =
    let origin = { pos = 0; col = 0; preceding = 0; scalar = 0 } in
    { source; start; stop; width
    ; stride = Int.max 256 ((stop - start + 254) / 255)
    ; checkpoints = Array.create ~len:256 origin
    ; count = 1; frontier = origin; steps = 0 }
  ;;

  let length t = t.stop - t.start
  let steps t = t.steps
  let checkpoint_count t = t.count

  let decode t p =
    let d = Stdlib.String.get_utf_8_uchar t.source (t.start + p.pos) in
    let u = Stdlib.Uchar.utf_decode_uchar d in
    let c = Uchar.to_scalar u in
    let width =
      if c = 9 then tab_stop - p.col % tab_stop
      else if c < 32 || c = 127 then 2
      else if (c >= 128 && c <= 159) || is_bidi_control c
      then String.length (sprintf "<%x>" c)
      else let w = t.width u in
        if w < 0 then String.length (sprintf "<%x>" c) else w
    in
    t.steps <- t.steps + 1;
    u, Stdlib.Uchar.utf_decode_length d, width
  ;;

  let advance t p len width =
    let next = { pos = p.pos + len; col = p.col + width; scalar = p.scalar + 1
               ; preceding = if width > 0 then p.col else p.preceding } in
    if next.pos > t.frontier.pos then (
      t.frontier <- next;
      if next.pos - t.checkpoints.(t.count - 1).pos >= t.stride && t.count < 256
      then (t.checkpoints.(t.count) <- next; t.count <- t.count + 1));
    next
  ;;

  let seek t ~before =
    let rec search lo hi =
      if lo = hi then lo else
      let mid = (lo + hi + 1) / 2 in
      if before t.checkpoints.(mid) then search mid hi else search lo (mid - 1)
    in
    if before t.frontier then t.frontier
    else t.checkpoints.(search 0 (t.count - 1))
  ;;

  let at_pos t pos =
    let rec loop p =
      if p.pos >= pos || p.pos >= length t then p
      else let _, len, width = decode t p in loop (advance t p len width)
    in
    loop (seek t ~before:(fun p -> p.pos <= pos))
  ;;

  let cursor_span t ~pos ~insertion =
    let p = at_pos t pos in
    if p.pos >= length t then p.col, 1
    else let _, _, width = decode t p in
      if width = 0 then p.preceding, 1
      else p.col, if insertion then 1 else width
  ;;

  let column t ~pos ~tab_end =
    let p = at_pos t pos in
    if p.pos >= length t then p.col
    else let u, _, width = decode t p in
      if tab_end && Uchar.to_scalar u = 9 then p.col + width - 1
      else if width = 0 then p.preceding else p.col
  ;;

  let total_width t = (at_pos t (length t)).col

  let scalar_column t ~pos = (at_pos t pos).scalar

  let pos_of_scalar_column t column =
    let rec loop p =
      if p.scalar >= column || p.pos >= length t then p.pos
      else let _, len, width = decode t p in loop (advance t p len width)
    in
    loop (seek t ~before:(fun p -> p.scalar <= column))
  ;;

  let pos_of_column t col =
    let rec loop p =
      if p.pos >= length t then None
      else let _, len, width = decode t p in
        if width > 0 && p.col <= col && col < p.col + width then Some p.pos
        else loop (advance t p len width)
    in
    if col < 0 then None
    else loop (seek t ~before:(fun p -> p.col <= col))
  ;;

  let window t ~left ~cols =
    let result = Queue.create () in
    let right = left + cols in
    let rec loop p =
      if p.pos < length t then (
        let u, len, width = decode t p in
        (* Include trailing combining marks, but stop before the next base. *)
        if p.col < right || width = 0 then (
          if p.col + width > left || (width = 0 && p.col >= left) then (
            let text, kind, _ = render ~width:t.width u ~col:p.col in
            Queue.enqueue result { Glyph.pos = p.pos; col = p.col; width; text; kind });
          loop (advance t p len width)))
    in
    if cols > 0 then loop (seek t ~before:(fun p -> p.col <= left));
    Queue.to_array result
  ;;
end
