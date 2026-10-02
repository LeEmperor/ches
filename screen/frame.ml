open! Core
open Ches_core
open Ches_app

module Span = Span

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
      ; status = _
      ; offset = _
      ; areas
      }
    =
    geometry
  in
  let fields = Status.fields ui in
  let area_on_row layout y =
    List.find areas ~f:(fun { rect; layout = l; _ } ->
      Geometry.Area.equal_layout l layout && y >= rect.y && y < rect.y + rect.height)
  in
  let rule n = String.concat (List.init n ~f:(fun _ -> "─")) in
  let tile_row y =
    let inner = viewport.width + gutter.width in
    if border && y = tile.y
    then (
      let top =
        match area_on_row Border_title y with
        | Some area -> Status.render area fields
        | None -> [ Span.create Border (rule inner) ~width:inner ]
      in
      [ Span.create Border "╭" ~width:1 ] @ top @ [ Span.create Border "╮" ~width:1 ])
    else if border && y = tile.y + tile.height - 1
    then [ Span.create Border ("╰" ^ rule inner ^ "╯") ~width:(inner + 2) ]
    else (
      let line = scroll.top + (y - viewport.y) in
      let on_cursor_line = line = cursor_line in
      let exists = line < line_count in
      let gutter_spans =
        if gutter.width = 0
        then []
        else if not exists
        then [ Span.blank Gutter gutter.width ]
        else
          [ Span.create
              (if on_cursor_line then Gutter_cursor_line else Gutter)
              (Line_numbers.label
                 (Ui_state.prefs ui).line_numbers
                 ~digits:gutter_digits
                 ~line
                 ~cursor_line)
              ~width:gutter.width
          ]
      in
      let text_spans =
        if not exists
        then [ Span.blank Text viewport.width ]
        else (
          let text_style, special_style =
            if on_cursor_line
            then Style.Text_cursor_line, Style.Special_cursor_line
            else Text, Special
          in
          Span.of_glyphs
            (Cell_map.glyphs (Text_buffer.line_text text line))
            ~left:scroll.left
            ~cols:viewport.width
            ~text:text_style
            ~special:special_style)
      in
      let side = if border then [ Span.create Border "│" ~width:1 ] else [] in
      side @ gutter_spans @ text_spans @ side)
  in
  let rows =
    List.init height ~f:(fun y ->
      let row (rect : Geometry.Rect.t) spans =
        Span.merge
          ([ Span.blank Backdrop rect.x ]
           @ spans
           @ [ Span.blank Backdrop (width - rect.x - rect.width) ])
      in
      match area_on_row Status_row y with
      | Some area -> row area.rect (Status.render area fields)
      | None -> row tile (tile_row y))
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
