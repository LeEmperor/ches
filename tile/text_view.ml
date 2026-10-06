open! Core
open Ches_input
module Cell_layout = Ches_core.Cell_layout
module Glyph = Cell_layout.Glyph
module Register = Ches_core.Register

module Kind = struct
  type t =
    | Characterwise
    | Linewise
  [@@deriving sexp_of, equal]
end

module Motion = struct
  type t =
    | Left
    | Right
    | Down
    | Up
    | Line_start
    | First_nonblank
    | Line_end
    | Word_forward
    | Word_backward
    | Half_down
    | Half_up
    | First
    | Last
  [@@deriving sexp_of, equal]
end

module Action = struct
  type t =
    | Move of Motion.t
    | Visual of Kind.t
    | Swap_ends
    | Yank
    | Yank_line
    | Exit_visual
    | Edit
  [@@deriving sexp_of, equal]
end

module Effect = struct
  type t =
    | Copy of Register.t
    | Notice of string
  [@@deriving sexp_of, equal]

  let plural n word = sprintf "Copied %d %s%s" n word (if n = 1 then "" else "s")

  (* Code points, counting each byte that does not continue a UTF-8 sequence. *)
  let characters s =
    String.count s ~f:(fun c -> Char.to_int c land 0xC0 <> 0x80)
  ;;

  let describe_copy : Register.t -> string = function
    | Text { text; kind = Characterwise } -> plural (characters text) "character"
    | Text { text; kind = Linewise } -> plural (String.count text ~f:(Char.equal '\n')) "line"
    | Block { rows; width = _ } -> plural (List.length rows) "line"
  ;;
end

module Line = struct
  type t =
    { start : int
    ; length : int
    ; glyphs : Glyph.t array (** [pos] relative to [start]. *)
    }
  [@@deriving sexp_of]

  (* Cursor positions: glyphs with cells, or the line start when there are none. *)
  let positions t =
    match
      Array.filter_map t.glyphs ~f:(fun (g : Glyph.t) ->
        Option.some_if (g.width > 0) (t.start + g.pos))
    with
    | [||] -> [| t.start |]
    | positions -> positions
  ;;

  let glyph_at t offset =
    Array.find t.glyphs ~f:(fun (g : Glyph.t) -> t.start + g.pos = offset && g.width > 0)
  ;;

  let is_blank (g : Glyph.t) =
    match g.kind with
    | Tab -> true
    | Escape -> false
    | Plain -> String.equal g.text " "
  ;;
end

module Row = struct
  type t =
    { line_start : int
    ; glyphs : Glyph.t array
    ; first_col : int
    ; break : int option
    }
  [@@deriving sexp_of]
end

type t =
  { text : string
  ; lines : Line.t array
  ; cell_width : (Cell_layout.Width.t[@sexp.opaque])
  ; cursor : int
  ; visual : (Kind.t * int) option (** Kind and anchor. *)
  ; want : int option (** Preferred display column within a row. *)
  ; top : int
  }
[@@deriving sexp_of]

let split ~cell_width text =
  let lines = String.split text ~on:'\n' in
  let _, lines =
    List.fold_map lines ~init:0 ~f:(fun start line ->
      ( start + String.length line + 1
      , { Line.start
        ; length = String.length line
        ; glyphs = Cell_layout.glyphs ~width:cell_width line
        } ))
  in
  Array.of_list lines
;;

let create ~cell_width text =
  { text
  ; lines = split ~cell_width text
  ; cell_width
  ; cursor = 0
  ; visual = None
  ; want = None
  ; top = 0
  }
;;

let text t = t.text
let cursor t = t.cursor
let visual t = Option.map t.visual ~f:fst
let top t = t.top
let read_only = "read-only; edits unavailable"
let last_line t = Array.length t.lines - 1

let line_index t offset =
  let rec go i = if i > 0 && t.lines.(i).start > offset then go (i - 1) else i in
  go (last_line t)
;;

let line_of t offset = t.lines.(line_index t offset)

(* {1 Layout} *)

let rows_of_line t i (line : Line.t) ~width =
  let break =
    Option.some_if (i < last_line t) (line.start + line.length)
  in
  let row glyphs ~last =
    let glyphs = Array.of_list_rev glyphs in
    { Row.line_start = line.start
    ; glyphs
    ; first_col = (if Array.is_empty glyphs then 0 else glyphs.(0).col)
    ; break = (if last then break else None)
    }
  in
  let rows, current, _ =
    Array.fold line.glyphs ~init:([], [], 0) ~f:(fun (rows, current, used) glyph ->
      if used > 0 && used + glyph.width > width
      then row current ~last:false :: rows, [ glyph ], glyph.width
      else rows, glyph :: current, used + glyph.width)
  in
  List.rev (row current ~last:true :: rows)
;;

let layout t ~width =
  let width = Int.max 1 width in
  Array.of_list (List.concat_mapi (Array.to_list t.lines) ~f:(fun i line ->
    rows_of_line t i line ~width))
;;

let rows t ~width = Array.to_list (layout t ~width)

(* The row holding [offset]: the last row of its line starting at or before it. *)
let row_index rows offset ~line_start =
  Array.foldi rows ~init:None ~f:(fun i found (row : Row.t) ->
    if row.line_start <> line_start
    then found
    else (
      match found, row.glyphs with
      | None, _ -> Some i
      | Some _, [||] -> found
      | Some _, glyphs -> if line_start + glyphs.(0).pos <= offset then Some i else found))
  |> Option.value ~default:0
;;

let cursor_row t rows = row_index rows t.cursor ~line_start:(line_of t t.cursor).start

let column_in (row : Row.t) offset =
  Array.find row.glyphs ~f:(fun g -> row.line_start + g.pos = offset)
  |> Option.value_map ~default:0 ~f:(fun (g : Glyph.t) -> g.col - row.first_col)
;;

(* The position in [row] covering display column [col], or its last one. *)
let position_in t (row : Row.t) col =
  let glyphs = Array.filter row.glyphs ~f:(fun (g : Glyph.t) -> g.width > 0) in
  match
    Array.find glyphs ~f:(fun g ->
      let c = g.col - row.first_col in
      c <= col && col < c + g.width)
  with
  | Some g -> row.line_start + g.pos
  | None ->
    if Array.is_empty glyphs
    then (Line.positions (line_of t row.line_start)).(0)
    else row.line_start + (Array.last_exn glyphs).pos
;;

(* The nearest cursor position at or before [offset] on its line. *)
let valid t offset =
  let offset = Int.clamp_exn offset ~min:0 ~max:(String.length t.text) in
  let positions = Line.positions (line_of t offset) in
  Array.fold positions ~init:positions.(0) ~f:(fun best p -> if p <= offset then p else best)
;;

let fit t ~width ~rows:viewport =
  let rows = layout t ~width in
  let t = { t with cursor = valid t t.cursor } in
  let viewport = Int.max 1 viewport in
  let r = cursor_row t rows in
  let top = Int.clamp_exn t.top ~min:0 ~max:(Int.max 0 (Array.length rows - viewport)) in
  let top =
    if r < top then r else if r >= top + viewport then r - viewport + 1 else top
  in
  { t with top }
;;

let cursor_cell t ~width =
  let rows = layout t ~width in
  let r = cursor_row t rows in
  r, column_in rows.(r) t.cursor
;;

(* {1 Words} *)

type token =
  | Glyph of int * [ `Identifier | `Punctuation | `Blank ]
  | Empty of int
  | Break

let tokens t =
  Array.to_list t.lines
  |> List.mapi ~f:(fun i (line : Line.t) ->
    let glyphs =
      Array.to_list line.glyphs
      |> List.filter_map ~f:(fun (g : Glyph.t) ->
        if g.width = 0
        then None
        else (
          let cls =
            if Line.is_blank g
            then `Blank
            else (
              match g.kind with
              | Escape | Tab -> `Punctuation
              | Plain ->
                let c = g.text.[0] in
                if Char.to_int c >= 0x80 || Char.is_alphanum c || Char.equal c '_'
                then `Identifier
                else `Punctuation)
          in
          Some (Glyph (line.start + g.pos, cls))))
    in
    (if List.is_empty glyphs then [ Empty line.start ] else glyphs)
    @ if i < last_line t then [ Break ] else [])
  |> List.concat
  |> Array.of_list
;;

let word t ~forward =
  let tokens = tokens t in
  let n = Array.length tokens in
  let offset = function
    | Glyph (o, _) | Empty o -> Some o
    | Break -> None
  in
  let blank i =
    match tokens.(i) with
    | Break | Glyph (_, `Blank) -> true
    | Glyph _ | Empty _ -> false
  in
  let cls i =
    match tokens.(i) with
    | Glyph (_, c) -> Some c
    | Empty _ | Break -> None
  in
  let i =
    Array.findi tokens ~f:(fun _ token -> [%equal: int option] (offset token) (Some t.cursor))
    |> Option.value_map ~default:0 ~f:fst
  in
  let ends = if forward then n - 1 else 0 in
  let at j = Option.value_exn (offset tokens.(j)) in
  if forward
  then (
    let j = ref (i + 1) in
    (match cls i with
     | Some c when not (blank i) ->
       while !j < n && [%equal: [ `Identifier | `Punctuation | `Blank ] option] (cls !j) (Some c) do
         incr j
       done
     | Some _ | None -> ());
    while !j < n && blank !j do
      incr j
    done;
    if !j < n then at !j else at ends)
  else (
    let j = ref (i - 1) in
    while !j >= 0 && blank !j do
      decr j
    done;
    if !j < 0
    then at ends
    else (
      match cls !j with
      | None -> at !j
      | Some c ->
        while !j > 0
              && [%equal: [ `Identifier | `Punctuation | `Blank ] option] (cls (!j - 1)) (Some c)
        do
          decr j
        done;
        at !j))
;;

(* {1 Selection} *)

let line_stop t i =
  let line = t.lines.(i) in
  line.start + line.length + if i < last_line t then 1 else 0
;;

(* Just past the glyph at [offset] and its combining marks, or past the line break of
   an empty line. *)
let glyph_stop t offset =
  let i = line_index t offset in
  let line = t.lines.(i) in
  match Line.glyph_at line offset with
  | None -> line_stop t i
  | Some _ ->
    let after =
      Array.find line.glyphs ~f:(fun g -> line.start + g.pos > offset && g.width > 0)
    in
    Option.value_map after ~default:(line.start + line.length) ~f:(fun g -> line.start + g.pos)
;;

let selection t =
  Option.map t.visual ~f:(fun (kind, anchor) ->
    let lo = Int.min anchor t.cursor
    and hi = Int.max anchor t.cursor in
    match kind with
    | Characterwise -> lo, glyph_stop t hi
    | Linewise -> (line_of t lo).start, line_stop t (line_index t hi))
;;

let linewise text =
  Register.Text
    { text = (if String.is_suffix text ~suffix:"\n" then text else text ^ "\n")
    ; kind = Linewise
    }
;;

let copy_item text : Effect.t =
  if String.is_empty text then Notice "nothing to copy" else Copy (linewise text)
;;

let yank t =
  match t.visual, selection t with
  | Some (kind, _), Some (start, stop) ->
    let text = String.sub t.text ~pos:start ~len:(stop - start) in
    let register : Register.t =
      match kind with
      | Characterwise -> Text { text; kind = Characterwise }
      | Linewise -> linewise text
    in
    let effect : Effect.t =
      if String.is_empty text then Notice "nothing to copy" else Copy register
    in
    let anchor = Option.value_map t.visual ~default:t.cursor ~f:snd in
    ( { t with visual = None; cursor = Int.min anchor t.cursor; want = None }
    , Some effect )
  | _ -> t, None
;;

(* {1 Keys} *)

let edit_keys = "iIaAoOxXdDcCsSrRpPuUJ~<>."

let is_edit = function
  | [ Key.Ctrl 'r' ] -> true
  | [ Key.Char c ] ->
    Uchar.is_char c && String.mem edit_keys (Uchar.to_char_exn c)
  | _ -> false
;;

let interpret t (keys : Key.t list) : Action.t Content_key.t =
  let visual = Option.is_some t.visual in
  let is c = function
    | Key.Char u -> Uchar.is_char u && Char.equal (Uchar.to_char_exn u) c
    | _ -> false
  in
  match keys with
  | [ key ] when is 'h' key -> Action (Move Left)
  | [ key ] when is 'l' key -> Action (Move Right)
  | [ key ] when is '0' key -> Action (Move Line_start)
  | [ key ] when is '^' key -> Action (Move First_nonblank)
  | [ key ] when is '$' key -> Action (Move Line_end)
  | [ key ] when is 'w' key -> Action (Move Word_forward)
  | [ key ] when is 'b' key -> Action (Move Word_backward)
  | [ key ] when is 'v' key -> Action (Visual Characterwise)
  | [ key ] when is 'V' key -> Action (Visual Linewise)
  | [ key ] when is 'o' key && visual -> Action Swap_ends
  | [ key ] when is 'y' key -> if visual then Action Yank else Prefix
  | [ key ] when is 'Y' key -> Action (if visual then Yank else Yank_line)
  | [ y; key ] when is 'y' y && is 'y' key -> Action Yank_line
  | keys when is_edit keys -> Action Edit
  | keys ->
    Content_key.map (Navigation.interpret keys) ~f:(fun (motion : Navigation.Motion.t) ->
      Action.Move
        (match motion with
         | Down -> Down
         | Up -> Up
         | Half_down -> Half_down
         | Half_up -> Half_up
         | First -> First
         | Last -> Last))
;;

let escape t = Option.map t.visual ~f:(fun _ -> Action.Exit_visual)

let interpret_item (keys : Key.t list) : [ `Copy | `Edit ] Content_key.t =
  match keys with
  | [ key ] when Key.equal key (Key.char 'Y') -> Action `Copy
  | [ key ] when Key.equal key (Key.char 'y') -> Prefix
  | [ y; key ] when Key.equal y (Key.char 'y') && Key.equal key (Key.char 'y') ->
    Action `Copy
  | keys when is_edit keys -> Action `Edit
  | _ -> Unbound
;;

(* {1 Actions} *)

let move t ~width ~rows:viewport (motion : Motion.t) =
  let rows = layout t ~width in
  let line = line_of t t.cursor in
  let positions = Line.positions line in
  let index =
    Array.findi positions ~f:(fun _ p -> p = t.cursor) |> Option.value_map ~default:0 ~f:fst
  in
  let r = cursor_row t rows in
  let col = Option.value t.want ~default:(column_in rows.(r) t.cursor) in
  let last_row = Array.length rows - 1 in
  let to_row r' = { t with cursor = position_in t rows.(r') col; want = Some col } in
  let horizontal cursor = { t with cursor; want = None } in
  let half = Int.max 1 (Int.max 1 viewport / 2) in
  match motion with
  | Left -> horizontal positions.(Int.max 0 (index - 1))
  | Right -> horizontal positions.(Int.min (Array.length positions - 1) (index + 1))
  | Line_start -> horizontal positions.(0)
  | Line_end -> horizontal (Array.last_exn positions)
  | First_nonblank ->
    horizontal
      (Array.find positions ~f:(fun p ->
         Option.exists (Line.glyph_at line p) ~f:(fun g -> not (Line.is_blank g)))
       |> Option.value ~default:(Array.last_exn positions))
  | Word_forward -> horizontal (word t ~forward:true)
  | Word_backward -> horizontal (word t ~forward:false)
  | Down -> to_row (Int.min last_row (r + 1))
  | Up -> to_row (Int.max 0 (r - 1))
  | Half_down | Half_up ->
    let delta = if Motion.equal motion Half_down then half else -half in
    let maximum = Int.max 0 (Array.length rows - Int.max 1 viewport) in
    { (to_row (Int.clamp_exn (r + delta) ~min:0 ~max:last_row)) with
      top = Int.clamp_exn (t.top + delta) ~min:0 ~max:maximum
    }
  | First -> { t with cursor = position_in t rows.(0) 0; want = None }
  | Last -> { t with cursor = position_in t rows.(last_row) 0; want = None }
;;

let perform t ~width ~rows action =
  let t = fit t ~width ~rows in
  let t, effect =
    match (action : Action.t) with
    | Move motion -> move t ~width ~rows motion, None
    | Visual kind ->
      ( (match t.visual with
         | Some (current, _) when Kind.equal current kind -> { t with visual = None }
         | Some (_, anchor) -> { t with visual = Some (kind, anchor) }
         | None -> { t with visual = Some (kind, t.cursor) })
      , None )
    | Swap_ends ->
      ( (match t.visual with
         | Some (kind, anchor) ->
           { t with visual = Some (kind, t.cursor); cursor = anchor; want = None }
         | None -> t)
      , None )
    | Exit_visual -> { t with visual = None }, None
    | Yank -> yank t
    | Yank_line ->
      let i = line_index t t.cursor in
      let line = t.lines.(i) in
      t, Some (Effect.Copy (linewise (String.sub t.text ~pos:line.start ~len:line.length)))
    | Edit -> t, Some (Notice read_only)
  in
  fit t ~width ~rows, effect
;;

let update t text =
  if String.equal text t.text
  then t, `Same
  else (
    let rows = layout t ~width:Int.max_value in
    let line = line_index t t.cursor in
    let col = column_in rows.(line) t.cursor in
    let fresh = { (create ~cell_width:t.cell_width text) with top = t.top } in
    let row = (layout fresh ~width:Int.max_value).(Int.min line (last_line fresh)) in
    { fresh with cursor = position_in fresh row col }, `Changed (Option.is_some t.visual))
;;
