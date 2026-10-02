open! Core
open Ches_core
open Ches_input
open Ches_app

module Span = struct
  type t =
    { text : string
    ; width : int
    ; style : Style.t
    }
  [@@deriving sexp_of]
end

module Cursor = struct
  type shape =
    | Block
    | Bar
  [@@deriving sexp_of, equal]

  type t =
    { x : int
    ; y : int
    ; shape : shape
    }
  [@@deriving sexp_of, equal]
end

type t =
  { width : int
  ; height : int
  ; rows : Span.t list list
  ; cursor : Cursor.t option
  }
[@@deriving sexp_of]

let span style text ~width = { Span.text; width; style }
let blank style width = span style (String.make width ' ') ~width

(* Joins adjacent spans of the same style and drops empty ones. *)
let merge spans =
  List.fold spans ~init:[] ~f:(fun acc (s : Span.t) ->
    match acc with
    | _ when String.is_empty s.text -> acc
    | (prev : Span.t) :: rest when Style.equal prev.style s.style ->
      { prev with text = prev.text ^ s.text; width = prev.width + s.width } :: rest
    | _ -> s :: acc)
  |> List.rev
;;

(* The cells [left, left + cols) of a line laid out as [glyphs], exactly [cols] wide. *)
let clip_line glyphs ~left ~cols ~(text : Style.t) ~(special : Style.t) =
  let right = left + cols in
  let spans, _attachable =
    Array.fold
      glyphs
      ~init:([], false)
      ~f:
        (fun
          (spans, attachable)
          ({ col; width; text = s; kind; _ } : Cell_map.Glyph.t)
        ->
        let stop = col + width in
        let style : Style.t =
          match kind with
          | Escape -> special
          | Plain | Tab -> text
        in
        if width = 0
        then
          (* Attach to the preceding cell when that cell was drawn as itself. *)
          if attachable then span text s ~width:0 :: spans, true else spans, false
        else if stop <= left || col >= right
        then spans, false
        else if col >= left && stop <= right
        then span style s ~width :: spans, Cell_map.Kind.equal kind Plain
        else (
          let first = Int.max col left in
          let visible = Int.min stop right - first in
          let clipped =
            match kind with
            | Tab -> blank text visible
            | Escape ->
              span
                special
                (String.sub s ~pos:(first - col) ~len:visible)
                ~width:visible
            | Plain ->
              (* A wide character cut by an edge. *)
              span special (if col < left then "<" else ">") ~width:visible
          in
          clipped :: spans, false))
  in
  let used = List.sum (module Int) spans ~f:(fun s -> s.width) in
  List.rev (blank text (cols - used) :: spans) |> merge
;;

(* [s] drawn in [style], with escape forms in [special]. *)
let text_spans s ~style ~special =
  let glyphs = Cell_map.glyphs s in
  clip_line glyphs ~left:0 ~cols:(Cell_map.total_width glyphs) ~text:style ~special
;;

let spans_width spans = List.sum (module Int) spans ~f:(fun (s : Span.t) -> s.width)

(* The last [n] cells of [spans] (a single line of text), marked with [<] when cut. *)
let keep_right spans ~n ~marker_style =
  let total = spans_width spans in
  if total <= n
  then spans
  else if n <= 0
  then []
  else (
    let rec drop spans k =
      (* Drop [k] cells from the left. *)
      match spans with
      | [] -> []
      | (s : Span.t) :: rest ->
        if k <= 0
        then spans
        else if s.width <= k
        then drop rest (k - s.width)
        else (
          (* Keep the whole glyphs after the cut; a glyph cut in two becomes spaces.
             Span text is already mapped, so mapping it again changes nothing. *)
          let kept = Array.filter (Cell_map.glyphs s.text) ~f:(fun g -> g.col >= k) in
          let first = if Array.is_empty kept then s.width else kept.(0).col in
          blank s.style (first - k)
          :: span
               s.style
               (String.concat_array (Array.map kept ~f:(fun g -> g.text)))
               ~width:(s.width - first)
          :: rest)
    in
    span marker_style "<" ~width:1 :: drop spans (total - n + 1) |> merge)
;;

(* The first [n] cells of [spans], marked with [>] when cut. *)
let keep_left spans ~n ~marker_style =
  let total = spans_width spans in
  if total <= n
  then spans
  else if n <= 0
  then []
  else (
    let rec take spans k =
      match spans with
      | [] -> []
      | (s : Span.t) :: rest ->
        if k <= 0
        then []
        else if s.width <= k
        then s :: take rest (k - s.width)
        else (
          let glyphs = Cell_map.glyphs s.text in
          let kept = Array.filter glyphs ~f:(fun g -> g.col + g.width <= k) in
          let kept_width = Cell_map.total_width kept in
          [ span
              s.style
              (String.concat_array (Array.map kept ~f:(fun g -> g.text)))
              ~width:kept_width
          ; blank s.style (k - kept_width)
          ])
    in
    take spans (n - 1) @ [ span marker_style ">" ~width:1 ] |> merge)
;;

module Field = struct
  type fit =
    | Whole (** Shown completely or not at all. *)
    | Cut_left (** Keeps its end, marked with [<]. *)
    | Cut_right (** Keeps its start, marked with [>]. *)

  type t =
    { spans : Span.t list
    ; fit : fit
    }
end

(* Fields that are shown cut must keep at least this many cells. *)
let min_cut_width = 4

let status_line ui ~width =
  let editor = Controller.editor (Ui_state.controller ui) in
  let keymap = Controller.keymap (Ui_state.controller ui) in
  let mode = Editor.mode editor in
  let badge =
    let label = sprintf " %s " (Mode.to_string mode) in
    span
      (Mode mode)
      (String.prefix label width)
      ~width:(Int.min width (String.length label))
  in
  let field fit spans = Some { Field.spans; fit } in
  let message =
    Option.map (Ui_state.message ui) ~f:(fun { kind; text } ->
      ( kind
      , { Field.spans =
            text_spans
              text
              ~style:
                (match kind with
                 | Info -> Info
                 | Warning -> Warning
                 | Error -> Error)
              ~special:Status_special
        ; fit = Cut_right
        } ))
  in
  let error_message, other_message =
    match message with
    | Some (Error, f) -> Some f, None
    | Some ((Info | Warning), f) -> None, Some f
    | None -> None, None
  in
  let filename =
    Option.bind (Editor.path editor) ~f:(fun path ->
      field Cut_left (text_spans path ~style:Status ~special:Status_special))
  in
  let dirty =
    if Editor.is_dirty editor then field Whole [ span Dirty "[+]" ~width:3 ] else None
  in
  let pending =
    Option.bind (Keymap.pending keymap) ~f:(fun keys ->
      field Whole (text_spans keys ~style:Pending ~special:Status_special))
  in
  let position =
    let s =
      sprintf "%d:%d" (Editor.cursor_line editor + 1) (Editor.cursor_column editor + 1)
    in
    field Whole [ span Status s ~width:(String.length s) ]
  in
  (* Allocate space in priority order. Each field also takes a separator before it,
     and one cell is kept free at the right end. Once a field does not fit, every
     field of lower priority is dropped too, so fields disappear strictly by priority
     as the line narrows. *)
  let by_priority =
    [ `Error, error_message
    ; `Pending, pending
    ; `Dirty, dirty
    ; `Position, position
    ; `Filename, filename
    ; `Other, other_message
    ]
  in
  let shown =
    List.fold_until
      by_priority
      ~init:([], width - badge.width - 1)
      ~f:(fun (shown, remaining) (key, field) ->
        match field with
        | None -> Continue (shown, remaining)
        | Some { Field.spans; fit } ->
          let available = remaining - 1 in
          if spans_width spans <= available
          then Continue ((key, spans) :: shown, available - spans_width spans)
          else (
            match fit with
            | Whole -> Stop shown
            | (Cut_left | Cut_right) when available < min_cut_width -> Stop shown
            | Cut_left ->
              Stop
                ((key, keep_right spans ~n:available ~marker_style:Status_special)
                 :: shown)
            | Cut_right ->
              Stop
                ((key, keep_left spans ~n:available ~marker_style:Status_special)
                 :: shown)))
      ~finish:fst
  in
  let fields keys =
    List.concat_map keys ~f:(fun key ->
      match List.Assoc.find shown key ~equal:Poly.equal with
      | None -> []
      | Some spans -> blank Status 1 :: spans)
  in
  let left = badge :: fields [ `Filename; `Dirty; `Error; `Other ] in
  let right =
    fields [ `Pending; `Position ]
    @ if width > badge.width then [ blank Status 1 ] else []
  in
  let fill = width - spans_width left - spans_width right in
  merge (left @ [ blank Status fill ] @ right)
;;

let render ui ~width ~height =
  let width = Int.max 0 width
  and height = Int.max 0 height in
  let editor = Controller.editor (Ui_state.controller ui) in
  let text = Editor.text editor in
  let line_count = Text_buffer.line_count text in
  let cursor_line = Editor.cursor_line editor in
  let geometry = Ui_state.geometry ui ~width ~height in
  let scroll = Ui_state.fitted_scroll ui ~width ~height in
  let { Geometry.tile
      ; border
      ; gutter
      ; gutter_digits
      ; text = viewport
      ; status
      ; offset = _
      }
    =
    geometry
  in
  let tile_row y =
    let inner = viewport.width + gutter.width in
    if border && y = tile.y
    then
      [ span
          Border
          ("┌" ^ String.concat (List.init inner ~f:(fun _ -> "─")) ^ "┐")
          ~width:(inner + 2)
      ]
    else if border && y = tile.y + tile.height - 1
    then
      [ span
          Border
          ("└" ^ String.concat (List.init inner ~f:(fun _ -> "─")) ^ "┘")
          ~width:(inner + 2)
      ]
    else (
      let line = scroll.top + (y - viewport.y) in
      let on_cursor_line = line = cursor_line in
      let exists = line < line_count in
      let gutter_spans =
        if gutter.width = 0
        then []
        else if not exists
        then [ blank Gutter gutter.width ]
        else
          [ span
              (if on_cursor_line then Gutter_cursor_line else Gutter)
              (sprintf "%*d " gutter_digits (line + 1))
              ~width:gutter.width
          ]
      in
      let text_spans =
        if not exists
        then [ blank Text viewport.width ]
        else (
          let text_style, special_style =
            if on_cursor_line
            then Style.Text_cursor_line, Style.Special_cursor_line
            else Text, Special
          in
          clip_line
            (Cell_map.glyphs (Text_buffer.line_text text line))
            ~left:scroll.left
            ~cols:viewport.width
            ~text:text_style
            ~special:special_style)
      in
      let side = if border then [ span Border "│" ~width:1 ] else [] in
      side @ gutter_spans @ text_spans @ side)
  in
  let rows =
    List.init height ~f:(fun y ->
      if y >= status.y
      then status_line ui ~width
      else
        merge
          ([ blank Backdrop tile.x ]
           @ tile_row y
           @ [ blank Backdrop (width - tile.x - tile.width) ]))
  in
  let cursor =
    let line_text = Text_buffer.line_text text cursor_line in
    let start, _ =
      Cell_map.cursor_span
        (Cell_map.glyphs line_text)
        ~pos:(Editor.cursor editor - Text_buffer.line_start text cursor_line)
        ~insertion:true
    in
    let x = start - scroll.left
    and y = cursor_line - scroll.top in
    if x >= 0 && x < viewport.width && y >= 0 && y < viewport.height
    then
      Some
        { Cursor.x = viewport.x + x
        ; y = viewport.y + y
        ; shape =
            (match Editor.mode editor with
             | Normal -> Block
             | Insert -> Bar)
        }
    else None
  in
  { width; height; rows; cursor }
;;

let to_string t =
  let rows =
    List.map t.rows ~f:(fun spans ->
      String.concat (List.map spans ~f:(fun (s : Span.t) -> s.text)) ^ "|")
  in
  let cursor =
    match t.cursor with
    | None -> "cursor: none"
    | Some { x; y; shape } -> sprintf !"cursor: %d,%d %{sexp:Cursor.shape}" x y shape
  in
  String.concat ~sep:"\n" (rows @ [ cursor ])
;;

let to_string_styled t =
  List.map t.rows ~f:(fun spans ->
    String.concat
      ~sep:" "
      (List.map spans ~f:(fun (s : Span.t) ->
         sprintf !"%{sexp:Style.t}[%s]" s.style s.text)))
  |> String.concat ~sep:"\n"
;;
